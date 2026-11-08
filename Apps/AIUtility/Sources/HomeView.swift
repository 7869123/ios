import SwiftUI
import AIUtilityCore

/// Home workbench: entry point to every AIUtility feature. Native iOS navigation; original visual design.
/// Tiles only navigate; statuses are honest (planned features are not presented as working).
@MainActor struct HomeView: View {
    @EnvironmentObject private var app: AppModel
    let open: (Workspace) -> Void

    private struct Tile: Identifiable {
        let id: String
        let title: String
        let detail: String
        let icon: String
        let status: FeatureStatus
        let target: Workspace
    }

    private let daily: [Tile] = [
        .init(id: "screenshot", title: "截图翻译", detail: "Discord 等截图本地 OCR 后翻译", icon: "viewfinder", status: .available, target: .screenshot),
        .init(id: "subtitle", title: "字幕翻译", detail: "粘贴文本翻译；实时字幕规划中", icon: "captions.bubble", status: .available, target: .subtitles),
        .init(id: "settings", title: "AI 供应商与模型", detail: "Key、模型绑定与调用预算", icon: "slider.horizontal.3", status: .available, target: .settings),
    ]
    private let media: [Tile] = [
        .init(id: "download", title: "X · Pixiv · B站下载", detail: "解析链接并加入统一下载任务", icon: "arrow.down.circle", status: .planned, target: .media),
        .init(id: "image", title: "图片处理", detail: "视频转 GIF、多图拼接、文件指纹", icon: "photo.stack", status: .planned, target: .media),
        .init(id: "search", title: "反向搜图", detail: "SauceNAO / 搜图 Bot 酱", icon: "magnifyingglass", status: .planned, target: .media),
        .init(id: "tasks", title: "下载任务", detail: "进度、取消、重试与历史", icon: "tray.full", status: .planned, target: .media),
    ]
    /// 330 pt keeps compact tiles wide enough for full titles: 2 per row in iPad landscape
    /// (~735 pt content), 1 per row in portrait and on iPhone portrait.
    private let columns = [GridItem(.adaptive(minimum: 330), spacing: 12)]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                header
                setupNotice
                section("常用", tiles: daily)
                section("媒体工具", tiles: media)
            }
            .frame(maxWidth: UtilityTheme.pageMaxWidth)
            .padding(UtilityTheme.pagePadding)
            .frame(maxWidth: .infinity)
        }
        .background { WorkspaceBackdrop() }
    }

    private var header: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .bottom) { headerTitle; Spacer(minLength: 24); providerSummary }
            VStack(alignment: .leading, spacing: 16) { headerTitle; providerSummary }
        }
    }

    private var headerTitle: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                SlantBar().fill(UtilityTheme.brandGradient).frame(width: 28, height: 6)
                Text(Date.now, format: .dateTime.month().day().weekday(.wide))
                    .font(.caption.weight(.semibold)).foregroundStyle(UtilityTheme.brandStrong)
            }
            Text("工作台").font(.largeTitle.bold()).foregroundStyle(UtilityTheme.ink)
            Text("翻译、字幕与媒体工具的统一入口").font(.subheadline).foregroundStyle(UtilityTheme.inkSecondary)
        }
        .legibleOnWallpaper()
    }

    /// One row when it fits; on narrow screens (iPhone portrait) the two provider chips share a row
    /// and the wallpaper button moves below, so chip text never wraps mid-word.
    private var providerSummary: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 10) { providerChips; wallpaperButton }
            VStack(alignment: .leading, spacing: 8) { HStack(spacing: 10) { providerChips }; wallpaperButton }
            VStack(alignment: .leading, spacing: 8) { providerChips; wallpaperButton }
        }
    }

    @ViewBuilder private var providerChips: some View {
        summaryChip(label: "截图", provider: app.screenshotProvider)
        summaryChip(label: "字幕", provider: app.subtitleProvider)
    }

    private var wallpaperButton: some View {
        Button { open(.settings) } label: {
            Label("壁纸", systemImage: "photo")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(UtilityTheme.brandStrong)
                .padding(.horizontal, 12).padding(.vertical, 8)
                .glassSurface(Capsule())
        }
        .buttonStyle(PressableCardStyle())
        .accessibilityLabel("更换壁纸，打开设置")
    }

    /// Provider chip with the real Key status from the cold-start check.
    private func summaryChip(label: String, provider: ProviderID) -> some View {
        let status = app.status(of: provider)
        return Button { open(.settings) } label: {
            HStack(spacing: 6) {
                Text(label).foregroundStyle(UtilityTheme.inkSecondary)
                Text(provider.title).fontWeight(.semibold).foregroundStyle(UtilityTheme.ink)
                if status == .checking || status == .unknown {
                    ProgressView().controlSize(.mini)
                } else {
                    Circle().fill(status.color).frame(width: 7, height: 7)
                }
                Text(status.title).fontWeight(.semibold).foregroundStyle(status.color)
            }
            .font(.footnote)
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, 12).padding(.vertical, 8)
            .glassSurface(Capsule())
        }
        .buttonStyle(PressableCardStyle())
        .accessibilityLabel("\(label)翻译供应商：\(provider.title)，\(status.title)，打开设置")
    }

    /// First-run / broken-configuration guidance; hidden while checking and when everything is usable.
    @ViewBuilder private var setupNotice: some View {
        let screenshot = app.status(of: app.screenshotProvider)
        let subtitle = app.status(of: app.subtitleProvider)
        let message: String? = {
            if app.nothingConfigured { return "还没有配置 AI 供应商，截图翻译和字幕翻译暂不可用。" }
            func problem(_ name: String, _ provider: ProviderID, _ s: KeyStatus) -> String? {
                switch s {
                case .notConfigured: "\(name)所选的 \(provider.title) 还没有配置 Key。"
                case .rejected: "\(name)所选的 \(provider.title) Key 已失效或没有权限。"
                case .available(false): "\(name)所选的 \(provider.title) 绑定的模型已不在模型目录中。"
                default: nil
                }
            }
            return problem("截图翻译", app.screenshotProvider, screenshot) ?? problem("字幕翻译", app.subtitleProvider, subtitle)
        }()
        if let message {
            Button { open(.settings) } label: {
                HStack(spacing: 12) {
                    Image(systemName: "key.horizontal").font(.body.weight(.semibold)).foregroundStyle(UtilityTheme.poc)
                    Text(message).font(.subheadline).foregroundStyle(UtilityTheme.ink).multilineTextAlignment(.leading)
                    Spacer(minLength: 8)
                    Text("去设置").font(.subheadline.weight(.semibold)).foregroundStyle(UtilityTheme.brandStrong)
                    Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(UtilityTheme.brandStrong)
                }
                .padding(.horizontal, 14).padding(.vertical, 12)
                .glassSurface(RoundedRectangle(cornerRadius: 14))
            }
            .buttonStyle(PressableCardStyle())
            .accessibilityHint("打开设置配置 AI 供应商")
        }
    }

    private func section(_ title: String, tiles: [Tile]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                SlantBar().fill(UtilityTheme.brand).frame(width: 16, height: 14)
                Text(title).font(.title3.bold()).foregroundStyle(UtilityTheme.ink)
            }
            .legibleOnWallpaper()
            .accessibilityAddTraits(.isHeader)
            LazyVGrid(columns: columns, spacing: 12) {
                ForEach(tiles) { tile in
                    Button { open(tile.target) } label: { FeatureTile(title: tile.title, detail: tile.detail, icon: tile.icon, status: tile.status) }
                        .buttonStyle(PressableCardStyle())
                }
            }
        }
    }
}

/// Compact tile: icon, title and one-line detail in a row, so more wallpaper stays visible.
@MainActor struct FeatureTile: View {
    let title: String
    let detail: String
    let icon: String
    let status: FeatureStatus
    @Environment(\.dynamicTypeSize) private var typeSize
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.body.weight(.semibold))
                .foregroundStyle(status == .planned ? UtilityTheme.planned : .white)
                .frame(width: 36, height: 36)
                .background {
                    if status == .planned {
                        RoundedRectangle(cornerRadius: 10).fill(UtilityTheme.planned.opacity(0.14))
                    } else {
                        RoundedRectangle(cornerRadius: 10).fill(UtilityTheme.deepGradient)
                    }
                }
            VStack(alignment: .leading, spacing: 2) {
                // One line normally; wrap at large / accessibility text sizes instead of truncating.
                Text(title).font(.headline).foregroundStyle(UtilityTheme.ink).lineLimit(typeSize > .xLarge ? 2 : 1)
                Text(detail).font(.caption).foregroundStyle(UtilityTheme.inkSecondary).lineLimit(typeSize > .xLarge ? 3 : 1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            StatusChip(status: status)
        }
        .padding(.horizontal, 14).padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassSurface(RoundedRectangle(cornerRadius: 14))
        .overlay(alignment: .topLeading) {
            SlantBar().fill(status == .planned ? AnyShapeStyle(UtilityTheme.planned.opacity(0.4)) : AnyShapeStyle(UtilityTheme.brandGradient))
                .frame(width: 28, height: 3).padding(.leading, 14)
        }
        .shadow(color: UtilityTheme.brand.opacity(0.04), radius: 6, y: 2)
        .contentShape(RoundedRectangle(cornerRadius: 14))
        .accessibilityElement(children: .combine)
    }
}

@MainActor struct LiveCaptionInfoSheet: View {
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            List {
                Section("当前状态") {
                    Label("独立诊断工程 PoCs/iOS27Capture，未接入本 App", systemImage: "hammer")
                    Label("iOS 27.1 SDK 编译与未签名 IPA 已通过 CI", systemImage: "checkmark.seal")
                    Label("尚未在任何真机上安装或验证", systemImage: "exclamationmark.triangle")
                }
                Section("待确认") {
                    Text("能否采集其他 App 的音频（暂无官方示例证明）")
                    Text("后台采集、本地识别与 PiP 能否同时持续工作")
                    Text("免费 Personal Team 签名下的系统授权行为")
                }
            }
            .navigationTitle("实时字幕 · PiP")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
        }
        .presentationDetents([.medium, .large])
    }
}

#Preview("iPad mini · 横屏", traits: .landscapeLeft) {
    HomeView(open: { _ in }).environmentObject(AppModel())
}
