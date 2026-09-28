import Darwin
import AppKit
import Foundation
import Darwin
import CoreGraphics

struct HUDSettings: Codable {
    var backgroundOpacity: Double = 0.78
    var selectedPositionID: String?
    var originX: Double = 0
    var originY: Double = 0
    var hasManualOrigin = false
    var positionLocked = false
    var hideWhenInactive = false
    var keepOnTop = true
}

enum HUDSettingsStore {
    static let supportURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/lsfg-metal", isDirectory: true)
    static let fileURL = supportURL.appendingPathComponent("hud-settings.plist")

    static func load() -> HUDSettings {
        guard let data = try? Data(contentsOf: fileURL),
              let settings = try? PropertyListDecoder().decode(HUDSettings.self, from: data) else {
            return HUDSettings()
        }
        return settings
    }

    static func save(_ settings: HUDSettings) {
        try? FileManager.default.createDirectory(at: supportURL, withIntermediateDirectories: true)
        guard let data = try? PropertyListEncoder().encode(settings) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}

// Ported from the LSFG Metal Installer HUD implementation; kept standalone so the runtime can ship the same HUD logic.

enum HUDSettingsStyle {
    static let accent = NSColor(calibratedRed: 103.0 / 255.0, green: 100.0 / 255.0, blue: 100.0 / 255.0, alpha: 1)
    static let textPrimary = NSColor(calibratedWhite: 0.12, alpha: 1)
    static let accentLight = NSColor(calibratedRed: 128.0 / 255.0, green: 124.0 / 255.0, blue: 124.0 / 255.0, alpha: 1)
    static let accentSoft = accent.withAlphaComponent(0.22)
    static let textSecondary = NSColor(calibratedWhite: 0.24, alpha: 0.72)
    static let textFaint = NSColor(calibratedWhite: 0.30, alpha: 0.55)
    static let cardFill = NSColor(calibratedWhite: 1.0, alpha: 0.55)
    static let cardBorder = NSColor(calibratedWhite: 0.0, alpha: 0.08)

    static func card() -> NSView {
        let view = NSView()
        view.translatesAutoresizingMaskIntoConstraints = false
        view.wantsLayer = true
        view.layer?.cornerRadius = 16
        view.layer?.masksToBounds = true
        view.layer?.backgroundColor = cardFill.cgColor
        view.layer?.borderWidth = 1
        view.layer?.borderColor = cardBorder.cgColor
        view.layer?.shadowColor = NSColor.black.cgColor
        view.layer?.shadowOpacity = 0.12
        view.layer?.shadowRadius = 14
        view.layer?.shadowOffset = CGSize(width: 0, height: -4)
        return view
    }

    static func innerStack() -> NSStackView {
        let stack = NSStackView()
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        return stack
    }

    static func section(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = NSFont.systemFont(ofSize: 10, weight: .heavy)
        label.textColor = accent
        return label
    }

    static func styleCheckbox(_ button: NSButton) {
        button.font = NSFont.systemFont(ofSize: 12.5, weight: .medium)
        button.contentTintColor = accent
        button.alignment = .left
    }

    static func styleButton(_ button: NSButton) {
        button.wantsLayer = true
        button.isBordered = false
        button.bezelStyle = .regularSquare
        button.font = NSFont.systemFont(ofSize: 12.5, weight: .medium)
        button.contentTintColor = textPrimary
        button.layer?.cornerRadius = 8
        button.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.46).cgColor
        button.layer?.borderWidth = 1
        button.layer?.borderColor = cardBorder.cgColor
        button.layer?.shadowColor = NSColor.black.cgColor
        button.layer?.shadowOpacity = 0.05
        button.layer?.shadowRadius = 5
        button.layer?.shadowOffset = CGSize(width: 0, height: -1)
    }

    static func styleProminentButton(_ button: NSButton) {
        button.wantsLayer = true
        button.isBordered = false
        button.bezelStyle = .regularSquare
        button.font = NSFont.systemFont(ofSize: 13, weight: .semibold)
        button.contentTintColor = .white
        button.layer?.cornerRadius = 8
        button.layer?.backgroundColor = accent.cgColor
        button.layer?.shadowColor = accent.cgColor
        button.layer?.shadowOpacity = 0.14
        button.layer?.shadowRadius = 7
        button.layer?.shadowOffset = CGSize(width: 0, height: -1)
    }
}

final class HUDAccentSliderCell: NSSliderCell {
    private let accentColor = NSColor(calibratedRed: 103.0 / 255.0, green: 100.0 / 255.0, blue: 100.0 / 255.0, alpha: 1)

    override func drawBar(inside rect: NSRect, flipped: Bool) {
        let track = rect.insetBy(dx: 1, dy: max(1, (rect.height - 4) / 2))
        let radius = track.height / 2

        NSColor.black.withAlphaComponent(0.10).setFill()
        NSBezierPath(roundedRect: track, xRadius: radius, yRadius: radius).fill()

        let range = maxValue - minValue
        let fraction = range > 0 ? CGFloat((doubleValue - minValue) / range) : 0
        let fill = NSRect(x: track.minX, y: track.minY, width: track.width * min(max(fraction, 0), 1), height: track.height)

        accentColor.setFill()
        NSBezierPath(roundedRect: fill, xRadius: radius, yRadius: radius).fill()
    }

    override func drawKnob(_ knobRect: NSRect) {
        let diameter: CGFloat = 16
        let knob = NSRect(
            x: knobRect.midX - diameter / 2,
            y: knobRect.midY - diameter / 2 - 1.5,
            width: diameter,
            height: diameter
        )

        accentColor.setFill()
        NSBezierPath(ovalIn: knob).fill()

        NSColor.white.withAlphaComponent(0.95).setStroke()
        let outline = NSBezierPath(ovalIn: knob.insetBy(dx: 0.5, dy: 0.5))
        outline.lineWidth = 1
        outline.stroke()
    }
}

final class HUDSettingsBackgroundView: NSView {
    override func draw(_ dirtyRect: NSRect) {
        NSColor(calibratedRed: 0.95, green: 0.95, blue: 0.95, alpha: 1).setFill()
        bounds.fill()
    }
}

struct Stats {
    let pid: pid_t
    let source: Int
    let original: Int
    let generated: Int
    let total: Int
    let sourceFPS: Int?
}

final class HUDView: NSView {
    weak var controller: HUDController?
    var multiplier = 2
    var nativeFPS: Int?
    var outputFPS: Int?
    var generatedFPS: Int?
    var originalCount: Int?
    var generatedCount: Int?
    var totalCount: Int?
    var generationActive = false
    var backgroundOpacity: CGFloat = 0.78
    var statusText = "WAITING FOR LSFG"

    private var dragStartScreen: NSPoint?
    private var panelStart: NSPoint?

    override var isOpaque: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        let bounds = self.bounds
        let card = NSBezierPath(roundedRect: bounds, xRadius: 16, yRadius: 16)

        // Dark glass surface, matching the installer's geometry while keeping the HUD dark.
        NSColor.black.withAlphaComponent(backgroundOpacity).setFill()
        card.fill()

        let border = NSBezierPath(
            roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5),
            xRadius: 16,
            yRadius: 16
        )
        NSColor.white.withAlphaComponent(0.14).setStroke()
        border.lineWidth = 1
        border.stroke()

        // Small accent rule reinforces the installer's RGB(103,100,100) visual language.
        HUDSettingsStyle.accent.withAlphaComponent(0.72).setFill()
        NSBezierPath(
            roundedRect: NSRect(x: 16, y: bounds.height - 28, width: 42, height: 2),
            xRadius: 1,
            yRadius: 1
        ).fill()

        let dotColor = generationActive
            ? NSColor.systemGreen
            : HUDSettingsStyle.accent.withAlphaComponent(0.85)
        dotColor.setFill()
        NSBezierPath(ovalIn: NSRect(x: 15, y: bounds.height - 23, width: 8, height: 8)).fill()

        let titleAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12.5, weight: .semibold),
            .foregroundColor: NSColor.white.withAlphaComponent(0.92)
        ]
        let valueAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 18, weight: .bold),
            .foregroundColor: NSColor.white
        ]
        let labelAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 9, weight: .medium),
            .foregroundColor: NSColor.white.withAlphaComponent(0.54)
        ]
        let countAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .medium),
            .foregroundColor: NSColor.white.withAlphaComponent(0.70)
        ]
        let statusAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 9, weight: .semibold),
            .foregroundColor: generationActive
                ? HUDSettingsStyle.accent
                : NSColor.white.withAlphaComponent(0.48)
        ]

        let title = "LSFG \(multiplier)×"
        (title as NSString).draw(
            at: NSPoint(x: 31, y: bounds.height - 27),
            withAttributes: titleAttrs
        )

        ("\(generationActive ? "FRAME GEN ACTIVE" : "FRAME GEN IDLE")" as NSString)
            .draw(
                at: NSPoint(x: bounds.width - 118, y: bounds.height - 26),
                withAttributes: statusAttrs
            )

        let columns: [(String, String)] = [
            ("NATIVE", nativeFPS.map { "\($0) FPS" } ?? "--"),
            ("OUTPUT", outputFPS.map { "\($0) FPS" } ?? "--"),
            ("GENERATED", generatedFPS.map { "+\($0)/s" } ?? "--")
        ]
        let columnWidth = bounds.width / CGFloat(columns.count)

        for (index, item) in columns.enumerated() {
            let x = 15 + CGFloat(index) * columnWidth
            (item.0 as NSString).draw(
                at: NSPoint(x: x, y: 54),
                withAttributes: labelAttrs
            )
            (item.1 as NSString).draw(
                at: NSPoint(x: x, y: 31),
                withAttributes: valueAttrs
            )
        }

        let original = originalCount.map(String.init) ?? "--"
        let generated = generatedCount.map(String.init) ?? "--"
        let total = totalCount.map(String.init) ?? "--"
        let counters = "Original \(original)  •  Generated \(generated)  •  Total \(total)"

        (counters as NSString).draw(
            at: NSPoint(x: 15, y: 13),
            withAttributes: countAttrs
        )
    }

    override func mouseDown(with event: NSEvent) {
        guard event.type == .leftMouseDown, let window else { return }
        dragStartScreen = window.convertPoint(toScreen: event.locationInWindow)
        panelStart = window.frame.origin
        controller?.beginManualPositioning()
    }

    override func mouseDragged(with event: NSEvent) {
        guard let window, let dragStartScreen, let panelStart else { return }
        let currentScreen = window.convertPoint(toScreen: event.locationInWindow)
        let origin = NSPoint(
            x: panelStart.x + (currentScreen.x - dragStartScreen.x),
            y: panelStart.y + (currentScreen.y - dragStartScreen.y)
        )
        controller?.updateManualPosition(origin)
    }

    override func mouseUp(with event: NSEvent) {
        let origin = window?.frame.origin ?? .zero
        controller?.saveManualOrigin(origin)
        dragStartScreen = nil
        panelStart = nil
    }

    override func rightMouseDown(with event: NSEvent) {
        controller?.showContextMenu(with: event, in: self)
    }
}

final class HUDController: NSObject, NSApplicationDelegate {
    private enum Defaults {
        static let opacity = "LSFGHUD.backgroundOpacity"
        static let originX = "LSFGHUD.originX"
        static let originY = "LSFGHUD.originY"
        static let hasManualOrigin = "LSFGHUD.hasManualOrigin"
        static let positionLocked = "LSFGHUD.positionLocked"
        static let hideWhenInactive = "LSFGHUD.hideWhenInactive"
        static let keepOnTop = "LSFGHUD.keepOnTop"
    }

    private let logURL: URL
    private let fallbackMultiplier: Int
    private let parentPID: pid_t?
    private var parentCheckTicks = 0
    private var isDraggingHUD = false
    private var instanceLockFD: Int32 = -1
    private var panel: NSPanel?
    private var view: HUDView?
    private var timer: Timer?
    private var logWatcher: DispatchSourceFileSystemObject?
    private var logFileDescriptor: Int32 = -1
    private var settingsWindow: NSWindow?
    private weak var settingsOpacityValueLabel: NSTextField?
    private var suppressSettingsWrite = false
    private var sharedSettingsDate: Date?

    private var positionLocked: Bool {
        didSet {
            guard !suppressSettingsWrite else { return }
            var settings = HUDSettingsStore.load()
            settings.positionLocked = positionLocked
            HUDSettingsStore.save(settings)
        }
    }

    private var hideWhenInactive: Bool {
        didSet {
            guard !suppressSettingsWrite else { return }
            var settings = HUDSettingsStore.load()
            settings.hideWhenInactive = hideWhenInactive
            HUDSettingsStore.save(settings)
        }
    }

    private var keepOnTop: Bool {
        didSet {
            guard !suppressSettingsWrite else { return }
            var settings = HUDSettingsStore.load()
            settings.keepOnTop = keepOnTop
            HUDSettingsStore.save(settings)
            panel?.level = keepOnTop ? .screenSaver : .floating
        }
    }

    private var backgroundOpacity: CGFloat {
        didSet {
            guard !suppressSettingsWrite else {
                view?.backgroundOpacity = backgroundOpacity
                view?.needsDisplay = true
                return
            }
            var settings = HUDSettingsStore.load()
            settings.backgroundOpacity = Double(backgroundOpacity)
            HUDSettingsStore.save(settings)
            view?.backgroundOpacity = backgroundOpacity
            view?.needsDisplay = true
        }
    }

    private var manualOrigin: NSPoint? {
        didSet {
            guard !suppressSettingsWrite else { return }
            var settings = HUDSettingsStore.load()
            if let origin = manualOrigin {
                settings.hasManualOrigin = true
                settings.originX = Double(origin.x)
                settings.originY = Double(origin.y)
            } else {
                settings.hasManualOrigin = false
            }
            HUDSettingsStore.save(settings)
        }
    }

    private var lastPID: pid_t?
    private var lastSource: Int?
    private var lastOriginal: Int?
    private var lastGenerated: Int?
    private var lastTotal: Int?
    private var lastSampleAt: Date?
    private var lastStatsSignature: String?
    private var currentNativeFPS: Int?
    private var currentOutputFPS: Int?
    private var currentGeneratedFPS: Int?
    private var missingTargetSince: Date?

    init(arguments: [String]) {
        var logPath: String?
        var mult = 2
        var parentPID: pid_t?
        var i = 1
        while i < arguments.count {
            switch arguments[i] {
            case "--log":
                if i + 1 < arguments.count {
                    logPath = arguments[i + 1]
                    i += 2
                } else {
                    i += 1
                }
            case "--mult":
                if i + 1 < arguments.count {
                    mult = Int(arguments[i + 1]) ?? 2
                    i += 2
                } else {
                    i += 1
                }
            case "--parent-pid":
                if i + 1 < arguments.count {
                    let value = Int32(arguments[i + 1])
                    parentPID = value.map { pid_t($0) }
                    i += 2
                } else {
                    i += 1
                }
            default:
                i += 1
            }
        }
        self.logURL = URL(fileURLWithPath: logPath ?? "")
        self.fallbackMultiplier = mult
        self.parentPID = parentPID

        let stored = HUDSettingsStore.load()
        self.positionLocked = stored.positionLocked
        self.hideWhenInactive = stored.hideWhenInactive
        self.keepOnTop = stored.keepOnTop
        self.backgroundOpacity = CGFloat(min(1.0, max(0.12, stored.backgroundOpacity)))

        if stored.hasManualOrigin {
            self.manualOrigin = NSPoint(x: stored.originX, y: stored.originY)
        } else {
            self.manualOrigin = nil
        }
        self.sharedSettingsDate = try? FileManager.default.attributesOfItem(atPath: HUDSettingsStore.fileURL.path)[.modificationDate] as? Date
        super.init()

        let owner = parentPID.map(String.init) ?? String(getpid())
        let lockPath = "/tmp/lsfg-metal-hud-\(getuid())-\(owner).lock"
        let fd = open(lockPath, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard fd >= 0, flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            if fd >= 0 { close(fd) }
            exit(EXIT_SUCCESS)
        }
        instanceLockFD = fd
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        buildPanel()
        applyStoredPositionPreset()
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            self?.update()
        }
        startLogWatcher()
        update()
    }

    func applicationWillTerminate(_ notification: Notification) {
        timer?.invalidate()
        logWatcher?.cancel()
        logWatcher = nil
        if logFileDescriptor >= 0 {
            close(logFileDescriptor)
            logFileDescriptor = -1
        }
        if instanceLockFD >= 0 {
            flock(instanceLockFD, LOCK_UN)
            close(instanceLockFD)
            instanceLockFD = -1
        }
        settingsWindow?.close()
        panel?.orderOut(nil)
    }

    private func buildPanel() {
        let size = NSSize(width: 390, height: 118)
        let p = NSPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        p.backgroundColor = .clear
        p.isOpaque = false
        p.hasShadow = true
        p.ignoresMouseEvents = false
        p.hidesOnDeactivate = false
        p.level = keepOnTop ? .screenSaver : .floating
        p.isMovableByWindowBackground = true
        if #available(macOS 13.0, *) {
            p.collectionBehavior = [.canJoinAllSpaces, .canJoinAllApplications]
        } else {
            p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        }
        p.isReleasedWhenClosed = false

        let v = HUDView(frame: NSRect(origin: .zero, size: size))
        v.controller = self
        v.backgroundOpacity = backgroundOpacity
        p.contentView = v

        panel = p
        view = v
    }

    fileprivate func beginManualPositioning() {
        guard !positionLocked else { return }
        isDraggingHUD = true
    }

    fileprivate func updateManualPosition(_ origin: NSPoint) {
        guard !positionLocked else { return }
        isDraggingHUD = true
        panel?.setFrameOrigin(origin)
    }

    fileprivate func saveManualOrigin(_ origin: NSPoint) {
        guard !positionLocked else {
            isDraggingHUD = false
            return
        }
        isDraggingHUD = false
        manualOrigin = origin
    }

    @objc fileprivate func resetPosition() {
        var settings = HUDSettingsStore.load()
        settings.hasManualOrigin = false
        settings.selectedPositionID = nil
        HUDSettingsStore.save(settings)

        suppressSettingsWrite = true
        manualOrigin = nil
        suppressSettingsWrite = false
        sharedSettingsDate = try? FileManager.default.attributesOfItem(
            atPath: HUDSettingsStore.fileURL.path
        )[.modificationDate] as? Date

        updatePanelPosition()
    }

    func showContextMenu(with event: NSEvent, in view: NSView) {
        let menu = NSMenu()
        menu.addItem(withTitle: "HUD Settings…", action: #selector(showSettings), keyEquivalent: "")
        menu.items.last?.target = self
        menu.addItem(NSMenuItem.separator())
        menu.addItem(withTitle: "Reset Position", action: #selector(resetPosition), keyEquivalent: "")
        menu.items.last?.target = self
        menu.addItem(NSMenuItem.separator())

        let opacityMenu = NSMenu(title: "Background Opacity")
        for value in [0.25, 0.40, 0.55, 0.70, 0.82, 0.92] {
            let item = NSMenuItem(
                title: "\(Int(value * 100))%",
                action: #selector(selectOpacity(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = value
            if abs(backgroundOpacity - CGFloat(value)) < 0.01 {
                item.state = .on
            }
            opacityMenu.addItem(item)
        }

        let opacityItem = NSMenuItem(title: "Background Opacity", action: nil, keyEquivalent: "")
        opacityItem.submenu = opacityMenu
        menu.addItem(opacityItem)

        NSMenu.popUpContextMenu(menu, with: event, for: view)
    }

    @objc private func selectOpacity(_ sender: NSMenuItem) {
        guard let value = sender.representedObject as? Double else { return }
        backgroundOpacity = CGFloat(value)
    }

    @objc private func showSettings() {
        if let settingsWindow, settingsWindow.isVisible {
            settingsWindow.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let size = NSSize(width: 520, height: 450)
        let window = NSPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "LSFG HUD Settings"
        window.level = .floating
        window.isReleasedWhenClosed = false
        window.backgroundColor = NSColor(calibratedRed: 0.95, green: 0.95, blue: 0.95, alpha: 1)
        window.isOpaque = true
        window.appearance = NSAppearance(named: .aqua)

        let content = HUDSettingsBackgroundView(frame: NSRect(origin: .zero, size: size))
        window.contentView = content

        let title = NSTextField(labelWithString: "HUD Settings")
        title.font = NSFont.systemFont(ofSize: 24, weight: .heavy)
        title.textColor = HUDSettingsStyle.textPrimary
        title.frame = NSRect(x: 26, y: 404, width: 468, height: 28)
        content.addSubview(title)

        let subtitle = NSTextField(labelWithString: "Position, appearance and behavior")
        subtitle.font = NSFont.systemFont(ofSize: 12.5)
        subtitle.textColor = HUDSettingsStyle.textSecondary
        subtitle.frame = NSRect(x: 26, y: 380, width: 468, height: 18)
        content.addSubview(subtitle)

        let appearanceCard = HUDSettingsStyle.card()
        appearanceCard.frame = NSRect(x: 18, y: 300, width: 484, height: 74)
        content.addSubview(appearanceCard)

        let appearanceTitle = HUDSettingsStyle.section("APPEARANCE")
        appearanceTitle.frame = NSRect(x: 16, y: 38, width: 140, height: 14)
        appearanceCard.addSubview(appearanceTitle)

        let opacityLabel = NSTextField(labelWithString: "Background opacity")
        opacityLabel.font = NSFont.systemFont(ofSize: 12.5)
        opacityLabel.textColor = HUDSettingsStyle.textPrimary
        opacityLabel.frame = NSRect(x: 16, y: 13, width: 145, height: 20)
        appearanceCard.addSubview(opacityLabel)

        let slider = NSSlider(value: Double(backgroundOpacity) * 100,
                              minValue: 12,
                              maxValue: 100,
                              target: self,
                              action: #selector(settingsOpacityChanged(_:)))
        slider.isContinuous = true
        slider.controlSize = .small
        slider.cell = HUDAccentSliderCell()
        slider.minValue = 12
        slider.maxValue = 100
        slider.doubleValue = Double(backgroundOpacity) * 100
        slider.target = self
        slider.action = #selector(settingsOpacityChanged(_:))
        slider.frame = NSRect(x: 164, y: 12, width: 220, height: 22)
        appearanceCard.addSubview(slider)

        let opacityValue = NSTextField(labelWithString: "\(Int((backgroundOpacity * 100).rounded()))%")
        opacityValue.font = NSFont.monospacedDigitSystemFont(ofSize: 11.5, weight: .medium)
        opacityValue.textColor = HUDSettingsStyle.textSecondary
        opacityValue.alignment = .right
        opacityValue.frame = NSRect(x: 390, y: 13, width: 52, height: 20)
        self.settingsOpacityValueLabel = opacityValue
        appearanceCard.addSubview(opacityValue)

        let behaviorCard = HUDSettingsStyle.card()
        behaviorCard.frame = NSRect(x: 18, y: 148, width: 484, height: 132)
        content.addSubview(behaviorCard)

        let behaviorTitle = HUDSettingsStyle.section("BEHAVIOR")
        behaviorTitle.frame = NSRect(x: 16, y: 88, width: 140, height: 14)
        behaviorCard.addSubview(behaviorTitle)

        let lockButton = NSButton(checkboxWithTitle: "Lock HUD position", target: self, action: #selector(togglePositionLock(_:)))
        lockButton.state = positionLocked ? .on : .off
        HUDSettingsStyle.styleCheckbox(lockButton)
        lockButton.frame = NSRect(x: 16, y: 59, width: 210, height: 22)
        behaviorCard.addSubview(lockButton)

        let hideButton = NSButton(checkboxWithTitle: "Hide when LSFG is inactive", target: self, action: #selector(toggleHideWhenInactive(_:)))
        hideButton.state = hideWhenInactive ? .on : .off
        HUDSettingsStyle.styleCheckbox(hideButton)
        hideButton.frame = NSRect(x: 238, y: 59, width: 210, height: 22)
        behaviorCard.addSubview(hideButton)

        let topButton = NSButton(checkboxWithTitle: "Keep HUD above other windows", target: self, action: #selector(toggleKeepOnTop(_:)))
        topButton.state = keepOnTop ? .on : .off
        HUDSettingsStyle.styleCheckbox(topButton)
        topButton.frame = NSRect(x: 16, y: 28, width: 260, height: 22)
        behaviorCard.addSubview(topButton)

        let positionCard = HUDSettingsStyle.card()
        positionCard.frame = NSRect(x: 9, y: 48, width: 502, height: 88)
        content.addSubview(positionCard)

        let positionTitle = HUDSettingsStyle.section("POSITION")
        positionTitle.frame = NSRect(x: 16, y: 50, width: 120, height: 14)
        positionCard.addSubview(positionTitle)

        let positions: [(String, String, CGFloat)] = [
            ("Top Left", "tl", 16),
            ("Top Right", "tr", 134),
            ("Bottom Left", "bl", 252),
            ("Bottom Right", "br", 370)
        ]
        for (label, id, x) in positions {
            let button = NSButton(title: label, target: self, action: #selector(selectPositionPreset(_:)))
            button.identifier = NSUserInterfaceItemIdentifier(id)
            HUDSettingsStyle.styleButton(button)
            button.frame = NSRect(x: x, y: 12, width: 118, height: 32)
            positionCard.addSubview(button)
        }

        let reset = NSButton(title: "Reset Position", target: self, action: #selector(resetPosition))
        HUDSettingsStyle.styleButton(reset)
        reset.frame = NSRect(x: 26, y: 12, width: 130, height: 32)
        content.addSubview(reset)

        let done = NSButton(title: "Done", target: self, action: #selector(closeSettings))
        HUDSettingsStyle.styleProminentButton(done)
        done.frame = NSRect(x: 410, y: 10, width: 102, height: 32)
        content.addSubview(done)

        settingsWindow = window
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func closeSettings() {
        settingsWindow?.orderOut(nil)
    }

    @objc private func togglePositionLock(_ sender: NSButton) {
        positionLocked = sender.state == .on
    }

    @objc private func toggleHideWhenInactive(_ sender: NSButton) {
        hideWhenInactive = sender.state == .on
        if hideWhenInactive {
            update()
        } else {
            panel?.orderFrontRegardless()
        }
    }

    @objc private func toggleKeepOnTop(_ sender: NSButton) {
        keepOnTop = sender.state == .on
        panel?.orderFrontRegardless()
    }

    @objc private func settingsOpacityChanged(_ sender: NSSlider) {
        backgroundOpacity = CGFloat(sender.doubleValue / 100.0)
        settingsOpacityValueLabel?.stringValue = String(format: "%.0f%%", sender.doubleValue)
    }

    @objc private func selectPositionPreset(_ sender: NSButton) {
        guard let screen = targetScreen() else { return }
        let frame = panel?.frame ?? .zero
        let margin: CGFloat = 24
        let visible = screen.visibleFrame

        let origin: NSPoint
        switch sender.identifier?.rawValue {
        case "tl":
            origin = NSPoint(x: visible.minX + margin, y: visible.maxY - frame.height - margin)
        case "tr":
            origin = NSPoint(x: visible.maxX - frame.width - margin, y: visible.maxY - frame.height - margin)
        case "bl":
            origin = NSPoint(x: visible.minX + margin, y: visible.minY + margin)
        default:
            origin = NSPoint(x: visible.maxX - frame.width - margin, y: visible.minY + margin)
        }

        panel?.setFrameOrigin(origin)
        saveManualOrigin(origin)
    }

    private func startLogWatcher() {
        guard logFileDescriptor < 0,
              !logURL.path.isEmpty else {
            return
        }

        let descriptor = open(logURL.path, O_EVTONLY)
        guard descriptor >= 0 else { return }

        logFileDescriptor = descriptor
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: .write,
            queue: DispatchQueue.global(qos: .userInteractive)
        )

        source.setEventHandler { [weak self] in
            guard let self else { return }
            DispatchQueue.main.async {
                self.update()
            }
        }

        source.setCancelHandler { [weak self] in
            guard let self, self.logFileDescriptor == descriptor else { return }
            close(descriptor)
            self.logFileDescriptor = -1
        }

        logWatcher = source
        source.resume()
    }

    private func syncSharedSettings() {
        guard let modified = try? FileManager.default.attributesOfItem(atPath: HUDSettingsStore.fileURL.path)[.modificationDate] as? Date else {
            return
        }
        guard modified != sharedSettingsDate else { return }
        sharedSettingsDate = modified

        let stored = HUDSettingsStore.load()
        suppressSettingsWrite = true
        positionLocked = stored.positionLocked
        hideWhenInactive = stored.hideWhenInactive
        keepOnTop = stored.keepOnTop
        backgroundOpacity = CGFloat(min(1.0, max(0.12, stored.backgroundOpacity)))
        manualOrigin = stored.hasManualOrigin
            ? NSPoint(x: stored.originX, y: stored.originY)
            : nil
        suppressSettingsWrite = false

        panel?.level = keepOnTop ? .screenSaver : .floating
        updatePanelPosition()
        view?.backgroundOpacity = backgroundOpacity
        view?.needsDisplay = true

        if hideWhenInactive {
            panel?.orderOut(nil)
        } else {
            panel?.orderFrontRegardless()
        }
    }

    private func update() {
        syncSharedSettings()
        parentCheckTicks += 1
        if parentCheckTicks >= 30 {
            parentCheckTicks = 0
            if let parentPID, parentPID > 1, kill(parentPID, 0) != 0 {
                NSApp.terminate(nil)
                return
            }
        }

        guard let stats = readLatestStats(),
              isProcessRunning(stats.pid) else {
            if Date().timeIntervalSince(missingTargetSince ?? Date.distantPast) > 3 {
                missingTargetSince = Date()
            }
            showWaiting()
            return
        }

        missingTargetSince = nil
        let now = Date()
        let signature = "\(stats.pid):\(stats.source):\(stats.original):\(stats.generated):\(stats.total)"

        if signature != lastStatsSignature {
            if lastPID != stats.pid {
                lastPID = stats.pid
                lastSource = nil
                lastOriginal = nil
                lastGenerated = nil
                lastTotal = nil
                lastSampleAt = nil
            }

            let newNativeFPS = stats.sourceFPS
            var newOutputFPS = currentOutputFPS
            var newGeneratedFPS = currentGeneratedFPS

            if let previousSource = lastSource,
               let previousTotal = lastTotal,
               let previousGenerated = lastGenerated,
               let previousTime = lastSampleAt {
                let dt = now.timeIntervalSince(previousTime)
                if dt > 0.2 && dt < 10.0 {
                    let sourceDelta = max(0, stats.source - previousSource)
                    let totalDelta = max(0, stats.total - previousTotal)
                    let generatedDelta = max(0, stats.generated - previousGenerated)

                    if stats.sourceFPS == nil && sourceDelta > 0 {
                        currentNativeFPS = max(0, Int((Double(sourceDelta) / dt).rounded()))
                    }

                    newOutputFPS = max(0, Int((Double(totalDelta) / dt).rounded()))
                    newGeneratedFPS = max(0, Int((Double(generatedDelta) / dt).rounded()))
                }
            } else if let native = newNativeFPS, stats.source > 0 {
                newOutputFPS = max(0, Int((Double(stats.total) / Double(stats.source) * Double(native)).rounded()))
                newGeneratedFPS = max(0, Int((Double(stats.generated) / Double(stats.source) * Double(native)).rounded()))
            }

            if let native = newNativeFPS {
                currentNativeFPS = native
            }

            currentOutputFPS = newOutputFPS
            currentGeneratedFPS = newGeneratedFPS

            lastSource = stats.source
            lastOriginal = stats.original
            lastGenerated = stats.generated
            lastTotal = stats.total
            lastSampleAt = now
            lastStatsSignature = signature
        }

        let effectiveMultiplier = readMultiplier(from: logURL) ?? fallbackMultiplier
        let active = stats.generated > 0
        view?.multiplier = effectiveMultiplier
        view?.nativeFPS = currentNativeFPS
        view?.outputFPS = currentOutputFPS
        view?.generatedFPS = currentGeneratedFPS
        view?.originalCount = stats.original
        view?.generatedCount = stats.generated
        view?.totalCount = stats.total
        view?.generationActive = active
        view?.statusText = active ? "FRAME GEN ACTIVE" : "FRAME GEN IDLE"
        view?.backgroundOpacity = backgroundOpacity

        updatePanelPosition()
        panel?.orderFrontRegardless()
        view?.needsDisplay = true
    }

    private func showWaiting() {
        if hideWhenInactive {
            panel?.orderOut(nil)
            return
        }
        if view?.nativeFPS != nil || view?.outputFPS != nil || view?.generatedFPS != nil {
            resetSampleState()
        }
        view?.multiplier = fallbackMultiplier
        view?.nativeFPS = nil
        view?.outputFPS = nil
        view?.generatedFPS = nil
        view?.originalCount = nil
        view?.generatedCount = nil
        view?.totalCount = nil
        view?.generationActive = false
        view?.statusText = "WAITING FOR LSFG"
        view?.backgroundOpacity = backgroundOpacity

        if manualOrigin == nil, let screen = targetScreen() {
            let size = panel?.frame.size ?? NSSize(width: 390, height: 118)
            let frame = screen.visibleFrame
            panel?.setFrameOrigin(NSPoint(
                x: frame.maxX - size.width - 24,
                y: frame.maxY - size.height - 24
            ))
        }
        panel?.orderFrontRegardless()
        view?.needsDisplay = true
    }

    private func applyStoredPositionPreset() {
        let stored = HUDSettingsStore.load()
        guard let preset = stored.selectedPositionID,
              let screen = targetScreen(),
              let panel else {
            return
        }

        let visible = screen.visibleFrame
        let margin: CGFloat = 24
        let size = panel.frame.size

        let origin: NSPoint
        switch preset {
        case "tl":
            origin = NSPoint(x: visible.minX + margin, y: visible.maxY - size.height - margin)
        case "tr":
            origin = NSPoint(x: visible.maxX - size.width - margin, y: visible.maxY - size.height - margin)
        case "bl":
            origin = NSPoint(x: visible.minX + margin, y: visible.minY + margin)
        case "br":
            origin = NSPoint(x: visible.maxX - size.width - margin, y: visible.minY + margin)
        default:
            return
        }

        suppressSettingsWrite = true
        manualOrigin = origin
        suppressSettingsWrite = false

        var updated = stored
        updated.originX = Double(origin.x)
        updated.originY = Double(origin.y)
        updated.hasManualOrigin = true
        HUDSettingsStore.save(updated)
        sharedSettingsDate = try? FileManager.default.attributesOfItem(
            atPath: HUDSettingsStore.fileURL.path
        )[.modificationDate] as? Date

        panel.setFrameOrigin(origin)
    }

    private func resetSampleState() {
        lastPID = nil
        lastSource = nil
        lastOriginal = nil
        lastGenerated = nil
        lastTotal = nil
        lastSampleAt = nil
        lastStatsSignature = nil
        currentNativeFPS = nil
        currentOutputFPS = nil
        currentGeneratedFPS = nil
    }

    private func readLatestStats() -> Stats? {
        guard !logURL.path.isEmpty,
              let data = try? Data(contentsOf: logURL),
              let text = String(data: data.suffix(256 * 1024), encoding: .utf8) else {
            return nil
        }

        for raw in text.split(separator: "\n").reversed() {
            let line = String(raw)
            guard line.contains("Frame generation stats"),
                  let pid = int(after: "pid=", in: line),
                  let source = int(after: "source=", in: line),
                  let original = int(after: "original=", in: line),
                  let generated = int(after: "generated=", in: line),
                  let total = int(after: "total=", in: line) else {
                continue
            }

            return Stats(
                pid: pid_t(pid),
                source: source,
                original: original,
                generated: generated,
                total: total,
                sourceFPS: int(after: "source_fps=", in: line)
            )
        }
        return nil
    }

    private func readMultiplier(from url: URL) -> Int? {
        guard !url.path.isEmpty,
              let data = try? Data(contentsOf: url),
              let text = String(data: data.suffix(64 * 1024), encoding: .utf8) else {
            return nil
        }

        for raw in text.split(separator: "\n").reversed() {
            let line = String(raw)
            if let value = int(after: "multiplier ", in: line) {
                return value
            }
        }
        return nil
    }

    private func int(after marker: String, in line: String) -> Int? {
        guard let range = line.range(of: marker) else { return nil }
        let tail = line[range.upperBound...]
        let digits = tail.prefix { $0.isNumber }
        return Int(digits)
    }

    private func targetScreen() -> NSScreen? {
        if let panel, let screen = NSScreen.screens.first(where: { $0.frame.intersects(panel.frame) }) {
            return screen
        }
        return NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) })
            ?? NSScreen.main
            ?? NSScreen.screens.first
    }

    private func updatePanelPosition() {
        if isDraggingHUD {
            return
        }

        if let origin = manualOrigin {
            let size = panel?.frame.size ?? NSSize(width: 390, height: 118)
            let candidate = NSRect(origin: origin, size: size)
            let onScreen = NSScreen.screens.contains { candidate.intersects($0.visibleFrame) }
            if onScreen {
                panel?.setFrameOrigin(origin)
                return
            }

            manualOrigin = nil
        }

        guard let statsPID = readPIDFromLatestStats(),
              let bounds = windowBounds(for: statsPID) else {
            return
        }
        let panelSize = panel?.frame.size ?? NSSize(width: 390, height: 118)
        panel?.setFrame(
            frame(for: bounds, panelSize: panelSize),
            display: false
        )
    }

    private func isProcessRunning(_ pid: pid_t) -> Bool {
        guard pid > 1 else { return false }
        return kill(pid, 0) == 0
    }

    private func readPIDFromLatestStats() -> pid_t? {
        readLatestStats().map(\.pid)
    }

    private func windowBounds(for pid: pid_t) -> CGRect? {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let infoList = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            return nil
        }

        var best: CGRect?
        var bestArea: CGFloat = 0
        for info in infoList {
            guard let owner = (info[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value,
                  owner == pid,
                  let layer = (info[kCGWindowLayer as String] as? NSNumber)?.intValue,
                  layer == 0,
                  let boundsObject = info[kCGWindowBounds as String] as? NSDictionary else {
                continue
            }

            var rect = CGRect.zero
            guard CGRectMakeWithDictionaryRepresentation(boundsObject as CFDictionary, &rect),
                  rect.width >= 300,
                  rect.height >= 200 else {
                continue
            }

            let area = rect.width * rect.height
            if area > bestArea {
                bestArea = area
                best = rect
            }
        }
        return best
    }

    private func frame(for cgRect: CGRect?, panelSize: NSSize) -> NSRect {
        guard let cgRect,
              let screen = screenContaining(cgRect) else {
            let screen = targetScreen() ?? NSScreen.screens[0]
            let visible = screen.visibleFrame
            return NSRect(
                x: visible.maxX - panelSize.width - 24,
                y: visible.maxY - panelSize.height - 24,
                width: panelSize.width,
                height: panelSize.height
            )
        }

        let screenNumber = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)
            .map { CGDirectDisplayID($0.uint32Value) }
        let cgDisplay = screenNumber.map(CGDisplayBounds) ?? .zero
        let localX = cgRect.minX - cgDisplay.minX
        let localTop = cgRect.minY - cgDisplay.minY
        let yFromBottom = cgDisplay.height - localTop

        let x = screen.frame.minX + max(12, localX + cgRect.width - panelSize.width - 24)
        let y = screen.frame.minY + yFromBottom - panelSize.height - 24
        return NSRect(x: x, y: y, width: panelSize.width, height: panelSize.height)
    }

    private func screenContaining(_ cgRect: CGRect) -> NSScreen? {
        let windowCenter = CGPoint(x: cgRect.midX, y: cgRect.midY)
        var displayID = kCGNullDirectDisplay
        var displayCount: UInt32 = 0
        guard CGGetDisplaysWithPoint(windowCenter, 1, &displayID, &displayCount) == .success,
              displayCount > 0,
              displayID != kCGNullDirectDisplay else {
            return nil
        }

        return NSScreen.screens.first {
            guard let number = $0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
                return false
            }
            return CGDirectDisplayID(number.uint32Value) == displayID
        }
    }
}

let app = NSApplication.shared
let delegate = HUDController(arguments: CommandLine.arguments)
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
