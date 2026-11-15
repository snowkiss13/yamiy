import AppKit
import Foundation
import CoreGraphics

// Yamiy — keeps your Mac's built-in display dark and the brightness keys
// dead while agents (or anything else) work on the machine, and gives the
// screen back only to you.
//
// STEALTH (default): brightness held at 0 (re-asserted every 0.15s),
//   brightness keys remapped to no-op via hidutil (re-asserted every 10s).
// OWNER: entered on screen unlock (Touch ID / password). Keys restored,
//   brightness set to a comfortable level. Returns to STEALTH on screen
//   lock, or after 300s without any input.
//
// The display itself is never put to sleep: screen capture and remote
// control keep working, because brightness and the framebuffer are
// independent. Brightness uses the private DisplayServices API, which is
// why Yamiy is distributed outside the Mac App Store.

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

// MARK: - App

enum Mode { case stealth, owner }

final class AppDelegate: NSObject, NSApplicationDelegate {
    var mode: Mode = .stealth
    var lastMapAssert = Date.distantPast
    let ownerBrightness: Float = 0.65
    let idleSecondsToStealth: Double = 300

    var statusItem: NSStatusItem!
    var modeItem: NSMenuItem!

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
        setBrightness(ownerBrightness)
        yamiyLog("Yamiy terminated; keys and brightness restored")
    }

    func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.title = "Yamiy"
        let menu = NSMenu()
        modeItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        menu.addItem(modeItem)
        menu.addItem(.separator())
        let hint = NSMenuItem(title: "本人モード: Touch IDでロック → 指紋で解除", action: nil, keyEquivalent: "")
        menu.addItem(hint)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Yamiyを終了", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        statusItem.menu = menu
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
        modeItem?.title = "状態: 真っ暗（ステルス）"
        yamiyLog("-> STEALTH (\(why))")
    }

    func enterOwner(_ why: String) {
        mode = .owner
        enableBrightnessKeys()
        setBrightness(ownerBrightness)
        modeItem?.title = "状態: 本人モード"
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
            if idle > idleSecondsToStealth { enterStealth("idle \(Int(idleSecondsToStealth))s") }
        }
    }
}

// Restore the machine on SIGTERM/SIGINT too: NSApplication's
// applicationWillTerminate does not run when the process is killed.
signal(SIGTERM, SIG_IGN)
signal(SIGINT, SIG_IGN)
let sigSrc = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
sigSrc.setEventHandler {
    enableBrightnessKeys()
    setBrightness(0.65)
    yamiyLog("Yamiy stopped by signal; keys and brightness restored")
    exit(0)
}
sigSrc.resume()
let sigSrc2 = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
sigSrc2.setEventHandler {
    enableBrightnessKeys()
    setBrightness(0.65)
    yamiyLog("Yamiy stopped by signal; keys and brightness restored")
    exit(0)
}
sigSrc2.resume()

let delegate = AppDelegate()
NSApplication.shared.delegate = delegate
NSApplication.shared.run()
