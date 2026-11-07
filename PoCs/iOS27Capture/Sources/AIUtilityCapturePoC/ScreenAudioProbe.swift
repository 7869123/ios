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
@MainActor public final class ScreenAudioProbe: NSObject, ObservableObject, SCContentSharingPickerObserver, SCStreamDelegate {
    @Published public private(set) var state = "未验证：等待系统选择器"
    @Published public private(set) var metrics: CaptureMetrics?
    private var stream: SCStream?
    private var output: CaptureOutput?
    private let speech: LocalSpeechProbe
    private let queue = DispatchQueue(label: "com.aiutility.poc.audio")
    private var active = false
    private var starting = false
    var onTermination: (() async -> Void)?
    public init(speech: LocalSpeechProbe) { self.speech = speech; super.init() }
    public func presentPicker() {
        guard !active, !starting else { return }
        active = true
        let picker = SCContentSharingPicker.shared
        var configuration = SCContentSharingPickerConfiguration()
        configuration.showsMicrophoneControl = false
        configuration.showsCameraControl = false
        picker.defaultConfiguration = configuration
        picker.add(self); picker.isActive = true
        state = "请选择整个屏幕；本操作需要系统授权"
        picker.present()
    }
    private func start(filter: SCContentFilter) async {
        guard active, !starting else { return }
        if let stream {
            do { try await stream.updateContentFilter(filter) }
            catch { state = "更新采集范围失败" }
            return
        }
        starting = true
        defer { starting = false }
        let configuration = SCStreamConfiguration()
        configuration.capturesAudio = true
        configuration.excludesCurrentProcessAudio = true
        configuration.sampleRate = 48_000
        configuration.channelCount = 1
        configuration.width = 16; configuration.height = 16
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 1)
        let output = CaptureOutput(speech: speech.sink) { [weak self] metrics in
            Task { @MainActor [weak self] in self?.metrics = metrics }
        }
        let stream = SCStream(filter: filter, configuration: configuration, delegate: self)
        self.output = output; self.stream = stream
        do {
            // iOS sample uses a screen output on every stream. Screen frames are discarded.
            try stream.addStreamOutput(output, type: .screen, sampleHandlerQueue: queue)
            try stream.addStreamOutput(output, type: .audio, sampleHandlerQueue: queue)
            try await stream.startCapture()
            guard active else { try? await stream.stopCapture(); return }
            state = "startCapture 已返回；跨 App 音频仍需核验"
        } catch {
            await stop(); await onTermination?()
            state = "采集启动失败；检查权限、SDK 和签名"
        }
    }
    public func stop() async {
        active = false
        let picker = SCContentSharingPicker.shared
        picker.remove(self); picker.isActive = false
        if let stream { try? await stream.stopCapture() }
        stream = nil; output = nil; state = "已停止；无真机结论"
    }
    nonisolated public func contentSharingPicker(_ picker: SCContentSharingPicker, didUpdateWith filter: SCContentFilter, for stream: SCStream?) {
        Task { @MainActor [weak self] in await self?.start(filter: filter) }
    }
    nonisolated public func contentSharingPicker(_ picker: SCContentSharingPicker, didCancelFor stream: SCStream?) {
        Task { @MainActor [weak self] in
            await self?.stop(); await self?.onTermination?()
        }
    }
    nonisolated public func contentSharingPickerStartDidFailWithError(_ error: Error) {
        Task { @MainActor [weak self] in
            await self?.stop(); await self?.onTermination?(); self?.state = "系统选择器启动失败"
        }
    }
    nonisolated public func stream(_ stream: SCStream, didStopWithError error: Error) {
        Task { @MainActor [weak self] in
            guard self?.stream === stream else { return }
            await self?.stop(); await self?.onTermination?(); self?.state = "系统终止采集；需人工检查中断原因"
        }
    }
}
#endif
