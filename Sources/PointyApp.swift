import SwiftUI

@main
struct PointyApp: App {
    @StateObject private var model = PointyModel()

    var body: some Scene {
        Window("Pointy", id: "main") {
            ContentView()
                .environmentObject(model)
                .onReceive(NotificationCenter.default.publisher(
                    for: NSApplication.didBecomeActiveNotification
                )) { _ in
                    model.refreshOnActivate()
                }
        }
        .windowResizability(.contentSize)
    }
}

struct ContentView: View {
    @EnvironmentObject private var model: PointyModel

    private let columns = [GridItem(.adaptive(minimum: 76), spacing: 10)]

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            if model.blocked {
                warningBanner
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    section("Presets") {
                        LazyVGrid(columns: columns, spacing: 10) {
                            ForEach(model.presets, id: \.self) { emoji in
                                CursorTile(selected: model.selectedID == CursorChoice.emoji(emoji).id) {
                                    model.apply(.emoji(emoji))
                                } content: {
                                    Text(emoji).font(.system(size: 38))
                                }
                            }
                        }
                    }
                    section("Your Images") {
                        LazyVGrid(columns: columns, spacing: 10) {
                            ForEach(model.imported, id: \.self) { url in
                                CursorTile(selected: model.selectedID == CursorChoice.file(url).id) {
                                    model.apply(.file(url))
                                } content: {
                                    if let img = NSImage(contentsOf: url) {
                                        Image(nsImage: img)
                                            .resizable()
                                            .scaledToFit()
                                            .frame(width: 44, height: 44)
                                    } else {
                                        Image(systemName: "questionmark.square.dashed")
                                            .font(.system(size: 28))
                                    }
                                }
                                .contextMenu {
                                    Button("Remove") { model.removeImported(url) }
                                }
                            }
                            CursorTile(selected: false) {
                                model.importImages()
                            } content: {
                                VStack(spacing: 4) {
                                    Image(systemName: "plus")
                                        .font(.system(size: 22, weight: .medium))
                                    Text("Add").font(.caption)
                                }
                                .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                .padding(.bottom, 4)
            }
            footer
        }
        .padding(20)
        .frame(width: 480)
        .frame(minHeight: 560, maxHeight: 720)
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Pointy").font(.largeTitle.bold())
                Text("Give your Mac a custom cursor")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Reset to Default") { model.resetToDefault() }
                .disabled(model.selectedID == nil)
        }
    }

    private var warningBanner: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("macOS is overriding custom cursors", systemImage: "exclamationmark.triangle.fill")
                .font(.headline)
            Text(model.themingActive
                 ? "Your pointer color or size is customized in Accessibility settings, which can block custom cursors. In System Settings → Accessibility → Display, reset the pointer color and set the pointer size to normal — then come back and click a cursor."
                 : "The system refused the cursor change. Try clicking the cursor again, or check the pointer settings in System Settings → Accessibility → Display.")
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
            Button("Open Accessibility Settings") { model.openAccessibilitySettings() }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.orange.opacity(0.15), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.orange.opacity(0.4)))
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("Click point", selection: $model.hotspotMode) {
                Text("Top-left tip").tag("topleft")
                Text("Center").tag("center")
            }
            .pickerStyle(.segmented)
            .frame(width: 280)
            Text("Cursors apply everywhere and survive quitting Pointy. They clear on logout or restart — open Pointy again to re-apply.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func section(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.headline)
            content()
        }
    }
}

struct CursorTile<Content: View>: View {
    let selected: Bool
    let action: () -> Void
    @ViewBuilder let content: Content

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            content
                .frame(width: 72, height: 72)
                .background(
                    RoundedRectangle(cornerRadius: 12)
                        .fill(hovering ? Color.primary.opacity(0.08) : Color.primary.opacity(0.04))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .strokeBorder(selected ? Color.accentColor : .clear, lineWidth: 2.5)
                )
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}
