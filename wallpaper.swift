// A tiny wallpaper player. It loops cosmos.mp4 behind the desktop icons and
// pauses whenever nobody can see it, so the video decoder can rest.
//
// usage: pale-blue-dot [path/to/cosmos.mp4]

import AVFoundation
import Cocoa

final class Wallpaper: NSObject, NSApplicationDelegate {
    private let videoURL: URL
    private let player = AVQueuePlayer()
    private var looper: AVPlayerLooper?
    private var windows: [NSWindow] = []
    private var statusItem: NSStatusItem!
    private var pauseItem: NSMenuItem!
    private var pausedByUser = false
    private var screensAsleep = false

    init(videoURL: URL) {
        self.videoURL = videoURL
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        player.isMuted = true
        player.allowsExternalPlayback = false
        player.preventsDisplaySleepDuringVideoPlayback = false   // let the screen sleep as usual
        looper = AVPlayerLooper(player: player, templateItem: AVPlayerItem(url: videoURL))

        buildWindows()
        buildMenu()

        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(screensChanged),
                           name: NSApplication.didChangeScreenParametersNotification, object: nil)
        center.addObserver(self, selector: #selector(powerStateChanged),
                           name: .NSProcessInfoPowerStateDidChange, object: nil)

        let workspace = NSWorkspace.shared.notificationCenter
        workspace.addObserver(self, selector: #selector(screensSlept),
                              name: NSWorkspace.screensDidSleepNotification, object: nil)
        workspace.addObserver(self, selector: #selector(screensWoke),
                              name: NSWorkspace.screensDidWakeNotification, object: nil)

        updatePlayback()
    }

    // One borderless window per display, all sharing the same player and decoder.
    private func buildWindows() {
        let center = NotificationCenter.default
        for window in windows {
            center.removeObserver(self, name: NSWindow.didChangeOcclusionStateNotification, object: window)
            window.orderOut(nil)
        }
        windows.removeAll()

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
            let videoLayer = AVPlayerLayer(player: player)
            videoLayer.videoGravity = .resizeAspectFill
            videoLayer.frame = view.bounds
            videoLayer.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
            view.layer?.addSublayer(videoLayer)
            window.contentView = view
            window.orderFront(nil)

            center.addObserver(self, selector: #selector(occlusionChanged),
                               name: NSWindow.didChangeOcclusionStateNotification, object: window)
            windows.append(window)
        }
    }

    private func buildMenu() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        let icon = NSImage(systemSymbolName: "sparkles", accessibilityDescription: "Pale Blue Dot wallpaper")
        icon?.isTemplate = true
        statusItem.button?.image = icon

        let menu = NSMenu()
        pauseItem = NSMenuItem(title: "Pause Motion", action: #selector(togglePause), keyEquivalent: "")
        pauseItem.target = self
        menu.addItem(pauseItem)
        menu.addItem(.separator())
        let quitItem = NSMenuItem(title: "Quit Wallpaper", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)
        statusItem.menu = menu
    }

    // Play only while some part of the wallpaper is actually on screen.
    private func updatePlayback() {
        let visible = windows.contains { $0.occlusionState.contains(.visible) }
        let shouldPlay = visible && !pausedByUser && !screensAsleep
            && !ProcessInfo.processInfo.isLowPowerModeEnabled
        if shouldPlay && player.timeControlStatus == .paused {
            player.play()
        } else if !shouldPlay && player.timeControlStatus != .paused {
            player.pause()
        }
        pauseItem?.title = pausedByUser ? "Resume Motion" : "Pause Motion"
    }

    @objc private func occlusionChanged() { updatePlayback() }
    @objc private func screensSlept() { screensAsleep = true; updatePlayback() }
    @objc private func screensWoke() { screensAsleep = false; updatePlayback() }
    @objc private func powerStateChanged() { DispatchQueue.main.async { self.updatePlayback() } }
    @objc private func screensChanged() { buildWindows(); updatePlayback() }
    @objc private func togglePause() { pausedByUser.toggle(); updatePlayback() }
    @objc private func quit() { NSApp.terminate(nil) }
}

let executable = Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0])
let videoURL = CommandLine.arguments.count > 1
    ? URL(fileURLWithPath: CommandLine.arguments[1])
    : executable.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("cosmos.mp4")

guard FileManager.default.fileExists(atPath: videoURL.path) else {
    fputs("Video not found at \(videoURL.path). Run ./render-video.sh first.\n", stderr)
    exit(1)
}

let app = NSApplication.shared
let delegate = Wallpaper(videoURL: videoURL)
app.delegate = delegate
app.run()
