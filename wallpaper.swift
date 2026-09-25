// The bundled app plays its own video; the original command-line player also
// accepts a video path. Neither mode changes the user's desktop picture.

import AVFoundation
import Cocoa
import ServiceManagement

// Own the desktop windows, shared decoder, menu controls, and login preference.
final class Wallpaper: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let videoURL: URL
    private let player = AVQueuePlayer()
    private var looper: AVPlayerLooper?
    private var windows: [NSWindow] = []
    private var statusItem: NSStatusItem!
    private var pauseItem: NSMenuItem!
    private var loginItem: NSMenuItem?
    private var loginApprovalItem: NSMenuItem?
    private var videoLayers: [AVPlayerLayer] = []
    private var loopObservation: NSKeyValueObservation?
    private var pausedByUser = false
    private var screensAsleep = false
    private var playbackFailed = false
    private let bundled = Bundle.main.bundleURL.pathExtension == "app"
    private let smokeTest = CommandLine.arguments.contains("--smoke-test")

    // Keep the resource location explicit so legacy custom videos still work.
    init(videoURL: URL) {
        self.videoURL = videoURL
        super.init()
    }

    // Prepare first-launch guidance, playback, and event observers after AppKit is ready.
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        // Finder normally reuses a running app; also guard direct binary launches.
        if bundled && !smokeTest, let identifier = Bundle.main.bundleIdentifier,
           let running = NSRunningApplication.runningApplications(withBundleIdentifier: identifier)
            .first(where: { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }) {
            running.activate(options: [])
            NSApp.terminate(nil)
            return
        }

        // First launch is explicit and never enables login startup without a choice.
        if bundled && !smokeTest {
            guard replaceLegacyInstallation() else { NSApp.terminate(nil); return }
            if !UserDefaults.standard.bool(forKey: "hasWelcomed") {
                let welcome = NSAlert()
                welcome.messageText = "Welcome to Einstein Ring"
                welcome.informativeText = "Your wallpaper is ready. Use the ✨ menu bar icon to pause it or choose Open at Login. Quitting reveals your existing desktop picture."
                welcome.addButton(withTitle: "Start Wallpaper")
                welcome.addButton(withTitle: "Cancel")
                NSApp.activate(ignoringOtherApps: true)
                guard welcome.runModal() == .alertFirstButtonReturn else { NSApp.terminate(nil); return }
                UserDefaults.standard.set(true, forKey: "hasWelcomed")
            }
        }

        // All displays share one silent looping player and its hardware decoder.
        player.isMuted = true
        player.allowsExternalPlayback = false
        player.preventsDisplaySleepDuringVideoPlayback = false   // let the screen sleep as usual
        looper = AVPlayerLooper(player: player, templateItem: AVPlayerItem(url: videoURL))
        loopObservation = looper?.observe(\.status, options: [.initial, .new]) { [weak self] looper, _ in
            guard looper.status == .failed else { return }
            let message = looper.error?.localizedDescription ?? "The wallpaper video could not be played."
            DispatchQueue.main.async { self?.handlePlaybackFailure(message) }
        }

        buildWindows()
        buildMenu()

        // React to visibility, power, and display changes instead of polling.
        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(screensChanged),
                           name: NSApplication.didChangeScreenParametersNotification, object: nil)
        center.addObserver(self, selector: #selector(powerStateChanged),
                           name: .NSProcessInfoPowerStateDidChange, object: nil)
        center.addObserver(self, selector: #selector(itemFailed(_:)),
                           name: .AVPlayerItemFailedToPlayToEndTime, object: nil)

        let workspace = NSWorkspace.shared.notificationCenter
        workspace.addObserver(self, selector: #selector(screensSlept),
                              name: NSWorkspace.screensDidSleepNotification, object: nil)
        workspace.addObserver(self, selector: #selector(screensWoke),
                              name: NSWorkspace.screensDidWakeNotification, object: nil)

        updatePlayback()
        if smokeTest { runSmokeTest() }
    }

    // One borderless window per display, all sharing the same player and decoder.
    private func buildWindows() {
        let center = NotificationCenter.default
        for window in windows {
            center.removeObserver(self, name: NSWindow.didChangeOcclusionStateNotification, object: window)
            window.orderOut(nil)
        }
        windows.removeAll()
        videoLayers.removeAll()

        for screen in NSScreen.screens {
            let window = NSWindow(contentRect: screen.frame, styleMask: .borderless,
                                  backing: .buffered, defer: false)
            window.setFrame(screen.frame, display: false)
            // One level above the desktop picture, still behind the desktop icons.
            window.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopWindow)) + 1)
            window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
            window.isOpaque = true
            window.backgroundColor = .black
            window.hasShadow = false
            window.ignoresMouseEvents = true
            window.isReleasedWhenClosed = false

            let view = NSView(frame: NSRect(origin: .zero, size: screen.frame.size))
            view.layer = CALayer()
            view.wantsLayer = true
            // The bundled still appears while the decoder starts or if playback fails.
            if let stillURL = Bundle.main.url(forResource: "cosmos", withExtension: "png"),
               let still = NSImage(contentsOf: stillURL) {
                view.layer?.contents = still
                view.layer?.contentsGravity = .resizeAspectFill
            }
            let videoLayer = AVPlayerLayer(player: player)
            videoLayer.videoGravity = .resizeAspectFill
            videoLayer.frame = view.bounds
            videoLayer.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
            videoLayer.isHidden = playbackFailed
            view.layer?.addSublayer(videoLayer)
            videoLayers.append(videoLayer)
            window.contentView = view
            window.orderFront(nil)

            center.addObserver(self, selector: #selector(occlusionChanged),
                               name: NSWindow.didChangeOcclusionStateNotification, object: window)
            windows.append(window)
        }
    }

    // Keep everyday controls in the menu bar; no Dock icon or settings window is needed.
    private func buildMenu() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        let icon = NSImage(systemSymbolName: "sparkles", accessibilityDescription: "Einstein Ring wallpaper")
        icon?.isTemplate = true
        statusItem.button?.image = icon

        let menu = NSMenu()
        menu.delegate = self
        menu.autoenablesItems = false
        let aboutItem = NSMenuItem(title: "About Einstein Ring", action: #selector(showAbout), keyEquivalent: "")
        aboutItem.target = self
        menu.addItem(aboutItem)
        menu.addItem(.separator())
        pauseItem = NSMenuItem(title: "Pause Motion", action: #selector(togglePause), keyEquivalent: "")
        pauseItem.target = self
        menu.addItem(pauseItem)
        if bundled {
            let item = NSMenuItem(title: "Open at Login", action: #selector(toggleLogin), keyEquivalent: "")
            item.target = self
            loginItem = item
            menu.addItem(item)
            let approval = NSMenuItem(title: "Approve Login Startup…", action: #selector(openLoginSettings), keyEquivalent: "")
            approval.target = self
            approval.isHidden = true
            loginApprovalItem = approval
            menu.addItem(approval)
        }
        menu.addItem(.separator())
        let quitItem = NSMenuItem(title: "Quit Wallpaper", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)
        statusItem.menu = menu
    }

    // Play only while some part of the wallpaper is actually on screen.
    private func updatePlayback() {
        let visible = windows.contains { $0.occlusionState.contains(.visible) }
        let shouldPlay = (visible || smokeTest) && !pausedByUser && !screensAsleep && !playbackFailed
            && !ProcessInfo.processInfo.isLowPowerModeEnabled
        if shouldPlay && player.timeControlStatus == .paused {
            player.play()
        } else if !shouldPlay && player.timeControlStatus != .paused {
            player.pause()
        }
        pauseItem?.title = pausedByUser ? "Resume Motion" : "Pause Motion"
        pauseItem?.isEnabled = !playbackFailed
    }

    // Read the OS preference each time, including changes made in System Settings.
    func menuWillOpen(_ menu: NSMenu) {
        let status = SMAppService.mainApp.status
        loginItem?.state = status == .enabled ? .on : (status == .requiresApproval ? .mixed : .off)
        loginApprovalItem?.isHidden = status != .requiresApproval
    }

    // Login registration must point at an installed app, never a mounted DMG or Downloads.
    @objc private func toggleLogin() {
        let appURL = Bundle.main.bundleURL.resolvingSymlinksInPath()
        let applicationFolders = [URL(fileURLWithPath: "/Applications", isDirectory: true),
                                  FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications")]
        guard applicationFolders.contains(where: { appURL.path.hasPrefix($0.resolvingSymlinksInPath().path + "/") }) else {
            showMessage("Move Einstein Ring to Applications", "Quit the app, drag Einstein Ring into your Applications folder, and open it there before enabling Open at Login.")
            return
        }
        do {
            switch SMAppService.mainApp.status {
            case .enabled, .requiresApproval:
                try SMAppService.mainApp.unregister()
            default:
                try SMAppService.mainApp.register()
                if SMAppService.mainApp.status == .requiresApproval {
                    SMAppService.openSystemSettingsLoginItems()
                }
            }
        } catch {
            showMessage("Couldn’t change Open at Login", error.localizedDescription + " You can also manage Einstein Ring in System Settings → General → Login Items.")
        }
    }

    // Keep approval separate so a pending login item can still be disabled from the app.
    @objc private func openLoginSettings() { SMAppService.openSystemSettingsLoginItems() }

    // Explain the controls and removal without sending people to a terminal.
    @objc private func showAbout() {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "development"
        showMessage("Einstein Ring \(version)", "A black hole, a sky full of stars, and one pale blue dot.\n\nUse this menu to pause motion or open at login. Motion pauses when the desktop is covered, displays sleep, or Low Power Mode is on.\n\nTo remove: turn off Open at Login, quit, then move Einstein Ring from Applications to the Trash. Your desktop picture stays unchanged.")
    }

    // Bring accessory-app alerts forward so failures are visible to Finder users.
    private func showMessage(_ title: String, _ message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    // Retire only this project's old launch agent, and only after the user's consent.
    private func replaceLegacyInstallation() -> Bool {
        let plist = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/com.danishpuri.pale-blue-dot.plist")
        guard FileManager.default.fileExists(atPath: plist.path) else { return true }
        let alert = NSAlert()
        alert.messageText = "Replace the older wallpaper player?"
        alert.informativeText = "Einstein Ring found an installation made with wallpaper.sh. Replace its player and login item to prevent two copies running. Your video files and desktop picture will stay in place. You can enable Open at Login in the new app’s menu."
        alert.addButton(withTitle: "Replace")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return false }
        do {
            let service = "gui/\(getuid())/com.danishpuri.pale-blue-dot"
            if try runLaunchctl(["print", service]) == 0 {
                guard try runLaunchctl(["bootout", service]) == 0 else {
                    showMessage("Couldn’t stop the older player", "Quit the older wallpaper and try opening Einstein Ring again.")
                    return false
                }
            }
            try FileManager.default.removeItem(at: plist)
            return true
        } catch {
            showMessage("Couldn’t replace the older player", error.localizedDescription)
            return false
        }
    }

    // Pass launchctl arguments directly, avoiding shell interpolation of file paths.
    private func runLaunchctl(_ arguments: [String]) throws -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        return process.terminationStatus
    }

    // Leave a still visible if decoding fails; report the problem once rather than looping alerts.
    private func handlePlaybackFailure(_ message: String) {
        guard !playbackFailed else { return }
        playbackFailed = true
        videoLayers.forEach { $0.isHidden = true }
        updatePlayback()
        NSLog("Einstein Ring playback failed: %@", message)
        if !smokeTest { showMessage("Couldn’t play the wallpaper", message + " Download a fresh copy of Einstein Ring and try again.") }
    }

    // Ignore failure notifications from any player other than our own looping queue.
    @objc private func itemFailed(_ notification: Notification) {
        guard let item = notification.object as? AVPlayerItem,
              player.items().contains(where: { $0 === item }) else { return }
        let error = notification.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? Error
        handlePlaybackFailure(error?.localizedDescription ?? "The video stopped unexpectedly.")
    }

    // Exercise actual decoding, desktop windows, and pause/resume without onboarding or login changes.
    private func runSmokeTest() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [self] in
            guard !windows.isEmpty, videoLayers.allSatisfy({ $0.isReadyForDisplay }),
                  player.currentItem?.status == .readyToPlay, player.currentTime().seconds > 0 else {
                fputs("FAIL: wallpaper did not decode and display a frame.\n", stderr)
                exit(1)
            }
            togglePause()
            guard player.rate == 0 else { fputs("FAIL: pause did not stop playback.\n", stderr); exit(1) }
            togglePause()
            guard player.rate > 0 else { fputs("FAIL: resume did not restart playback.\n", stderr); exit(1) }
            print("PASS: decoded video on \(windows.count) display(s), paused, and resumed.")
            NSApp.terminate(nil)
        }
    }

    // Visibility and power notifications all feed the same playback policy.
    @objc private func occlusionChanged() { updatePlayback() }
    // Remember display sleep separately from window occlusion.
    @objc private func screensSlept() { screensAsleep = true; updatePlayback() }
    // Re-evaluate every pause reason on wake instead of unconditionally playing.
    @objc private func screensWoke() { screensAsleep = false; updatePlayback() }
    // Power notifications can arrive off the main queue; UI/player changes stay on it.
    @objc private func powerStateChanged() { DispatchQueue.main.async { self.updatePlayback() } }
    // Rebuild windows after monitors are connected, removed, or rearranged.
    @objc private func screensChanged() { buildWindows(); updatePlayback() }
    // Manual pause stays in effect through power and visibility changes.
    @objc private func togglePause() { pausedByUser.toggle(); updatePlayback() }
    // Removing our windows reveals the unchanged system desktop underneath.
    @objc private func quit() { NSApp.terminate(nil) }
}

// Resolve bundled assets independently of the working directory, while preserving CLI usage.
let executable = Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0])
let bundled = Bundle.main.bundleURL.pathExtension == "app"
let customPath = CommandLine.arguments.dropFirst().first { !$0.hasPrefix("-") }
let videoURL = bundled
    ? Bundle.main.resourceURL!.appendingPathComponent("cosmos.mp4")
    : customPath.map { URL(fileURLWithPath: $0) }
        ?? executable.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("cosmos.mp4")

// Missing resources produce an actionable dialog for app users and stderr for developers.
guard FileManager.default.fileExists(atPath: videoURL.path) else {
    if bundled && !CommandLine.arguments.contains("--check-resources") {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        app.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "The wallpaper video is missing"
        alert.informativeText = "Download a fresh copy of Einstein Ring and drag the entire app to Applications."
        alert.runModal()
    }
    fputs("Video not found at \(videoURL.path). Download the app again, or run ./render-video.sh for the command-line player.\n", stderr)
    exit(1)
}

// Build/CI validation loads the actual media without showing windows or changing preferences.
if CommandLine.arguments.contains("--check-resources") {
    Task {
        do {
            let asset = AVURLAsset(url: videoURL)
            let playable = try await asset.load(.isPlayable)
            let duration = try await asset.load(.duration)
            guard playable, duration.seconds.isFinite, duration.seconds > 0 else {
                fputs("FAIL: video is not playable or has no duration.\n", stderr)
                exit(1)
            }
            if bundled {
                guard let still = Bundle.main.url(forResource: "cosmos", withExtension: "png"),
                      NSImage(contentsOf: still) != nil else {
                    fputs("FAIL: bundled still image is missing or invalid.\n", stderr)
                    exit(1)
                }
            }
            print("PASS: playable video (\(duration.seconds) seconds) and valid bundled resources.")
            exit(0)
        } catch {
            fputs("FAIL: \(error.localizedDescription)\n", stderr)
            exit(1)
        }
    }
    dispatchMain()
}

// Retain the delegate for the lifetime of the native AppKit event loop.
let app = NSApplication.shared
let delegate = Wallpaper(videoURL: videoURL)
app.delegate = delegate
app.run()
