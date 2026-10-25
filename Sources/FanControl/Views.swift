import FanKit
import SwiftUI

// MARK: look

enum Theme {
    static let mint = Color(red: 0.18, green: 0.88, blue: 0.65)
    static let headerTop = Color(red: 0.11, green: 0.36, blue: 0.85)
    static let headerBottom = Color(red: 0.04, green: 0.16, blue: 0.42)
    static let body = Color(red: 0.06, green: 0.08, blue: 0.13)
    static let row = Color.white.opacity(0.05)
}

enum Format {
    static func rpm(_ v: Double) -> String { v < 50 ? "Off" : "\(Int(v.rounded()).formatted())" }
    static func shortRPM(_ v: Double) -> String { v < 50 ? "off" : v >= 1000 ? String(format: "%.1fk", v / 1000) : "\(Int(v))" }
    static func celsius(_ v: Double) -> String { String(format: "%.0f°", v) }

    static func heat(_ c: Double) -> Color {
        switch c {
        case ..<55: return Theme.mint
        case ..<75: return .yellow
        case ..<90: return .orange
        default: return .red
        }
    }
}

// MARK: one setting for one or several fans

/// A fan setting independent of a fan's own range, so one setting can drive fans with different maximums.
enum Setting: Equatable {
    case auto
    case speed(Double)                                   // 0...1 of each fan's range
    case sensor(id: String, start: Double, full: Double)

    enum Kind: String, CaseIterable, Identifiable { case auto = "Auto", speed = "Speed", sensor = "Sensor"; var id: Self { self } }

    var kind: Kind {
        switch self { case .auto: .auto; case .speed: .speed; case .sensor: .sensor }
    }

    init(_ rule: FanRule, fan: FanReading) {
        switch rule {
        case .auto: self = .auto
        case .constant(let rpm):
            let span = fan.maximum - fan.minimum
            self = .speed(span > 0 ? max(0, min(1, (rpm - fan.minimum) / span)) : 1)
        case .sensor(let id, let start, let full): self = .sensor(id: id, start: start, full: full)
        }
    }

    func rule(for fan: FanReading) -> FanRule {
        switch self {
        case .auto: return .auto
        case .speed(let share): return .constant(rpm: ((fan.minimum + share * (fan.maximum - fan.minimum)) / 50).rounded() * 50)
        case .sensor(let id, let start, let full): return .sensor(id: id, startCelsius: start, fullCelsius: full)
        }
    }

    /// The shared setting of several fans, or nil when they are set differently.
    @MainActor static func common(_ fans: [FanReading], model: FanModel) -> Setting? {
        let settings = fans.map { Setting(model.rule($0.id), fan: $0) }
        guard let first = settings.first else { return nil }
        return settings.allSatisfy { $0.isClose(to: first) } ? first : nil
    }

    private func isClose(to other: Setting) -> Bool {
        if case .speed(let a) = self, case .speed(let b) = other { return abs(a - b) < 0.02 }
        return self == other
    }

    @MainActor func summary(_ model: FanModel) -> String {
        switch self {
        case .auto: return "Auto"
        case .speed(let share): return share >= 0.995 ? "Max speed" : "Speed \(Int((share * 100).rounded()))%"
        case .sensor(let id, let start, let full):
            let name = model.availableSensors.first { $0.id == id }?.name ?? id
            return "\(name) \(Int(start))–\(Int(full))°"
        }
    }
}

/// Mode picker plus the controls for that mode, applied to one or more fans.
struct SettingControls: View {
    @Environment(FanModel.self) private var model
    let fans: [FanReading]

    var body: some View {
        let current = Setting.common(fans, model: model)
        VStack(alignment: .leading, spacing: 10) {
            Picker("Mode", selection: Binding(get: { current?.kind }, set: { if let kind = $0 { select(kind) } })) {
                ForEach(Setting.Kind.allCases) { Text($0.rawValue).tag(Optional($0)) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            switch current {
            case nil:
                note("Fans are set differently. Pick a mode to link them.")
            case .auto?:
                note(fans.count > 1 ? "macOS controls both fans." : "macOS controls this fan.")
            case .speed(let share)?:
                speed(share)
            case .sensor(let id, let start, let full)?:
                sensor(id: id, start: start, full: full)
            }
        }
    }

    private func note(_ text: String) -> some View {
        Text(text).font(.caption).foregroundStyle(.secondary)
    }

    private func apply(_ setting: Setting) {
        model.setRules(Dictionary(uniqueKeysWithValues: fans.map { ($0.id, setting.rule(for: $0)) }))
    }

    private func select(_ kind: Setting.Kind) {
        switch kind {
        case .auto: apply(.auto)
        case .speed: apply(.speed(max(0.3, fans.map(\.load).max() ?? 0.5)))
        case .sensor: apply(.sensor(id: "cpu-hot", start: 50, full: 85))
        }
    }

    @ViewBuilder private func speed(_ share: Double) -> some View {
        HStack(spacing: 8) {
            Slider(value: Binding(get: { share }, set: { apply(.speed(($0 * 100).rounded() / 100)) }), in: 0...1)
                .tint(Theme.mint)
            Text("\(Int((share * 100).rounded()))%").font(.callout.monospacedDigit()).frame(width: 38, alignment: .trailing)
        }
        HStack(spacing: 6) {
            ForEach([("Low", 0.0), ("50%", 0.5), ("75%", 0.75), ("Max", 1.0)], id: \.0) { name, value in
                Chip(name, selected: abs(share - value) < 0.01) { apply(.speed(value)) }
            }
        }
    }

    @ViewBuilder private func sensor(id: String, start: Double, full: Double) -> some View {
        Picker("Follow", selection: Binding(get: { id }, set: { apply(.sensor(id: $0, start: start, full: full)) })) {
            ForEach(model.availableSensors) { s in Text(s.name).tag(s.id) }
        }
        .controlSize(.small)
        HStack {
            Stepper(value: Binding(get: { start }, set: { apply(.sensor(id: id, start: $0, full: max(full, $0 + 5))) }), in: 30...95) {
                Text("From \(Int(start))°").monospacedDigit()
            }
            Spacer()
            Stepper(value: Binding(get: { full }, set: { apply(.sensor(id: id, start: start, full: max($0, start + 5))) }), in: 35...105) {
                Text("Max at \(Int(full))°").monospacedDigit()
            }
        }
        .font(.caption)
        .controlSize(.small)
    }
}

struct Chip: View {
    let title: String
    let selected: Bool
    let action: () -> Void
    init(_ title: String, selected: Bool, action: @escaping () -> Void) { self.title = title; self.selected = selected; self.action = action }

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.caption.weight(.semibold))
                .padding(.horizontal, 10).padding(.vertical, 4)
                .background(Capsule().fill(selected ? Theme.mint.opacity(0.22) : Theme.row))
                .foregroundStyle(selected ? Theme.mint : .secondary)
        }
        .buttonStyle(.plain)
    }
}

// MARK: compact panel (window and menu bar)

struct CompactPanel: View {
    @Environment(FanModel.self) private var model
    @State private var showFans = false
    @State private var showTemps = false

    var body: some View {
        VStack(spacing: 0) {
            Header()
            VStack(spacing: 8) {
                if model.fans.count > 1 {
                    Section(title: "Both Fans") { SettingControls(fans: model.fans) }
                }
                Expander(title: model.fans.count > 1 ? "Each Fan" : "Fan", open: $showFans) {
                    ForEach(model.fans) { fan in
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Text(fan.name).font(.callout.weight(.semibold))
                                Spacer()
                                Text(Format.rpm(fan.rpm) + (fan.rpm < 50 ? "" : " rpm"))
                                    .font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                            }
                            SettingControls(fans: [fan])
                        }
                        if fan.id != model.fans.last?.id { Divider().opacity(0.4) }
                    }
                }
                Expander(title: "Temperatures", open: $showTemps) {
                    ForEach(model.sensors) { s in
                        HStack {
                            Circle().fill(Format.heat(s.celsius)).frame(width: 6, height: 6)
                            Text(s.name).font(.caption)
                            Spacer()
                            Text(String(format: "%.0f °C", s.celsius)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .padding(12)
            Footer()
        }
        .frame(width: 340)
        .background(Theme.body)
        .environment(\.colorScheme, .dark)
    }
}

private struct Header: View {
    @Environment(FanModel.self) private var model

    var body: some View {
        let setting = Setting.common(model.fans, model: model)
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 6) {
                    Image(systemName: "fan.fill").font(.headline)
                    Text("Fan Control").font(.system(.title3, design: .rounded).weight(.bold))
                }
                .foregroundStyle(.white)
                HStack(spacing: 6) {
                    Text(model.isOn ? "ON" : "AUTO")
                        .font(.caption2.weight(.heavy))
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(Capsule().fill(model.isOn ? Theme.mint.opacity(0.2) : .white.opacity(0.12)))
                        .foregroundStyle(model.isOn ? Theme.mint : .white.opacity(0.7))
                    Text(model.isOn ? (setting?.summary(model) ?? "Custom") : "macOS decides")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(model.isOn ? Theme.mint : .white.opacity(0.7))
                        .lineLimit(1)
                }
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(model.celsius("cpu-hot").map(Format.celsius) ?? "–")
                        .font(.system(size: 34, weight: .bold, design: .rounded).monospacedDigit())
                        .foregroundStyle(.white)
                        .contentTransition(.numericText())
                    Text("CPU").font(.caption.weight(.bold)).foregroundStyle(.white.opacity(0.6))
                }
                HStack(spacing: 12) {
                    ForEach(model.fans) { fan in
                        HStack(spacing: 4) {
                            Image(systemName: "fan")
                                .symbolEffect(.rotate, options: .repeat(.continuous).speed(max(0.3, fan.load * 3)), isActive: fan.rpm >= 50)
                            Text(fan.name.replacingOccurrences(of: " Fan", with: "").prefix(1) + " " + Format.rpm(fan.rpm))
                                .monospacedDigit()
                        }
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.8))
                    }
                }
            }
            Spacer(minLength: 0)
            PowerButton()
        }
        .padding(16)
        .background(LinearGradient(colors: [Theme.headerTop, Theme.headerBottom], startPoint: .topLeading, endPoint: .bottomTrailing))
    }
}

private struct PowerButton: View {
    @Environment(FanModel.self) private var model

    var body: some View {
        Button { model.togglePower() } label: {
            ZStack {
                Circle().fill(.white)
                Circle().strokeBorder(model.isOn ? Theme.mint : .white.opacity(0.35), lineWidth: 6)
                Image(systemName: "power")
                    .font(.system(size: 34, weight: .semibold))
                    .foregroundStyle(model.isOn ? Theme.headerBottom : .gray)
            }
            .frame(width: 92, height: 92)
            .shadow(color: model.isOn ? Theme.mint.opacity(0.5) : .clear, radius: 10)
            .animation(.spring(duration: 0.3), value: model.isOn)
        }
        .buttonStyle(.plain)
        .help(model.helperInstalled ? (model.isOn ? "Hand the fans back to macOS" : "Use your fan settings") : "Install the helper first")
    }
}

private struct Section<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title.uppercased()).font(.caption2.weight(.bold)).foregroundStyle(.secondary).tracking(1)
            content
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(Theme.row))
    }
}

private struct Expander<Content: View>: View {
    let title: String
    @Binding var open: Bool
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button { withAnimation(.snappy) { open.toggle() } } label: {
                HStack {
                    Text(title).font(.callout.weight(.semibold))
                    Spacer()
                    Image(systemName: "chevron.down")
                        .font(.caption.weight(.bold))
                        .rotationEffect(.degrees(open ? 180 : 0))
                        .frame(width: 24, height: 24)
                        .background(Circle().fill(Theme.row))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if open { content }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(Theme.row))
    }
}

private struct Footer: View {
    @Environment(FanModel.self) private var model
    @Environment(\.openSettings) private var openSettings
    @State private var savingPreset = false
    @State private var presetName = ""

    var body: some View {
        HStack(spacing: 8) {
            if !model.helperInstalled {
                Button(model.installing ? "Installing…" : "Install Helper") { model.installHelper() }
                    .buttonStyle(.borderedProminent).tint(Theme.headerTop).controlSize(.small)
                    .disabled(model.installing)
                Text("needed to change speeds").font(.caption).foregroundStyle(.secondary)
            } else if let message = model.message {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                Text(message).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            } else {
                Menu {
                    ForEach(model.presets) { preset in
                        Button { model.apply(preset) } label: {
                            if preset.id == model.activePresetID { Label(preset.name, systemImage: "checkmark") } else { Text(preset.name) }
                        }
                    }
                    Divider()
                    Button("Save Current as Preset…") { savingPreset = true }
                    if !model.customPresets.isEmpty {
                        Menu("Delete Preset") {
                            ForEach(model.customPresets) { p in Button(p.name, role: .destructive) { model.deletePreset(p) } }
                        }
                    }
                } label: {
                    Label(model.activePreset?.name ?? "Custom", systemImage: "slider.horizontal.3").font(.caption.weight(.semibold))
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }
            Spacer()
            Menu {
                Button("Settings…") { openSettings(); NSApp.activate() }
                Divider()
                Button("Quit Fan Control") { NSApp.terminate(nil) }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .background(Color.black.opacity(0.3))
        .alert("Save Preset", isPresented: $savingPreset) {
            TextField("Name", text: $presetName)
            Button("Save") { model.saveCurrentAsPreset(named: presetName); presetName = "" }
            Button("Cancel", role: .cancel) { presetName = "" }
        }
    }
}

// MARK: settings

struct SettingsView: View {
    @Environment(FanModel.self) private var model

    var body: some View {
        @Bindable var model = model
        Form {
            SwiftUI.Section("Menu bar") {
                Picker("Temperature", selection: $model.menuBarSensor) {
                    Text("None").tag("")
                    ForEach(model.availableSensors) { Text($0.name).tag($0.id) }
                }
                Toggle("Show fan speed", isOn: $model.menuBarShowsRPM)
            }
            SwiftUI.Section("Behaviour") {
                Toggle("Launch at login", isOn: Binding(get: { model.launchAtLogin }, set: { model.launchAtLogin = $0 }))
                Toggle("Keep fan settings when the app quits", isOn: $model.keepRulesOnQuit)
                Text("When off, quitting hands the fans back to macOS.").font(.caption).foregroundStyle(.secondary)
            }
            SwiftUI.Section("Helper") {
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
            Image(systemName: model.isOn ? "fan.fill" : "fan")
            if let temp { Text(Format.celsius(temp)) }
            if model.menuBarShowsRPM, let rpm { Text(Format.shortRPM(rpm)) }
        }
        .monospacedDigit()
    }
}
