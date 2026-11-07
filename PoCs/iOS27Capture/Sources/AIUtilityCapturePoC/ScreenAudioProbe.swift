#if os(iOS) && canImport(ScreenCaptureKit)
import Foundation
import Combine
import AudioToolbox
import AVFoundation
@preconcurrency import ScreenCaptureKit

public struct CaptureMetrics: Sendable {
    public let audioBuffers: Int
    public let audioSamples: Int
    public let sampleRate: Double
    public let channels: UInt32
    public let rms: Double?
}

@available(iOS 27.0, *)
private final class CaptureOutput: NSObject, SCStreamOutput, @unchecked Sendable {
    let speech: SpeechAudioSink
    let publish: @Sendable (CaptureMetrics) -> Void
    // Confined to the serial sampleHandlerQueue.
    private var buffers = 0
    private var samples = 0
    init(speech: SpeechAudioSink, publish: @escaping @Sendable (CaptureMetrics) -> Void) {
        self.speech = speech; self.publish = publish
    }
    func stream(_ stream: SCStream, didOutputSampleBuffer buffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio, CMSampleBufferIsValid(buffer), CMSampleBufferDataIsReady(buffer) else { return }
        buffers += 1; samples += CMSampleBufferGetNumSamples(buffer)
        speech.append(buffer)
        if buffers == 1 || buffers % 30 == 0 {
            let description = CMSampleBufferGetFormatDescription(buffer).flatMap { CMAudioFormatDescriptionGetStreamBasicDescription($0) }?.pointee
            publish(CaptureMetrics(audioBuffers: buffers, audioSamples: samples,
                sampleRate: description?.mSampleRate ?? 0, channels: description?.mChannelsPerFrame ?? 0,
                rms: Self.rms(buffer, format: description)))
        }
    }
    private static func rms(_ sample: CMSampleBuffer, format: AudioStreamBasicDescription?) -> Double? {
        guard let format, format.mFormatID == kAudioFormatLinearPCM,
              format.mBitsPerChannel == 32, format.mFormatFlags & kAudioFormatFlagIsFloat != 0 else { return nil }
        var needed = 0
        CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(sample, bufferListSizeNeededOut: &needed,
            bufferListOut: nil, bufferListSize: 0, blockBufferAllocator: nil, blockBufferMemoryAllocator: nil,
            flags: 0, blockBufferOut: nil)
        guard needed >= MemoryLayout<AudioBufferList>.size else { return nil }
        let memory = UnsafeMutableRawPointer.allocate(byteCount: needed, alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { memory.deallocate() }
        let list = memory.bindMemory(to: AudioBufferList.self, capacity: 1)
        var retained: CMBlockBuffer?
        guard CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(sample, bufferListSizeNeededOut: nil,
            bufferListOut: list, bufferListSize: needed, blockBufferAllocator: nil, blockBufferMemoryAllocator: nil,
            flags: 0, blockBufferOut: &retained) == noErr else { return nil }
        var sum = 0.0; var count = 0
        for audio in UnsafeMutableAudioBufferListPointer(list) {
            guard let data = audio.mData else { continue }
            let values = data.assumingMemoryBound(to: Float.self)
            for index in 0..<(Int(audio.mDataByteSize) / 4) {
                let value = Double(values[index]); sum += value * value; count += 1
            }
        }
        return count > 0 ? sqrt(sum / Double(count)) : nil
    }
}

@available(iOS 27.0, *)
@MainActor public final class ScreenAudioProbe: NSObject, ObservableObject {
    @Published public private(set) var state = "未验证：等待系统选择器"
    @Published public private(set) var metrics: CaptureMetrics?
    private var stream: SCStream?
    private var output: CaptureOutput?
    private let speech: LocalSpeechProbe
    private let queue = DispatchQueue(label: "com.aiutility.poc.audio")
    private let lifecycle = ProbeLifecycle()
    private var callbacks: CaptureCallbacks?
    private var starting = false
    private var startTask: Task<Void, Never>?
    var isStopped: Bool { lifecycle.phase == .idle }
    var onTermination: (() async -> Void)?
    public init(speech: LocalSpeechProbe) { self.speech = speech; super.init() }
    public func presentPicker() {
        guard let session = lifecycle.begin() else { return }
        metrics = nil
        let callbacks = CaptureCallbacks(owner: self, session: session)
        self.callbacks = callbacks
        let picker = SCContentSharingPicker.shared
        var configuration = SCContentSharingPickerConfiguration()
        configuration.showsMicrophoneControl = false
        configuration.showsCameraControl = false
        picker.defaultConfiguration = configuration
        picker.add(callbacks); picker.isActive = true
        state = "请选择整个屏幕；本操作需要系统授权"
        picker.present()
    }
    fileprivate func update(filter: SCContentFilter, stream source: ObjectIdentifier?, session: UInt64) {
        guard lifecycle.accepts(session), source == nil || source == stream.map(ObjectIdentifier.init), !starting else { return }
        if stream != nil {
            // SCStream.updateContentFilter is unavailable on iOS (iOS 27.1 SDK); ignore range changes while capturing.
            state = "采集中忽略范围更新；如需更换范围请先停止"
            return
        }
        starting = true
        startTask = Task { @MainActor [weak self] in await self?.start(filter: filter, session: session) }
    }
    private func start(filter: SCContentFilter, session: UInt64) async {
        guard lifecycle.accepts(session) else { return }
        defer { if lifecycle.revision == session { starting = false } }
        let configuration = SCStreamConfiguration()
        configuration.capturesAudio = true
        configuration.excludesCurrentProcessAudio = true
        configuration.sampleRate = 48_000
        configuration.channelCount = 1
        configuration.width = 16; configuration.height = 16
        // minimumFrameInterval is unavailable on iOS (iOS 27.1 SDK); screen frames are discarded anyway.
        let output = CaptureOutput(speech: speech.sink) { [weak self] metrics in
            Task { @MainActor [weak self] in
                guard let self, self.lifecycle.accepts(session) else { return }
                self.metrics = metrics
            }
        }
        let stream = SCStream(filter: filter, configuration: configuration, delegate: callbacks)
        self.output = output; self.stream = stream
        do {
            // iOS sample uses a screen output on every stream. Screen frames are discarded.
            try stream.addStreamOutput(output, type: .screen, sampleHandlerQueue: queue)
            try stream.addStreamOutput(output, type: .audio, sampleHandlerQueue: queue)
            try await stream.startCapture()
            // stop() owns this stream and waits for this task before stopping it exactly once.
            guard lifecycle.accepts(session), !Task.isCancelled else { return }
            lifecycle.didStart(session)
            state = "startCapture 已返回；跨 App 音频仍需核验"
        } catch {
            // Do not await our own startTask from inside it. A separate termination task owns cleanup.
            Task { @MainActor [weak self] in
                await self?.terminate(session: session, source: nil, message: "采集启动失败；检查权限、SDK 和签名")
            }
        }
    }
    public func stop() async {
        await lifecycle.stop { [self] in await release() }
    }
    private func release() async -> Bool {
        let picker = SCContentSharingPicker.shared
        if let callbacks { picker.remove(callbacks) }
        picker.isActive = false
        let pendingStart = startTask
        let stoppingStream = stream
        let stoppingOutput = output
        let stoppingCallbacks = callbacks
        startTask = nil
        pendingStart?.cancel()
        await pendingStart?.value
        if let stoppingStream {
            do { try await stoppingStream.stopCapture() }
            catch {
                // Keep ownership and block a replacement stream until an explicit stop retry succeeds.
                state = "stopCapture 返回错误；禁止重新开始，请再次停止或结束 App，勿认定系统已释放"
                return false
            }
        }
        withExtendedLifetime((stoppingOutput, stoppingCallbacks)) {}
        stream = nil; output = nil; callbacks = nil
        starting = false
        state = "已停止；无真机结论"
        return true
    }
    fileprivate func terminate(session: UInt64, source: ObjectIdentifier?, message: String) async {
        guard lifecycle.accepts(session), source == nil || source == stream.map(ObjectIdentifier.init) else { return }
        let notify = onTermination
        await stop()
        // stop() keeps restart blocked until release finishes. No stale callback may stop a newer session.
        guard lifecycle.revision == session else { return }
        await notify?()
        if lifecycle.revision == session, lifecycle.phase == .idle { state = message }
    }
}

/// A distinct observer/delegate per session carries the identity even for picker callbacks with nil streams.
@available(iOS 27.0, *)
@MainActor private final class CaptureCallbacks: NSObject, SCContentSharingPickerObserver, SCStreamDelegate {
    private weak var owner: ScreenAudioProbe?
    private let session: UInt64
    @MainActor init(owner: ScreenAudioProbe, session: UInt64) {
        self.owner = owner; self.session = session
    }
    nonisolated func contentSharingPicker(_ picker: SCContentSharingPicker, didUpdateWith filter: SCContentFilter, for stream: SCStream?) {
        let identity = stream.map(ObjectIdentifier.init)
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.owner?.update(filter: filter, stream: identity, session: self.session)
        }
    }
    nonisolated func contentSharingPicker(_ picker: SCContentSharingPicker, didCancelFor stream: SCStream?) {
        terminate(stream: stream, message: "系统选择器已取消")
    }
    nonisolated func contentSharingPickerStartDidFailWithError(_ error: Error) {
        terminate(stream: nil, message: "系统选择器启动失败")
    }
    nonisolated func stream(_ stream: SCStream, didStopWithError error: Error) {
        terminate(stream: stream, message: "系统终止采集；需人工检查中断原因")
    }
    nonisolated private func terminate(stream: SCStream?, message: String) {
        let identity = stream.map(ObjectIdentifier.init)
        Task { @MainActor [weak self] in
            guard let self else { return }
            await self.owner?.terminate(session: self.session, source: identity, message: message)
        }
    }
}
#endif
