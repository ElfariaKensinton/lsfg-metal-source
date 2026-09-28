import AppKit
import Darwin
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

private enum UnixSocketError: Error, LocalizedError {
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .failed(let message): return message
        }
    }
}

private enum UnixSocket {
    static func path(pid: Int) -> String {
        "/tmp/lsfg-metal-\(pid).sock"
    }

    static func request(pid: Int, command: String) throws -> String {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw UnixSocketError.failed("socket() failed: \(String(cString: strerror(errno)))")
        }
        defer { close(fd) }

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)

        let bytes = Array(path(pid: pid).utf8) + [0]
        guard bytes.count <= MemoryLayout.size(ofValue: address.sun_path) else {
            throw UnixSocketError.failed("socket path is too long")
        }

        withUnsafeMutableBytes(of: &address.sun_path) { destination in
            destination.initializeMemory(as: UInt8.self, repeating: 0)
            bytes.withUnsafeBytes { source in
                destination.copyBytes(from: source)
            }
        }

        let connectResult = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connectResult == 0 else {
            throw UnixSocketError.failed(String(cString: strerror(errno)))
        }

        let payload = Array((command + "\n").utf8)
        let wrote = payload.withUnsafeBytes {
            write(fd, $0.baseAddress, payload.count)
        }
        guard wrote == payload.count else {
            throw UnixSocketError.failed("write() failed: \(String(cString: strerror(errno)))")
        }
        _ = shutdown(fd, SHUT_WR)

        var output = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = read(fd, &buffer, buffer.count)
            if count == 0 {
                break
            }
            if count < 0 {
                throw UnixSocketError.failed("read() failed: \(String(cString: strerror(errno)))")
            }
            output.append(buffer, count: count)
        }

        return String(data: output, encoding: .utf8) ?? ""
    }
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
        result.flowScale = Double(value("flow_scale", start: section.start, end: end) ?? "") ?? 1.0
        result.performanceMode = parseBool(value("performance_mode", start: section.start, end: end)) ?? false
        result.pacingMode = value("pacing_mode", start: section.start, end: end) ?? "vsync"
        result.overridePresentMode = parseBool(value("override_present_mode", start: section.start, end: end)) ?? true
        result.preserveSwapchainImageCount = parseBool(value("preserve_swapchain_image_count", start: section.start, end: end)) ?? false
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
        if raw.count >= 2, raw.first == Character("\""), raw.last == Character("\"") {
            return String(raw.dropFirst().dropLast())
        }
        if raw.count >= 2, raw.first == Character("'"), raw.last == Character("'") {
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
        flow_scale = 1.0
        performance_mode = false
        pacing_mode = "vsync"
        override_present_mode = true
        preserve_swapchain_image_count = false
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
    private var liveTargets: [LiveTarget] = []
    private var timer: Timer?
    private var suppress = false

    private let configPathLabel = NSTextField(labelWithString: "")
    private let targetPopup = NSPopUpButton()
    private let profilePopup = NSPopUpButton()
    private let multiplierPopup = NSPopUpButton()
    private let flowSlider = NSSlider(value: 1.0, minValue: 0.25, maxValue: 1.0, target: nil, action: nil)
    private let flowLabel = NSTextField(labelWithString: "")
    private let performance = NSButton(checkboxWithTitle: "Performance shader mode", target: nil, action: nil)
    private let pacingPopup = NSPopUpButton()
    private let overridePresent = NSButton(checkboxWithTitle: "Override present/display sync", target: nil, action: nil)
    private let preserveCount = NSButton(checkboxWithTitle: "Preserve swapchain image count", target: nil, action: nil)
    private let profileInfo = NSTextField(labelWithString: "")
    private let statusLabel = NSTextField(labelWithString: "")

    func applicationDidFinishLaunching(_ notification: Notification) {
        store = ConfigStore(url: defaultConfigURL())
        buildWindow()
        reloadConfig(showError: true)
        refreshLiveTargets()
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.refreshLiveTargets()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        timer?.invalidate()
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
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 700, height: 610))
        content.wantsLayer = true
        content.layer?.backgroundColor = NSColor(calibratedWhite: 0.96, alpha: 1).cgColor

        let title = NSTextField(labelWithString: "LSFG Metal Settings")
        title.font = .systemFont(ofSize: 24, weight: .bold)
        title.frame = NSRect(x: 28, y: 555, width: 500, height: 30)
        content.addSubview(title)

        let subtitle = NSTextField(wrappingLabelWithString:
            "Live control is sent directly to the running lsfg-metal dylib over its local 0600 Unix socket. The same values are also saved to the selected profile.")
        subtitle.font = .systemFont(ofSize: 12)
        subtitle.textColor = .secondaryLabelColor
        subtitle.frame = NSRect(x: 30, y: 513, width: 630, height: 38)
        content.addSubview(subtitle)

        let choose = NSButton(title: "Choose Config…", target: self, action: #selector(chooseConfig))
        choose.frame = NSRect(x: 28, y: 470, width: 120, height: 28)
        content.addSubview(choose)

        configPathLabel.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        configPathLabel.textColor = .secondaryLabelColor
        configPathLabel.lineBreakMode = .byTruncatingMiddle
        configPathLabel.frame = NSRect(x: 160, y: 474, width: 510, height: 22)
        content.addSubview(configPathLabel)

        let targetTitle = NSTextField(labelWithString: "Live target")
        targetTitle.font = .systemFont(ofSize: 13, weight: .semibold)
        targetTitle.frame = NSRect(x: 30, y: 430, width: 110, height: 20)
        content.addSubview(targetTitle)

        targetPopup.frame = NSRect(x: 150, y: 426, width: 390, height: 28)
        targetPopup.target = self
        targetPopup.action = #selector(targetChanged)
        targetPopup.addItem(withTitle: "Config only")
        content.addSubview(targetPopup)

        let refresh = NSButton(title: "Refresh", target: self, action: #selector(refreshPressed))
        refresh.frame = NSRect(x: 555, y: 426, width: 110, height: 28)
        content.addSubview(refresh)

        let profileTitle = NSTextField(labelWithString: "Profile")
        profileTitle.font = .systemFont(ofSize: 13, weight: .semibold)
        profileTitle.frame = NSRect(x: 30, y: 392, width: 100, height: 20)
        content.addSubview(profileTitle)

        profilePopup.frame = NSRect(x: 150, y: 388, width: 390, height: 28)
        profilePopup.target = self
        profilePopup.action = #selector(profileChanged)
        content.addSubview(profilePopup)

        let reload = NSButton(title: "Reload", target: self, action: #selector(reloadPressed))
        reload.frame = NSRect(x: 555, y: 388, width: 110, height: 28)
        content.addSubview(reload)

        let revert = NSButton(title: "Revert Live", target: self, action: #selector(revertLive))
        revert.frame = NSRect(x: 555, y: 350, width: 110, height: 28)
        content.addSubview(revert)

        let card = NSView(frame: NSRect(x: 26, y: 88, width: 640, height: 248))
        card.wantsLayer = true
        card.layer?.backgroundColor = NSColor.white.cgColor
        card.layer?.cornerRadius = 12
        card.layer?.borderWidth = 1
        card.layer?.borderColor = NSColor.black.withAlphaComponent(0.08).cgColor
        content.addSubview(card)

        addLabel("Multiplier", x: 22, y: 196, in: card)
        multiplierPopup.addItems(withTitles: ["1× / Off", "2×", "3×", "4×"])
        multiplierPopup.target = self
        multiplierPopup.action = #selector(multiplierChanged)
        multiplierPopup.frame = NSRect(x: 180, y: 192, width: 120, height: 28)
        card.addSubview(multiplierPopup)

        addLabel("Flow scale", x: 22, y: 152, in: card)
        flowSlider.isContinuous = false
        flowSlider.target = self
        flowSlider.action = #selector(flowChanged)
        flowSlider.frame = NSRect(x: 180, y: 148, width: 330, height: 24)
        card.addSubview(flowSlider)

        flowLabel.alignment = .right
        flowLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        flowLabel.frame = NSRect(x: 525, y: 148, width: 85, height: 24)
        card.addSubview(flowLabel)

        performance.target = self
        performance.action = #selector(performanceChanged)
        performance.frame = NSRect(x: 20, y: 104, width: 300, height: 24)
        card.addSubview(performance)

        addLabel("Pacing", x: 340, y: 108, in: card)
        pacingPopup.addItems(withTitles: ["VSync / fixed", "Adaptive"])
        pacingPopup.target = self
        pacingPopup.action = #selector(pacingChanged)
        pacingPopup.frame = NSRect(x: 440, y: 104, width: 170, height: 28)
        card.addSubview(pacingPopup)

        overridePresent.target = self
        overridePresent.action = #selector(overrideChanged)
        overridePresent.frame = NSRect(x: 20, y: 60, width: 300, height: 24)
        card.addSubview(overridePresent)

        preserveCount.target = self
        preserveCount.action = #selector(preserveChanged)
        preserveCount.frame = NSRect(x: 320, y: 60, width: 300, height: 24)
        card.addSubview(preserveCount)

        let note = NSTextField(wrappingLabelWithString:
            "Changes sent to a live target are applied in the running dylib. Some Vulkan swapchain properties take effect when the swapchain is recreated.")
        note.font = .systemFont(ofSize: 11)
        note.textColor = .secondaryLabelColor
        note.frame = NSRect(x: 28, y: 48, width: 640, height: 30)
        content.addSubview(note)

        profileInfo.textColor = .secondaryLabelColor
        profileInfo.font = .systemFont(ofSize: 11.5)
        profileInfo.frame = NSRect(x: 30, y: 30, width: 640, height: 20)
        content.addSubview(profileInfo)

        statusLabel.font = .systemFont(ofSize: 11.5, weight: .semibold)
        statusLabel.textColor = .systemGreen
        statusLabel.frame = NSRect(x: 30, y: 8, width: 640, height: 20)
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
                if profilePopup.indexOfSelectedItem < 0 {
                    profilePopup.selectItem(at: 0)
                }
                applyConfig(store.values(for: first))
                profileInfo.stringValue = "Selected profile: \(first.name)"
                status("Config loaded.", error: false)
            } else {
                clearControls()
                status("Config has no [[profile]] section.", error: true)
            }
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

    private func applyConfig(_ values: ProfileValues) {
        suppress = true
        selectValues(values)
        suppress = false
    }

    private func selectValues(_ values: ProfileValues) {
        multiplierPopup.selectItem(at: max(0, min(3, values.multiplier - 1)))
        flowSlider.doubleValue = min(1.0, max(0.25, values.flowScale))
        flowLabel.stringValue = String(format: "%.0f%%", values.flowScale * 100)
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
    }

    private var selectedPID: Int? {
        let index = targetPopup.indexOfSelectedItem
        guard index > 0, index - 1 < liveTargets.count else { return nil }
        return liveTargets[index - 1].pid
    }

    private func refreshLiveTargets() {
        let entries = FileManager.default.enumerator(atPath: "/tmp")?
            .compactMap { $0 as? String }
            .compactMap { path -> Int? in
                guard path.hasPrefix("lsfg-metal-"), path.hasSuffix(".sock") else { return nil }
                let number = path.dropFirst("lsfg-metal-".count).dropLast(".sock".count)
                return Int(number)
            } ?? []

        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else { return }
            var targets: [LiveTarget] = []
            for pid in entries {
                guard let response = try? UnixSocket.request(pid: pid, command: "GET"),
                      let target = self.parseTarget(pid: pid, response: response)
                else { continue }
                targets.append(target)
            }
            targets.sort { $0.pid < $1.pid }

            DispatchQueue.main.async {
                let previous = self.selectedPID
                self.liveTargets = targets
                self.targetPopup.removeAllItems()
                self.targetPopup.addItem(withTitle: "Config only")
                for target in targets {
                    self.targetPopup.addItem(withTitle: "PID \(target.pid) — \(target.profile)")
                }
                if let previous, let idx = targets.firstIndex(where: { $0.pid == previous }) {
                    self.targetPopup.selectItem(at: idx + 1)
                    self.applyTarget(targets[idx])
                } else {
                    self.targetPopup.selectItem(at: 0)
                }
            }
        }
    }

    private func parseTarget(pid: Int, response: String) -> LiveTarget? {
        guard response.hasPrefix("OK\t") else { return nil }
        var values = ProfileValues()
        var profile = "Live target"
        for part in response.dropFirst(3).split(separator: "\t") {
            guard let eq = part.firstIndex(of: "=") else { continue }
            let key = String(part[..<eq])
            let value = String(part[part.index(after: eq)...])
            switch key {
            case "profile": profile = value
            case "multiplier": values.multiplier = Int(value) ?? values.multiplier
            case "flow_scale": values.flowScale = Double(value) ?? values.flowScale
            case "performance_mode": values.performanceMode = value == "1"
            case "pacing_mode": values.pacingMode = value
            case "override_present_mode": values.overridePresentMode = value == "1"
            case "preserve_swapchain_image_count": values.preserveSwapchainImageCount = value == "1"
            default: break
            }
        }
        return LiveTarget(pid: pid, profile: profile, values: values)
    }

    private func applyTarget(_ target: LiveTarget) {
        suppress = true
        selectValues(target.values)
        profileInfo.stringValue = "LIVE PID \(target.pid) — \(target.profile)"
        suppress = false
        status("Connected directly to the running dylib.", error: false)
    }

    private func write(key: String, value: String, message: String) {
        guard !suppress else { return }

        if let pid = selectedPID {
            do {
                let response = try UnixSocket.request(pid: pid, command: "SET \(key)=\(value)")
                guard response.hasPrefix("OK\t") else {
                    throw UnixSocketError.failed(response.replacingOccurrences(of: "ERR ", with: ""))
                }
                if let target = parseTarget(pid: pid, response: response) {
                    DispatchQueue.main.async { self.applyTarget(target) }
                }
                status("\(message) — applied live to PID \(pid).", error: false)
            } catch {
                status(error.localizedDescription, error: true)
                return
            }
        }

        guard let section = currentSection() else { return }
        do {
            try store.set(key: key, value: value, in: section)
            reloadConfig(showError: false)
            if selectedPID == nil {
                status("\(message) — saved to config.", error: false)
            }
        } catch {
            status(error.localizedDescription, error: true)
        }
    }

    private func currentSection() -> ProfileSection? {
        let index = profilePopup.indexOfSelectedItem
        guard index >= 0, index < sections.count else { return nil }
        return sections[index]
    }

    private func status(_ message: String, error: Bool) {
        statusLabel.stringValue = message
        statusLabel.textColor = error ? .systemRed : .systemGreen
    }

    @objc private func targetChanged() {
        guard let pid = selectedPID else {
            if let section = currentSection() {
                applyConfig(store.values(for: section))
                profileInfo.stringValue = "Config-only editing."
            }
            return
        }
        do {
            let response = try UnixSocket.request(pid: pid, command: "GET")
            guard let target = parseTarget(pid: pid, response: response) else {
                throw UnixSocketError.failed("Invalid response from PID \(pid)")
            }
            applyTarget(target)
        } catch {
            status(error.localizedDescription, error: true)
            refreshLiveTargets()
        }
    }

    @objc private func refreshPressed() {
        refreshLiveTargets()
    }

    @objc private func revertLive() {
        guard let pid = selectedPID else {
            status("Select a live target first.", error: true)
            return
        }
        do {
            let response = try UnixSocket.request(pid: pid, command: "CLEAR")
            guard let target = parseTarget(pid: pid, response: response) else {
                throw UnixSocketError.failed("Invalid response from PID \(pid)")
            }
            applyTarget(target)
            status("Live override cleared for PID \(pid).", error: false)
        } catch {
            status(error.localizedDescription, error: true)
        }
    }

    @objc private func profileChanged() {
        guard selectedPID == nil, let section = currentSection() else { return }
        applyConfig(store.values(for: section))
        profileInfo.stringValue = "Selected profile: \(section.name)"
    }

    @objc private func multiplierChanged() {
        let value = max(1, min(4, multiplierPopup.indexOfSelectedItem + 1))
        write(key: "multiplier", value: "\(value)", message: "Multiplier \(value)×")
    }

    @objc private func flowChanged() {
        let value = min(1.0, max(0.25, flowSlider.doubleValue))
        write(key: "flow_scale", value: String(format: "%.2f", value), message: String(format: "Flow scale %.0f%%", value * 100))
    }

    @objc private func performanceChanged() {
        write(key: "performance_mode", value: performance.state == .on ? "true" : "false", message: performance.state == .on ? "Performance mode enabled" : "Performance mode disabled")
    }

    @objc private func pacingChanged() {
        let adaptive = pacingPopup.indexOfSelectedItem == 1
        write(key: "pacing_mode", value: adaptive ? "adaptive" : "vsync", message: adaptive ? "Adaptive pacing enabled" : "Fixed pacing enabled")
    }

    @objc private func overrideChanged() {
        write(key: "override_present_mode", value: overridePresent.state == .on ? "true" : "false", message: overridePresent.state == .on ? "Present override enabled" : "Present override disabled")
    }

    @objc private func preserveChanged() {
        write(key: "preserve_swapchain_image_count", value: preserveCount.state == .on ? "true" : "false", message: preserveCount.state == .on ? "Swapchain image preservation enabled" : "Swapchain image preservation disabled")
    }

    @objc private func reloadPressed() {
        reloadConfig(showError: true)
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

    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.regular)
        app.run()
    }
}
