import AppKit
import FanKit
import Foundation
import Observation
import ServiceManagement

/// Live fan and sensor state, the rules in force and the saved presets.
@MainActor @Observable
final class FanModel {
    static let shared = FanModel()

    private(set) var fans: [FanReading] = []
    private(set) var sensors: [SensorReading] = []
    private(set) var availableSensors: [SensorGroup] = []
    private(set) var rules: [Int: FanRule] = [:]
    private(set) var customPresets: [Preset] = []
    private(set) var activePresetID: UUID?
    /// The settings in force before the power button turned the fans over to macOS.
    private(set) var lastRules: [Int: FanRule] = [:]
    private(set) var helperInstalled = false
    private(set) var helperRunning = false
    private(set) var installing = false
    var message: String?

    var keepRulesOnQuit: Bool { didSet { defaults.set(keepRulesOnQuit, forKey: "keepRulesOnQuit") } }
    var menuBarSensor: String { didSet { defaults.set(menuBarSensor, forKey: "menuBarSensor") } }
    var menuBarShowsRPM: Bool { didSet { defaults.set(menuBarShowsRPM, forKey: "menuBarShowsRPM") } }

    private let smc: SMC?
    private let reader: SensorReader?
    private let defaults = UserDefaults.standard
    private var timer: Timer?
    private var ticks = 0

    static let automatic = Preset(id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!, name: "Automatic", rules: [:])
    static let fullBlast = Preset(id: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!, name: "Full Blast",
                                  rules: [0: .constant(rpm: 100_000), 1: .constant(rpm: 100_000)])
    static let cool = Preset(id: UUID(uuidString: "00000000-0000-0000-0000-000000000003")!, name: "Cool & Quiet",
                             rules: [0: .sensor(id: "cpu-hot", startCelsius: 55, fullCelsius: 85),
                                     1: .sensor(id: "cpu-hot", startCelsius: 55, fullCelsius: 85)])
    static let builtIn = [automatic, cool, fullBlast]

    var presets: [Preset] { Self.builtIn + customPresets }
    var activePreset: Preset? { presets.first { $0.id == activePresetID } }

    private init() {
        smc = try? SMC()
        reader = smc.map { SensorReader(smc: $0) }
        keepRulesOnQuit = defaults.object(forKey: "keepRulesOnQuit") as? Bool ?? false
        menuBarSensor = defaults.string(forKey: "menuBarSensor") ?? "cpu-hot"
        menuBarShowsRPM = defaults.object(forKey: "menuBarShowsRPM") as? Bool ?? true
        if let data = defaults.data(forKey: "customPresets"), let saved = try? JSONDecoder().decode([Preset].self, from: data) { customPresets = saved }
        if let data = defaults.data(forKey: "rules"), let saved = try? JSONDecoder().decode([Int: FanRule].self, from: data) { rules = saved }
        if let data = defaults.data(forKey: "lastRules"), let saved = try? JSONDecoder().decode([Int: FanRule].self, from: data) { lastRules = saved }
        activePresetID = defaults.string(forKey: "activePreset").flatMap(UUID.init) ?? Self.automatic.id
        availableSensors = reader?.available ?? []
        if smc == nil { message = "This Mac's fan controller could not be opened." }
        refresh()
        if !CommandLine.arguments.contains("--snapshot") { push() }   // re-apply the last rules after a restart of the app
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
            MainActor.assumeIsolated { FanModel.shared.refresh() }
        }
    }

    // MARK: readings

    func refresh() {
        guard let smc, let reader else { return }
        fans = smc.fans()
        sensors = reader.readings()
        helperInstalled = FileManager.default.fileExists(atPath: Paths.launchDaemon)
            && FileManager.default.isWritableFile(atPath: Paths.configDirectory)
        if !helperInstalled { helperRunning = false } else if ticks % 5 == 0 { helperRunning = Self.processRunning(Paths.helper) }
        ticks += 1
    }

    func celsius(_ sensor: String) -> Double? { sensors.first { $0.id == sensor }?.celsius }

    func rule(_ fan: Int) -> FanRule { rules[fan] ?? .auto }

    /// What a rule would ask for right now (for previews), nil when automatic.
    func preview(_ rule: FanRule, fan: FanReading) -> Double? {
        guard let reader else { return nil }
        return targetRPM(for: rule, fan: fan, sensors: reader)
    }

    // MARK: rules and presets

    func setRule(_ rule: FanRule, fan: Int) { setRules([fan: rule]) }

    /// Changes several fans in one write, so linked changes reach the helper together.
    func setRules(_ changes: [Int: FanRule]) {
        var next = rules
        for (fan, rule) in changes { next[fan] = rule == .auto ? nil : rule }
        guard next != rules else { return }
        rules = next
        activePresetID = presets.first { $0.rules == rules }?.id
        if !rules.isEmpty { lastRules = rules }
        push()
    }

    func apply(_ preset: Preset) {
        rules = preset.rules.filter { $0.value != .auto }
        activePresetID = preset.id
        if !rules.isEmpty { lastRules = rules }
        push()
    }

    /// On: any fan follows your settings. Off: macOS controls every fan.
    var isOn: Bool { !rules.isEmpty }

    /// The power button: off hands the fans to macOS; on brings back the last settings (or 60% on both fans).
    func togglePower() {
        guard helperInstalled else { installHelper(); return }
        if isOn {
            lastRules = rules
            rules = [:]
            activePresetID = Self.automatic.id
            push()
        } else if !lastRules.isEmpty {
            setRules(lastRules)
        } else {
            setRules(Dictionary(uniqueKeysWithValues: fans.map { fan in
                (fan.id, FanRule.constant(rpm: ((fan.minimum + 0.6 * (fan.maximum - fan.minimum)) / 50).rounded() * 50))
            }))
        }
    }

    func saveCurrentAsPreset(named name: String) {
        let preset = Preset(name: name.trimmingCharacters(in: .whitespaces).isEmpty ? "My Preset" : name, rules: rules)
        customPresets.append(preset)
        activePresetID = preset.id
        persist()
    }

    func deletePreset(_ preset: Preset) {
        customPresets.removeAll { $0.id == preset.id }
        if activePresetID == preset.id { activePresetID = presets.first { $0.rules == rules }?.id }
        persist()
    }

    private func persist() {
        defaults.set(try? JSONEncoder().encode(customPresets), forKey: "customPresets")
        defaults.set(try? JSONEncoder().encode(rules), forKey: "rules")
        defaults.set(try? JSONEncoder().encode(lastRules), forKey: "lastRules")
        defaults.set(activePresetID?.uuidString, forKey: "activePreset")
    }

    /// Hands the rules to the helper, which applies them as root.
    private func push() {
        persist()
        guard FileManager.default.isWritableFile(atPath: Paths.configDirectory) else {
            if !rules.isEmpty { message = "Install the helper to control the fans." }
            return
        }
        do {
            try HelperConfig(rules: rules).save()
            message = nil
        } catch {
            message = "Could not update the helper: \(error.localizedDescription)"
        }
    }

    /// Called when the app quits: unless asked to keep them, fans go back to macOS.
    func releaseOnQuit() {
        guard !keepRulesOnQuit, FileManager.default.isWritableFile(atPath: Paths.configDirectory) else { return }
        try? HelperConfig().save()
    }

    #if DEBUG
    /// Snapshots only: show these rules without sending them to the helper.
    func previewRules(_ preview: [Int: FanRule]) { rules = preview }
    #endif

    // MARK: helper

    func installHelper() { runPrivileged("install --user \(NSUserName())") }
    func uninstallHelper() { runPrivileged("uninstall") }

    private func runPrivileged(_ arguments: String) {
        guard let tool = Bundle.main.url(forResource: "fanctl", withExtension: nil)?.path else {
            message = "fanctl is missing from the app bundle."
            return
        }
        installing = true
        let quoted = "'" + tool.replacingOccurrences(of: "'", with: "'\\''") + "'"
        let script = "do shell script \"\(quoted) \(arguments)\" with administrator privileges"
        Task.detached {
            var error: NSDictionary?
            NSAppleScript(source: script)?.executeAndReturnError(&error)
            let failure = (error?[NSAppleScript.errorMessage] as? String)
            await MainActor.run {
                let model = FanModel.shared
                model.installing = false
                if let failure, !(failure.contains("canceled") || failure.contains("cancelled")) { model.message = failure }
                model.ticks = 0   // check the helper process now, not on the next 5-second pass
                model.refresh()
                model.push()
            }
        }
    }

    private static func processRunning(_ path: String) -> Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        p.arguments = ["-f", path]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return false }
        p.waitUntilExit()
        return p.terminationStatus == 0
    }

    // MARK: launch at login

    var launchAtLogin: Bool {
        get { SMAppService.mainApp.status == .enabled }
        set {
            do {
                if newValue { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            } catch {
                message = "Launch at login: \(error.localizedDescription)"
            }
        }
    }
}
