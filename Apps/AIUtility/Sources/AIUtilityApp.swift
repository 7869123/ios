import SwiftUI
import UIKit
import AIUtilityCore
import AIUtilityAppleServices

@main @MainActor struct AIUtilityApp: App {
    @StateObject private var model = AppModel()
    @State private var wallpaper = WallpaperStore()
    var body: some Scene {
        WindowGroup {
            RootView().environmentObject(model).environment(wallpaper).tint(UtilityTheme.cyan).preferredColorScheme(.light)
            #if DEBUG
                .task { Self.applyReviewOrientation() }
            #endif
        }
    }
}

#if DEBUG
extension AIUtilityApp {
    /// CI review screenshots only: `-AIUtilityPreviewLandscape` rotates the simulator to landscape.
    static func applyReviewOrientation() {
        guard ProcessInfo.processInfo.arguments.contains("-AIUtilityPreviewLandscape"),
              let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene else { return }
        scene.requestGeometryUpdate(.iOS(interfaceOrientations: .landscapeRight))
    }
}
#endif

/// A single composition root keeps the shared key coordinator and session budget alive.
@MainActor final class AppModel: ObservableObject {
    let services = AIUtilityServices()
    @Published var screenshotDraft = ""
    @Published var subtitleDraft = ""
    @Published var screenshotProvider: ProviderID {
        didSet { UserDefaults.standard.set(screenshotProvider.rawValue, forKey: "screenshotProvider") }
    }
    @Published var subtitleProvider: ProviderID {
        didSet { UserDefaults.standard.set(subtitleProvider.rawValue, forKey: "subtitleProvider") }
    }
    init() {
        screenshotProvider = ProviderID(rawValue: UserDefaults.standard.string(forKey: "screenshotProvider") ?? "") ?? .openAI
        subtitleProvider = ProviderID(rawValue: UserDefaults.standard.string(forKey: "subtitleProvider") ?? "") ?? .openAI
    }
}

extension ProviderID {
    var title: String {
        switch self { case .openAI: "OpenAI"; case .anthropic: "Anthropic"; case .deepSeek: "DeepSeek" }
    }
}

enum TranslationLanguage: String, CaseIterable, Identifiable {
    case chinese = "简体中文", english = "English", japanese = "日本語", korean = "한국어"
    var id: String { rawValue }
}

enum UserFacingError {
    static func text(_ error: any Error) -> String {
        switch AIUtilityError.sanitized(error) {
        case .notConfigured: "请先在设置中保存此供应商的 Key 并绑定模型。"
        case .invalidCredential, .unauthorized: "Key 无效或已失效，请在设置中检查。原配置未被替换。"
        case .modelUnavailable: "该模型不可用或没有访问权限，请重新选择。"
        case .forbidden: "供应商拒绝访问，请检查账户权限。"
        case .invalidRequest: "输入或模型参数无效，请检查后重试。"
        case .quotaExceeded: "供应商额度不足，请检查账户余额。"
        case .rateLimited, .overloaded: "供应商繁忙或触发限流，请稍后重试。"
        case .timeout: "请求超时；远端可能已执行，未自动重试。"
        case .cancelled: "操作已取消。"
        case .budgetExceeded: "本次应用会话的调用预算已用尽。"
        case .configurationBusy: "该供应商已有配置验证正在进行。"
        case .storageFailure: "Keychain 当前不可访问或保存失败，原记录保持不变。"
        case .outputTruncated: "响应被截断，未作为成功结果使用。"
        case .contentRejected: "供应商拒绝生成此内容。"
        case .privacyViolation: "敏感信息占位符被改写，已拒绝该结果。"
        default: "操作未完成，请检查网络和配置后重试。"
        }
    }
}
