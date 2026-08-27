import AppKit
import SwiftUI
import UniformTypeIdentifiers

enum CursorChoice: Hashable, Identifiable {
    case emoji(String)
    case file(URL)

    var id: String {
        switch self {
        case .emoji(let e): return "emoji:\(e)"
        case .file(let url): return "file:\(url.lastPathComponent)"
        }
    }
}

@MainActor
final class PointyModel: ObservableObject {
    @Published var imported: [URL] = []
    @Published var selectedID: String?
    @Published var blocked = false
    @Published var themingActive = false

    @AppStorage("hotspotMode") var hotspotMode = "topleft" {
        didSet { reapplySelection() }
    }

    let presets = ["🍕", "🍌", "🦄", "🔥", "👾", "🍩", "⚡️", "🌵", "🎯", "🐝", "🍄", "🪄"]

    private let defaults = UserDefaults.standard
    private let selectedKey = "selectedCursor"

    static let cursorsDirectory: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Pointy/Cursors", isDirectory: true)
    }()

    init() {
        try? FileManager.default.createDirectory(at: Self.cursorsDirectory, withIntermediateDirectories: true)
        rescanImported()
        themingActive = CursorEngine.pointerThemingActive()
        selectedID = defaults.string(forKey: selectedKey)
        // Registrations clear on logout; put the saved cursor back on launch.
        reapplySelection()
    }

    private var hotspot: CGPoint {
        let side = CursorEngine.canvasPoints
        return hotspotMode == "center" ? CGPoint(x: side / 2, y: side / 2) : CGPoint(x: 2, y: 2)
    }

    private func choice(for id: String) -> CursorChoice? {
        if id.hasPrefix("emoji:") { return .emoji(String(id.dropFirst("emoji:".count))) }
        if id.hasPrefix("file:") {
            let url = Self.cursorsDirectory.appendingPathComponent(String(id.dropFirst("file:".count)))
            return FileManager.default.fileExists(atPath: url.path) ? .file(url) : nil
        }
        return nil
    }

    func apply(_ choice: CursorChoice) {
        let images: [CGImage]
        switch choice {
        case .emoji(let e): images = CursorEngine.emojiImages(e)
        case .file(let url): images = CursorEngine.fileImages(url)
        }
        guard images.count == 2 else { return }

        let ok = CursorEngine.applyArrow(images: images, hotspot: hotspot)
        blocked = !ok
        themingActive = CursorEngine.pointerThemingActive()
        selectedID = choice.id
        defaults.set(choice.id, forKey: selectedKey)
    }

    func resetToDefault() {
        CursorEngine.reset()
        blocked = false
        selectedID = nil
        defaults.removeObject(forKey: selectedKey)
    }

    private func reapplySelection() {
        guard let id = selectedID, let choice = choice(for: id) else { return }
        apply(choice)
    }

    /// Called when the app comes to the front: the user may have just changed
    /// the Accessibility pointer settings, so recheck and retry silently.
    func refreshOnActivate() {
        themingActive = CursorEngine.pointerThemingActive()
        if selectedID != nil, blocked {
            reapplySelection()
        }
    }

    // MARK: - Imported images

    private func rescanImported() {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: Self.cursorsDirectory, includingPropertiesForKeys: nil
        )) ?? []
        imported = files
            .filter { !$0.lastPathComponent.hasPrefix(".") }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    func importImages() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = true
        panel.message = "Choose images to use as cursors (transparent PNGs look best)"
        guard panel.runModal() == .OK else { return }

        var lastCopied: URL?
        for source in panel.urls {
            var dest = Self.cursorsDirectory.appendingPathComponent(source.lastPathComponent)
            var counter = 1
            let base = dest.deletingPathExtension().lastPathComponent
            let ext = dest.pathExtension
            while FileManager.default.fileExists(atPath: dest.path) {
                dest = Self.cursorsDirectory.appendingPathComponent("\(base)-\(counter).\(ext)")
                counter += 1
            }
            if (try? FileManager.default.copyItem(at: source, to: dest)) != nil {
                lastCopied = dest
            }
        }
        rescanImported()
        if let lastCopied {
            apply(.file(lastCopied))
        }
    }

    func removeImported(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
        if selectedID == CursorChoice.file(url).id {
            resetToDefault()
        }
        rescanImported()
    }

    func openAccessibilitySettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.universalaccess?Seeing_Display")!
        NSWorkspace.shared.open(url)
    }
}
