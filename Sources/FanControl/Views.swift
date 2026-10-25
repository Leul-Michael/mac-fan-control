import FanKit
import SwiftUI

// MARK: formatting

enum Format {
    static func rpm(_ v: Double) -> String { "\(Int(v.rounded())) rpm" }
    static func shortRPM(_ v: Double) -> String { v >= 1000 ? String(format: "%.1fk", v / 1000) : "\(Int(v))" }
    static func celsius(_ v: Double) -> String { String(format: "%.0f°", v) }

    static func heat(_ c: Double) -> Color {
        switch c {
        case ..<55: return .green
        case ..<75: return .yellow
        case ..<90: return .orange
        default: return .red
        }
    }

    static func describe(_ rule: FanRule, sensors: [SensorGroup]) -> String {
        switch rule {
        case .auto: return "Auto"
        case .constant(let rpm): return rpm >= 99_999 ? "Max" : "\(Int(rpm)) rpm"
        case .sensor(let id, let start, let full):
            let name = sensors.first { $0.id == id }?.name ?? id
            return "\(name) \(Int(start))–\(Int(full))°"
        }
    }
}

// MARK: main window

struct MainWindow: View {
    @Environment(FanModel.self) private var model
    @State private var savingPreset = false
    @State private var presetName = ""

    var body: some View {
        VStack(spacing: 0) {
            if !model.helperInstalled || model.message != nil { HelperBanner() }
            HStack(alignment: .top, spacing: 0) {
                FansPanel()
                    .frame(minWidth: 420)
                Divider()
                SensorsPanel()
                    .frame(minWidth: 260)
            }
        }
        .frame(minWidth: 720, minHeight: 420)
        .toolbar {
            ToolbarItem(placement: .principal) { PresetPicker() }
            ToolbarItem {
                Button { savingPreset = true } label: { Label("Save as Preset", systemImage: "square.and.arrow.down") }
                    .help("Save the current fan rules as a preset")
            }
        }
        .alert("Save Preset", isPresented: $savingPreset) {
            TextField("Name", text: $presetName)
            Button("Save") { model.saveCurrentAsPreset(named: presetName); presetName = "" }
            Button("Cancel", role: .cancel) { presetName = "" }
        } message: {
            Text("Saves how each fan is set right now.")
        }
    }
}

struct HelperBanner: View {
    @Environment(FanModel.self) private var model

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: model.helperInstalled ? "exclamationmark.triangle.fill" : "lock.shield")
                .font(.title2)
                .foregroundStyle(model.helperInstalled ? .orange : .accentColor)
            VStack(alignment: .leading, spacing: 2) {
                Text(model.helperInstalled ? "Fan Control" : "Install the helper to control the fans")
                    .font(.headline)
                Text(model.message ?? "Reading fans and sensors works without it. Changing fan speed needs a small helper that runs with administrator rights; macOS asks for your password once.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            if !model.helperInstalled {
                Button(model.installing ? "Installing…" : "Install Helper") { model.installHelper() }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.installing)
            } else {
                Button("Dismiss") { model.message = nil }
            }
        }
        .padding(14)
        .background(.bar)
        .overlay(alignment: .bottom) { Divider() }
    }
}

struct PresetPicker: View {
    @Environment(FanModel.self) private var model

    var body: some View {
        Menu {
            ForEach(model.presets) { preset in
                Button { model.apply(preset) } label: {
                    if preset.id == model.activePresetID { Label(preset.name, systemImage: "checkmark") } else { Text(preset.name) }
                }
            }
            if !model.customPresets.isEmpty {
                Divider()
                Menu("Delete Preset") {
                    ForEach(model.customPresets) { preset in Button(preset.name, role: .destructive) { model.deletePreset(preset) } }
                }
            }
        } label: {
            Label(model.activePreset?.name ?? "Custom", systemImage: "slider.horizontal.3")
        }
        .fixedSize()
        .help("Presets")
    }
}

// MARK: fans

struct FansPanel: View {
    @Environment(FanModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Fans").font(.title3.weight(.semibold))
            if model.fans.isEmpty {
                ContentUnavailableView("No fans found", systemImage: "fan.slash", description: Text("This Mac does not report any fans."))
            }
            ForEach(model.fans) { fan in FanCard(fan: fan) }
            Spacer(minLength: 0)
        }
        .padding(16)
    }
}

struct FanCard: View {
    @Environment(FanModel.self) private var model
    let fan: FanReading
    @State private var editing = false

    var body: some View {
        let rule = model.rule(fan.id)
        HStack(spacing: 14) {
            Image(systemName: "fan.fill")
                .font(.system(size: 26))
                .foregroundStyle(rule == .auto ? Color.secondary : Color.accentColor)
                .symbolEffect(.rotate, options: .repeat(.continuous).speed(max(0.2, fan.load * 3)), isActive: fan.rpm > 100)
                .frame(width: 34)
            VStack(alignment: .leading, spacing: 5) {
                HStack(alignment: .firstTextBaseline) {
                    Text(fan.name).font(.headline)
                    Spacer()
                    Text(Format.rpm(fan.rpm)).font(.system(.title3, design: .rounded).monospacedDigit().weight(.semibold))
                }
                ProgressView(value: fan.load)
                    .tint(rule == .auto ? .secondary : .accentColor)
                HStack {
                    Text("\(Int(fan.minimum))–\(Int(fan.maximum)) rpm").foregroundStyle(.secondary)
                    Spacer()
                    if fan.manual, rule != .auto { Text("target \(Int(fan.target))").foregroundStyle(.secondary) }
                }
                .font(.caption.monospacedDigit())
            }
            .frame(maxWidth: .infinity)
            Button(Format.describe(rule, sensors: model.availableSensors)) { editing = true }
                .fixedSize()
                .popover(isPresented: $editing, arrowEdge: .trailing) { FanRuleEditor(fan: fan) }
                .help("Choose how this fan runs")
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(.background.secondary))
    }
}

struct FanRuleEditor: View {
    @Environment(FanModel.self) private var model
    let fan: FanReading

    enum Mode: String, CaseIterable { case auto = "Auto", constant = "Constant", sensor = "Sensor" }

    @State private var mode: Mode = .auto
    @State private var rpm: Double = 2000
    @State private var sensor = "cpu-hot"
    @State private var start: Double = 50
    @State private var full: Double = 85

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(fan.name).font(.headline)
            Picker("Mode", selection: $mode) {
                ForEach(Mode.allCases, id: \.self) { Text($0.rawValue) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            switch mode {
            case .auto:
                Text("macOS controls this fan.").foregroundStyle(.secondary)
            case .constant:
                HStack {
                    Slider(value: $rpm, in: fan.minimum...fan.maximum, step: 50)
                    Text("\(Int(rpm))").monospacedDigit().frame(width: 48, alignment: .trailing)
                }
                HStack {
                    Button("Min") { rpm = fan.minimum }
                    Button("50%") { rpm = ((fan.minimum + fan.maximum) / 2 / 50).rounded() * 50 }
                    Button("Max") { rpm = fan.maximum }
                }
                .controlSize(.small)
            case .sensor:
                Picker("Sensor", selection: $sensor) {
                    ForEach(model.availableSensors) { s in
                        Text("\(s.name) (\(model.celsius(s.id).map(Format.celsius) ?? "–"))").tag(s.id)
                    }
                }
                LabeledContent("Start speeding up at") {
                    Stepper("\(Int(start)) °C", value: $start, in: 30...95, step: 1).monospacedDigit()
                }
                LabeledContent("Full speed at") {
                    Stepper("\(Int(full)) °C", value: $full, in: (start + 5)...105, step: 1).monospacedDigit()
                }
                if let now = model.celsius(sensor), let target = model.preview(current, fan: fan) {
                    Text("Now \(Format.celsius(now)) → \(Format.rpm(target))")
                        .font(.callout.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(16)
        .frame(width: 320)
        .onAppear(perform: load)
        .onChange(of: current) { _, rule in model.setRule(rule, fan: fan.id) }
    }

    private var current: FanRule {
        switch mode {
        case .auto: return .auto
        case .constant: return .constant(rpm: rpm)
        case .sensor: return .sensor(id: sensor, startCelsius: start, fullCelsius: max(full, start + 5))
        }
    }

    private func load() {
        rpm = max(fan.minimum, min(fan.maximum, fan.rpm))
        switch model.rule(fan.id) {
        case .auto: mode = .auto
        case .constant(let value): mode = .constant; rpm = min(value, fan.maximum)
        case .sensor(let id, let s, let f): mode = .sensor; sensor = id; start = s; full = f
        }
    }
}

// MARK: sensors

struct SensorsPanel: View {
    @Environment(FanModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Temperatures").font(.title3.weight(.semibold))
            ForEach(model.sensors) { s in
                HStack {
                    Circle().fill(Format.heat(s.celsius)).frame(width: 8, height: 8)
                    Text(s.name)
                    Spacer()
                    Text(String(format: "%.1f °C", s.celsius)).monospacedDigit().foregroundStyle(.secondary)
                }
                .font(.callout)
            }
            Spacer(minLength: 0)
        }
        .padding(16)
    }
}

// MARK: settings

struct SettingsView: View {
    @Environment(FanModel.self) private var model

    var body: some View {
        @Bindable var model = model
        Form {
            Section("Menu bar") {
                Picker("Temperature", selection: $model.menuBarSensor) {
                    Text("None").tag("")
                    ForEach(model.availableSensors) { Text($0.name).tag($0.id) }
                }
                Toggle("Show fan speed", isOn: $model.menuBarShowsRPM)
            }
            Section("Behaviour") {
                Toggle("Launch at login", isOn: Binding(get: { model.launchAtLogin }, set: { model.launchAtLogin = $0 }))
                Toggle("Keep fan rules when the app quits", isOn: $model.keepRulesOnQuit)
                Text("When off, quitting hands the fans back to macOS.").font(.caption).foregroundStyle(.secondary)
            }
            Section("Helper") {
                LabeledContent("Status", value: model.helperRunning ? "Running" : model.helperInstalled ? "Installed, not running" : "Not installed")
                HStack {
                    Button(model.helperInstalled ? "Reinstall Helper" : "Install Helper") { model.installHelper() }
                    if model.helperInstalled { Button("Uninstall Helper", role: .destructive) { model.uninstallHelper() } }
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 420)
    }
}

// MARK: menu bar

struct MenuBarLabel: View {
    @Environment(FanModel.self) private var model

    var body: some View {
        let temp = model.menuBarSensor.isEmpty ? nil : model.celsius(model.menuBarSensor)
        let rpm = model.fans.map(\.rpm).max()
        HStack(spacing: 3) {
            Image(systemName: model.rules.isEmpty ? "fan" : "fan.fill")
            if let temp { Text(Format.celsius(temp)) }
            if model.menuBarShowsRPM, let rpm { Text(Format.shortRPM(rpm)) }
        }
        .monospacedDigit()
    }
}

struct MenuBarMenu: View {
    @Environment(FanModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        ForEach(model.fans) { fan in
            Text("\(fan.name): \(Format.rpm(fan.rpm)) · \(Format.describe(model.rule(fan.id), sensors: model.availableSensors))")
        }
        if let hot = model.celsius("cpu-hot") { Text("CPU \(Format.celsius(hot))C") }
        Divider()
        ForEach(model.presets) { preset in
            Toggle(preset.name, isOn: Binding(get: { model.activePresetID == preset.id }, set: { _ in model.apply(preset) }))
        }
        Divider()
        Button("Open Fan Control…") {
            openWindow(id: "main")
            NSApp.activate()
        }
        .keyboardShortcut("o")
        Button("Settings…") {
            openSettings()
            NSApp.activate()
        }
        .keyboardShortcut(",")
        Divider()
        Button("Quit Fan Control") { NSApp.terminate(nil) }.keyboardShortcut("q")
    }
}
