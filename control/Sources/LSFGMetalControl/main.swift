import AppKit
import Foundation

private struct ProfileSection {
    let name: String
    let start: Int
}

private struct ProfileValues {
    var multiplier: Int = 2
    var flowScale: Double = 1.0
    var performanceMode = false
    var pacingMode = "vsync"
    var overridePresentMode = true
    var preserveSwapchainImageCount = false
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
        if lines.last == "" { lines.removeLast() }
    }

    func profiles() -> [ProfileSection] {
        var result: [ProfileSection] = []
        for i in lines.indices where lines[i].trimmingCharacters(in: .whitespacesAndNewlines) == "[[profile]]" {
            let end = nextProfileIndex(after: i)
            let name = value("name", start: i, end: end) ?? "Profile (result.count + 1)"
            result.append(ProfileSection(name: name, start: i))
        }
        return result
    }

    func values(for section: ProfileSection) -> ProfileValues {
        let end = nextProfileIndex(after: section.start)
        var v = ProfileValues()
        v.multiplier = Int(value("multiplier", start: section.start, end: end) ?? "") ?? 2
        v.flowScale = Double(value("flow_scale", start: section.start, end: end) ?? "") ?? 1.0
        v.performanceMode = parseBool(value("performance_mode", start: section.start, end: end)) ?? false
        v.pacingMode = value("pacing_mode", start: section.start, end: end) ?? "vsync"
        v.overridePresentMode = parseBool(value("override_present_mode", start: section.start, end: end)) ?? true
        v.preserveSwapchainImageCount = parseBool(value("preserve_swapchain_image_count", start: section.start, end: end)) ?? false
        return v
    }

    func set(key: String, value: String, in section: ProfileSection) throws {
        let end = nextProfileIndex(after: section.start)
        if let index = keyIndex(key, start: section.start, end: end) {
            lines[index] = "(key) = (value)"
        } else {
            lines.insert("(key) = (value)", at: end)
        }
        try write()
    }

    func reloadFromDisk() throws {
        try reload()
    }

    private func nextProfileIndex(after start: Int) -> Int {
        for i in lines.index(after: start)..<lines.endIndex {
            if lines[i].trimmingCharacters(in: .whitespacesAndNewlines) == "[[profile]]" {
                return i
            }
        }
        return lines.count
    }

    private func keyIndex(_ key: String, start: Int, end: Int) -> Int? {
        for i in start..<end {
            let trimmed = lines[i].trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("#") { continue }
            guard let equals = trimmed.firstIndex(of: "=") else { continue }
            let lhs = trimmed[..<equals].trimmingCharacters(in: .whitespaces)
            if lhs == key { return i }
        }
        return nil
    }

    private func value(_ key: String, start: Int, end: Int) -> String? {
        guard let i = keyIndex(key, start: start, end: end) else { return nil }
        let trimmed = lines[i].trimmingCharacters(in: .whitespaces)
        guard let equals = trimmed.firstIndex(of: "=") else { return nil }
        var raw = String(trimmed[trimmed.index(after: equals)...]).trimmingCharacters(in: .whitespaces)
        if let hash = raw.firstIndex(of: "#") {
            raw = String(raw[..<hash]).trimmingCharacters(in: .whitespaces)
        }
        if raw.count >= 2, raw.first == """ && raw.last == """ {
            return String(raw.dropFirst().dropLast())
        }
        if raw.count >= 2, raw.first == "'" && raw.last == "'" {
            return String(raw.dropFirst().dropLast())
        }
        return raw
    }

    private func parseBool(_ string: String?) -> Bool? {
        switch string?.lowercased() {
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
        let defaultText = """
        # active_in lists Steam App IDs ($SteamAppId), not executable names
        version = 2

        [global]
        allow_fp16 = true
        log_level = "info"

        [[profile]]
        name = "Default 2x"
        active_in = "000000"
        pacing_mode = "vsync"
        multiplier = 2
        flow_scale = 1.0
        performance_mode = false
        override_present_mode = true
        preserve_swapchain_image_count = false
        """
        try defaultText.write(to: url, atomically: true, encoding: .utf8)
    }

    private func write() throws {
        let text = lines.joined(separator: "
") + "
"
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let temp = directory.appendingPathComponent(".(url.lastPathComponent).tmp-\(UUID().uuidString)")
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
    private var profileSections: [ProfileSection] = []

    private let configPathLabel = NSTextField(labelWithString: "")
    private let profilePopup = NSPopUpButton()
    private let multiplierPopup = NSPopUpButton()
    private let flowSlider = NSSlider(value: 1.0, minValue: 0.25, maxValue: 1.0, target: nil, action: nil)
    private let flowLabel = NSTextField(labelWithString: "")
    private let performance = NSButton(checkboxWithTitle: "Performance shader mode", target: nil, action: nil)
    private let pacingPopup = NSPopUpButton()
    private let overridePresent = NSButton(checkboxWithTitle: "Override present mode / display sync", target: nil, action: nil)
    private let preserveCount = NSButton(checkboxWithTitle: "Preserve swapchain image count", target: nil, action: nil)
    private let statusLabel = NSTextField(labelWithString: "")
    private let profileInfo = NSTextField(wrappingLabelWithString: "")
    private var watchTimer: Timer?
    private var suppress = false
    private var lastModificationDate: Date?

    func applicationDidFinishLaunching(_ notification: Notification) {
        store = ConfigStore(url: defaultConfigURL())
        buildWindow()
        reloadConfig(showError: true)
        watchTimer = Timer.scheduledTimer(withTimeInterval: 0.6, repeats: true) { [weak self] _ in
            self?.pollConfig()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        watchTimer?.invalidate()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    private func defaultConfigURL() -> URL {
        let fm = FileManager.default
        if let override = ProcessInfo.processInfo.environment["LSFGM_CONFIG"], !override.isEmpty {
            return URL(fileURLWithPath: override)
        }
        if let xdg = ProcessInfo.processInfo.environment["XDG_CONFIG_HOME"], !xdg.isEmpty {
            return URL(fileURLWithPath: xdg).appendingPathComponent("lsfg-metal/conf.toml")
        }
        return fm.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/lsfg-metal/conf.toml")
    }

    private func buildWindow() {
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 650, height: 520))
        content.wantsLayer = true
        content.layer?.backgroundColor = NSColor(calibratedWhite: 0.96, alpha: 1).cgColor

        let title = NSTextField(labelWithString: "LSFG Metal Settings")
        title.font = .systemFont(ofSize: 24, weight: .bold)
        title.frame = NSRect(x: 28, y: 470, width: 420, height: 30)
        content.addSubview(title)

        let subtitle = NSTextField(wrappingLabelWithString:
            "Live configuration for a running lsfg-metal process. Changes are written immediately; no environment-variable editing is needed.")
        subtitle.font = .systemFont(ofSize: 12)
        subtitle.textColor = .secondaryLabelColor
        subtitle.frame = NSRect(x: 30, y: 426, width: 590, height: 42)
        content.addSubview(subtitle)

        let configButton = NSButton(title: "Choose Config…", target: self, action: #selector(chooseConfig))
        configButton.frame = NSRect(x: 28, y: 393, width: 120, height: 28)
        content.addSubview(configButton)

        configPathLabel.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        configPathLabel.textColor = .secondaryLabelColor
        configPathLabel.lineBreakMode = .byTruncatingMiddle
        configPathLabel.frame = NSRect(x: 160, y: 397, width: 460, height: 22)
        content.addSubview(configPathLabel)

        let profileTitle = NSTextField(labelWithString: "Profile")
        profileTitle.frame = NSRect(x: 30, y: 352, width: 100, height: 20)
        profileTitle.font = .systemFont(ofSize: 13, weight: .semibold)
        content.addSubview(profileTitle)

        profilePopup.frame = NSRect(x: 150, y: 348, width: 300, height: 28)
        profilePopup.target = self
        profilePopup.action = #selector(profileChanged)
        content.addSubview(profilePopup)

        let reload = NSButton(title: "Reload", target: self, action: #selector(reloadPressed))
        reload.frame = NSRect(x: 470, y: 348, width: 150, height: 28)
        content.addSubview(reload)

        let card = NSView(frame: NSRect(x: 26, y: 110, width: 598, height: 220))
        card.wantsLayer = true
        card.layer?.backgroundColor = NSColor.white.cgColor
        card.layer?.cornerRadius = 12
        card.layer?.borderWidth = 1
        card.layer?.borderColor = NSColor.black.withAlphaComponent(0.08).cgColor
        content.addSubview(card)

        addLabel("Multiplier", x: 22, y: 176, in: card)
        multiplierPopup.addItems(withTitles: ["2×", "3×", "4×"])
        multiplierPopup.target = self
        multiplierPopup.action = #selector(multiplierChanged)
        multiplierPopup.frame = NSRect(x: 170, y: 172, width: 100, height: 28)
        card.addSubview(multiplierPopup)

        addLabel("Flow scale", x: 22, y: 132, in: card)
        flowSlider.isContinuous = false
        flowSlider.target = self
        flowSlider.action = #selector(flowChanged)
        flowSlider.frame = NSRect(x: 170, y: 128, width: 270, height: 24)
        card.addSubview(flowSlider)

        flowLabel.alignment = .right
        flowLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        flowLabel.frame = NSRect(x: 455, y: 128, width: 100, height: 24)
        card.addSubview(flowLabel)

        performance.target = self
        performance.action = #selector(performanceChanged)
        performance.frame = NSRect(x: 20, y: 84, width: 300, height: 24)
        card.addSubview(performance)

        pacingPopup.addItems(withTitles: ["VSync / fixed", "Adaptive pacing"])
        pacingPopup.target = self
        pacingPopup.action = #selector(pacingChanged)
        pacingPopup.frame = NSRect(x: 170, y: 48, width: 190, height: 28)
        card.addSubview(pacingPopup)
        addLabel("Pacing", x: 22, y: 52, in: card)

        overridePresent.target = self
        overridePresent.action = #selector(overrideChanged)
        overridePresent.frame = NSRect(x: 20, y: 16, width: 300, height: 24)
        card.addSubview(overridePresent)

        preserveCount.target = self
        preserveCount.action = #selector(preserveChanged)
        preserveCount.frame = NSRect(x: 322, y: 16, width: 250, height: 24)
        card.addSubview(preserveCount)

        profileInfo.textColor = .secondaryLabelColor
        profileInfo.font = .systemFont(ofSize: 11.5)
        profileInfo.frame = NSRect(x: 30, y: 70, width: 590, height: 28)
        content.addSubview(profileInfo)

        statusLabel.font = .systemFont(ofSize: 11.5, weight: .semibold)
        statusLabel.textColor = .systemGreen
        statusLabel.frame = NSRect(x: 30, y: 28, width: 590, height: 24)
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
        label.frame = NSRect(x: x, y: y, width: 135, height: 22)
        parent.addSubview(label)
    }

    private func reloadConfig(showError: Bool) {
        do {
            try store.reload()
            lastModificationDate = modificationDate()
            profileSections = store.profiles()
            profilePopup.removeAllItems()
            profilePopup.addItems(withTitles: profileSections.map(\.name))
            profilePopup.isEnabled = !profileSections.isEmpty
            if !profileSections.isEmpty {
                profilePopup.selectItem(at: 0)
                profileChanged(profilePopup)
            } else {
                clearControls()
                status("No [[profile]] sections in this config.", error: true)
            }
            configPathLabel.stringValue = store.url.path
        } catch {
            status(error.localizedDescription, error: showError)
        }
    }

    private func clearControls() {
        multiplierPopup.isEnabled = false
        flowSlider.isEnabled = false
        performance.isEnabled = false
        pacingPopup.isEnabled = false
        overridePresent.isEnabled = false
        preserveCount.isEnabled = false
    }

    private func selectCurrentValues(_ values: ProfileValues) {
        suppress = true
        multiplierPopup.selectItem(at: max(0, min(2, values.multiplier - 2)))
        flowSlider.doubleValue = min(1.0, max(0.25, values.flowScale))
        flowLabel.stringValue = String(format: "%.0f%%", values.flowScale * 100.0)
        performance.state = values.performanceMode ? .on : .off
        pacingPopup.selectItem(at: values.pacingMode.lowercased() == "adaptive" ? 1 : 0)
        overridePresent.state = values.overridePresentMode ? .on : .off
        preserveCount.state = values.preserveSwapchainImageCount ? .on : .off
        multiplierPopup.isEnabled = true
        flowSlider.isEnabled = true
        performance.isEnabled = true
        pacingPopup.isEnabled = true
        overridePresent.isEnabled = true
        preserveCount.isEnabled = true
        suppress = false
    }

    private func currentSection() -> ProfileSection? {
        let i = profilePopup.indexOfSelectedItem
        return i >= 0 && i < profileSections.count ? profileSections[i] : nil
    }

    private func write(key: String, value: String, description: String) {
        guard !suppress, let section = currentSection() else { return }
        do {
            try store.set(key: key, value: value, in: section)
            lastModificationDate = modificationDate()
            status("\(description) — live on the next frame boundary.", error: false)
            reloadConfig(showError: false)
            if let refreshed = currentSection() {
                selectCurrentValues(store.values(for: refreshed))
            }
        } catch {
            status(error.localizedDescription, error: true)
        }
    }

    private func pollConfig() {
        guard let date = modificationDate(), date != lastModificationDate else { return }
        lastModificationDate = date
        reloadConfig(showError: false)
        status("Config changed externally — controls reloaded.", error: false)
    }

    private func modificationDate() -> Date? {
        try? FileManager.default.attributesOfItem(atPath: store.url.path)[.modificationDate] as? Date
    }

    @objc private func reloadPressed() {
        reloadConfig(showError: true)
    }

    @objc private func profileChanged(_ sender: Any?) {
        guard let section = currentSection() else { return }
        let values = store.values(for: section)
        selectCurrentValues(values)
        profileInfo.stringValue = "Selected profile: \(section.name). Existing running processes reload this profile from the same config file."
    }

    @objc private func multiplierChanged() {
        let value = max(2, min(4, multiplierPopup.indexOfSelectedItem + 2))
        write(key: "multiplier", value: "(value)", description: "Multiplier changed to \(value)×")
    }

    @objc private func flowChanged() {
        let value = flowSlider.doubleValue
        write(key: "flow_scale", value: String(format: "%.2f", value), description: String(format: "Flow scale changed to %.0f%%", value * 100))
    }

    @objc private func performanceChanged() {
        write(key: "performance_mode", value: performance.state == .on ? "true" : "false", description: "Performance mode (performance.state == .on ? "enabled" : "disabled")")
    }

    @objc private func pacingChanged() {
        let adaptive = pacingPopup.indexOfSelectedItem == 1
        write(key: "pacing_mode", value: adaptive ? ""adaptive"" : ""vsync"", description: adaptive ? "Adaptive pacing enabled" : "Fixed pacing enabled")
    }

    @objc private func overrideChanged() {
        write(key: "override_present_mode", value: overridePresent.state == .on ? "true" : "false", description: "Present override (overridePresent.state == .on ? "enabled" : "disabled")")
    }

    @objc private func preserveChanged() {
        write(key: "preserve_swapchain_image_count", value: preserveCount.state == .on ? "true" : "false", description: "Swapchain image preservation (preserveCount.state == .on ? "enabled" : "disabled")")
    }

    @objc private func chooseConfig() {
        let panel = NSOpenPanel()
        panel.allowedFileTypes = ["toml"]
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.begin { [weak self] response in
            guard let self, response == .OK, let url = panel.url else { return }
            self.store.url = url
            self.reloadConfig(showError: true)
        }
    }

    private func status(_ message: String, error: Bool) {
        statusLabel.stringValue = message
        statusLabel.textColor = error ? .systemRed : .systemGreen
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
