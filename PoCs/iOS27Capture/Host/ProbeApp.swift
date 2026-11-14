import SwiftUI
import UIKit
import AIUtilityCapturePoC

@main struct ProbeApp: App {
    var body: some Scene { WindowGroup { ProbeView() } }
}

// ScreenCaptureKit is only importable from the iphoneos SDK; the iphonesimulator SDK does not
// provide it, so PoCSession / ScreenAudioProbe are compiled out there. The device build keeps the
// full capture UI unchanged; the simulator build only gets a placeholder so the target compiles.
#if !targetEnvironment(simulator) && !canImport(ScreenCaptureKit)
#error("iphoneos must compile the real ScreenCaptureKit probe; a device placeholder is forbidden")
#elseif canImport(ScreenCaptureKit)
@available(iOS 27.0, *)
@MainActor struct ProbeView: View {
    @StateObject private var session = PoCSession()
    @State private var error = "未进行真机验证。本诊断入口只做本地英文 ASR；不含 API Key。"
    var body: some View {
        ProbeControls(session: session, speech: session.speech, capture: session.capture, pip: session.pip, error: $error)
    }
}

@available(iOS 27.0, *)
@MainActor private struct ProbeControls: View {
    @ObservedObject var session: PoCSession
    @ObservedObject var speech: LocalSpeechProbe
    @ObservedObject var capture: ScreenAudioProbe
    @ObservedObject var pip: SubtitlePiPProbe
    @Binding var error: String
    var body: some View {
        VStack(spacing: 12) {
            Text("AIUtility 技术诊断 · 未验收")
            Text(error).font(.caption)
            Text(capture.state); Text(speech.state); Text(pip.state)
            Text(session.translationState)
            if let metrics = capture.metrics {
                Text("音频缓冲 \(metrics.audioBuffers) / 样本 \(metrics.audioSamples) / \(Int(metrics.sampleRate)) Hz / RMS \(metrics.rms.map { String(format: "%.5f", $0) } ?? "格式不支持")")
            }
            Text(speech.caption)
            LayerPreview(pip: pip).frame(height: 120)
            Button("授权并采集") { Task { do { try await session.start() } catch { self.error = "启动失败；请检查设备能力、权限及签名" } } }
            Button("开始 PiP") { do { try pip.start() } catch { self.error = "PiP 尚不可用；检查预览层和后台模式" } }
            Button("停止") { Task { await session.stop() } }
        }
        .padding()
        .onChange(of: speech.caption) { _, text in pip.caption = text }
    }
}

@available(iOS 27.0, *)
private struct LayerPreview: UIViewRepresentable {
    let pip: SubtitlePiPProbe
    func makeUIView(context: Context) -> PreviewView { let view = PreviewView(); view.layer.addSublayer(pip.displayLayer); return view }
    func updateUIView(_ uiView: PreviewView, context: Context) {}
    final class PreviewView: UIView {
        override func layoutSubviews() { super.layoutSubviews(); layer.sublayers?.forEach { $0.frame = bounds } }
    }
}
#else
@MainActor struct ProbeView: View {
    var body: some View {
        VStack(spacing: 12) {
            Text("AIUtility 技术诊断 · 未验收")
            Text("当前 SDK 不提供 ScreenCaptureKit（如 iOS Simulator）。跨 App 音频采集只能在 iphoneos 构建与真机上运行；本占位界面不代表任何采集能力。")
                .font(.caption)
        }
        .padding()
    }
}
#endif
