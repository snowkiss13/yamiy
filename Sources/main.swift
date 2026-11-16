import AppKit
import Foundation
import CoreGraphics
import ServiceManagement
import IOKit
import IOKit.hid

// Yamiy — keeps your Mac's built-in display dark and the brightness keys
// dead while agents (or anything else) work on the machine, and gives the
// screen back only to you.
//
// STEALTH (default): brightness held at 0 (re-asserted every 0.15s).
//   Brightness keys are blocked twice over: an event tap swallows them
//   (they bypass hidutil on the built-in keyboard), and a hidutil remap
//   covers external keyboards. External displays are taken offline when
//   the Settings toggle is on. Closing the lid enters STEALTH at once.
// OWNER: entered on screen unlock (Touch ID / password). Keys restored,
//   external displays back, brightness set to the level chosen in
//   Settings. Returns to STEALTH on screen lock, on lid close, or after
//   the configured idle time without any input.
//
// The display itself is never put to sleep: screen capture and remote
// control keep working, because brightness and the framebuffer are
// independent. Brightness uses the private DisplayServices API, which is
// why Yamiy is distributed outside the Mac App Store.
//
// UI shape follows the conventions of small macOS menu-bar utilities:
// a crescent status icon, a plain vertical menu with the current state
// and the main actions, and Settings in its own window.

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
// The global hidutil --set does not reliably reach the built-in keyboard
// on Apple Silicon, so the same mapping is also written to every HID
// keyboard device individually through IOHIDManager.
let keyMapEntries: [[String: Any]] = [
    ["HIDKeyboardModifierMappingSrc": UInt64(0xC0000006F), "HIDKeyboardModifierMappingDst": UInt64(0x700000000)],
    ["HIDKeyboardModifierMappingSrc": UInt64(0xC00000070), "HIDKeyboardModifierMappingDst": UInt64(0x700000000)],
]

func applyKeyMappingToKeyboards(_ entries: [[String: Any]]) {
    let mgr = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
    let matching: NSDictionary = [
        kIOHIDPrimaryUsagePageKey: 1,  // Generic Desktop
        kIOHIDPrimaryUsageKey: 6,      // Keyboard
    ]
    IOHIDManagerSetDeviceMatching(mgr, matching)
    guard IOHIDManagerOpen(mgr, IOOptionBits(kIOHIDOptionsTypeNone)) == kIOReturnSuccess,
          let devices = IOHIDManagerCopyDevices(mgr) as? Set<IOHIDDevice> else {
        IOHIDManagerClose(mgr, IOOptionBits(kIOHIDOptionsTypeNone))
        return
    }
    for dev in devices {
        _ = IOHIDDeviceSetProperty(dev, "UserKeyMapping" as CFString, entries as CFArray)
    }
    IOHIDManagerClose(mgr, IOOptionBits(kIOHIDOptionsTypeNone))
}

func disableBrightnessKeys() {
    runHidutil(keyMapJSON)
    applyKeyMappingToKeyboards(keyMapEntries)
}
func enableBrightnessKeys() {
    runHidutil(keyClearJSON)
    applyKeyMappingToKeyboards([])
}

// MARK: - Brightness key event tap

// The internal keyboard's brightness keys travel as NSSystemDefined
// auxiliary-button events and bypass hidutil's UserKeyMapping entirely
// (measured on Apple Silicon: the mapping is set, the screen still
// flashes). The reliable block is a CGEvent tap that swallows those
// events while in STEALTH. An active (event-dropping) tap needs the
// Accessibility permission; without it the tap creation fails and
// Yamiy simply logs the fact and keeps the hidutil + snap-back layers.
var yamiyInStealth = true
var brightnessTap: CFMachPort?

func brightnessTapCallback(proxy: CGEventTapProxy, type: CGEventType,
                           event: CGEvent, refcon: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        if let t = brightnessTap { CGEvent.tapEnable(tap: t, enable: true) }
        return Unmanaged.passUnretained(event)
    }
    guard yamiyInStealth, type.rawValue == 14, // NSSystemDefined
          let ns = NSEvent(cgEvent: event), ns.subtype.rawValue == 8 else {
        return Unmanaged.passUnretained(event)
    }
    let keyCode = (ns.data1 & 0xFFFF0000) >> 16
    if keyCode == 2 || keyCode == 3 { // NX_KEYTYPE_BRIGHTNESS_UP / DOWN
        return nil // swallow: the key press never reaches the OS
    }
    return Unmanaged.passUnretained(event)
}

func startBrightnessTap() {
    let mask = CGEventMask(1 << 14) // NSSystemDefined
    guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap,
                                      place: .headInsertEventTap,
                                      options: .defaultTap,
                                      eventsOfInterest: mask,
                                      callback: brightnessTapCallback,
                                      userInfo: nil) else {
        yamiyLog("brightness event tap unavailable (Accessibility permission not granted?)")
        return
    }
    brightnessTap = tap
    let src = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
    CFRunLoopAddSource(CFRunLoopGetMain(), src, .commonModes)
    CGEvent.tapEnable(tap: tap, enable: true)
    yamiyLog("brightness event tap active")
}

// MARK: - External displays (SkyLight private API)

// An external monitor would happily show everything the built-in panel
// is hiding, so in STEALTH Yamiy can take external displays offline
// entirely (they report "no signal"), and bring them back in OWNER.
// Uses CGSConfigureDisplayEnabled from SkyLight — another private API,
// resolved with dlsym so a missing symbol just disables the feature.
typealias CGSConfigureEnabledFn = @convention(c) (Int32, UInt32, Bool) -> Int32
typealias CGSMainConnectionFn = @convention(c) () -> Int32
var cgsConfigureEnabled: CGSConfigureEnabledFn?
var cgsMainConnection: CGSMainConnectionFn?
var disabledExternalDisplays = Set<UInt32>()

func loadSkyLightDisplayAPI() {
    guard let h = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_NOW) else { return }
    if let s = dlsym(h, "CGSConfigureDisplayEnabled") {
        cgsConfigureEnabled = unsafeBitCast(s, to: CGSConfigureEnabledFn.self)
    }
    if let s = dlsym(h, "CGSMainConnectionID") {
        cgsMainConnection = unsafeBitCast(s, to: CGSMainConnectionFn.self)
    }
    if cgsConfigureEnabled == nil || cgsMainConnection == nil {
        yamiyLog("external display control unavailable (SkyLight symbols missing)")
    }
}

func setExternalDisplay(_ id: UInt32, enabled: Bool) -> Bool {
    guard let cfg = cgsConfigureEnabled, let conn = cgsMainConnection else { return false }
    let err = cfg(conn(), id, enabled)
    if err != 0 { yamiyLog("CGSConfigureDisplayEnabled(\(id), \(enabled)) -> \(err)") }
    return err == 0
}

func onlineExternalDisplayIDs() -> [UInt32] {
    var ids = [UInt32](repeating: 0, count: 16)
    var count: UInt32 = 0
    guard CGGetOnlineDisplayList(16, &ids, &count) == .success else { return [] }
    return ids.prefix(Int(count)).filter { CGDisplayIsBuiltin($0) == 0 }
}

func disableExternalDisplaysNow() {
    guard Prefs.shared.disableExternalDisplays else { return }
    for id in onlineExternalDisplayIDs() where !disabledExternalDisplays.contains(id) {
        if setExternalDisplay(id, enabled: false) {
            disabledExternalDisplays.insert(id)
            yamiyLog("external display \(id) disabled")
        }
    }
}

func enableExternalDisplaysNow() {
    for id in disabledExternalDisplays {
        if setExternalDisplay(id, enabled: true) {
            yamiyLog("external display \(id) re-enabled")
        }
    }
    disabledExternalDisplays.removeAll()
}

// Hot-plug: a display connected while in STEALTH is taken offline too.
// Disabling one fires this callback again, but by then it is no longer
// in the online list, so the second pass is a no-op.
func displayReconfigurationCallback(_ display: UInt32, _ flags: CGDisplayChangeSummaryFlags,
                                    _ userInfo: UnsafeMutableRawPointer?) {
    if flags.contains(.beginConfigurationFlag) { return } // act on completion
    if yamiyInStealth { disableExternalDisplaysNow() }
}

// MARK: - Lid (clamshell) state

// AppleClamshellState on IOPMrootDomain: true while the lid is closed.
// Yamiy treats a closed lid as an immediate STEALTH trigger (no waiting
// for the idle timer), and opening the lid never enters OWNER by itself —
// only a screen unlock does.
func lidIsClosed() -> Bool {
    let entry = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
    if entry == 0 { return false }
    defer { IOObjectRelease(entry) }
    guard let prop = IORegistryEntryCreateCFProperty(
        entry, "AppleClamshellState" as CFString, kCFAllocatorDefault, 0
    )?.takeRetainedValue() as? Bool else { return false }
    return prop
}

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
            "disableExternalDisplays": true,
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
    var disableExternalDisplays: Bool {
        get { d.bool(forKey: "disableExternalDisplays") }
        set { d.set(newValue, forKey: "disableExternalDisplays") }
    }
}

// MARK: - Status icon (a plain crescent, no frame)

// Drawn as a template image so the menu bar tints it like every other
// status icon: a crescent cut out of a circle, nothing around it.
func crescentTemplateImage() -> NSImage {
    let img = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { _ in
        let p = NSBezierPath()
        p.append(NSBezierPath(ovalIn: NSRect(x: 2.5, y: 2.5, width: 13, height: 13)))
        p.append(NSBezierPath(ovalIn: NSRect(x: 7.0, y: 5.5, width: 11, height: 11)))
        p.windingRule = .evenOdd
        NSColor.black.setFill()
        p.fill()
        return true
    }
    img.isTemplate = true
    return img
}

// MARK: - Settings window

final class SettingsWindowController: NSWindowController, NSWindowDelegate {
    private let brightnessSlider = NSSlider(value: 0.65, minValue: 0.3, maxValue: 1.0, target: nil, action: nil)
    private let brightnessValue = NSTextField(labelWithString: "")
    private let idleSlider = NSSlider(value: 300, minValue: 60, maxValue: 900, target: nil, action: nil)
    private let idleValue = NSTextField(labelWithString: "")
    private let loginCheckbox = NSButton(checkboxWithTitle: "ログイン時に起動", target: nil, action: nil)
    private let externalCheckbox = NSButton(checkboxWithTitle: "外部ディスプレイも無効にする", target: nil, action: nil)

    convenience init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 380, height: 235),
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
        externalCheckbox.target = self
        externalCheckbox.action = #selector(externalChanged)

        let stack = NSStackView(views: [
            row("本人モードの明るさ", brightnessSlider, brightnessValue),
            row("無操作で真っ暗に戻るまで", idleSlider, idleValue),
            row("", loginCheckbox),
            row("", externalCheckbox),
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
        externalCheckbox.state = Prefs.shared.disableExternalDisplays ? .on : .off
        updateLabels()
    }

    @objc private func externalChanged() {
        Prefs.shared.disableExternalDisplays = (externalCheckbox.state == .on)
        yamiyLog("disable external displays -> \(externalCheckbox.state == .on)")
        NotificationCenter.default.post(name: Notification.Name("YamiyExternalDisplayPrefChanged"), object: nil)
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
    var stateMenuItem: NSMenuItem!
    var settingsController: SettingsWindowController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        setupStatusItem()
        setupObservers()
        loadSkyLightDisplayAPI()
        CGDisplayRegisterReconfigurationCallback(displayReconfigurationCallback, nil)
        NotificationCenter.default.addObserver(forName: Notification.Name("YamiyExternalDisplayPrefChanged"),
                                               object: nil, queue: .main) { [weak self] _ in
            guard let self else { return }
            if Prefs.shared.disableExternalDisplays {
                if self.mode == .stealth { disableExternalDisplaysNow() }
            } else {
                enableExternalDisplaysNow()
            }
        }
        startBrightnessTap()
        enterStealth("start")
        yamiyLog("Yamiy started")
        Timer.scheduledTimer(withTimeInterval: 0.15, repeats: true) { [weak self] _ in
            self?.tick()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Leave the machine usable: keys back, brightness back.
        enableExternalDisplaysNow()
        enableBrightnessKeys()
        setBrightness(Prefs.shared.ownerBrightness)
        yamiyLog("Yamiy terminated; keys and brightness restored")
    }

    // A plain NSMenu, like most menu-bar apps: state first, then the
    // actions in a vertical list with their shortcuts on the right.
    func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = crescentTemplateImage()

        let menu = NSMenu()
        stateMenuItem = NSMenuItem(title: "真っ暗（ステルス）", action: nil, keyEquivalent: "")
        stateMenuItem.image = NSImage(systemSymbolName: "moon.fill", accessibilityDescription: nil)
        menu.addItem(stateMenuItem)
        menu.addItem(.separator())

        let stealthItem = NSMenuItem(title: "今すぐ真っ暗にする", action: #selector(forceStealth), keyEquivalent: "")
        stealthItem.target = self
        stealthItem.image = NSImage(systemSymbolName: "moon.zzz.fill", accessibilityDescription: nil)
        menu.addItem(stealthItem)
        menu.addItem(.separator())

        let settingsItem = NSMenuItem(title: "設定を開く…", action: #selector(showSettings), keyEquivalent: ",")
        settingsItem.target = self
        settingsItem.image = NSImage(systemSymbolName: "gearshape", accessibilityDescription: nil)
        menu.addItem(settingsItem)

        let aboutItem = NSMenuItem(title: "Yamiyについて", action: #selector(openAbout), keyEquivalent: "")
        aboutItem.target = self
        aboutItem.image = NSImage(systemSymbolName: "info.circle", accessibilityDescription: nil)
        menu.addItem(aboutItem)
        menu.addItem(.separator())

        let quitItem = NSMenuItem(title: "Yamiyを終了", action: #selector(quitApp), keyEquivalent: "q")
        quitItem.target = self
        quitItem.image = NSImage(systemSymbolName: "power", accessibilityDescription: nil)
        menu.addItem(quitItem)

        statusItem.menu = menu
    }

    @objc func forceStealth() {
        if mode != .stealth { enterStealth("menu") }
    }

    @objc func openAbout() {
        NSApp.activate(ignoringOtherApps: true)
        NSApp.orderFrontStandardAboutPanel(nil)
    }

    @objc func quitApp() { NSApp.terminate(nil) }

    @objc func showSettings() {
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
        yamiyInStealth = true
        disableBrightnessKeys()
        lastMapAssert = Date()
        setBrightness(0.0)
        disableExternalDisplaysNow()
        stateMenuItem?.title = "真っ暗（ステルス）"
        yamiyLog("-> STEALTH (\(why))")
    }

    func enterOwner(_ why: String) {
        mode = .owner
        yamiyInStealth = false
        enableExternalDisplaysNow()
        enableBrightnessKeys()
        setBrightness(Prefs.shared.ownerBrightness)
        stateMenuItem?.title = "本人モード"
        yamiyLog("-> OWNER (\(why))")
    }

    var lastLidCheck = Date.distantPast
    var lidClosed = false

    func tick() {
        if Date().timeIntervalSince(lastLidCheck) > 1 {
            lastLidCheck = Date()
            let closed = lidIsClosed()
            if closed != lidClosed {
                lidClosed = closed
                yamiyLog(closed ? "lid closed" : "lid opened")
            }
            if closed && mode != .stealth { enterStealth("lid closed") }
        }
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
    enableExternalDisplaysNow()
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
