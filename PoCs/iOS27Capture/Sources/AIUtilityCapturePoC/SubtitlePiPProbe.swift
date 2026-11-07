#if os(iOS)
import UIKit
import Combine
import AVKit
import AVFoundation

/// Renders changing caption pixels into real video sample buffers for AVKit PiP.
/// This probes platform behavior; it does not claim approval for a subtitle-only shipping app.
@available(iOS 27.0, *)
@MainActor public final class SubtitlePiPProbe: NSObject, ObservableObject,
    AVPictureInPictureSampleBufferPlaybackDelegate, AVPictureInPictureControllerDelegate {
    public let displayLayer = AVSampleBufferDisplayLayer()
    @Published public private(set) var state = "未验证"
    public var caption = "AIUtility 字幕技术验证"
    private var controller: AVPictureInPictureController?
    private var timer: Timer?
    private var timebase: CMTimebase?
    public override init() { super.init(); displayLayer.videoGravity = .resizeAspect }
    public func prepare() throws {
        guard AVPictureInPictureController.isPictureInPictureSupported() else { throw ProbeError.pictureInPictureUnavailable }
        let audio = AVAudioSession.sharedInstance()
        try audio.setCategory(.playback, mode: .moviePlayback, options: [.mixWithOthers])
        try audio.setActive(true)
        var timebase: CMTimebase?
        guard CMTimebaseCreateWithSourceClock(allocator: kCFAllocatorDefault,
            sourceClock: CMClockGetHostTimeClock(), timebaseOut: &timebase) == noErr,
            let timebase else { throw ProbeError.frameCreationFailed }
        CMTimebaseSetTime(timebase, time: .zero); CMTimebaseSetRate(timebase, rate: 1)
        self.timebase = timebase; displayLayer.controlTimebase = timebase
        let source = AVPictureInPictureController.ContentSource(sampleBufferDisplayLayer: displayLayer, playbackDelegate: self)
        controller = AVPictureInPictureController(contentSource: source)
        controller?.delegate = self
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                do { try self?.renderFrame() } catch { self?.state = "字幕帧生成失败" }
            }
        }
        try renderFrame()
        state = "已准备；请等待 isPictureInPicturePossible"
    }
    public func start() throws {
        guard controller?.isPictureInPicturePossible == true else { throw ProbeError.pictureInPictureUnavailable }
        controller?.startPictureInPicture(); state = "已请求 PiP；等待系统回调"
    }
    public func stop() {
        controller?.stopPictureInPicture(); timer?.invalidate(); timer = nil
        displayLayer.flushAndRemoveImage()
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        state = "已停止；无真机结论"
    }
    private func renderFrame() throws {
        if displayLayer.status == .failed { displayLayer.flush() }
        guard displayLayer.isReadyForMoreMediaData else { return }
        let width = 960, height = 240
        var pixelBuffer: CVPixelBuffer?
        let attributes = [kCVPixelBufferCGImageCompatibilityKey: true, kCVPixelBufferCGBitmapContextCompatibilityKey: true] as CFDictionary
        guard CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA, attributes, &pixelBuffer) == kCVReturnSuccess,
              let pixelBuffer else { throw ProbeError.frameCreationFailed }
        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }
        let bitmap = CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        guard let context = CGContext(data: CVPixelBufferGetBaseAddress(pixelBuffer), width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(pixelBuffer),
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: bitmap) else { throw ProbeError.frameCreationFailed }
        context.setFillColor(UIColor.black.cgColor); context.fill(CGRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height)))
        context.translateBy(x: 0, y: CGFloat(height)); context.scaleBy(x: 1, y: -1)
        UIGraphicsPushContext(context)
        let paragraph = NSMutableParagraphStyle(); paragraph.alignment = .center
        (String(caption.prefix(400)) as NSString).draw(in: CGRect(x: 24, y: 24, width: CGFloat(width - 48), height: CGFloat(height - 48)),
            withAttributes: [.font: UIFont.systemFont(ofSize: 34), .foregroundColor: UIColor.white, .paragraphStyle: paragraph])
        UIGraphicsPopContext()
        var description: CMVideoFormatDescription?
        guard CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: pixelBuffer,
            formatDescriptionOut: &description) == noErr, let description else { throw ProbeError.frameCreationFailed }
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 2),
            presentationTimeStamp: timebase.map { CMTimebaseGetTime($0) } ?? .zero, decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        guard CMSampleBufferCreateReadyWithImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: pixelBuffer,
            formatDescription: description, sampleTiming: &timing, sampleBufferOut: &sample) == noErr,
            let sample else { throw ProbeError.frameCreationFailed }
        displayLayer.enqueue(sample)
    }
    public func pictureInPictureController(_ controller: AVPictureInPictureController, setPlaying playing: Bool) {}
    public func pictureInPictureControllerTimeRangeForPlayback(_ controller: AVPictureInPictureController) -> CMTimeRange {
        CMTimeRange(start: .zero, duration: .positiveInfinity)
    }
    public func pictureInPictureControllerIsPlaybackPaused(_ controller: AVPictureInPictureController) -> Bool { false }
    public func pictureInPictureController(_ controller: AVPictureInPictureController, didTransitionToRenderSize newRenderSize: CMVideoDimensions) {}
    public func pictureInPictureController(_ controller: AVPictureInPictureController, skipByInterval skipInterval: CMTime,
        completion completionHandler: @escaping () -> Void) { completionHandler() }
    public func pictureInPictureControllerDidStartPictureInPicture(_ controller: AVPictureInPictureController) {
        state = "收到 PiP 启动回调；需人工确认跨 App 持续刷新"
    }
    public func pictureInPictureController(_ controller: AVPictureInPictureController, failedToStartPictureInPictureWithError error: Error) {
        state = "PiP 启动失败"
    }
}
#endif
