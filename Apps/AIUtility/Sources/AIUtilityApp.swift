import SwiftUI
import PhotosUI
import UIKit
import AIUtilityCore
import AIUtilityAppleServices

@main @MainActor struct AIUtilityApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var model = AppModel()
    /// One download manager for the whole app (it owns the on-disk queue).
    @StateObject private var media = MediaModel()
    @State private var wallpaper = WallpaperStore()
    @State private var appearance = AppearanceStore()
    var body: some Scene {
        WindowGroup {
            RootView().environmentObject(model).environmentObject(media).environment(wallpaper).environment(appearance).environment(\.locale, Locale(identifier: "zh_Hans_CN")).tint(UtilityTheme.cyan).preferredColorScheme(appearance.preferredColorScheme)
                .onChange(of: scenePhase, initial: true) { _, phase in model.setForeground(phase == .active) }
            #if DEBUG
                .task {
                    Self.applyReviewOrientation()
                    await Self.captureReviewScreenshot(model: model, media: media, wallpaper: wallpaper, appearance: appearance)
                }
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

    /// CI review screenshots only: `-AIUtilityCapture <name>` renders after the UI settles and writes
    /// Documents/<name>.png plus <name>.txt. Portrait renders the real key window. iPadOS ignores the
    /// orientation request for multitasking apps, so with `-AIUtilityPreviewLandscape` (and the scene
    /// still portrait) the same RootView is rendered in an off-screen window of the swapped size; the
    /// .txt records which mode produced the image. Nothing is rotated after capture.
    static func captureReviewScreenshot(model: AppModel, media: MediaModel, wallpaper: WallpaperStore, appearance: AppearanceStore) async {
        let args = ProcessInfo.processInfo.arguments
        guard let index = args.firstIndex(of: "-AIUtilityCapture"), index + 1 < args.count else { return }
        let name = args[index + 1]
        try? await Task.sleep(for: .seconds(6))
        // Wait (up to ~20 s more) for a laid-out window on slow first launches.
        var found: (UIWindowScene, UIWindow)?
        for _ in 0..<20 {
            if let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first,
               let window = scene.windows.first(where: \.isKeyWindow) ?? scene.windows.first,
               window.bounds.width > 0 {
                found = (scene, window); break
            }
            try? await Task.sleep(for: .seconds(1))
        }
        guard let found else { return }
        let (scene, window) = found
        let wantsLandscape = args.contains("-AIUtilityPreviewLandscape")
        let image: UIImage
        let info: String
        if wantsLandscape && !scene.interfaceOrientation.isLandscape {
            let size = CGSize(width: max(window.bounds.width, window.bounds.height),
                              height: min(window.bounds.width, window.bounds.height))
            let offscreen = UIWindow(windowScene: scene)
            offscreen.frame = CGRect(origin: .zero, size: size)
            offscreen.windowLevel = UIWindow.Level(rawValue: UIWindow.Level.normal.rawValue - 1)
            let host = UIHostingController(rootView: RootView()
                .environmentObject(model).environmentObject(media).environment(wallpaper).environment(appearance)
                .tint(UtilityTheme.cyan).preferredColorScheme(appearance.preferredColorScheme))
            host.traitOverrides.horizontalSizeClass = window.traitCollection.horizontalSizeClass
            offscreen.rootViewController = host
            offscreen.isHidden = false
            try? await Task.sleep(for: .seconds(4))
            image = UIGraphicsImageRenderer(bounds: offscreen.bounds).image { _ in
                _ = offscreen.drawHierarchy(in: offscreen.bounds, afterScreenUpdates: true)
            }
            offscreen.isHidden = true
            info = "mode=offscreen-landscape-layout window=\(Int(size.width))x\(Int(size.height)) (scene stayed portrait; no status bar or safe-area insets)\n"
        } else {
            image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
                _ = window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
            }
            let orientation = scene.interfaceOrientation.isLandscape ? "landscape" : "portrait"
            info = "mode=device window=\(Int(window.bounds.width))x\(Int(window.bounds.height)) orientation=\(orientation)\n"
        }
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        try? image.pngData()?.write(to: documents.appendingPathComponent("\(name).png"))
        try? info.write(to: documents.appendingPathComponent("\(name).txt"), atomically: true, encoding: .utf8)
    }
}
#endif

/// A single composition root keeps the shared key coordinator and session budget alive.
@MainActor final class AppModel: ObservableObject {
    /// Session guard (reset when the app process restarts). Every translation reserves its whole saved output cap
    /// up front, so the token pool is sized for about 16 translations at the suggested 32768 cap instead of 2.
    nonisolated static let sessionAttempts = 100
    nonisolated static let sessionOutputTokens = 524_288
    let services = AIUtilityServices(maxAttempts: AppModel.sessionAttempts,
                                     maxReservedOutputTokens: AppModel.sessionOutputTokens)
    @Published var screenshotDraft = ""
    @Published var subtitleDraft = ""
    /// Page state that must survive a page being rebuilt (sidebar switch, size-class change).
    @Published var screenshot = LoadedScreenshot()
    @Published var translationOutput: [TranslationFeature: String] = [:]
    /// Per-provider Key status, refreshed on every cold start (see KeyHealth.swift).
    @Published var keyStatus: [ProviderID: KeyStatus] = [:]
    @Published var screenshotProvider: ProviderID {
        didSet { UserDefaults.standard.set(screenshotProvider.rawValue, forKey: "screenshotProvider") }
    }
    /// Latest low-balance event from the DeepSeek monitor, shown on the home page until dismissed. Persisted:
    /// the monitor records "already notified" on disk, so an in-memory-only banner could be lost for good.
    @Published var lowBalance: LowBalanceNotice? {
        didSet { LowBalanceNotice.store(lowBalance) }
    }
    private var balanceLoop: Task<Void, Never>?
    @Published var subtitleProvider: ProviderID {
        didSet { UserDefaults.standard.set(subtitleProvider.rawValue, forKey: "subtitleProvider") }
    }
    init() {
        screenshotProvider = ProviderID(rawValue: UserDefaults.standard.string(forKey: "screenshotProvider") ?? "") ?? .openAI
        subtitleProvider = ProviderID(rawValue: UserDefaults.standard.string(forKey: "subtitleProvider") ?? "") ?? .openAI
        lowBalance = LowBalanceNotice.stored()
        // Cold start: AppModel is created once per process, so this runs once per launch.
        Task { [weak self] in await self?.checkAllKeys() }
        Task { [weak self] in await self?.watchLowBalance() }
    }

    private func watchLowBalance() async {
        guard let events = try? await services.deepSeekBalance.lowBalanceEvents() else { return }
        for await event in events {
            lowBalance = LowBalanceNotice(currency: event.currency, total: event.total, threshold: event.threshold)
        }
    }

    private var isForeground = false

    /// Foreground only: checks the DeepSeek balance (the monitor throttles to once per 5 minutes) while the app is
    /// active, a DeepSeek Key is usable and at least one reminder threshold is set (queries have their own counter in
    /// AIUtilityServices, separate from translation). Stops when the app leaves the foreground.
    func setForeground(_ active: Bool) {
        isForeground = active
        balanceLoop?.cancel(); balanceLoop = nil
        guard active else { return }
        balanceLoop = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.checkBalanceIfWanted()
                try? await Task.sleep(for: .seconds(300))
            }
        }
    }

    /// Also called right after the DeepSeek Key check finishes, so a cold start does not wait 5 minutes.
    func checkBalanceIfWanted() async {
        guard isForeground, status(of: .deepSeek).isUsable else { return }
        var wanted = false
        for currency in BalanceCurrency.allCases {
            // `try?` flattens to Decimal?: nil means no threshold (or unreadable, which also skips polling).
            if (try? await services.deepSeekBalance.threshold(for: currency)) != nil { wanted = true }
        }
        guard wanted else { return }
        _ = try? await services.deepSeekBalance.checkWhileActive()
    }
}

struct LoadedScreenshot {
    var photo: PhotosPickerItem?
    var data: Data?
    var preview: UIImage?
}

/// App-side copy of a low-balance event, kept in UserDefaults until the user dismisses it.
struct LowBalanceNotice: Codable, Equatable {
    let currency: BalanceCurrency
    let total: Decimal
    let threshold: Decimal
    private static let key = "deepSeekLowBalanceNotice"
    static func stored() -> LowBalanceNotice? {
        UserDefaults.standard.data(forKey: key).flatMap { try? JSONDecoder().decode(LowBalanceNotice.self, from: $0) }
    }
    static func store(_ notice: LowBalanceNotice?) {
        if let notice, let data = try? JSONEncoder().encode(notice) { UserDefaults.standard.set(data, forKey: key) }
        else { UserDefaults.standard.removeObject(forKey: key) }
    }
}

extension ProviderID {
    var title: String {
        switch self { case .openAI: "OpenAI"; case .anthropic: "Anthropic"; case .deepSeek: "DeepSeek" }
    }
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
        case .budgetExceeded: "本次应用会话的调用预算已用尽，完全退出并重新打开 App 后恢复。"
        case .configurationBusy: "该供应商已有配置验证正在进行。"
        case .storageFailure: "Keychain 当前不可访问或保存失败，原记录保持不变。"
        case .outputTruncated: "响应被截断，未作为成功结果使用。"
        case .contentRejected: "供应商拒绝生成此内容。"
        case .privacyViolation: "敏感信息占位符被改写，已拒绝该结果。"
        default: "操作未完成，请检查网络和配置后重试。"
        }
    }
}
