import AppKit
import Foundation
import UniformTypeIdentifiers

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

private struct LiveTarget {
    let pid: Int
    let profile: String
    let values: ProfileValues
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
            let name = value("name", start: i, end: end) ?? "Profile \(result.count + 1)"
            result.append(ProfileSection(name: name, start: i))
        }
        return result
    }

    func values(for section: ProfileSection) -> ProfileValues {
        let end = nextProfileIndex(after: section.start)
        var values = ProfileValues()
        values.multiplier = Int(value("multiplier", start: section.start, end: end) ?? "") ?? 2
        values.flowScale = Double(value("flow_scale", start: section.start, end: end) ?? "") ?? 1.0
        values.performanceMode = parseBool(value("performance_mode", start: section.start, end: end)) ?? false
        values.pacingMode = value("pacing_mode", start: section.start, end: end) ?? "vsync"
        values.overridePresentMode = parseBool(value("override_present_mode", start: section.start, end: end)) ?? true
        values.preserveSwapchainImageCount = parseBool(value("preserve_swapchain_image_count", start: section.start, end: end)) ?? false
        return values
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
        guard start + 1 < lines.endIndex else { return lines.count }
        for i in lines.index(after: start)..<lines.endIndex {
            if lines[i].trimmingCharacters(in: .whitespacesAndNewlines) == "[[profile]]" {
                return i
            }
        }
        return lines.count
    }

    private func keyIndex(_ key: String, start: Int, end: Int) -> Int? {
        guard start < end else { return nil }
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

        if raw.count >= 2, raw.first == "\"", raw.last == "\"" {
            return String(raw.dropFirst().dropLast())
        }
        if raw.count >= 2, raw.first == "'", raw.last == "'" {
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
        let text = lines.joined(separator: "\n") + "\n"
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let temp = directory.appendingPathComponent(
            ".\(url.lastPathComponent).tmp-\(UUID().uuidString)"
        )
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
    private var liveTargets: [LiveTarget] = []

    private let configPathLabel = NSTextField(labelWithString: "")
    private let targetPopup = NSPopUpButton()
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
        refreshLiveTargets()
        watchTimer = Timer.scheduledTimer(withTimeInterval: 0.8, repeats: true) { [weak self] _ in
            self?.poll()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        watchTimer?.invalidate()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    private func defaultConfigURL() -> URL {
        let env = ProcessInfo.processInfo.environment
        if let override = env["LSFGM_CONFIG"], !override.isEmpty {
            return URL(fileURLWithPath: override)
        }
        if let xdg = env["XDG_CONFIG_HOME"], !xdg.isEmpty {
            return URL(fileURLWithPath: xdg).appendingPathComponent("lsfg-metal/conf.toml")
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/lsfg-metal/conf.toml")
    }

    private func helperURL() -> URL? {
        let bundled = Bundle.main.resourceURL?.appendingPathComponent("lsfg-control")
        if let bundled, FileManager.default.isExecutableFile(atPath: bundled.path) {
            return bundled
        }

        let local = URL(fileURLWithPath: "control/.build/release/lsfg-control", relativeTo: URL(fileURLWithPath: FileManager.default.currentDirectoryPath))
        if FileManager.default.isExecutableFile(atPath: local.path) {
            return local
        }

        return nil
    }

    private func runHelper(_ arguments: [String]) -> Result<String, Error> {
        guard let executable = helperURL() else {
            return .failure(NSError(domain: "LSFGMetalControl", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "Live control helper is missing. Rebuild with Scripts/build-control.sh."
            ]))
        }

        let process = Process()
        let output = Pipe()
        let errors = Pipe()
        process.executableURL = executable
        process.arguments = arguments
        process.standardOutput = output
        process.standardError = errors

        do {
            try process.run()
        } catch {
            return .failure(error)
        }
        process.waitUntilExit()

        let data = output.fileHandleForReading.readDataToEndOfFile()
        let errorData = errors.fileHandleForReading.readDataToEndOfFile()
        let stdout = String(data: data, encoding: .utf8) ?? ""
        let stderr = String(data: errorData, encoding: .utf8) ?? ""

        if process.terminationStatus != 0 {
            let text = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            return .failure(NSError(domain: "LSFGMetalControl", code: Int(process.terminationStatus), userInfo: [
                NSLocalizedDescriptionKey: text.isEmpty ? stdout : text
            ]))
        }

        return .success(stdout)
    }

    private func buildWindow() {
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 680, height: 610))
        content.wantsLayer = true
        content.layer?.backgroundColor = NSColor(calibratedWhite: 0.96, alpha: 1).cgColor

        let title = NSTextField(labelWithString: "LSFG Metal Settings")
        title.font = .systemFont(ofSize: 24, weight: .bold)
        title.frame = NSRect(x: 28, y: 558, width: 450, height: 30)
        content.addSubview(title)

        let subtitle = NSTextField(wrappingLabelWithString:
            "Live settings for a running lsfg-metal process. Changes are saved to the profile and, when a target is selected, pushed directly into the running process.")
        subtitle.font = .systemFont(ofSize: 12)
        subtitle.textColor = .secondaryLabelColor
        subtitle.frame = NSRect(x: 30, y: 516, width: 620, height: 38)
        content.addSubview(subtitle)

        let configButton = NSButton(title: "Choose Config…", target: self, action: #selector(chooseConfig))
        configButton.frame = NSRect(x: 28, y: 478, width: 120, height: 28)
        content.addSubview(configButton)

        configPathLabel.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        configPathLabel.textColor = .secondaryLabelColor
        configPathLabel.lineBreakMode = .byTruncatingMiddle
        configPathLabel.frame = NSRect(x: 160, y: 482, width: 500, height: 22)
        content.addSubview(configPathLabel)

        let targetTitle = NSTextField(labelWithString: "Live target")
        targetTitle.font = .systemFont(ofSize: 13, weight: .semibold)
        targetTitle.frame = NSRect(x: 30, y: 437, width: 110, height: 20)
        content.addSubview(targetTitle)

        targetPopup.frame = NSRect(x: 150, y: 433, width: 315, height: 28)
        targetPopup.target = self
        targetPopup.action = #selector(targetChanged)
        targetPopup.addItem(withTitle: "Config only")
        content.addSubview(targetPopup)

        let revertLive = NSButton(title: "Revert Live", target: self, action: #selector(revertLivePressed))
        revertLive.frame = NSRect(x: 475, y: 433, width: 100, height: 28)
        content.addSubview(revertLive)

        let targetRefresh = NSButton(title: "Refresh", target: self, action: #selector(refreshTargetsPressed))
        targetRefresh.frame = NSRect(x: 585, y: 433, width: 65, height: 28)
        content.addSubview(targetRefresh)

        let profileTitle = NSTextField(labelWithString: "Profile")
        profileTitle.font = .systemFont(ofSize: 13, weight: .semibold)
        profileTitle.frame = NSRect(x: 30, y: 397, width: 110, height: 20)
        content.addSubview(profileTitle)

        profilePopup.frame = NSRect(x: 150, y: 393, width: 355, height: 28)
        profilePopup.target = self
        profilePopup.action = #selector(profileChanged)
        content.addSubview(profilePopup)

        let reload = NSButton(title: "Reload", target: self, action: #selector(reloadPressed))
        reload.frame = NSRect(x: 520, y: 393, width: 130, height: 28)
        content.addSubview(reload)

        let card = NSView(frame: NSRect(x: 26, y: 118, width: 628, height: 250))
        card.wantsLayer = true
        card.layer?.backgroundColor = NSColor.white.cgColor
        card.layer?.cornerRadius = 12
        card.layer?.borderWidth = 1
        card.layer?.borderColor = NSColor.black.withAlphaComponent(0.08).cgColor
        content.addSubview(card)

        addLabel("Multiplier", x: 22, y: 202, in: card)
        multiplierPopup.addItems(withTitles: ["1× / Off", "2×", "3×", "4×"])
        multiplierPopup.target = self
        multiplierPopup.action = #selector(multiplierChanged)
        multiplierPopup.frame = NSRect(x: 180, y: 198, width: 120, height: 28)
        card.addSubview(multiplierPopup)

        addLabel("Flow scale", x: 22, y: 158, in: card)
        flowSlider.isContinuous = false
        flowSlider.target = self
        flowSlider.action = #selector(flowChanged)
        flowSlider.frame = NSRect(x: 180, y: 154, width: 300, height: 24)
        card.addSubview(flowSlider)

        flowLabel.alignment = .right
        flowLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        flowLabel.frame = NSRect(x: 500, y: 154, width: 90, height: 24)
        card.addSubview(flowLabel)

        performance.target = self
        performance.action = #selector(performanceChanged)
        performance.frame = NSRect(x: 20, y: 110, width: 300, height: 24)
        card.addSubview(performance)

        pacingPopup.addItems(withTitles: ["VSync / fixed", "Adaptive pacing"])
        pacingPopup.target = self
        pacingPopup.action = #selector(pacingChanged)
        pacingPopup.frame = NSRect(x: 180, y: 74, width: 210, height: 28)
        card.addSubview(pacingPopup)
        addLabel("Pacing", x: 22, y: 78, in: card)

        overridePresent.target = self
        overridePresent.action = #selector(overrideChanged)
        overridePresent.frame = NSRect(x: 20, y: 40, width: 300, height: 24)
        card.addSubview(overridePresent)

        preserveCount.target = self
        preserveCount.action = #selector(preserveChanged)
        preserveCount.frame = NSRect(x: 322, y: 40, width: 280, height: 24)
        card.addSubview(preserveCount)

        let hint = NSTextField(wrappingLabelWithString:
            "A selected live target is updated through the running shim's local control socket. This also works when the game was launched with LSFGM_ENV=1.")
        hint.font = .systemFont(ofSize: 11)
        hint.textColor = .secondaryLabelColor
        hint.frame = NSRect(x: 28, y: 82, width: 620, height: 28)
        content.addSubview(hint)

        profileInfo.textColor = .secondaryLabelColor
        profileInfo.font = .systemFont(ofSize: 11.5)
        profileInfo.frame = NSRect(x: 30, y: 52, width: 620, height: 24)
        content.addSubview(profileInfo)

        statusLabel.font = .systemFont(ofSize: 11.5, weight: .semibold)
        statusLabel.textColor = .systemGreen
        statusLabel.frame = NSRect(x: 30, y: 22, width: 620, height: 24)
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
        let previousName = currentSection()?.name
        do {
            try store.reload()
            lastModificationDate = modificationDate()
            profileSections = store.profiles()
            profilePopup.removeAllItems()
            profilePopup.addItems(withTitles: profileSections.map(\.name))
            profilePopup.isEnabled = !profileSections.isEmpty

            if !profileSections.isEmpty {
                let preferred = previousName.flatMap { name in
                    profileSections.firstIndex(where: { $0.name == name })
                } ?? 0
                profilePopup.selectItem(at: preferred)
                if selectedTargetPID == nil {
                    profileChanged(profilePopup)
                }
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
        let multiplierIndex = max(0, min(3, values.multiplier - 1))
        multiplierPopup.selectItem(at: multiplierIndex)
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
        let index = profilePopup.indexOfSelectedItem
        return index >= 0 && index < profileSections.count ? profileSections[index] : nil
    }

    private var selectedTargetPID: Int? {
        let index = targetPopup.indexOfSelectedItem
        guard index > 0 else { return nil }
        let targetIndex = index - 1
        return targetIndex >= 0 && targetIndex < liveTargets.count ? liveTargets[targetIndex].pid : nil
    }

    private func parseLiveTargets(_ text: String) -> [LiveTarget] {
        text.split(separator: "\n").compactMap { raw in
            let parts = raw.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard parts.count >= 8, let pid = Int(parts[0]) else { return nil }
            let profile = parts[1].hasPrefix("profile=")
                ? String(parts[1].dropFirst("profile=".count))
                : parts[1]
            let values = ProfileValues(
                multiplier: Int(parts[2]) ?? 2,
                flowScale: Double(parts[3]) ?? 1.0,
                performanceMode: parts[4] == "1",
                pacingMode: parts[5],
                overridePresentMode: parts[6] == "1",
                preserveSwapchainImageCount: parts[7] == "1"
            )
            return LiveTarget(pid: pid, profile: profile, values: values)
        }
    }

    private func refreshLiveTargets() {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else { return }
            let result = self.runHelper(["list"])
            let targets: [LiveTarget] = {
                guard case .success(let output) = result else { return [] }
                return self.parseLiveTargets(output)
            }()

            DispatchQueue.main.async {
                let previousPID = self.selectedTargetPID
                self.liveTargets = targets
                self.targetPopup.removeAllItems()
                self.targetPopup.addItem(withTitle: "Config only")
                for target in targets {
                    self.targetPopup.addItem(withTitle: "PID \(target.pid) — \(target.profile)")
                }

                if let previousPID, let index = targets.firstIndex(where: { $0.pid == previousPID }) {
                    self.targetPopup.selectItem(at: index + 1)
                    self.applyLiveTargetToControls(targets[index])
                } else {
                    self.targetPopup.selectItem(at: 0)
                }
            }
        }
    }

    private func applyLiveTargetToControls(_ target: LiveTarget) {
        selectCurrentValues(target.values)
        profileInfo.stringValue = "Live target PID \(target.pid) — \(target.profile)"
        status("Connected to the running lsfg-metal process.", error: false)
    }

    private func write(key: String, value: String, description: String) {
        guard !suppress else { return }

        var liveTargetAfter: LiveTarget?
        if let pid = selectedTargetPID {
            switch runHelper(["set", String(pid), "\(key)=\(value)"]) {
            case .success(let output):
                if output.hasPrefix("ERR ") {
                    status(String(output.dropFirst(4)), error: true)
                    return
                }
                if output.hasPrefix("OK ") {
                    liveTargetAfter = parseLiveTargets("\(pid)\t" + String(output.dropFirst(3))).first
                }
            case .failure(let error):
                status(error.localizedDescription, error: true)
                return
            }
        }

        guard let section = currentSection() else {
            if let liveTargetAfter {
                applyLiveTargetToControls(liveTargetAfter)
            }
            status(description + " applied live.", error: false)
            return
        }

        do {
            try store.set(key: key, value: value, in: section)
            lastModificationDate = modificationDate()

            if let liveTargetAfter,
               let index = liveTargets.firstIndex(where: { $0.pid == liveTargetAfter.pid }) {
                liveTargets[index] = liveTargetAfter
            }

            reloadConfig(showError: false)

            if let liveTargetAfter {
                applyLiveTargetToControls(liveTargetAfter)
                status("\(description) — applied live to PID \(liveTargetAfter.pid) and saved to config.", error: false)
            } else {
                status("\(description) — saved to config; a running file-mode process reloads it at the next frame boundary.", error: false)
            }
        } catch {
            status(error.localizedDescription, error: true)
        }
    }

    private func poll() {
        pollConfig()
        refreshLiveTargets()
    }

    private func pollConfig() {
        guard let date = modificationDate(), date != lastModificationDate else { return }
        lastModificationDate = date
        reloadConfig(showError: false)
        if selectedTargetPID == nil {
            status("Config changed externally — controls reloaded.", error: false)
        }
    }

    private func modificationDate() -> Date? {
        try? FileManager.default.attributesOfItem(atPath: store.url.path)[.modificationDate] as? Date
    }

    @objc private func reloadPressed() {
        reloadConfig(showError: true)
    }

    @objc private func refreshTargetsPressed() {
        refreshLiveTargets()
    }

    @objc private func revertLivePressed() {
        guard let pid = selectedTargetPID else {
            status("Select a running target first.", error: true)
            return
        }

        switch runHelper(["clear", String(pid)]) {
        case .success(let output):
            guard !output.hasPrefix("ERR ") else {
                status(String(output.dropFirst(4)), error: true)
                return
            }
            if let section = currentSection() {
                selectCurrentValues(store.values(for: section))
            }
            status("Live override cleared for PID (pid). The config profile is active again.", error: false)
            refreshLiveTargets()
        case .failure(let error):
            status(error.localizedDescription, error: true)
        }
    }

    @objc private func targetChanged(_ sender: Any?) {
        guard let pid = selectedTargetPID else {
            if let section = currentSection() {
                selectCurrentValues(store.values(for: section))
                status("Editing the config file without a live target.", error: false)
            }
            return
        }

        switch runHelper(["get", String(pid)]) {
        case .success(let output):
            let targets = parseLiveTargets("\(pid)\t" + String(output.dropFirst(3)))
            if let target = targets.first {
                applyLiveTargetToControls(target)
            } else {
                status("Could not read the live target settings.", error: true)
            }
        case .failure(let error):
            status(error.localizedDescription, error: true)
        }
    }

    @objc private func profileChanged(_ sender: Any?) {
        guard selectedTargetPID == nil, let section = currentSection() else { return }
        let values = store.values(for: section)
        selectCurrentValues(values)
        profileInfo.stringValue = "Selected profile: \(section.name)."
    }

    @objc private func multiplierChanged() {
        let index = max(0, min(3, multiplierPopup.indexOfSelectedItem))
        let value = index + 1
        write(key: "multiplier", value: "\(value)", description: "Multiplier changed to \(value)×")
    }

    @objc private func flowChanged() {
        let value = flowSlider.doubleValue
        write(
            key: "flow_scale",
            value: String(format: "%.2f", value),
            description: String(format: "Flow scale changed to %.0f%%", value * 100)
        )
    }

    @objc private func performanceChanged() {
        write(
            key: "performance_mode",
            value: performance.state == .on ? "true" : "false",
            description: "Performance mode \(performance.state == .on ? "enabled" : "disabled")"
        )
    }

    @objc private func pacingChanged() {
        let adaptive = pacingPopup.indexOfSelectedItem == 1
        write(
            key: "pacing_mode",
            value: adaptive ? "\"adaptive\"" : "\"vsync\"",
            description: adaptive ? "Adaptive pacing enabled" : "Fixed pacing enabled"
        )
    }

    @objc private func overrideChanged() {
        write(
            key: "override_present_mode",
            value: overridePresent.state == .on ? "true" : "false",
            description: "Present override \(overridePresent.state == .on ? "enabled" : "disabled")"
        )
    }

    @objc private func preserveChanged() {
        write(
            key: "preserve_swapchain_image_count",
            value: preserveCount.state == .on ? "true" : "false",
            description: "Swapchain image preservation \(preserveCount.state == .on ? "enabled" : "disabled")"
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
            guard let self, response == .OK, let url = panel.url else { return }
            self.store.url = url
            self.reloadConfig(showError: true)
        }
    }

    private func status(_ message: String, error: Bool) {
        statusLabel.stringValue = message
        statusLabel.textColor = error ? .systemRed : .systemGreen
    }
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.regular)
        app.run()
    }
}
