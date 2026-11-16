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
// and the main actions, and Settings in its own window. Since 0.3.0 the
// Settings window uses the standard macOS settings layout: a sidebar of
// sections on the left, grouped cards with switches and status dots on
// the right.

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

// Reading the brightness is optional: it is only needed for the
// "carry over the last brightness" setting. A missing symbol just turns
// that setting off in the UI.
typealias DSGetFn = @convention(c) (UInt32, UnsafeMutablePointer<Float>) -> Int32
let dsGet: DSGetFn? = {
    guard let s = dlsym(dsHandle, "DisplayServicesGetBrightness") else { return nil }
    return unsafeBitCast(s, to: DSGetFn.self)
}()

func currentBrightness() -> Float? {
    guard let get = dsGet else { return nil }
    var v: Float = 0
    return get(mainDisplay, &v) == 0 ? v : nil
}

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
// Mirror of the "blockBrightnessKeys" setting, kept in a plain global so
// the tap callback does not have to touch UserDefaults on every event.
var yamiyBlockKeys = true
var brightnessTap: CFMachPort?

func brightnessTapCallback(proxy: CGEventTapProxy, type: CGEventType,
                           event: CGEvent, refcon: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        if let t = brightnessTap { CGEvent.tapEnable(tap: t, enable: true) }
        return Unmanaged.passUnretained(event)
    }
    guard yamiyInStealth, yamiyBlockKeys, type.rawValue == 14, // NSSystemDefined
          let ns = NSEvent(cgEvent: event), ns.subtype.rawValue == 8 else {
        return Unmanaged.passUnretained(event)
    }
    let keyCode = (ns.data1 & 0xFFFF0000) >> 16
    if keyCode == 2 || keyCode == 3 { // NX_KEYTYPE_BRIGHTNESS_UP / DOWN
        return nil // swallow: the key press never reaches the OS
    }
    return Unmanaged.passUnretained(event)
}

// quiet: used by the periodic retry, so a missing permission is logged
// once at launch and not every few seconds.
func startBrightnessTap(quiet: Bool = false) {
    if brightnessTap != nil { return }
    let mask = CGEventMask(1 << 14) // NSSystemDefined
    guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap,
                                      place: .headInsertEventTap,
                                      options: .defaultTap,
                                      eventsOfInterest: mask,
                                      callback: brightnessTapCallback,
                                      userInfo: nil) else {
        if !quiet {
            yamiyLog("brightness event tap unavailable (Accessibility permission not granted?)")
        }
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
// only a screen unlock does. The trigger can be turned off in Settings
// for people who work in OWNER mode with the lid closed.
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

// The four keys that existed before 0.3.0 (ownerBrightness, idleSeconds,
// launchAtLogin, disableExternalDisplays) keep their names, types and
// meaning. The keys added in 0.3.0 default to the behaviour 0.2.x had,
// so an existing install behaves the same after the update.
final class Prefs {
    static let shared = Prefs()
    private let d = UserDefaults.standard
    private init() {
        d.register(defaults: [
            "ownerBrightness": 0.65,
            "idleSeconds": 300.0,
            "launchAtLogin": false,
            "disableExternalDisplays": true,
            "idleReturnEnabled": true,
            "stealthOnLidClose": true,
            "blockBrightnessKeys": true,
            "rememberOwnerBrightness": false,
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
    // Added in 0.3.0.
    var idleReturnEnabled: Bool {
        get { d.bool(forKey: "idleReturnEnabled") }
        set { d.set(newValue, forKey: "idleReturnEnabled") }
    }
    var stealthOnLidClose: Bool {
        get { d.bool(forKey: "stealthOnLidClose") }
        set { d.set(newValue, forKey: "stealthOnLidClose") }
    }
    var blockBrightnessKeys: Bool {
        get { d.bool(forKey: "blockBrightnessKeys") }
        set { d.set(newValue, forKey: "blockBrightnessKeys") }
    }
    var rememberOwnerBrightness: Bool {
        get { d.bool(forKey: "rememberOwnerBrightness") }
        set { d.set(newValue, forKey: "rememberOwnerBrightness") }
    }
}

// MARK: - Localization

// Every string the owner sees (menu, Settings, About) comes from this
// table. The language follows the system: Bundle picks from the listed
// languages by the user's preferred languages, and by the per-app
// language chosen in System Settings when there is one. Anything other
// than Japanese falls back to English.
// To add a language: add a case to YamiyLang, a column to the table,
// its code to yamiyLanguageCodes, and to CFBundleLocalizations in
// Info.plist.
enum YamiyLang { case ja, en }
let yamiyLanguageCodes = ["en", "ja"]
let yamiyLang: YamiyLang = {
    let picked = Bundle.preferredLocalizations(from: yamiyLanguageCodes).first ?? "en"
    return picked.hasPrefix("ja") ? .ja : .en
}()

let yamiyStrings: [String: (ja: String, en: String)] = [
    // Menu
    "menu.state.stealth": (ja: "真っ暗（ステルス）", en: "Dark (Stealth)"),
    "menu.state.owner": (ja: "本人モード", en: "Owner Mode"),
    "menu.stealthNow": (ja: "今すぐ真っ暗にする", en: "Go Dark Now"),
    "menu.settings": (ja: "設定を開く…", en: "Open Settings…"),
    "menu.about": (ja: "Yamiyについて", en: "About Yamiy"),
    "menu.quit": (ja: "Yamiyを終了", en: "Quit Yamiy"),
    // About
    "about.credits": (ja: "Macの画面を、真っ暗なまま止めずに保ちます。",
                      en: "Keeps your Mac's display dark without putting it to sleep."),
    // Settings: frame
    "settings.title": (ja: "Yamiyの設定", en: "Yamiy Settings"),
    "side.general": (ja: "一般", en: "General"),
    "side.stealth": (ja: "ステルス", en: "Stealth"),
    "side.owner": (ja: "本人モード", en: "Owner Mode"),
    // Settings: General
    "general.version": (ja: "バージョン%@", en: "Version %@"),
    "general.state": (ja: "いまの状態", en: "Current State"),
    "general.screen": (ja: "画面", en: "Screen"),
    "general.ax": (ja: "アクセシビリティの許可", en: "Accessibility permission"),
    "general.ax.detail": (ja: "内蔵キーボードの明るさキーを止めるために使います。",
                          en: "Used to block the brightness keys on the built-in keyboard."),
    "general.ax.open": (ja: "設定を開く", en: "Open Settings"),
    "general.tap": (ja: "内蔵キーボードの明るさキーの遮断", en: "Brightness key block on the built-in keyboard"),
    "general.external": (ja: "外部ディスプレイの無効化", en: "External display disabling"),
    "general.launch": (ja: "起動", en: "Startup"),
    "general.login": (ja: "ログイン時に起動", en: "Launch at login"),
    "general.log": (ja: "動作の記録", en: "Activity Log"),
    "general.log.file": (ja: "ログファイル", en: "Log file"),
    "general.log.detail": (ja: "状態が切り替わった時刻と理由を、~/Library/Logs/yamiy.logに書いています。",
                           en: "Mode changes are written with their time and reason to ~/Library/Logs/yamiy.log."),
    "general.log.reveal": (ja: "Finderで表示", en: "Show in Finder"),
    // Settings: Stealth
    "stealth.targets": (ja: "ステルスの間に止めるもの", en: "What Stealth Turns Off"),
    "stealth.keys": (ja: "明るさキーを無効にする", en: "Disable the brightness keys"),
    "stealth.keys.detail": (ja: "明るさキーを押しても、画面が光らないようにします。",
                            en: "Pressing a brightness key does not light the screen."),
    "stealth.external": (ja: "外部ディスプレイも無効にする", en: "Disable external displays too"),
    "stealth.external.detail": (ja: "外部ディスプレイを無効にし、本人モードと終了時に戻します。",
                                en: "External displays are disabled, and restored in owner mode and on quit."),
    "stealth.targets.note": (ja: "内蔵ディスプレイの明るさは、どの設定でも0に保ちます。",
                             en: "The built-in display is held at zero brightness whatever these settings are."),
    "stealth.triggers": (ja: "ステルスへ入るきっかけ", en: "What Starts Stealth"),
    "stealth.lid": (ja: "フタを閉じたら、すぐステルスへ入る", en: "Enter stealth as soon as the lid closes"),
    "stealth.lid.detail": (ja: "オフにすると、フタを閉じても本人モードが続きます。",
                           en: "When off, owner mode continues with the lid closed."),
    "stealth.idle": (ja: "無操作が続いたら、ステルスへ戻る", en: "Return to stealth after a time without input"),
    "stealth.idle.detail": (ja: "オフにすると、本人モードは画面をロックするまで続きます。",
                            en: "When off, owner mode lasts until you lock the screen."),
    "stealth.idle.time": (ja: "ステルスへ戻るまでの無操作の時間", en: "Idle time before returning to stealth"),
    "stealth.triggers.note": (ja: "画面をロックしたときは、どの設定でもステルスへ入ります。",
                              en: "Locking the screen always enters stealth."),
    "time.minutes": (ja: "%ld分", en: "%ld min"),
    "time.seconds": (ja: "%ld秒", en: "%ld sec"),
    // Settings: Owner mode
    "owner.title": (ja: "本人モードの画面の明るさ", en: "Screen Brightness in Owner Mode"),
    "owner.brightness": (ja: "本人モードへ入ったときの明るさ", en: "Brightness when entering owner mode"),
    "owner.remember": (ja: "前回の明るさを引き継ぐ", en: "Carry over the last brightness"),
    "owner.remember.detail": (ja: "本人モードを出るときの明るさを覚え、次に入るときに使います。",
                              en: "Remembers the brightness when you leave owner mode and uses it next time."),
    "owner.remember.unavailable": (ja: "このMacでは明るさを読み取れないため、使えません。",
                                   en: "Unavailable, because this Mac does not report its brightness."),
    "owner.note": (ja: "本人モードへ入るのは、画面のロックを解除したときだけです。Yamiyを終了したときも、画面はこの明るさへ戻ります。",
                   en: "Owner mode starts only when you unlock the screen. The screen also returns to this brightness when you quit Yamiy."),
    // Status words
    "status.stealth": (ja: "ステルス", en: "Stealth"),
    "status.owner": (ja: "本人モード", en: "Owner mode"),
    "status.granted": (ja: "許可済み", en: "Granted"),
    "status.notGranted": (ja: "未許可", en: "Not granted"),
    "status.off": (ja: "オフ", en: "Off"),
    "status.running": (ja: "実行中", en: "Running"),
    "status.stopped": (ja: "停止中", en: "Stopped"),
    "status.unavailable": (ja: "このMacでは使えません", en: "Unavailable on this Mac"),
    "status.disabledCount": (ja: "%ld台を無効にしています", en: "%ld disabled"),
    "status.standby": (ja: "待機中", en: "Standing by"),
]

// A missing key shows the key itself, so a typo is visible on screen.
func L(_ key: String) -> String {
    guard let s = yamiyStrings[key] else { return key }
    return yamiyLang == .ja ? s.ja : s.en
}
func LF(_ key: String, _ args: CVarArg...) -> String {
    String(format: L(key), arguments: args)
}

// MARK: - Status icon (a plain crescent, no frame)

// Drawn as a template image so the menu bar tints it like every other
// status icon: a crescent cut out of a circle, nothing around it.
// The two circles use the same proportions as the app icon's moon
// (measured from icon-1024.png: cut centre offset +0.43r / +0.33r,
// cut radius 0.85r), so the menu bar shows the same crescent shape.
func crescentTemplateImage() -> NSImage {
    let img = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { _ in
        let p = NSBezierPath()
        p.append(NSBezierPath(ovalIn: NSRect(x: 2.5, y: 2.5, width: 13, height: 13)))
        p.append(NSBezierPath(ovalIn: NSRect(x: 6.3, y: 5.6, width: 11.0, height: 11.0)))
        p.windingRule = .evenOdd
        NSColor.black.setFill()
        p.fill()
        return true
    }
    img.isTemplate = true
    return img
}

// MARK: - Settings window parts

// One entry of the sidebar: icon + title, highlighted when selected.
final class SidebarItem: NSView {
    private let icon = NSImageView()
    private let label: NSTextField
    var onClick: (() -> Void)?
    var isSelected = false { didSet { updateLook() } }

    init(title: String, symbol: String) {
        label = NSTextField(labelWithString: title)
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 7
        translatesAutoresizingMaskIntoConstraints = false
        icon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        icon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 15, weight: .regular)
        label.font = .systemFont(ofSize: 13, weight: .medium)
        let s = NSStackView(views: [icon, label])
        s.orientation = .horizontal
        s.spacing = 8
        s.alignment = .centerY
        s.translatesAutoresizingMaskIntoConstraints = false
        addSubview(s)
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 34),
            s.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            s.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 22),
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(title)
        updateLook()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func mouseDown(with event: NSEvent) { onClick?() }

    private func updateLook() {
        layer?.backgroundColor = isSelected ? NSColor.controlAccentColor.cgColor : NSColor.clear.cgColor
        label.textColor = isSelected ? .white : .labelColor
        icon.contentTintColor = isSelected ? .white : .controlAccentColor
    }
}

// A coloured dot followed by a short state word, as in the system's own
// settings ("許可済み", "実行中").
final class StatusBadge: NSView {
    enum Kind { case good, warn, off }
    private let dot = NSView()
    private let text = NSTextField(labelWithString: "")

    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        dot.wantsLayer = true
        dot.layer?.cornerRadius = 4
        dot.translatesAutoresizingMaskIntoConstraints = false
        text.font = .systemFont(ofSize: 13)
        text.textColor = .secondaryLabelColor
        text.translatesAutoresizingMaskIntoConstraints = false
        addSubview(dot)
        addSubview(text)
        NSLayoutConstraint.activate([
            dot.widthAnchor.constraint(equalToConstant: 8),
            dot.heightAnchor.constraint(equalToConstant: 8),
            dot.leadingAnchor.constraint(equalTo: leadingAnchor),
            dot.centerYAnchor.constraint(equalTo: centerYAnchor),
            text.leadingAnchor.constraint(equalTo: dot.trailingAnchor, constant: 6),
            text.trailingAnchor.constraint(equalTo: trailingAnchor),
            text.topAnchor.constraint(equalTo: topAnchor),
            text.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        setContentHuggingPriority(.required, for: .horizontal)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func set(_ kind: Kind, _ s: String) {
        text.stringValue = s
        let color: NSColor
        switch kind {
        case .good: color = .systemGreen
        case .warn: color = .systemOrange
        case .off: color = .tertiaryLabelColor
        }
        dot.layer?.backgroundColor = color.cgColor
    }
}

// A row inside a card: title (and an optional one-line explanation) on
// the left, one control or status on the right.
func makeSettingRow(title: String, detail: String? = nil, accessory: NSView? = nil) -> NSView {
    let t = NSTextField(labelWithString: title)
    t.font = .systemFont(ofSize: 13)
    var left: [NSView] = [t]
    if let detail {
        let dl = NSTextField(wrappingLabelWithString: detail)
        dl.font = .systemFont(ofSize: 11)
        dl.textColor = .secondaryLabelColor
        dl.isSelectable = false
        dl.preferredMaxLayoutWidth = 340
        left.append(dl)
    }
    let lv = NSStackView(views: left)
    lv.orientation = .vertical
    lv.alignment = .leading
    lv.spacing = 2

    let row = NSStackView()
    row.orientation = .horizontal
    row.alignment = .centerY
    row.spacing = 12
    row.edgeInsets = NSEdgeInsets(top: 10, left: 0, bottom: 10, right: 0)
    row.addView(lv, in: .leading)
    if let accessory {
        accessory.setContentHuggingPriority(.required, for: .horizontal)
        row.addView(accessory, in: .trailing)
    }
    return row
}

// A rounded group of rows with hairlines between them.
func makeCard(_ rows: [NSView]) -> NSView {
    let card = NSView()
    card.wantsLayer = true
    card.layer?.backgroundColor = NSColor(white: 1.0, alpha: 0.055).cgColor
    card.layer?.cornerRadius = 10
    card.translatesAutoresizingMaskIntoConstraints = false

    var views: [NSView] = []
    for (i, r) in rows.enumerated() {
        if i > 0 {
            let sep = NSBox()
            sep.boxType = .separator
            views.append(sep)
        }
        views.append(r)
    }
    let s = NSStackView(views: views)
    s.orientation = .vertical
    s.alignment = .leading
    s.spacing = 0
    s.translatesAutoresizingMaskIntoConstraints = false
    card.addSubview(s)
    NSLayoutConstraint.activate([
        s.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 14),
        s.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -14),
        s.topAnchor.constraint(equalTo: card.topAnchor, constant: 2),
        s.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -2),
    ])
    for v in views {
        v.widthAnchor.constraint(equalTo: s.widthAnchor).isActive = true
    }
    return card
}

func makeSectionTitle(_ s: String) -> NSTextField {
    let l = NSTextField(labelWithString: s)
    l.font = .systemFont(ofSize: 13, weight: .semibold)
    return l
}

func makeFootnote(_ s: String) -> NSTextField {
    let l = NSTextField(wrappingLabelWithString: s)
    l.font = .systemFont(ofSize: 11)
    l.textColor = .secondaryLabelColor
    l.isSelectable = false
    l.preferredMaxLayoutWidth = 500
    return l
}

// One page of the right-hand side: section titles, cards and footnotes
// stacked from the top. `gaps` lists the views that start a new group.
func makePage(_ items: [NSView], groupStarts: [NSView] = []) -> NSStackView {
    let page = NSStackView(views: items)
    page.orientation = .vertical
    page.alignment = .leading
    page.spacing = 8
    page.translatesAutoresizingMaskIntoConstraints = false
    for v in items {
        v.widthAnchor.constraint(equalTo: page.widthAnchor).isActive = true
    }
    for (i, v) in items.enumerated() where i > 0 && groupStarts.contains(where: { $0 === v }) {
        page.setCustomSpacing(24, after: items[i - 1])
    }
    return page
}

// MARK: - Settings window

final class SettingsWindowController: NSWindowController, NSWindowDelegate {
    // 本人モード
    private let brightnessSlider = NSSlider(value: 0.65, minValue: 0.1, maxValue: 1.0, target: nil, action: nil)
    private let brightnessValue = NSTextField(labelWithString: "")
    private let rememberSwitch = NSSwitch()
    // ステルス
    private let keysSwitch = NSSwitch()
    private let externalSwitch = NSSwitch()
    private let lidSwitch = NSSwitch()
    private let idleSwitch = NSSwitch()
    private let idlePopup = NSPopUpButton(frame: .zero, pullsDown: false)
    // 一般
    private let loginSwitch = NSSwitch()
    private let modeBadge = StatusBadge()
    private let axBadge = StatusBadge()
    private let axButton = NSButton(title: L("general.ax.open"), target: nil, action: nil)
    private let tapBadge = StatusBadge()
    private let externalBadge = StatusBadge()

    private var sidebarItems: [SidebarItem] = []
    private var pages: [NSView] = []
    private var statusTimer: Timer?

    // Minutes offered for the idle return. A value saved by an older
    // version that is not in this list is added to the menu as it is.
    private let idleChoices: [Double] = [60, 120, 180, 300, 600, 900, 1800, 3600]

    private let settingsWindowSize = NSSize(width: 780, height: 560)

    convenience init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 780, height: 560),
            styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView],
            backing: .buffered, defer: false)
        window.title = L("settings.title")
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.appearance = NSAppearance(named: .darkAqua)
        window.isReleasedWhenClosed = false
        self.init(window: window)
        buildContent()
        select(0)
        refresh()
    }

    // MARK: Layout

    private func buildContent() {
        guard let content = window?.contentView else { return }

        let sidebar = NSVisualEffectView()
        sidebar.material = .sidebar
        sidebar.blendingMode = .behindWindow
        sidebar.state = .active
        sidebar.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(sidebar)

        let main = NSView()
        main.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(main)

        // A plain view, not an NSBox separator: a separator box has an
        // intrinsic size of its own, and this line is pinned to the full
        // height of the window.
        let divider = NSView()
        divider.wantsLayer = true
        divider.layer?.backgroundColor = NSColor(white: 1.0, alpha: 0.12).cgColor
        divider.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(divider)

        // The window has one fixed size. Stating it as constraints means
        // nothing inside can shrink or stretch the window during layout.
        let fixedWidth = content.widthAnchor.constraint(equalToConstant: settingsWindowSize.width)
        let fixedHeight = content.heightAnchor.constraint(equalToConstant: settingsWindowSize.height)
        NSLayoutConstraint.activate([fixedWidth, fixedHeight])

        NSLayoutConstraint.activate([
            sidebar.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            sidebar.topAnchor.constraint(equalTo: content.topAnchor),
            sidebar.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            sidebar.widthAnchor.constraint(equalToConstant: 210),
            divider.leadingAnchor.constraint(equalTo: sidebar.trailingAnchor),
            divider.topAnchor.constraint(equalTo: content.topAnchor),
            divider.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            divider.widthAnchor.constraint(equalToConstant: 1),
            main.leadingAnchor.constraint(equalTo: divider.trailingAnchor),
            main.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            main.topAnchor.constraint(equalTo: content.topAnchor),
            main.bottomAnchor.constraint(equalTo: content.bottomAnchor),
        ])

        // Sidebar
        let sections: [(String, String)] = [
            (L("side.general"), "gearshape"),
            (L("side.stealth"), "moon.fill"),
            (L("side.owner"), "touchid"),
        ]
        for (i, sec) in sections.enumerated() {
            let item = SidebarItem(title: sec.0, symbol: sec.1)
            item.onClick = { [weak self] in self?.select(i) }
            sidebarItems.append(item)
        }
        let sideStack = NSStackView(views: sidebarItems)
        sideStack.orientation = .vertical
        sideStack.alignment = .leading
        sideStack.spacing = 2
        sideStack.translatesAutoresizingMaskIntoConstraints = false
        sidebar.addSubview(sideStack)
        NSLayoutConstraint.activate([
            sideStack.topAnchor.constraint(equalTo: sidebar.topAnchor, constant: 52),
            sideStack.leadingAnchor.constraint(equalTo: sidebar.leadingAnchor, constant: 10),
            sideStack.trailingAnchor.constraint(equalTo: sidebar.trailingAnchor, constant: -10),
        ])
        for item in sidebarItems {
            item.widthAnchor.constraint(equalTo: sideStack.widthAnchor).isActive = true
        }

        // Title of the right-hand side
        let title = NSTextField(labelWithString: L("settings.title"))
        title.font = .systemFont(ofSize: 15, weight: .semibold)
        title.translatesAutoresizingMaskIntoConstraints = false
        main.addSubview(title)
        NSLayoutConstraint.activate([
            title.topAnchor.constraint(equalTo: main.topAnchor, constant: 18),
            title.leadingAnchor.constraint(equalTo: main.leadingAnchor, constant: 24),
        ])

        wireControls()
        pages = [buildGeneralPage(), buildStealthPage(), buildOwnerPage()]
        for page in pages {
            main.addSubview(page)
            NSLayoutConstraint.activate([
                page.topAnchor.constraint(equalTo: main.topAnchor, constant: 60),
                page.leadingAnchor.constraint(equalTo: main.leadingAnchor, constant: 24),
                page.trailingAnchor.constraint(equalTo: main.trailingAnchor, constant: -24),
            ])
        }
        window?.delegate = self
    }

    private func wireControls() {
        let pairs: [(NSControl, Selector)] = [
            (brightnessSlider, #selector(brightnessChanged)),
            (rememberSwitch, #selector(rememberChanged)),
            (keysSwitch, #selector(keysChanged)),
            (externalSwitch, #selector(externalChanged)),
            (lidSwitch, #selector(lidChanged)),
            (idleSwitch, #selector(idleSwitchChanged)),
            (idlePopup, #selector(idlePopupChanged)),
            (loginSwitch, #selector(loginChanged)),
            (axButton, #selector(openAccessibilitySettings)),
        ]
        for (control, action) in pairs {
            control.target = self
            control.action = action
        }
        axButton.bezelStyle = .rounded
        axButton.controlSize = .small
        brightnessSlider.translatesAutoresizingMaskIntoConstraints = false
        brightnessSlider.widthAnchor.constraint(equalToConstant: 190).isActive = true
        brightnessValue.alignment = .right
        brightnessValue.textColor = .secondaryLabelColor
        brightnessValue.translatesAutoresizingMaskIntoConstraints = false
        brightnessValue.widthAnchor.constraint(equalToConstant: 44).isActive = true
    }

    private func buildGeneralPage() -> NSView {
        // Header: icon, name, version
        let iconView = NSImageView()
        iconView.image = NSApp.applicationIconImage
        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.widthAnchor.constraint(equalToConstant: 32).isActive = true
        iconView.heightAnchor.constraint(equalToConstant: 32).isActive = true
        let name = NSTextField(labelWithString: "Yamiy")
        name.font = .systemFont(ofSize: 15, weight: .semibold)
        let nameStack = NSStackView(views: [iconView, name])
        nameStack.orientation = .horizontal
        nameStack.spacing = 12
        nameStack.alignment = .centerY
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? ""
        let versionLabel = NSTextField(labelWithString: LF("general.version", version))
        versionLabel.font = .systemFont(ofSize: 13)
        versionLabel.textColor = .secondaryLabelColor
        let header = NSStackView()
        header.orientation = .horizontal
        header.alignment = .centerY
        header.edgeInsets = NSEdgeInsets(top: 12, left: 0, bottom: 12, right: 0)
        header.addView(nameStack, in: .leading)
        header.addView(versionLabel, in: .trailing)
        let headerCard = makeCard([header])

        // State
        let stateTitle = makeSectionTitle(L("general.state"))
        let axAccessory = NSStackView(views: [axButton, axBadge])
        axAccessory.orientation = .horizontal
        axAccessory.spacing = 10
        axAccessory.alignment = .centerY
        let stateCard = makeCard([
            makeSettingRow(title: L("general.screen"), accessory: modeBadge),
            makeSettingRow(title: L("general.ax"),
                           detail: L("general.ax.detail"),
                           accessory: axAccessory),
            makeSettingRow(title: L("general.tap"), accessory: tapBadge),
            makeSettingRow(title: L("general.external"), accessory: externalBadge),
        ])

        // Launch
        let launchTitle = makeSectionTitle(L("general.launch"))
        let launchCard = makeCard([
            makeSettingRow(title: L("general.login"), accessory: loginSwitch),
        ])

        // Log
        let logButton = NSButton(title: L("general.log.reveal"), target: self, action: #selector(revealLog))
        logButton.bezelStyle = .rounded
        logButton.controlSize = .small
        let logTitle = makeSectionTitle(L("general.log"))
        let logCard = makeCard([
            makeSettingRow(title: L("general.log.file"),
                           detail: L("general.log.detail"),
                           accessory: logButton),
        ])

        return makePage([headerCard, stateTitle, stateCard, launchTitle, launchCard, logTitle, logCard],
                        groupStarts: [stateTitle, launchTitle, logTitle])
    }

    private func buildStealthPage() -> NSView {
        let targetTitle = makeSectionTitle(L("stealth.targets"))
        let targetCard = makeCard([
            makeSettingRow(title: L("stealth.keys"),
                           detail: L("stealth.keys.detail"),
                           accessory: keysSwitch),
            makeSettingRow(title: L("stealth.external"),
                           detail: L("stealth.external.detail"),
                           accessory: externalSwitch),
        ])
        let targetNote = makeFootnote(L("stealth.targets.note"))

        let triggerTitle = makeSectionTitle(L("stealth.triggers"))
        let triggerCard = makeCard([
            makeSettingRow(title: L("stealth.lid"),
                           detail: L("stealth.lid.detail"),
                           accessory: lidSwitch),
            makeSettingRow(title: L("stealth.idle"),
                           detail: L("stealth.idle.detail"),
                           accessory: idleSwitch),
            makeSettingRow(title: L("stealth.idle.time"), accessory: idlePopup),
        ])
        let triggerNote = makeFootnote(L("stealth.triggers.note"))

        return makePage([targetTitle, targetCard, targetNote, triggerTitle, triggerCard, triggerNote],
                        groupStarts: [triggerTitle])
    }

    private func buildOwnerPage() -> NSView {
        let sliderStack = NSStackView(views: [brightnessSlider, brightnessValue])
        sliderStack.orientation = .horizontal
        sliderStack.spacing = 8
        sliderStack.alignment = .centerY

        let title = makeSectionTitle(L("owner.title"))
        let rememberDetail = (dsGet == nil) ? L("owner.remember.unavailable") : L("owner.remember.detail")
        let card = makeCard([
            makeSettingRow(title: L("owner.brightness"), accessory: sliderStack),
            makeSettingRow(title: L("owner.remember"),
                           detail: rememberDetail,
                           accessory: rememberSwitch),
        ])
        let note = makeFootnote(L("owner.note"))
        return makePage([title, card, note])
    }

    // MARK: Section switching

    private func select(_ index: Int) {
        for (i, item) in sidebarItems.enumerated() { item.isSelected = (i == index) }
        for (i, page) in pages.enumerated() { page.isHidden = (i != index) }
    }

    // MARK: Values

    func refresh() {
        brightnessSlider.doubleValue = Double(Prefs.shared.ownerBrightness)
        rememberSwitch.state = Prefs.shared.rememberOwnerBrightness ? .on : .off
        rememberSwitch.isEnabled = (dsGet != nil)
        keysSwitch.state = Prefs.shared.blockBrightnessKeys ? .on : .off
        externalSwitch.state = Prefs.shared.disableExternalDisplays ? .on : .off
        lidSwitch.state = Prefs.shared.stealthOnLidClose ? .on : .off
        idleSwitch.state = Prefs.shared.idleReturnEnabled ? .on : .off
        loginSwitch.state = (SMAppService.mainApp.status == .enabled) ? .on : .off
        reloadIdlePopup()
        updateLabels()
        refreshStatus()
    }

    private func idleTitle(_ seconds: Double) -> String {
        let minutes = seconds / 60
        if minutes >= 1, minutes == minutes.rounded() { return LF("time.minutes", Int(minutes)) }
        return LF("time.seconds", Int(seconds.rounded()))
    }

    private func reloadIdlePopup() {
        var choices = idleChoices
        let current = Prefs.shared.idleSeconds
        if !choices.contains(current) {
            choices.append(current)
            choices.sort()
        }
        idlePopup.removeAllItems()
        for c in choices {
            let item = NSMenuItem(title: idleTitle(c), action: nil, keyEquivalent: "")
            item.representedObject = c
            idlePopup.menu?.addItem(item)
        }
        if let i = choices.firstIndex(of: current) { idlePopup.selectItem(at: i) }
        idlePopup.isEnabled = Prefs.shared.idleReturnEnabled
    }

    private func updateLabels() {
        brightnessValue.stringValue = "\(Int((brightnessSlider.doubleValue * 100).rounded()))%"
    }

    // The status rows show what the app is actually doing right now, so
    // they are re-read once a second while the window is open.
    private func refreshStatus() {
        modeBadge.set(yamiyInStealth ? .off : .good, yamiyInStealth ? L("status.stealth") : L("status.owner"))

        let trusted = AXIsProcessTrusted()
        axBadge.set(trusted ? .good : .warn, trusted ? L("status.granted") : L("status.notGranted"))
        axButton.isHidden = trusted

        if !Prefs.shared.blockBrightnessKeys {
            tapBadge.set(.off, L("status.off"))
        } else if brightnessTap != nil {
            tapBadge.set(.good, L("status.running"))
        } else {
            tapBadge.set(.warn, L("status.stopped"))
        }

        if cgsConfigureEnabled == nil || cgsMainConnection == nil {
            externalBadge.set(.warn, L("status.unavailable"))
        } else if !Prefs.shared.disableExternalDisplays {
            externalBadge.set(.off, L("status.off"))
        } else if !disabledExternalDisplays.isEmpty {
            externalBadge.set(.good, LF("status.disabledCount", disabledExternalDisplays.count))
        } else {
            externalBadge.set(.good, L("status.standby"))
        }

        // Picks up a brightness set by hand or carried over from the
        // last OWNER session while the window is open.
        if Prefs.shared.rememberOwnerBrightness,
           abs(brightnessSlider.doubleValue - Double(Prefs.shared.ownerBrightness)) > 0.005 {
            brightnessSlider.doubleValue = Double(Prefs.shared.ownerBrightness)
            updateLabels()
        }
    }

    // Puts the window on screen and writes what actually happened to
    // yamiy.log. Returns false when the window is not usable (missing,
    // not visible, or far from its intended size), so the caller can
    // open the plain window instead.
    func presentOnScreen() -> Bool {
        guard let w = window else {
            yamiyLog("settings: sidebar window is missing")
            return false
        }
        w.setContentSize(settingsWindowSize)
        w.center()
        showWindow(nil)
        w.makeKeyAndOrderFront(nil)
        // An accessory app is not always made active by the system, and a
        // window of an inactive app can open behind the frontmost app.
        w.orderFrontRegardless()
        let f = w.frame
        let onScreen = (w.screen != nil)
        yamiyLog("settings: sidebar window shown. frame=\(Int(f.origin.x)),\(Int(f.origin.y)) \(Int(f.width))x\(Int(f.height)) visible=\(w.isVisible) key=\(w.isKeyWindow) onScreen=\(onScreen) appActive=\(NSApp.isActive)")
        let sizeOK = f.width >= settingsWindowSize.width * 0.8 && f.height >= settingsWindowSize.height * 0.8
        return w.isVisible && onScreen && sizeOK
    }

    override func showWindow(_ sender: Any?) {
        super.showWindow(sender)
        statusTimer?.invalidate()
        statusTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.refreshStatus()
        }
    }

    func windowWillClose(_ notification: Notification) {
        statusTimer?.invalidate()
        statusTimer = nil
    }

    // MARK: Actions

    @objc private func brightnessChanged() {
        let v = Float(brightnessSlider.doubleValue)
        Prefs.shared.ownerBrightness = v
        updateLabels()
        // Show the chosen level at once when the screen is in use.
        if !yamiyInStealth { setBrightness(v) }
    }

    @objc private func rememberChanged() {
        Prefs.shared.rememberOwnerBrightness = (rememberSwitch.state == .on)
        yamiyLog("remember owner brightness -> \(rememberSwitch.state == .on)")
    }

    @objc private func keysChanged() {
        Prefs.shared.blockBrightnessKeys = (keysSwitch.state == .on)
        yamiyLog("block brightness keys -> \(keysSwitch.state == .on)")
        NotificationCenter.default.post(name: Notification.Name("YamiyBrightnessKeyPrefChanged"), object: nil)
        refreshStatus()
    }

    @objc private func externalChanged() {
        Prefs.shared.disableExternalDisplays = (externalSwitch.state == .on)
        yamiyLog("disable external displays -> \(externalSwitch.state == .on)")
        NotificationCenter.default.post(name: Notification.Name("YamiyExternalDisplayPrefChanged"), object: nil)
        refreshStatus()
    }

    @objc private func lidChanged() {
        Prefs.shared.stealthOnLidClose = (lidSwitch.state == .on)
        yamiyLog("stealth on lid close -> \(lidSwitch.state == .on)")
    }

    @objc private func idleSwitchChanged() {
        Prefs.shared.idleReturnEnabled = (idleSwitch.state == .on)
        idlePopup.isEnabled = Prefs.shared.idleReturnEnabled
        yamiyLog("idle return -> \(idleSwitch.state == .on)")
    }

    @objc private func idlePopupChanged() {
        guard let v = idlePopup.selectedItem?.representedObject as? Double else { return }
        Prefs.shared.idleSeconds = v
        yamiyLog("idle seconds -> \(Int(v))")
    }

    @objc private func loginChanged() {
        do {
            if loginSwitch.state == .on {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            Prefs.shared.launchAtLogin = (loginSwitch.state == .on)
            yamiyLog("launch at login -> \(loginSwitch.state == .on)")
        } catch {
            yamiyLog("launch at login change failed: \(error)")
            refresh()
        }
    }

    @objc private func openAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func revealLog() {
        if FileManager.default.fileExists(atPath: logPath) {
            NSWorkspace.shared.selectFile(logPath, inFileViewerRootedAtPath: "")
        } else {
            NSWorkspace.shared.open(URL(fileURLWithPath: (logPath as NSString).deletingLastPathComponent))
        }
    }
}

// MARK: - Settings window (plain fallback, added in 0.3.1)

// 0.3.0 shipped with the sidebar window above never having been seen on
// a real machine, and on the owner's Mac it did not open. This plain
// window is built the way the 0.2.x window was (one vertical stack
// pinned to the top-left corner, no gravity areas, no layers), which is
// known to open. AppDelegate.showSettings uses it whenever the sidebar
// window failed to build or to show, so Settings can always be reached.
// It edits the same UserDefaults keys through the same Prefs object.
final class SimpleSettingsWindowController: NSWindowController {
    private let brightnessSlider = NSSlider(value: 0.65, minValue: 0.1, maxValue: 1.0, target: nil, action: nil)
    private let brightnessValue = NSTextField(labelWithString: "")
    private let idleSlider = NSSlider(value: 300, minValue: 60, maxValue: 3600, target: nil, action: nil)
    private let idleValue = NSTextField(labelWithString: "")
    private let idleCheckbox = NSButton(checkboxWithTitle: L("stealth.idle"), target: nil, action: nil)
    private let lidCheckbox = NSButton(checkboxWithTitle: L("stealth.lid"), target: nil, action: nil)
    private let keysCheckbox = NSButton(checkboxWithTitle: L("stealth.keys"), target: nil, action: nil)
    private let externalCheckbox = NSButton(checkboxWithTitle: L("stealth.external"), target: nil, action: nil)
    private let rememberCheckbox = NSButton(checkboxWithTitle: L("owner.remember"), target: nil, action: nil)
    private let loginCheckbox = NSButton(checkboxWithTitle: L("general.login"), target: nil, action: nil)

    convenience init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 330),
            styleMask: [.titled, .closable],
            backing: .buffered, defer: false)
        window.title = L("settings.title")
        window.isReleasedWhenClosed = false
        self.init(window: window)
        buildContent()
        refresh()
    }

    private func row(_ label: String, _ control: NSView, _ value: NSTextField) -> NSStackView {
        let l = NSTextField(labelWithString: label)
        l.font = .systemFont(ofSize: 12)
        l.alignment = .right
        l.widthAnchor.constraint(equalToConstant: 210).isActive = true
        let s = NSStackView(views: [l, control, value])
        s.orientation = .horizontal
        s.spacing = 8
        s.alignment = .centerY
        control.widthAnchor.constraint(equalToConstant: 150).isActive = true
        return s
    }

    private func buildContent() {
        guard let content = window?.contentView else { return }
        brightnessSlider.target = self
        brightnessSlider.action = #selector(brightnessChanged)
        idleSlider.target = self
        idleSlider.action = #selector(idleChanged)
        idleCheckbox.target = self
        idleCheckbox.action = #selector(idleCheckboxChanged)
        lidCheckbox.target = self
        lidCheckbox.action = #selector(lidChanged)
        keysCheckbox.target = self
        keysCheckbox.action = #selector(keysChanged)
        externalCheckbox.target = self
        externalCheckbox.action = #selector(externalChanged)
        rememberCheckbox.target = self
        rememberCheckbox.action = #selector(rememberChanged)
        loginCheckbox.target = self
        loginCheckbox.action = #selector(loginChanged)

        let stack = NSStackView(views: [
            row(L("owner.brightness"), brightnessSlider, brightnessValue),
            row(L("stealth.idle.time"), idleSlider, idleValue),
            idleCheckbox,
            lidCheckbox,
            keysCheckbox,
            externalCheckbox,
            rememberCheckbox,
            loginCheckbox,
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 16),
        ])
    }

    func refresh() {
        brightnessSlider.doubleValue = Double(Prefs.shared.ownerBrightness)
        idleSlider.doubleValue = Prefs.shared.idleSeconds
        idleSlider.isEnabled = Prefs.shared.idleReturnEnabled
        idleCheckbox.state = Prefs.shared.idleReturnEnabled ? .on : .off
        lidCheckbox.state = Prefs.shared.stealthOnLidClose ? .on : .off
        keysCheckbox.state = Prefs.shared.blockBrightnessKeys ? .on : .off
        externalCheckbox.state = Prefs.shared.disableExternalDisplays ? .on : .off
        rememberCheckbox.state = Prefs.shared.rememberOwnerBrightness ? .on : .off
        rememberCheckbox.isEnabled = (dsGet != nil)
        loginCheckbox.state = (SMAppService.mainApp.status == .enabled) ? .on : .off
        updateLabels()
    }

    private func updateLabels() {
        brightnessValue.stringValue = "\(Int((brightnessSlider.doubleValue * 100).rounded()))%"
        idleValue.stringValue = LF("time.minutes", Int((idleSlider.doubleValue / 60).rounded()))
    }

    @objc private func brightnessChanged() {
        let v = Float(brightnessSlider.doubleValue)
        Prefs.shared.ownerBrightness = v
        updateLabels()
        if !yamiyInStealth { setBrightness(v) }
    }

    @objc private func idleChanged() {
        // Whole minutes, never less than one.
        let minutes = max(1.0, (idleSlider.doubleValue / 60).rounded())
        Prefs.shared.idleSeconds = minutes * 60
        updateLabels()
    }

    @objc private func idleCheckboxChanged() {
        Prefs.shared.idleReturnEnabled = (idleCheckbox.state == .on)
        idleSlider.isEnabled = Prefs.shared.idleReturnEnabled
        yamiyLog("idle return -> \(idleCheckbox.state == .on)")
    }

    @objc private func lidChanged() {
        Prefs.shared.stealthOnLidClose = (lidCheckbox.state == .on)
        yamiyLog("stealth on lid close -> \(lidCheckbox.state == .on)")
    }

    @objc private func keysChanged() {
        Prefs.shared.blockBrightnessKeys = (keysCheckbox.state == .on)
        yamiyLog("block brightness keys -> \(keysCheckbox.state == .on)")
        NotificationCenter.default.post(name: Notification.Name("YamiyBrightnessKeyPrefChanged"), object: nil)
    }

    @objc private func externalChanged() {
        Prefs.shared.disableExternalDisplays = (externalCheckbox.state == .on)
        yamiyLog("disable external displays -> \(externalCheckbox.state == .on)")
        NotificationCenter.default.post(name: Notification.Name("YamiyExternalDisplayPrefChanged"), object: nil)
    }

    @objc private func rememberChanged() {
        Prefs.shared.rememberOwnerBrightness = (rememberCheckbox.state == .on)
        yamiyLog("remember owner brightness -> \(rememberCheckbox.state == .on)")
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

// MARK: - Exception log (added in 0.3.1)

// AppKit catches an Objective-C exception raised while it handles a
// menu action or a layout pass, reports it to the system log and keeps
// the app running. That is how a window can fail to open without a
// crash and without a line in yamiy.log. This subclass writes the
// exception into yamiy.log as well, and marks the sidebar Settings
// window as failed so the next click opens the plain one.
var settingsWindowFailed = false

final class YamiyApplication: NSApplication {
    override func reportException(_ exception: NSException) {
        settingsWindowFailed = true
        yamiyLog("EXCEPTION \(exception.name.rawValue): \(exception.reason ?? "no reason")")
        let stack = exception.callStackSymbols.prefix(16).joined(separator: "\n    ")
        yamiyLog("EXCEPTION stack:\n    \(stack)")
        super.reportException(exception)
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
    var simpleSettingsController: SimpleSettingsWindowController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        yamiyBlockKeys = Prefs.shared.blockBrightnessKeys
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
        NotificationCenter.default.addObserver(forName: Notification.Name("YamiyBrightnessKeyPrefChanged"),
                                               object: nil, queue: .main) { [weak self] _ in
            guard let self else { return }
            yamiyBlockKeys = Prefs.shared.blockBrightnessKeys
            // The setting only matters in STEALTH: in OWNER the keys are
            // always live.
            guard self.mode == .stealth else { return }
            if yamiyBlockKeys {
                disableBrightnessKeys()
                self.lastMapAssert = Date()
            } else {
                enableBrightnessKeys()
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
        stateMenuItem = NSMenuItem(title: L("menu.state.stealth"), action: nil, keyEquivalent: "")
        stateMenuItem.image = NSImage(systemSymbolName: "moon.fill", accessibilityDescription: nil)
        menu.addItem(stateMenuItem)
        menu.addItem(.separator())

        let stealthItem = NSMenuItem(title: L("menu.stealthNow"), action: #selector(forceStealth), keyEquivalent: "")
        stealthItem.target = self
        stealthItem.image = NSImage(systemSymbolName: "moon.zzz.fill", accessibilityDescription: nil)
        menu.addItem(stealthItem)
        menu.addItem(.separator())

        let settingsItem = NSMenuItem(title: L("menu.settings"), action: #selector(showSettings), keyEquivalent: ",")
        settingsItem.target = self
        settingsItem.image = NSImage(systemSymbolName: "gearshape", accessibilityDescription: nil)
        menu.addItem(settingsItem)

        let aboutItem = NSMenuItem(title: L("menu.about"), action: #selector(openAbout), keyEquivalent: "")
        aboutItem.target = self
        aboutItem.image = NSImage(systemSymbolName: "info.circle", accessibilityDescription: nil)
        menu.addItem(aboutItem)
        menu.addItem(.separator())

        let quitItem = NSMenuItem(title: L("menu.quit"), action: #selector(quitApp), keyEquivalent: "q")
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
        // The standard panel supplies the icon, name and version; the
        // one line of text under them comes from the string table.
        let credits = NSAttributedString(
            string: L("about.credits"),
            attributes: [
                .font: NSFont.systemFont(ofSize: 11),
                .foregroundColor: NSColor.labelColor,
            ])
        NSApp.orderFrontStandardAboutPanel(options: [.credits: credits])
    }

    @objc func quitApp() { NSApp.terminate(nil) }

    // Settings must always open. The sidebar window is tried first. If
    // building or showing it raised an exception (see YamiyApplication),
    // or it did not end up on screen, the plain window is used instead,
    // and every step is written to yamiy.log.
    @objc func showSettings() {
        yamiyLog("settings: open requested")
        NSApp.activate(ignoringOtherApps: true)

        if !settingsWindowFailed {
            if settingsController == nil {
                // Stays true if the build below raises an exception: the
                // action is abandoned there and the next click takes the
                // plain window.
                settingsWindowFailed = true
                let built = SettingsWindowController()
                settingsController = built
                settingsWindowFailed = false
                yamiyLog("settings: sidebar window built")
            }
            if let controller = settingsController {
                controller.refresh()
                if controller.presentOnScreen() { return }
                yamiyLog("settings: sidebar window not usable, opening the plain window")
                settingsWindowFailed = true
            }
        }

        settingsController?.window?.orderOut(nil)
        if simpleSettingsController == nil {
            simpleSettingsController = SimpleSettingsWindowController()
        }
        simpleSettingsController?.refresh()
        simpleSettingsController?.window?.center()
        simpleSettingsController?.showWindow(nil)
        simpleSettingsController?.window?.orderFrontRegardless()
        yamiyLog("settings: plain window shown")
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
        // Carry the brightness the owner was using over to the next OWNER
        // session. Values near zero are ignored: with the lid closed or
        // the panel already dark the reading says nothing about what the
        // owner had chosen.
        if mode == .owner, Prefs.shared.rememberOwnerBrightness,
           let v = currentBrightness(), v >= 0.1 {
            Prefs.shared.ownerBrightness = min(v, 1.0)
        }
        mode = .stealth
        yamiyInStealth = true
        if Prefs.shared.blockBrightnessKeys {
            disableBrightnessKeys()
            lastMapAssert = Date()
        }
        setBrightness(0.0)
        disableExternalDisplaysNow()
        stateMenuItem?.title = L("menu.state.stealth")
        yamiyLog("-> STEALTH (\(why))")
    }

    func enterOwner(_ why: String) {
        mode = .owner
        yamiyInStealth = false
        enableExternalDisplaysNow()
        enableBrightnessKeys()
        setBrightness(Prefs.shared.ownerBrightness)
        stateMenuItem?.title = L("menu.state.owner")
        yamiyLog("-> OWNER (\(why))")
    }

    var lastLidCheck = Date.distantPast
    var lidClosed = false
    var lastTapRetry = Date.distantPast

    func tick() {
        if Date().timeIntervalSince(lastLidCheck) > 1 {
            lastLidCheck = Date()
            let closed = lidIsClosed()
            if closed != lidClosed {
                lidClosed = closed
                yamiyLog(closed ? "lid closed" : "lid opened")
            }
            if closed && mode != .stealth && Prefs.shared.stealthOnLidClose {
                enterStealth("lid closed")
            }
        }
        // The Accessibility permission may be granted after launch. Try
        // the event tap again every few seconds until it exists, so the
        // owner does not have to restart Yamiy.
        if brightnessTap == nil, Date().timeIntervalSince(lastTapRetry) > 5 {
            lastTapRetry = Date()
            if AXIsProcessTrusted() { startBrightnessTap(quiet: true) }
        }
        switch mode {
        case .stealth:
            setBrightness(0.0)
            if Prefs.shared.blockBrightnessKeys, Date().timeIntervalSince(lastMapAssert) > 10 {
                disableBrightnessKeys()
                lastMapAssert = Date()
            }
        case .owner:
            guard Prefs.shared.idleReturnEnabled else { break }
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

// YamiyApplication.shared must be the first use of the shared
// application object, so that the app instance is the subclass.
let delegate = AppDelegate()
let app = YamiyApplication.shared
app.delegate = delegate
app.run()
