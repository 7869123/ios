import SwiftUI

/// Home workbench: entry point to every AIUtility feature. Native iOS navigation; original visual design.
/// Tiles only navigate; statuses are honest (planned features are not presented as working).
@MainActor struct HomeView: View {
    @EnvironmentObject private var app: AppModel
    let open: (Workspace) -> Void
    @State private var showLiveCaptionInfo = false
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(AppearanceStore.self) private var appearance: AppearanceStore?
    private var heroStyle: GlassStyle {
        reduceTransparency ? .reducedTransparency : GlassStyle(transparency: appearance?.panelTransparency ?? AppearanceStore.defaultPanelTransparency)
    }

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
        .init(id: "subtitle", title: "字幕文本翻译", detail: "粘贴字幕文本，按字幕模型翻译", icon: "captions.bubble", status: .available, target: .subtitles),
        .init(id: "settings", title: "AI 供应商与模型", detail: "Key、模型绑定与调用预算", icon: "slider.horizontal.3", status: .available, target: .settings),
    ]
    private let media: [Tile] = [
        .init(id: "download", title: "X · Pixiv · B站下载", detail: "解析链接并加入统一下载任务", icon: "arrow.down.circle", status: .planned, target: .media),
        .init(id: "image", title: "图片处理", detail: "视频转 GIF、多图拼接、文件指纹", icon: "photo.stack", status: .planned, target: .media),
        .init(id: "search", title: "反向搜图", detail: "SauceNAO / 搜图 Bot 酱", icon: "magnifyingglass", status: .planned, target: .media),
        .init(id: "tasks", title: "下载任务", detail: "进度、取消、重试与历史", icon: "tray.full", status: .planned, target: .media),
    ]
    private let columns = [GridItem(.adaptive(minimum: 230), spacing: UtilityTheme.spacing)]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                header
                liveCaptionPanel
                section("常用", tiles: daily)
                section("媒体工具", tiles: media)
            }
            .frame(maxWidth: UtilityTheme.pageMaxWidth)
            .padding(UtilityTheme.pagePadding)
            .frame(maxWidth: .infinity)
        }
        .background { WorkspaceBackdrop() }
        .sheet(isPresented: $showLiveCaptionInfo) { LiveCaptionInfoSheet() }
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
            Text("翻译、字幕与媒体工具的统一入口").font(.subheadline).foregroundStyle(.secondary)
        }
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
                Text(label).foregroundStyle(.secondary)
                Text(value).fontWeight(.semibold).foregroundStyle(UtilityTheme.ink)
            }
            .font(.footnote)
            .padding(.horizontal, 12).padding(.vertical, 8)
            .glassSurface(Capsule())
        }
        .buttonStyle(PressableCardStyle())
        .accessibilityLabel("\(label)翻译供应商：\(value)，打开设置")
    }

    private var liveCaptionPanel: some View {
        Button { showLiveCaptionInfo = true } label: {
            HStack(alignment: .center, spacing: 20) {
                Image(systemName: "pip")
                    .font(.system(size: 30, weight: .semibold))
                    .frame(width: 64, height: 64)
                    .background(.white.opacity(0.18), in: RoundedRectangle(cornerRadius: 16))
                VStack(alignment: .leading, spacing: 6) {
                    Text("跨 App 实时字幕 · PiP").font(.title2.bold())
                    Text("采集其他 App 的音频，本地识别后在画中画中显示字幕。当前为独立诊断 PoC，尚未接入本 App，也未经真机验证。")
                        .font(.subheadline)
                        .multilineTextAlignment(.leading)
                }
                Spacer(minLength: 8)
                Text("了解进度")
                    .font(.subheadline.weight(.semibold))
                    .padding(.horizontal, 14).padding(.vertical, 8)
                    .background(.white, in: Capsule())
                    .foregroundStyle(UtilityTheme.brandStrong)
            }
            .foregroundStyle(.white)
            // Legibility over a translucent banner: soft dark shadow under white text.
            .shadow(color: UtilityTheme.ink.opacity(0.45 * heroStyle.legibilityBoost), radius: 3, y: 1)
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                ZStack(alignment: .topTrailing) {
                    RoundedRectangle(cornerRadius: 22).fill(UtilityTheme.deepGradient).opacity(heroStyle.heroOpacity)
                    // Local shading behind the text column, stronger as the banner gets more transparent.
                    LinearGradient(colors: [UtilityTheme.ink.opacity(0.30 * heroStyle.legibilityBoost), .clear],
                                   startPoint: .leading, endPoint: .trailing)
                    SlantBar(slant: 0.6).fill(.white.opacity(0.10)).frame(width: 220, height: 120).offset(x: 40, y: -10)
                }
                .clipShape(RoundedRectangle(cornerRadius: 22))
            }
            .shadow(color: UtilityTheme.brand.opacity(0.18), radius: 16, y: 6)
        }
        .buttonStyle(PressableCardStyle())
        .accessibilityElement(children: .combine)
        .accessibilityHint("查看实时字幕 PoC 的当前状态")
    }

    private func section(_ title: String, tiles: [Tile]) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                SlantBar().fill(UtilityTheme.brand).frame(width: 16, height: 14)
                Text(title).font(.title3.bold()).foregroundStyle(UtilityTheme.ink)
            }
            .accessibilityAddTraits(.isHeader)
            LazyVGrid(columns: columns, spacing: UtilityTheme.spacing) {
                ForEach(tiles) { tile in
                    Button { open(tile.target) } label: { FeatureTile(title: tile.title, detail: tile.detail, icon: tile.icon, status: tile.status) }
                        .buttonStyle(PressableCardStyle())
                }
            }
        }
    }
}

@MainActor struct FeatureTile: View {
    let title: String
    let detail: String
    let icon: String
    let status: FeatureStatus
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top) {
                Image(systemName: icon)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(status == .planned ? UtilityTheme.planned : .white)
                    .frame(width: 44, height: 44)
                    .background {
                        if status == .planned {
                            RoundedRectangle(cornerRadius: UtilityTheme.radiusIcon).fill(UtilityTheme.planned.opacity(0.12))
                        } else {
                            RoundedRectangle(cornerRadius: UtilityTheme.radiusIcon).fill(UtilityTheme.deepGradient)
                        }
                    }
                Spacer()
                StatusChip(status: status)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.headline).foregroundStyle(UtilityTheme.ink)
                Text(detail).font(.footnote).foregroundStyle(.secondary).lineLimit(2, reservesSpace: true)
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassSurface(RoundedRectangle(cornerRadius: UtilityTheme.radiusCard))
        .overlay(alignment: .topLeading) {
            SlantBar().fill(status == .planned ? AnyShapeStyle(UtilityTheme.planned.opacity(0.4)) : AnyShapeStyle(UtilityTheme.brandGradient))
                .frame(width: 40, height: 4).padding(.leading, 18)
        }
        .shadow(color: UtilityTheme.brand.opacity(0.05), radius: 10, y: 3)
        .contentShape(RoundedRectangle(cornerRadius: UtilityTheme.radiusCard))
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
