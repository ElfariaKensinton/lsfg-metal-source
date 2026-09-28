import AppKit
import Foundation
import UniformTypeIdentifiers

private struct ProfileSection {
    let name: String
    let start: Int
}

private struct ProfileValues {
    var multiplier: Int = 2
    var scaler = "off"
    var flowScale: Double = 1.0
    var performanceMode = false
    var pacingMode = "vsync"
}

private final class ConfigStore {
    var url: URL
    private(set) var lines: [String] = []

    init(url: URL) {
        self.url = url
    }

    func reload() throws {
        if !FileManager.default.fileExists(atPath: url.path) {
            try createDefault()
        }
        let text = try String(contentsOf: url, encoding: .utf8)
        lines = text.components(separatedBy: .newlines)
        if lines.last == "" {
            lines.removeLast()
        }
    }

    func profiles() -> [ProfileSection] {
        var result: [ProfileSection] = []
        for i in lines.indices {
            guard lines[i].trimmingCharacters(in: .whitespacesAndNewlines) == "[[profile]]" else {
                continue
            }
            let end = nextProfileIndex(after: i)
            let name = value("name", start: i, end: end) ?? "Profile \(result.count + 1)"
            result.append(ProfileSection(name: name, start: i))
        }
        return result
    }

    func values(for section: ProfileSection) -> ProfileValues {
        let end = nextProfileIndex(after: section.start)
        var result = ProfileValues()
        result.multiplier = Int(value("multiplier", start: section.start, end: end) ?? "") ?? 2
        result.scaler = value("scaler", start: section.start, end: end) ?? "off"
        result.flowScale = Double(value("flow_scale", start: section.start, end: end) ?? "") ?? 1.0
        result.performanceMode = parseBool(value("performance_mode", start: section.start, end: end)) ?? false
        result.pacingMode = value("pacing_mode", start: section.start, end: end) ?? "vsync"
        return result
    }

    func set(key: String, value: String, in section: ProfileSection) throws {
        let end = nextProfileIndex(after: section.start)
        if let index = keyIndex(key, start: section.start, end: end) {
            lines[index] = "\(key) = \(value)"
        } else {
            lines.insert("\(key) = \(value)", at: end)
        }
        try write()
    }

    private func nextProfileIndex(after start: Int) -> Int {
        guard start + 1 < lines.endIndex else {
            return lines.count
        }
        for i in lines.index(after: start)..<lines.endIndex {
            if lines[i].trimmingCharacters(in: .whitespacesAndNewlines) == "[[profile]]" {
                return i
            }
        }
        return lines.count
    }

    private func keyIndex(_ key: String, start: Int, end: Int) -> Int? {
        guard start < end else {
            return nil
        }
        for i in start..<end {
            let trimmed = lines[i].trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("#") {
                continue
            }
            guard let equals = trimmed.firstIndex(of: "=") else {
                continue
            }
            let lhs = trimmed[..<equals].trimmingCharacters(in: .whitespaces)
            if lhs == key {
                return i
            }
        }
        return nil
    }

    private func value(_ key: String, start: Int, end: Int) -> String? {
        guard let i = keyIndex(key, start: start, end: end) else {
            return nil
        }
        let trimmed = lines[i].trimmingCharacters(in: .whitespaces)
        guard let equals = trimmed.firstIndex(of: "=") else {
            return nil
        }

        var raw = String(trimmed[trimmed.index(after: equals)...]).trimmingCharacters(in: .whitespaces)
        if let hash = raw.firstIndex(of: "#") {
            raw = String(raw[..<hash]).trimmingCharacters(in: .whitespaces)
        }

        if raw.count >= 2, raw.first == """, raw.last == """ {
            return String(raw.dropFirst().dropLast())
        }
        if raw.count >= 2, raw.first == "'", raw.last == "'" {
            return String(raw.dropFirst().dropLast())
        }
        return raw
    }

    private func parseBool(_ text: String?) -> Bool? {
        switch text?.lowercased() {
        case "true": return true
        case "false": return false
        default: return nil
        }
    }

    private func createDefault() throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        let text = """
        version = 2

        [global]
        allow_fp16 = true
        log_level = "info"

        [[profile]]
        name = "Default 2x"
        active_in = "000000"
        multiplier = 2
        scaler = "off"
        flow_scale = 1.0
        performance_mode = false
        pacing_mode = "vsync"
        """
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    private func write() throws {
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let temp = directory.appendingPathComponent(".\(url.lastPathComponent).tmp-\(UUID().uuidString)")
        let text = lines.joined(separator: "\n") + "\n"
        try text.write(to: temp, atomically: true, encoding: .utf8)

        if FileManager.default.fileExists(atPath: url.path) {
            _ = try FileManager.default.replaceItemAt(url, withItemAt: temp)
        } else {
            try FileManager.default.moveItem(at: temp, to: url)
        }
    }
}

@main
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var window: NSWindow!
    private var store: ConfigStore!
    private var sections: [ProfileSection] = []
    private var suppress = false

    private let configPathLabel = NSTextField(labelWithString: "")
    private let profilePopup = NSPopUpButton()
    private let multiplierPopup = NSPopUpButton()
    private let scalerPopup = NSPopUpButton()
    private let flowSlider = NSSlider(value: 1.0, minValue: 0.25, maxValue: 1.0, target: nil, action: nil)
    private let flowLabel = NSTextField(labelWithString: "")
    private let performance = NSButton(checkboxWithTitle: "Performance shader mode", target: nil, action: nil)
    private let pacingPopup = NSPopUpButton()
    private let profileInfo = NSTextField(labelWithString: "")
    private let statusLabel = NSTextField(labelWithString: "")

    func applicationDidFinishLaunching(_ notification: Notification) {
        store = ConfigStore(url: defaultConfigURL())
        buildWindow()
        reloadConfig(showError: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    private func defaultConfigURL() -> URL {
        let env = ProcessInfo.processInfo.environment
        if let explicit = env["LSFGM_CONFIG"], !explicit.isEmpty {
            return URL(fileURLWithPath: explicit)
        }
        if let xdg = env["XDG_CONFIG_HOME"], !xdg.isEmpty {
            return URL(fileURLWithPath: xdg).appendingPathComponent("lsfg-metal/conf.toml")
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/lsfg-metal/conf.toml")
    }

    private func buildWindow() {
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 680, height: 520))
        content.wantsLayer = true
        content.layer?.backgroundColor = NSColor(calibratedWhite: 0.96, alpha: 1).cgColor

        let title = NSTextField(labelWithString: "LSFG Metal Settings")
        title.font = .systemFont(ofSize: 24, weight: .bold)
        title.frame = NSRect(x: 28, y: 468, width: 480, height: 30)
        content.addSubview(title)

        let subtitle = NSTextField(wrappingLabelWithString:
            "Companion UI for upstream itsOwen/lsfg-metal. It edits the standard profile file only; the frame-generation engine is untouched.")
        subtitle.font = .systemFont(ofSize: 12)
        subtitle.textColor = .secondaryLabelColor
        subtitle.frame = NSRect(x: 30, y: 427, width: 620, height: 34)
        content.addSubview(subtitle)

        let choose = NSButton(title: "Choose Config…", target: self, action: #selector(chooseConfig))
        choose.frame = NSRect(x: 28, y: 386, width: 120, height: 28)
        content.addSubview(choose)

        configPathLabel.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        configPathLabel.textColor = .secondaryLabelColor
        configPathLabel.lineBreakMode = .byTruncatingMiddle
        configPathLabel.frame = NSRect(x: 160, y: 390, width: 490, height: 22)
        content.addSubview(configPathLabel)

        let profileTitle = NSTextField(labelWithString: "Profile")
        profileTitle.font = .systemFont(ofSize: 13, weight: .semibold)
        profileTitle.frame = NSRect(x: 30, y: 346, width: 100, height: 20)
        content.addSubview(profileTitle)

        profilePopup.frame = NSRect(x: 130, y: 342, width: 380, height: 28)
        profilePopup.target = self
        profilePopup.action = #selector(profileChanged)
        content.addSubview(profilePopup)

        let reload = NSButton(title: "Reload", target: self, action: #selector(reloadPressed))
        reload.frame = NSRect(x: 525, y: 342, width: 125, height: 28)
        content.addSubview(reload)

        let card = NSView(frame: NSRect(x: 26, y: 92, width: 628, height: 230))
        card.wantsLayer = true
        card.layer?.backgroundColor = NSColor.white.cgColor
        card.layer?.cornerRadius = 12
        card.layer?.borderWidth = 1
        card.layer?.borderColor = NSColor.black.withAlphaComponent(0.08).cgColor
        content.addSubview(card)

        addLabel("Multiplier", x: 22, y: 176, in: card)
        multiplierPopup.addItems(withTitles: ["1×", "2×", "3×", "4×"])
        multiplierPopup.target = self
        multiplierPopup.action = #selector(multiplierChanged)
        multiplierPopup.frame = NSRect(x: 180, y: 172, width: 120, height: 28)
        card.addSubview(multiplierPopup)

        addLabel("Scaler", x: 22, y: 130, in: card)
        scalerPopup.addItems(withTitles: ["Off", "MetalFX"])
        scalerPopup.target = self
        scalerPopup.action = #selector(scalerChanged)
        scalerPopup.frame = NSRect(x: 180, y: 126, width: 150, height: 28)
        card.addSubview(scalerPopup)

        addLabel("Flow scale", x: 360, y: 130, in: card)
        flowSlider.isContinuous = false
        flowSlider.target = self
        flowSlider.action = #selector(flowChanged)
        flowSlider.frame = NSRect(x: 440, y: 126, width: 150, height: 24)
        card.addSubview(flowSlider)

        flowLabel.alignment = .right
        flowLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        flowLabel.frame = NSRect(x: 590, y: 126, width: 25, height: 24)
        card.addSubview(flowLabel)

        performance.target = self
        performance.action = #selector(performanceChanged)
        performance.frame = NSRect(x: 20, y: 82, width: 300, height: 24)
        card.addSubview(performance)

        addLabel("Pacing", x: 22, y: 36, in: card)
        pacingPopup.addItems(withTitles: ["VSync / fixed", "Adaptive"])
        pacingPopup.target = self
        pacingPopup.action = #selector(pacingChanged)
        pacingPopup.frame = NSRect(x: 180, y: 32, width: 210, height: 28)
        card.addSubview(pacingPopup)

        let hint = NSTextField(wrappingLabelWithString:
            "Restart the game after changing profile settings. The selected upstream engine remains untouched.")
        hint.font = .systemFont(ofSize: 11)
        hint.textColor = .secondaryLabelColor
        hint.frame = NSRect(x: 28, y: 56, width: 620, height: 24)
        content.addSubview(hint)

        profileInfo.textColor = .secondaryLabelColor
        profileInfo.font = .systemFont(ofSize: 11.5)
        profileInfo.frame = NSRect(x: 30, y: 32, width: 620, height: 20)
        content.addSubview(profileInfo)

        statusLabel.font = .systemFont(ofSize: 11.5, weight: .semibold)
        statusLabel.textColor = .systemGreen
        statusLabel.frame = NSRect(x: 30, y: 10, width: 620, height: 20)
        content.addSubview(statusLabel)

        window = NSWindow(
            contentRect: content.frame,
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "LSFG Metal Settings"
        window.contentView = content
        window.isReleasedWhenClosed = false
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func addLabel(_ text: String, x: CGFloat, y: CGFloat, in parent: NSView) {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 13)
        label.frame = NSRect(x: x, y: y, width: 145, height: 22)
        parent.addSubview(label)
    }

    private func reloadConfig(showError: Bool) {
        do {
            try store.reload()
            sections = store.profiles()
            profilePopup.removeAllItems()
            profilePopup.addItems(withTitles: sections.map(\.name))
            configPathLabel.stringValue = store.url.path

            if let first = sections.first {
                profilePopup.selectItem(at: 0)
                apply(store.values(for: first))
                profileInfo.stringValue = "Selected profile: \(first.name)"
                status("Loaded config.", error: false)
            } else {
                clearControls()
                profileInfo.stringValue = "No profile found."
                status("Config has no [[profile]] section.", error: true)
            }
        } catch {
            status(error.localizedDescription, error: showError)
        }
    }

    private func clearControls() {
        multiplierPopup.isEnabled = false
        scalerPopup.isEnabled = false
        flowSlider.isEnabled = false
        performance.isEnabled = false
        pacingPopup.isEnabled = false
    }

    private func apply(_ values: ProfileValues) {
        suppress = true
        multiplierPopup.selectItem(at: max(0, min(3, values.multiplier - 1)))
        scalerPopup.selectItem(at: values.scaler.lowercased() == "metalfx" ? 1 : 0)
        flowSlider.doubleValue = min(1.0, max(0.25, values.flowScale))
        flowLabel.stringValue = String(format: "%.0f%%", values.flowScale * 100)
        performance.state = values.performanceMode ? .on : .off
        pacingPopup.selectItem(at: values.pacingMode.lowercased() == "adaptive" ? 1 : 0)
        multiplierPopup.isEnabled = true
        scalerPopup.isEnabled = true
        flowSlider.isEnabled = true
        performance.isEnabled = true
        pacingPopup.isEnabled = true
        suppress = false
    }

    private func currentSection() -> ProfileSection? {
        let index = profilePopup.indexOfSelectedItem
        guard index >= 0 && index < sections.count else {
            return nil
        }
        return sections[index]
    }

    private func write(key: String, value: String, message: String) {
        guard !suppress, let section = currentSection() else {
            return
        }
        do {
            try store.set(key: key, value: value, in: section)
            reloadConfig(showError: false)
            status(message + " — saved. Restart the game to apply.", error: false)
        } catch {
            status(error.localizedDescription, error: true)
        }
    }

    private func status(_ message: String, error: Bool) {
        statusLabel.stringValue = message
        statusLabel.textColor = error ? .systemRed : .systemGreen
    }

    @objc private func reloadPressed() {
        reloadConfig(showError: true)
    }

    @objc private func profileChanged() {
        guard let section = currentSection() else {
            return
        }
        apply(store.values(for: section))
        profileInfo.stringValue = "Selected profile: \(section.name)"
    }

    @objc private func multiplierChanged() {
        let value = max(1, min(4, multiplierPopup.indexOfSelectedItem + 1))
        write(key: "multiplier", value: "\(value)", message: "Multiplier \(value)×")
    }

    @objc private func scalerChanged() {
        let value = scalerPopup.indexOfSelectedItem == 1 ? "\"metalfx\"" : "\"off\""
        write(key: "scaler", value: value, message: value == "\"metalfx\"" ? "MetalFX enabled" : "MetalFX disabled")
    }

    @objc private func flowChanged() {
        let value = min(1.0, max(0.25, flowSlider.doubleValue))
        write(
            key: "flow_scale",
            value: String(format: "%.2f", value),
            message: String(format: "Flow scale %.0f%%", value * 100)
        )
    }

    @objc private func performanceChanged() {
        write(
            key: "performance_mode",
            value: performance.state == .on ? "true" : "false",
            message: performance.state == .on ? "Performance mode enabled" : "Performance mode disabled"
        )
    }

    @objc private func pacingChanged() {
        let adaptive = pacingPopup.indexOfSelectedItem == 1
        write(
            key: "pacing_mode",
            value: adaptive ? "\"adaptive\"" : "\"vsync\"",
            message: adaptive ? "Adaptive pacing enabled" : "Fixed pacing enabled"
        )
    }

    @objc private func chooseConfig() {
        let panel = NSOpenPanel()
        if let toml = UTType(filenameExtension: "toml") {
            panel.allowedContentTypes = [toml]
        }
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false

        panel.begin { [weak self] response in
            guard let self, response == .OK, let url = panel.url else {
                return
            }
            self.store.url = url
            self.reloadConfig(showError: true)
        }
    }

    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.regular)
        app.run()
    }
}
