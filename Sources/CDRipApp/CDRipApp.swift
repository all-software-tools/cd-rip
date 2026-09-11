import AppKit
import SwiftUI
import CDRipCore

/// Explicit native window ownership avoids relying on SwiftUI scene restoration to open the
/// workspace when the local preview is relaunched. The workspace and sheets remain SwiftUI.
@MainActor final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    let model: AppModel
    let snapshotPath: String?
    private var window: NSWindow?
    private var terminationPending = false
    init(model: AppModel, snapshotPath: String?) { self.model = model; self.snapshotPath = snapshotPath }
    func applicationDidFinishLaunching(_ notification: Notification) {
        if let icon = Bundle.main.url(forResource: "AppIcon", withExtension: "icns") { NSApplication.shared.applicationIconImage = NSImage(contentsOf: icon) }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1220, height: 820),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.delegate = self
        window.title = "CD Rip"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.minSize = NSSize(width: 1000, height: 720)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = NSHostingView(rootView: WorkspaceView(model: model).preferredColorScheme(.dark).environment(\.locale, Locale(identifier: "en")))
        self.window = window
        window.center()
        if CommandLine.arguments.contains("--snapshot-background") { window.orderBack(nil) }
        else { window.makeKeyAndOrderFront(nil); NSApplication.shared.activate(ignoringOtherApps: true) }
        Task {
            await model.bootstrap()
            if snapshotPath == nil || CommandLine.arguments.contains("--snapshot-optical") || CommandLine.arguments.contains("--snapshot-rip-track") { await model.setDemonstration(false) }
            if let snapshotPath { await snapshot(to: snapshotPath, window: window) }
        }
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        NSApplication.shared.terminate(nil)
        return false // Keep the editor visible if the user cancels the quit dialog.
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        window?.makeKeyAndOrderFront(nil); return true
    }
    @objc func showSettings() { model.showSettings = true }
    @objc func showAbout() {
        let credits = NSAttributedString(string: "mykeydigital.ro", attributes: [
            .link: URL(string: "https://mykeydigital.ro")!,
            .font: NSFont.systemFont(ofSize: NSFont.systemFontSize)
        ])
        NSApplication.shared.orderFrontStandardAboutPanel(options: [
            .applicationName: "CD Rip",
            .applicationIcon: NSApplication.shared.applicationIconImage as Any,
            .credits: credits,
            .init(rawValue: "Copyright"): "© 2026 Mykey Digital. All rights reserved."
        ])
    }
    func applicationDidBecomeActive(_ notification: Notification) {
        guard model.isReady, !model.isBusy, let id = model.workspace.selectedSessionID else { return }
        Task { await model.refreshMediaFiles(sessionID: id) }
    }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if terminationPending { return .terminateLater }
        if model.isBusy || model.isTestingConnection {
            let alert = NSAlert(); alert.messageText = "Stop the current operation and quit?"
            alert.informativeText = "Saved progress remains in your session history. Unsaved metadata drafts will be saved before quitting."
            alert.addButton(withTitle: "Stop and quit"); alert.addButton(withTitle: "Keep working")
            alert.buttons[1].keyEquivalent = "\u{1b}"
            guard alert.runModal() == .alertFirstButtonReturn else { return .terminateCancel }
            terminationPending = true
            Task {
                await model.cancelAndWait()
                let saved: Bool
                if model.hasUnsavedMetadataEdits { saved = await model.flushMetadataEdits() } else { saved = true }
                terminationPending = false; sender.reply(toApplicationShouldTerminate: saved)
            }
            return .terminateLater
        }
        guard model.hasUnsavedMetadataEdits else { return .terminateNow }
        let alert = NSAlert(); alert.messageText = "Save metadata drafts before quitting?"
        alert.informativeText = "Saves your edits in the session. Audio files are changed only with Save to audio files or Save all."
        alert.addButton(withTitle: "Save drafts and quit"); alert.addButton(withTitle: "Keep editing"); alert.addButton(withTitle: "Discard and quit")
        alert.buttons[1].keyEquivalent = "\u{1b}"
        let choice = alert.runModal()
        if choice == .alertThirdButtonReturn { model.discardAllMetadataEdits(); return .terminateNow }
        guard choice == .alertFirstButtonReturn else { return .terminateCancel }
        terminationPending = true
        Task {
            let saved = await model.flushMetadataEdits()
            terminationPending = false
            if !saved { let error = NSAlert(); error.messageText = "Drafts could not be saved"; error.informativeText = model.message ?? "Keep the app open and copy your edits."; error.runModal() }
            sender.reply(toApplicationShouldTerminate: saved)
        }
        return .terminateLater
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    private func snapshot(to path: String, window: NSWindow) async {
        var settings = model.workspace.settings
        let args = CommandLine.arguments
        if let index = args.firstIndex(of: "--snapshot-rip-track"), args.indices.contains(index + 1), let number = Int(args[index + 1]),
           let folderIndex = args.firstIndex(of: "--qa-output"), args.indices.contains(folderIndex + 1),
           let track = model.disc?.tracks.first(where: { $0.number == number }), model.disc?.source == .optical {
            settings.destinationPath = args[folderIndex + 1]; settings.profile = .mp3AndFlac
            await model.updateSettings(settings)
            model.selectedTrackIDs = [track.id]
            await model.startRip()
            let deadline = ContinuousClock.now + .seconds(300)
            while model.isBusy && ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(100)) }
            if model.isBusy { await model.cancelAndWait(); exit(2) }
            guard model.currentSession?.tracks.first?.phase == .awaitingVerification, model.message == nil else { fputs("Native optical QA failed\n", stderr); exit(2) }
            model.tab = .metadata
        } else {
            if args.contains("--snapshot-rip-track") { fputs("Invalid optical QA arguments\n", stderr); exit(2) }
            settings.destinationPath = "/Volumes/Radio Library/CD Imports"
            await model.updateSettings(settings)
        }
        if CommandLine.arguments.contains("--snapshot-metadata") {
            await model.startSimulation()
            let deadline = ContinuousClock.now + .seconds(15)
            while model.isBusy && ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(50)) }
            guard !model.isBusy else { fputs("Snapshot: simulation timeout\n", stderr); exit(2) }
        }
        if CommandLine.arguments.contains("--snapshot-progress") {
            await model.startSimulation()
            try? await Task.sleep(for: .milliseconds(350))
        }
        if CommandLine.arguments.contains("--snapshot-tracklist-image") || CommandLine.arguments.contains("--snapshot-song-editor") || CommandLine.arguments.contains("--snapshot-tracklist") || CommandLine.arguments.contains("--snapshot-ai") || CommandLine.arguments.contains("--snapshot-cover") || CommandLine.arguments.contains("--snapshot-save-files") { model.tab = .metadata }
        if CommandLine.arguments.contains("--snapshot-ai-running"), let track = model.currentSession?.tracks.first {
            await model.startAIReview(trackIDs: [track.id], forceRefresh: true)
        }
        if CommandLine.arguments.contains("--snapshot-settings") { model.showSettings = true }
        if CommandLine.arguments.contains("--snapshot-destination") {
            let panel = makeDestinationPanel(currentPath: model.workspace.settings.destinationPath)
            panel.beginSheetModal(for: window) { _ in }
        }
        try? await Task.sleep(for: .milliseconds(700))
        if CommandLine.arguments.contains("--snapshot-song-editor"), let root = window.contentView {
            func scrollView(in view: NSView) -> NSScrollView? {
                if let scroll = view as? NSScrollView, scroll.documentView?.bounds.height ?? 0 > scroll.contentView.bounds.height { return scroll }
                return view.subviews.lazy.compactMap { scrollView(in: $0) }.first
            }
            if let scroll = scrollView(in: root), let document = scroll.documentView {
                document.scroll(NSPoint(x: 0, y: min(500, max(0, document.bounds.height - scroll.contentView.bounds.height))))
                scroll.reflectScrolledClipView(scroll.contentView)
                try? await Task.sleep(for: .milliseconds(300))
            }
        }
        if let view = (window.attachedSheet ?? window).contentView, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
            view.layoutSubtreeIfNeeded()
            view.cacheDisplay(in: view.bounds, to: rep)
            if let data = rep.representation(using: .png, properties: [:]) {
                do { try data.write(to: URL(fileURLWithPath: path)); print("Snapshot saved: \(path)"); exit(0) }
                catch { print("Snapshot failed: \(error)") }
            }
        }
        exit(2)
    }
}

@MainActor @main struct CDRipApplication {
    static func main() {
        let args = CommandLine.arguments
        func argument(_ key: String) -> String? { args.firstIndex(of: key).flatMap { args.indices.contains($0 + 1) ? args[$0 + 1] : nil } }
        let snapshot = argument("--snapshot")
        let root: URL
        if let directory = argument("--data-dir") { root = URL(fileURLWithPath: directory, isDirectory: true) }
        else if snapshot != nil { root = FileManager.default.temporaryDirectory.appendingPathComponent("CDRip-preview-\(UUID())") }
        else { root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("CDRip") }
        let lease: WorkspaceLease
        do { lease = try WorkspaceLease(fileURL: root.appendingPathComponent("workspace.json")) }
        catch {
            if snapshot == nil { let alert = NSAlert(); alert.messageText = "Workspace unavailable"; alert.informativeText = error.localizedDescription; alert.runModal() }
            else { fputs("Workspace unavailable\n", stderr) }
            return
        }
        let store = JSONWorkspaceStore(fileURL: root.appendingPathComponent("workspace.json"))
        let model = snapshot != nil && args.contains("--snapshot-ai-running")
            ? AppModel(store: store, aiCatalog: SlowSnapshotCatalog()) : AppModel(store: store)
        let delegate = AppDelegate(model: model, snapshotPath: snapshot)
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        app.delegate = delegate
        let menu = NSMenu()
        let appItem = NSMenuItem(); menu.addItem(appItem)
        let appMenu = NSMenu(title: "CD Rip"); appItem.submenu = appMenu
        let about = appMenu.addItem(withTitle: "About CD Rip", action: #selector(AppDelegate.showAbout), keyEquivalent: "")
        about.target = delegate
        appMenu.addItem(.separator())
        let settings = appMenu.addItem(withTitle: "Settings…", action: #selector(AppDelegate.showSettings), keyEquivalent: ",")
        settings.target = delegate
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit CD Rip", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        let editItem = NSMenuItem(); menu.addItem(editItem)
        let edit = NSMenu(title: "Edit"); editItem.submenu = edit
        for (title, action, key) in [("Undo", "undo:", "z"), ("Cut", "cut:", "x"), ("Copy", "copy:", "c"), ("Paste", "paste:", "v"), ("Select All", "selectAll:", "a")] {
            edit.addItem(withTitle: title, action: Selector(action), keyEquivalent: key)
        }
        app.mainMenu = menu
        withExtendedLifetime((delegate, lease)) { app.run() }
    }
}

/// Isolated UI fixture: deliberately waits without contacting any catalog, AI or drive.
private struct SlowSnapshotCatalog: AIMetadataCatalog {
    func candidates(session: RipSession, track: SessionTrack) async throws -> [AIMetadataCandidate] {
        try await Task.sleep(for: .seconds(30))
        return []
    }
}
