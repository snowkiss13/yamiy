import AppKit
import Foundation
import CoreGraphics
import ServiceManagement

// Yamiy — keeps your Mac's built-in display dark and the brightness keys
// dead while agents (or anything else) work on the machine, and gives the
// screen back only to you.
//
// STEALTH (default): brightness held at 0 (re-asserted every 0.15s),
//   brightness keys remapped to no-op via hidutil (re-asserted every 10s).
// OWNER: entered on screen unlock (Touch ID / password). Keys restored,
//   brightness set to the level chosen in Settings. Returns to STEALTH on
//   screen lock, or after the configured idle time without any input.
//
// The display itself is never put to sleep: screen capture and remote
// control keep working, because brightness and the framebuffer are
// independent. Brightness uses the private DisplayServices API, which is
// why Yamiy is distributed outside the Mac App Store.
//
// UI shape follows the conventions of small macOS menu-bar utilities:
// the status icon opens a compact panel with the current state and the
// main actions, and Settings lives in its own window.

// MARK: - Brightness (DisplayServices, private API)

let dsPath = "/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices"
guard let dsHandle = dlopen(dsPath, RTLD_NOW) else {
    FileHandle.standardError.write("Yamiy: cannot load DisplayServices\n".data(using: .utf8)!)
    exit(1)
}
typealias DSSetFn = @convention(c) (UInt32, Float) -> Int32
guard let setSym = dlsym(dsHandle, "DisplayServicesSetBrightness") else {
    FileHandle.standardError.write("Yamiy: DisplayServicesSetBrightness missing\n".data(using: .utf8)!)
    exit(1)
}
let dsSet = unsafeBitCast(setSym, to: DSSetFn.self)
let mainDisplay = CGMainDisplayID()

func setBrightness(_ v: Float) { _ = dsSet(mainDisplay, v) }

// MARK: - Brightness keys (hidutil remap)

// Consumer-page usages 0x6F (brightness up) / 0x70 (brightness down),
// remapped to keyboard usage 0 (reserved = no event at all).
let keyMapJSON = #"{"UserKeyMapping":[{"HIDKeyboardModifierMappingSrc":0xC0000006F,"HIDKeyboardModifierMappingDst":0x700000000},{"HIDKeyboardModifierMappingSrc":0xC00000070,"HIDKeyboardModifierMappingDst":0x700000000}]}"#
let keyClearJSON = #"{"UserKeyMapping":[]}"#

func runHidutil(_ json: String) {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/hidutil")
    p.arguments = ["property", "--set", json]
    p.standardOutput = FileHandle.nullDevice
    p.standardError = FileHandle.nullDevice
    try? p.run()
    p.waitUntilExit()
}
func disableBrightnessKeys() { runHidutil(keyMapJSON) }
func enableBrightnessKeys() { runHidutil(keyClearJSON) }

// MARK: - Log

let logPath = NSString(string: "~/Library/Logs/yamiy.log").expandingTildeInPath
func yamiyLog(_ s: String) {
    let line = "\(Date()) \(s)\n"
    if let h = FileHandle(forWritingAtPath: logPath) {
        h.seekToEndOfFile()
        if let d = line.data(using: .utf8) { h.write(d) }
        h.closeFile()
    } else {
        FileManager.default.createFile(atPath: logPath, contents: line.data(using: .utf8))
    }
}

// MARK: - Settings

final class Prefs {
    static let shared = Prefs()
    private let d = UserDefaults.standard
    private init() {
        d.register(defaults: [
            "ownerBrightness": 0.65,
            "idleSeconds": 300.0,
            "launchAtLogin": false,
        ])
    }
    var ownerBrightness: Float {
        get { Float(d.double(forKey: "ownerBrightness")) }
        set { d.set(Double(newValue), forKey: "ownerBrightness") }
    }
    var idleSeconds: Double {
        get { d.double(forKey: "idleSeconds") }
        set { d.set(newValue, forKey: "idleSeconds") }
    }
    var launchAtLogin: Bool {
        get { d.bool(forKey: "launchAtLogin") }
        set { d.set(newValue, forKey: "launchAtLogin") }
    }
}

// MARK: - Panel (status icon popover)

final class PanelViewController: NSViewController {
    let statusLabel = NSTextField(labelWithString: "")
    weak var delegate: AppDelegate?

    override func loadView() {
        let root = NSView()
        root.frame = NSRect(x: 0, y: 0, width: 320, height: 168)

        statusLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        let desc = NSTextField(wrappingLabelWithString:
            "画面は真っ暗なまま、Mac は起きています。本人モードは Touch ID でロックを解除したときだけです。")
        desc.font = .systemFont(ofSize: 11)
        desc.textColor = .secondaryLabelColor

        let settingsBtn = NSButton(title: "設定を開く…", target: nil, action: nil)
        settingsBtn.bezelStyle = .rounded
        settingsBtn.target = self
        settingsBtn.action = #selector(openSettings)
        let aboutBtn = NSButton(title: "Yamiyについて", target: nil, action: nil)
        aboutBtn.bezelStyle = .rounded
        aboutBtn.target = self
        aboutBtn.action = #selector(openAbout)
        let quitBtn = NSButton(title: "終了", target: nil, action: nil)
        quitBtn.bezelStyle = .rounded
        quitBtn.target = self
        quitBtn.action = #selector(quitApp)

        let buttons = NSStackView(views: [settingsBtn, aboutBtn, quitBtn])
        buttons.orientation = .horizontal
        buttons.spacing = 8

        let stack = NSStackView(views: [statusLabel, desc, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 14),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -14),
            stack.topAnchor.constraint(equalTo: root.topAnchor, constant: 12),
        ])
        self.view = root
    }

    @objc func openSettings() { delegate?.showSettings() }
    @objc func openAbout() {
        NSApp.activate(ignoringOtherApps: true)
        NSApp.orderFrontStandardAboutPanel(nil)
    }
    @objc func quitApp() { NSApp.terminate(nil) }
}

// MARK: - Settings window

final class SettingsWindowController: NSWindowController, NSWindowDelegate {
    private let brightnessSlider = NSSlider(value: 0.65, minValue: 0.3, maxValue: 1.0, target: nil, action: nil)
    private let brightnessValue = NSTextField(labelWithString: "")
    private let idleSlider = NSSlider(value: 300, minValue: 60, maxValue: 900, target: nil, action: nil)
    private let idleValue = NSTextField(labelWithString: "")
    private let loginCheckbox = NSButton(checkboxWithTitle: "ログイン時に起動", target: nil, action: nil)

    convenience init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 380, height: 190),
            styleMask: [.titled, .closable],
            backing: .buffered, defer: false)
        window.title = "Yamiy 設定"
        window.isReleasedWhenClosed = false
        self.init(window: window)
        buildContent()
        refresh()
    }

    private func row(_ label: String, _ control: NSView, _ value: NSTextField? = nil) -> NSStackView {
        let l = NSTextField(labelWithString: label)
        l.font = .systemFont(ofSize: 12)
        l.alignment = .right
        l.widthAnchor.constraint(equalToConstant: 150).isActive = true
        var views: [NSView] = [l, control]
        if let v = value { views.append(v) }
        let s = NSStackView(views: views)
        s.orientation = .horizontal
        s.spacing = 8
        s.alignment = .centerY
        control.widthAnchor.constraint(equalToConstant: 140).isActive = true
        return s
    }

    private func buildContent() {
        guard let content = window?.contentView else { return }
        brightnessSlider.target = self
        brightnessSlider.action = #selector(brightnessChanged)
        idleSlider.target = self
        idleSlider.action = #selector(idleChanged)
        loginCheckbox.target = self
        loginCheckbox.action = #selector(loginChanged)

        let stack = NSStackView(views: [
            row("本人モードの明るさ", brightnessSlider, brightnessValue),
            row("無操作で真っ暗に戻るまで", idleSlider, idleValue),
            row("", loginCheckbox),
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 16),
        ])
        window?.delegate = self
    }

    func refresh() {
        brightnessSlider.doubleValue = Double(Prefs.shared.ownerBrightness)
        idleSlider.doubleValue = Prefs.shared.idleSeconds
        loginCheckbox.state = (SMAppService.mainApp.status == .enabled) ? .on : .off
        updateLabels()
    }

    private func updateLabels() {
        brightnessValue.stringValue = "\(Int((brightnessSlider.doubleValue * 100).rounded()))%"
        idleValue.stringValue = "\(Int(idleSlider.doubleValue / 60))分"
    }

    @objc private func brightnessChanged() {
        Prefs.shared.ownerBrightness = Float(brightnessSlider.doubleValue)
        updateLabels()
    }

    @objc private func idleChanged() {
        Prefs.shared.idleSeconds = idleSlider.doubleValue
        updateLabels()
    }

    @objc private func loginChanged() {
        do {
            if loginCheckbox.state == .on {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            Prefs.shared.launchAtLogin = (loginCheckbox.state == .on)
            yamiyLog("launch at login -> \(loginCheckbox.state == .on)")
        } catch {
            yamiyLog("launch at login change failed: \(error)")
            refresh()
        }
    }
}

// MARK: - App

enum Mode { case stealth, owner }

final class AppDelegate: NSObject, NSApplicationDelegate {
    var mode: Mode = .stealth
    var lastMapAssert = Date.distantPast

    var statusItem: NSStatusItem!
    let panel = PanelViewController()
    var panelWindow: NSPanel?
    var outsideClickMonitor: Any?
    var settingsController: SettingsWindowController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        setupStatusItem()
        setupObservers()
        enterStealth("start")
        yamiyLog("Yamiy started")
        Timer.scheduledTimer(withTimeInterval: 0.15, repeats: true) { [weak self] _ in
            self?.tick()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Leave the machine usable: keys back, brightness back.
        enableBrightnessKeys()
        setBrightness(Prefs.shared.ownerBrightness)
        yamiyLog("Yamiy terminated; keys and brightness restored")
    }

    func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.title = "Yamiy"
        statusItem.button?.target = self
        statusItem.button?.action = #selector(togglePanel)
        panel.delegate = self
    }

    // The panel is a borderless floating window hung under the status
    // icon, like other small menu-bar utilities: it opens on icon click,
    // and closes on icon re-click or on any click outside it.
    func makePanelWindow() -> NSPanel {
        let w = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 320, height: 168),
                        styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        w.level = .floating
        w.isOpaque = false
        w.backgroundColor = .windowBackgroundColor
        w.hasShadow = true
        w.contentViewController = panel
        return w
    }

    @objc func togglePanel() {
        if let w = panelWindow, w.isVisible {
            closePanel()
            return
        }
        guard let button = statusItem.button, let buttonWindow = button.window else { return }
        if panelWindow == nil { panelWindow = makePanelWindow() }
        guard let w = panelWindow else { return }
        let buttonRect = buttonWindow.convertToScreen(button.frame)
        let x = buttonRect.maxX - w.frame.width
        let y = buttonRect.minY - w.frame.height - 4
        w.setFrameOrigin(NSPoint(x: x, y: y))
        w.orderFrontRegardless()
        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            guard let self, let w = self.panelWindow, w.isVisible else { return }
            let p = NSEvent.mouseLocation
            if !w.frame.contains(p), let bw = self.statusItem.button?.window,
               !bw.convertToScreen(self.statusItem.button!.frame).contains(p) {
                self.closePanel()
            }
        }
        yamiyLog("panel opened")
    }

    func closePanel() {
        panelWindow?.orderOut(nil)
        if let m = outsideClickMonitor {
            NSEvent.removeMonitor(m)
            outsideClickMonitor = nil
        }
    }

    func showSettings() {
        closePanel()
        if settingsController == nil { settingsController = SettingsWindowController() }
        settingsController?.refresh()
        settingsController?.window?.center()
        NSApp.activate(ignoringOtherApps: true)
        settingsController?.showWindow(nil)
    }

    func setupObservers() {
        let dnc = DistributedNotificationCenter.default()
        dnc.addObserver(forName: Notification.Name("com.apple.screenIsUnlocked"), object: nil, queue: nil) { [weak self] _ in
            if self?.mode != .owner { self?.enterOwner("unlock") }
        }
        dnc.addObserver(forName: Notification.Name("com.apple.screenIsLocked"), object: nil, queue: nil) { [weak self] _ in
            if self?.mode != .stealth { self?.enterStealth("lock") }
        }
    }

    func enterStealth(_ why: String) {
        mode = .stealth
        disableBrightnessKeys()
        lastMapAssert = Date()
        setBrightness(0.0)
        panel.statusLabel.stringValue = "状態: 真っ暗（ステルス）"
        yamiyLog("-> STEALTH (\(why))")
    }

    func enterOwner(_ why: String) {
        mode = .owner
        enableBrightnessKeys()
        setBrightness(Prefs.shared.ownerBrightness)
        panel.statusLabel.stringValue = "状態: 本人モード"
        yamiyLog("-> OWNER (\(why))")
    }

    func tick() {
        switch mode {
        case .stealth:
            setBrightness(0.0)
            if Date().timeIntervalSince(lastMapAssert) > 10 {
                disableBrightnessKeys()
                lastMapAssert = Date()
            }
        case .owner:
            let idle = CGEventSource.secondsSinceLastEventType(
                .hidSystemState, eventType: CGEventType(rawValue: UInt32.max)!)
            if idle > Prefs.shared.idleSeconds { enterStealth("idle \(Int(Prefs.shared.idleSeconds))s") }
        }
    }
}

// Restore the machine on SIGTERM/SIGINT too: NSApplication's
// applicationWillTerminate does not run when the process is killed.
func restoreAndExit() -> Never {
    enableBrightnessKeys()
    setBrightness(Prefs.shared.ownerBrightness)
    yamiyLog("Yamiy stopped by signal; keys and brightness restored")
    exit(0)
}
signal(SIGTERM, SIG_IGN)
signal(SIGINT, SIG_IGN)
let sigSrc = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
sigSrc.setEventHandler { restoreAndExit() }
sigSrc.resume()
let sigSrc2 = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
sigSrc2.setEventHandler { restoreAndExit() }
sigSrc2.resume()

let delegate = AppDelegate()
NSApplication.shared.delegate = delegate
NSApplication.shared.run()
