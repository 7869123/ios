import SwiftUI

enum UtilityTheme {
    static let cyan = Color(red: 0.0, green: 0.48, blue: 0.66)
    static let ink = Color(red: 0.10, green: 0.19, blue: 0.28)
    static let canvas = Color(red: 0.94, green: 0.97, blue: 0.99)
}

@MainActor struct UtilityCard<Content: View>: View {
    private let content: Content
    init(@ViewBuilder content: () -> Content) { self.content = content() }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) { content }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(20)
            .background(.background, in: RoundedRectangle(cornerRadius: 16))
            .overlay(alignment: .topLeading) {
                Rectangle().fill(UtilityTheme.cyan).frame(width: 36, height: 3).padding(.leading, 20)
            }
    }
}

@MainActor struct PageHeader: View {
    let title: String
    let subtitle: String
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("AIUTILITY / WORKSPACE").font(.caption.monospaced().weight(.semibold)).foregroundStyle(UtilityTheme.cyan)
            Text(title).font(.largeTitle.bold()).foregroundStyle(UtilityTheme.ink)
            Text(subtitle).font(.subheadline).foregroundStyle(.secondary)
        }.frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 12)
    }
}

@MainActor struct WorkspacePage<Content: View>: View {
    private let content: Content
    init(@ViewBuilder content: () -> Content) { self.content = content() }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) { content }
                .frame(maxWidth: 900).padding(20).frame(maxWidth: .infinity)
        }.background(UtilityTheme.canvas).scrollDismissesKeyboard(.interactively)
    }
}
