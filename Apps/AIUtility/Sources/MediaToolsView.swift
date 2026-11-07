import SwiftUI

struct MediaTool: Identifiable, Sendable {
    let id: String
    let title: String
    let icon: String
    let detail: String
    static let all: [MediaTool] = [
        .init(id: "x", title: "X 视频下载", icon: "arrow.down.circle", detail: "解析 X 视频并纳入统一下载任务。"),
        .init(id: "pixiv", title: "Pixiv 原画与 Ugoira", icon: "photo.on.rectangle.angled", detail: "保留原画下载与 Ugoira 动画处理范围。"),
        .init(id: "bilibili", title: "B站视频下载", icon: "play.rectangle", detail: "解析视频与清晰度，并通过统一任务管理下载。"),
        .init(id: "gif", title: "视频转 GIF", icon: "film.stack", detail: "选择片段、尺寸、帧率并在设备上转换。"),
        .init(id: "fingerprint", title: "图片文件指纹", icon: "fingerprint", detail: "修改图片文件指纹，保留原文件并显示处理结果。"),
        .init(id: "stitch", title: "多图拼接", icon: "rectangle.split.1x2", detail: "长图、网格与顺序编排。"),
        .init(id: "search", title: "SauceNAO / 搜图 Bot 酱", icon: "magnifyingglass", detail: "统一来源搜索与结果展示。"),
        .init(id: "tasks", title: "下载任务与历史", icon: "tray.full", detail: "统一进度、取消、重试与历史记录。")
    ]
}

@MainActor struct MediaToolsView: View {
    var body: some View {
        WorkspacePage {
            PageHeader(title: "媒体工具箱", subtitle: "所有已确认能力均保留在后续范围")
            ForEach(MediaTool.all) { tool in
                NavigationLink {
                    WorkspacePage {
                        PageHeader(title: tool.title, subtitle: "后续开发")
                        UtilityCard {
                            Label("尚未实现", systemImage: "clock")
                            Text(tool.detail)
                            Text("此入口用于浏览开发范围，当前不会发起下载或宣称处理成功。")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }.navigationTitle(tool.title)
                } label: {
                    UtilityCard {
                        HStack(spacing: 16) {
                            Image(systemName: tool.icon).font(.title2).foregroundStyle(UtilityTheme.cyan).frame(width: 34)
                            VStack(alignment: .leading, spacing: 5) {
                                Text(tool.title).font(.headline).foregroundStyle(UtilityTheme.ink)
                                Text("后续开发").font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Image(systemName: "chevron.right").foregroundStyle(.secondary)
                        }
                    }
                }.buttonStyle(.plain)
            }
        }
    }
}
