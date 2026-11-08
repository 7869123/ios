import SwiftUI

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

    private var providerSummary: some View {
        HStack(spacing: 10) {
            summaryChip(label: "截图", value: app.screenshotProvider.title)
            summaryChip(label: "字幕", value: app.subtitleProvider.title)
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
    }

    private func summaryChip(label: String, value: String) -> some View {
        Button { open(.settings) } label: {
            HStack(spacing: 6) {
                Text(label).foregroundStyle(UtilityTheme.inkSecondary)
                Text(value).fontWeight(.semibold).foregroundStyle(UtilityTheme.ink)
            }
            .font(.footnote)
            .padding(.horizontal, 12).padding(.vertical, 8)
            .glassSurface(Capsule())
        }
        .buttonStyle(PressableCardStyle())
        .accessibilityLabel("\(label)翻译供应商：\(value)，打开设置")
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
                Text(title).font(.headline).foregroundStyle(UtilityTheme.ink).lineLimit(1)
                Text(detail).font(.caption).foregroundStyle(UtilityTheme.inkSecondary).lineLimit(1)
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
