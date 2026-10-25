import FanKit
import SwiftUI

// MARK: design tokens

enum Theme {
    static let accent = Color(red: 0.22, green: 0.92, blue: 0.70)
    static let accentDeep = Color(red: 0.05, green: 0.68, blue: 0.56)
    static let blueTop = Color(red: 0.16, green: 0.42, blue: 0.98)
    static let blueBottom = Color(red: 0.05, green: 0.14, blue: 0.42)
    static let background = Color(red: 0.055, green: 0.067, blue: 0.105)
    static let card = Color.white.opacity(0.045)
    static let cardStroke = Color.white.opacity(0.07)
    static let control = Color.white.opacity(0.07)
    static let text = Color.white.opacity(0.94)
    static let text2 = Color.white.opacity(0.62)
    static let text3 = Color.white.opacity(0.38)
    static let accentGradient = LinearGradient(colors: [accent, accentDeep], startPoint: .top, endPoint: .bottom)

    /// SF Pro Rounded at a fixed size; digits keep a constant width so live numbers do not jitter.
    static func font(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .rounded).monospacedDigit()
    }

    // 4-point spacing scale
    static let s1: CGFloat = 4, s2: CGFloat = 8, s3: CGFloat = 12, s4: CGFloat = 16, s5: CGFloat = 20
    static let radius: CGFloat = 14
    static let width: CGFloat = 320
    static let maxBodyHeight: CGFloat = 380
}

enum Format {
    static func rpm(_ v: Double) -> String { v < 50 ? "Off" : Int(v.rounded()).formatted() }
    static func shortRPM(_ v: Double) -> String { v < 50 ? "off" : v >= 1000 ? String(format: "%.1fk", v / 1000) : "\(Int(v))" }
    static func celsius(_ v: Double) -> String { String(format: "%.0f°", v) }

    static func heat(_ c: Double) -> Color {
        switch c {
        case ..<55: return Theme.accent
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
        case .speed(let share): return share >= 0.995 ? "Max" : "\(Int((share * 100).rounded()))%"
        case .sensor(let id, let start, let full):
            let name = model.availableSensors.first { $0.id == id }?.name ?? id
            return "\(name.replacingOccurrences(of: "CPU ", with: "")) \(Int(start))–\(Int(full))°"
        }
    }
}

// MARK: controls

/// Capsule segmented control with a sliding highlight.
struct Segmented<Value: Hashable>: View {
    let options: [(Value, String)]
    let selection: Value?
    let onSelect: (Value) -> Void
    @Namespace private var highlight

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options, id: \.0) { value, title in
                let selected = value == selection
                Button { withAnimation(.snappy(duration: 0.25)) { onSelect(value) } } label: {
                    Text(title)
                        .font(Theme.font(12, .semibold))
                        .foregroundStyle(selected ? Color.black.opacity(0.85) : Theme.text2)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 7)
                        .background {
                            if selected { Capsule().fill(Theme.accentGradient).matchedGeometryEffect(id: "pill", in: highlight) }
                        }
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(3)
        .background(Capsule().fill(Theme.control))
    }
}

/// Gradient track slider; reports values in 0...1.
struct SpeedSlider: View {
    let value: Double
    let onChange: (Double) -> Void

    var body: some View {
        GeometryReader { geo in
            let knob: CGFloat = 18
            let x = (geo.size.width - knob) * value
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.control).frame(height: 6)
                Capsule().fill(Theme.accentGradient).frame(width: x + knob / 2, height: 6)
                Circle()
                    .fill(.white)
                    .frame(width: knob, height: knob)
                    .shadow(color: .black.opacity(0.35), radius: 3, y: 1)
                    .offset(x: x)
            }
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { g in
                let v = (g.location.x - knob / 2) / max(1, geo.size.width - knob)
                onChange((Double(max(0, min(1, v))) * 100).rounded() / 100)
            })
        }
        .frame(height: 22)
    }
}

struct Chip: View {
    let title: String
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(Theme.font(11, .semibold))
                .foregroundStyle(selected ? Theme.accent : Theme.text2)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 5)
                .background(Capsule().fill(selected ? Theme.accent.opacity(0.16) : Theme.control))
                .overlay(Capsule().strokeBorder(selected ? Theme.accent.opacity(0.4) : .clear, lineWidth: 1))
        }
        .buttonStyle(.plain)
    }
}

/// "– 50° +" pill.
struct TemperatureStepper: View {
    let label: String
    let value: Double
    let range: ClosedRange<Double>
    let onChange: (Double) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.s1) {
            Text(label.uppercased()).font(Theme.font(9, .bold)).tracking(0.8).foregroundStyle(Theme.text3)
            HStack(spacing: 0) {
                step("minus", -1)
                Text("\(Int(value))°").font(Theme.font(14, .semibold)).foregroundStyle(Theme.text).frame(maxWidth: .infinity)
                step("plus", 1)
            }
            .padding(3)
            .background(Capsule().fill(Theme.control))
        }
    }

    private func step(_ symbol: String, _ delta: Double) -> some View {
        Button { onChange(min(range.upperBound, max(range.lowerBound, value + delta))) } label: {
            Image(systemName: symbol)
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(Theme.text2)
                .frame(width: 24, height: 24)
                .background(Circle().fill(Theme.control))
        }
        .buttonStyle(.plain)
        .buttonRepeatBehavior(.enabled)
    }
}

/// Mode picker plus the controls for that mode, applied to one or more fans.
struct SettingControls: View {
    @Environment(FanModel.self) private var model
    let fans: [FanReading]

    var body: some View {
        let current = Setting.common(fans, model: model)
        VStack(alignment: .leading, spacing: Theme.s3) {
            Segmented(options: Setting.Kind.allCases.map { ($0, $0.rawValue) }, selection: current?.kind) { select($0) }

            switch current {
            case nil:
                note("Fans are set differently — pick a mode to link them.")
            case .auto?:
                note(fans.count > 1 ? "macOS is controlling both fans." : "macOS is controlling this fan.")
            case .speed(let share)?:
                speed(share)
            case .sensor(let id, let start, let full)?:
                sensor(id: id, start: start, full: full)
            }
        }
    }

    private func note(_ text: String) -> some View {
        Text(text).font(Theme.font(11, .medium)).foregroundStyle(Theme.text3)
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
        HStack(spacing: Theme.s3) {
            SpeedSlider(value: share) { apply(.speed($0)) }
            Text("\(Int((share * 100).rounded()))%")
                .font(Theme.font(13, .semibold))
                .foregroundStyle(Theme.text)
                .frame(width: 40, alignment: .trailing)
        }
        HStack(spacing: 6) {
            ForEach([("Low", 0.0), ("50%", 0.5), ("75%", 0.75), ("Max", 1.0)], id: \.0) { name, value in
                Chip(title: name, selected: abs(share - value) < 0.01) { apply(.speed(value)) }
            }
        }
    }

    @ViewBuilder private func sensor(id: String, start: Double, full: Double) -> some View {
        Menu {
            ForEach(model.availableSensors) { s in
                Button { apply(.sensor(id: s.id, start: start, full: full)) } label: {
                    Text("\(s.name)  \(model.celsius(s.id).map(Format.celsius) ?? "")")
                }
            }
        } label: {
            HStack(spacing: Theme.s2) {
                Image(systemName: "thermometer.medium").foregroundStyle(Theme.accent)
                Text(model.availableSensors.first { $0.id == id }?.name ?? id).foregroundStyle(Theme.text)
                Spacer()
                Text(model.celsius(id).map(Format.celsius) ?? "–").foregroundStyle(Theme.text2)
                Image(systemName: "chevron.up.chevron.down").font(.system(size: 9, weight: .bold)).foregroundStyle(Theme.text3)
            }
            .font(Theme.font(12, .semibold))
            .padding(.horizontal, Theme.s3).padding(.vertical, Theme.s2)
            .background(Capsule().fill(Theme.control))
            .contentShape(Capsule())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        HStack(spacing: Theme.s2) {
            TemperatureStepper(label: "Speed up from", value: start, range: 30...95) { apply(.sensor(id: id, start: $0, full: max(full, $0 + 5))) }
            TemperatureStepper(label: "Max speed at", value: full, range: 35...105) { apply(.sensor(id: id, start: start, full: max($0, start + 5))) }
        }
    }
}

// MARK: compact panel (window and menu bar)

struct CompactPanel: View {
    @Environment(FanModel.self) private var model
    /// The window shows traffic-light buttons over the header; the menu bar panel does not.
    var inWindow = false
    @State private var open: String?
    @State private var bodyHeight: CGFloat = 200

    var body: some View {
        VStack(spacing: 0) {
            Header(inWindow: inWindow)
            ScrollView {
                VStack(spacing: Theme.s2) {
                    if model.fans.count > 1 {
                        Card {
                            CardTitle(icon: "fan.fill", title: "Both Fans", detail: Setting.common(model.fans, model: model)?.summary(model) ?? "Mixed")
                            SettingControls(fans: model.fans)
                        }
                    }
                    Expander(id: "fans", open: $open, icon: "slider.horizontal.3", title: model.fans.count > 1 ? "Each Fan" : "Fan",
                             detail: model.fans.map { Setting(model.rule($0.id), fan: $0).summary(model) }.joined(separator: " · ")) {
                        ForEach(model.fans) { fan in
                            VStack(alignment: .leading, spacing: Theme.s3) {
                                HStack(alignment: .firstTextBaseline) {
                                    Text(fan.name).font(Theme.font(13, .semibold)).foregroundStyle(Theme.text)
                                    Spacer()
                                    Text(Format.rpm(fan.rpm)).font(Theme.font(13, .semibold)).foregroundStyle(Theme.text)
                                    if fan.rpm >= 50 { Text("rpm").font(Theme.font(10, .medium)).foregroundStyle(Theme.text3) }
                                }
                                SettingControls(fans: [fan])
                            }
                            if fan.id != model.fans.last?.id { Rectangle().fill(Theme.cardStroke).frame(height: 1) }
                        }
                    }
                    Expander(id: "temps", open: $open, icon: "thermometer.medium", title: "Temperatures",
                             detail: model.celsius("gpu").map { "GPU \(Format.celsius($0))" } ?? "") {
                        VStack(spacing: Theme.s3) {
                            ForEach(model.sensors) { s in TemperatureRow(sensor: s) }
                        }
                    }
                }
                .padding(Theme.s3)
                .onGeometryChange(for: CGFloat.self, of: \.size.height) { bodyHeight = $0 }
            }
            .scrollIndicators(.automatic)
            .frame(height: min(bodyHeight, Theme.maxBodyHeight))
            Footer()
        }
        .frame(width: Theme.width)
        .background(Theme.background)
        .environment(\.colorScheme, .dark)
    }
}

private struct Header: View {
    @Environment(FanModel.self) private var model
    let inWindow: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.s4) {
            HStack(spacing: Theme.s2) {
                if inWindow { Spacer().frame(width: 56) }   // room for the window buttons
                Text("Fan Control").font(Theme.font(13, .bold)).foregroundStyle(.white.opacity(0.9))
                Spacer()
                StatusPill(on: model.isOn)
            }
            HStack(alignment: .center, spacing: Theme.s3) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(alignment: .firstTextBaseline, spacing: 1) {
                        Text(model.celsius("cpu-hot").map { "\(Int($0.rounded()))" } ?? "–")
                            .font(.system(size: 52, weight: .bold, design: .rounded).monospacedDigit())
                            .tracking(-2)
                            .contentTransition(.numericText())
                            .animation(.snappy, value: Int(model.celsius("cpu-hot") ?? 0))
                        Text("°C").font(Theme.font(17, .semibold)).foregroundStyle(.white.opacity(0.7))
                    }
                    .foregroundStyle(.white)
                    Text("CPU hottest core").font(Theme.font(11, .medium)).foregroundStyle(.white.opacity(0.6))
                    Text(model.isOn ? (model.activePreset?.name ?? Setting.common(model.fans, model: model).map { "Both fans · \($0.summary(model))" } ?? "Custom") : "macOS decides")
                        .font(Theme.font(12, .semibold))
                        .foregroundStyle(model.isOn ? Theme.accent : .white.opacity(0.55))
                        .lineLimit(1)
                        .padding(.top, Theme.s1)
                }
                Spacer(minLength: 0)
                PowerButton()
            }
            HStack(spacing: Theme.s2) {
                ForEach(model.fans) { FanTile(fan: $0, controlled: model.rule($0.id) != .auto) }
            }
        }
        .padding(.horizontal, Theme.s4)
        .padding(.top, inWindow ? Theme.s3 : Theme.s4)
        .padding(.bottom, Theme.s4)
        .background {
            ZStack {
                LinearGradient(colors: [Theme.blueTop, Theme.blueBottom], startPoint: .topLeading, endPoint: .bottomTrailing)
                RadialGradient(colors: [.white.opacity(0.18), .clear], center: .topTrailing, startRadius: 0, endRadius: 220)
            }
        }
    }
}

private struct StatusPill: View {
    let on: Bool

    var body: some View {
        HStack(spacing: 5) {
            Circle().fill(on ? Theme.accent : .white.opacity(0.5)).frame(width: 6, height: 6)
            Text(on ? "ON" : "AUTO").font(Theme.font(10, .heavy)).tracking(0.8)
        }
        .foregroundStyle(on ? Theme.accent : .white.opacity(0.75))
        .padding(.horizontal, 9).padding(.vertical, 4)
        .background(Capsule().fill(.black.opacity(0.25)))
    }
}

private struct FanTile: View {
    let fan: FanReading
    let controlled: Bool

    var body: some View {
        HStack(spacing: Theme.s2) {
            Image(systemName: "fan.fill")
                .font(.system(size: 14))
                .foregroundStyle(fan.rpm < 50 ? .white.opacity(0.35) : controlled ? Theme.accent : .white.opacity(0.8))
                .symbolEffect(.rotate, options: .repeat(.continuous).speed(max(0.3, fan.load * 3)), isActive: fan.rpm >= 50)
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 3) {
                    Text(fan.name.replacingOccurrences(of: " Fan", with: "").uppercased())
                        .font(Theme.font(9, .bold)).tracking(0.8).foregroundStyle(.white.opacity(0.55))
                    Spacer(minLength: 0)
                    Text(Format.rpm(fan.rpm)).font(Theme.font(13, .semibold)).foregroundStyle(.white)
                        .contentTransition(.numericText())
                }
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(.white.opacity(0.15))
                        Capsule().fill(controlled ? Theme.accent : .white.opacity(0.7))
                            .frame(width: geo.size.width * max(0.02, fan.load))
                            .animation(.easeOut(duration: 0.6), value: fan.load)
                    }
                }
                .frame(height: 3)
            }
        }
        .padding(.horizontal, 10).padding(.vertical, Theme.s2)
        .background(RoundedRectangle(cornerRadius: 10).fill(.black.opacity(0.22)))
    }
}

private struct PowerButton: View {
    @Environment(FanModel.self) private var model
    @State private var pressed = false

    var body: some View {
        Button { model.togglePower() } label: {
            ZStack {
                Circle().fill(model.isOn ? Theme.accent.opacity(0.25) : .white.opacity(0.08)).padding(-6)
                Circle().fill(LinearGradient(colors: [.white, Color(white: 0.88)], startPoint: .top, endPoint: .bottom))
                Circle().strokeBorder(model.isOn ? Theme.accent : .white.opacity(0.3), lineWidth: 5)
                Image(systemName: "power")
                    .font(.system(size: 28, weight: .bold))
                    .foregroundStyle(model.isOn ? Theme.blueBottom : Color(white: 0.6))
            }
            .frame(width: 78, height: 78)
            .shadow(color: model.isOn ? Theme.accent.opacity(0.55) : .black.opacity(0.3), radius: model.isOn ? 14 : 6, y: 2)
            .scaleEffect(pressed ? 0.94 : 1)
            .animation(.spring(duration: 0.3), value: model.isOn)
            .animation(.spring(duration: 0.2), value: pressed)
        }
        .buttonStyle(.plain)
        .onLongPressGesture(minimumDuration: .infinity, pressing: { pressed = $0 }, perform: {})
        .help(model.helperInstalled ? (model.isOn ? "Hand the fans back to macOS" : "Use your fan settings") : "Install the helper first")
    }
}

private struct Card<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.s3) { content }
            .padding(Theme.s4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: Theme.radius).fill(Theme.card))
            .overlay(RoundedRectangle(cornerRadius: Theme.radius).strokeBorder(Theme.cardStroke, lineWidth: 1))
    }
}

private struct CardTitle: View {
    let icon: String
    let title: String
    let detail: String

    var body: some View {
        HStack(spacing: Theme.s2) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(Theme.accent)
                .frame(width: 24, height: 24)
                .background(RoundedRectangle(cornerRadius: 7).fill(Theme.accent.opacity(0.14)))
            Text(title).font(Theme.font(13, .semibold)).foregroundStyle(Theme.text)
            Spacer()
            Text(detail).font(Theme.font(11, .semibold)).foregroundStyle(Theme.text2).lineLimit(1)
        }
    }
}

/// Collapsible card; only one is open at a time so the panel stays short.
private struct Expander<Content: View>: View {
    let id: String
    @Binding var open: String?
    let icon: String
    let title: String
    let detail: String
    @ViewBuilder let content: Content

    var body: some View {
        let isOpen = open == id
        Card {
            Button { withAnimation(.snappy(duration: 0.28)) { open = isOpen ? nil : id } } label: {
                HStack(spacing: Theme.s2) {
                    Image(systemName: icon)
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(Theme.text2)
                        .frame(width: 24, height: 24)
                        .background(RoundedRectangle(cornerRadius: 7).fill(Theme.control))
                    Text(title).font(Theme.font(13, .semibold)).foregroundStyle(Theme.text)
                    Spacer()
                    if !isOpen { Text(detail).font(Theme.font(11, .medium)).foregroundStyle(Theme.text3).lineLimit(1) }
                    Image(systemName: "chevron.down")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(Theme.text2)
                        .rotationEffect(.degrees(isOpen ? 180 : 0))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if isOpen { content.transition(.opacity) }
        }
    }
}

private struct TemperatureRow: View {
    let sensor: SensorReading

    var body: some View {
        VStack(spacing: 5) {
            HStack {
                Text(sensor.name).font(Theme.font(12, .medium)).foregroundStyle(Theme.text2)
                Spacer()
                Text(String(format: "%.0f°", sensor.celsius)).font(Theme.font(12, .semibold)).foregroundStyle(Theme.text)
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Theme.control)
                    Capsule().fill(Format.heat(sensor.celsius).gradient)
                        .frame(width: geo.size.width * max(0.03, min(1, (sensor.celsius - 20) / 85)))
                }
            }
            .frame(height: 3)
        }
    }
}

private struct Footer: View {
    @Environment(FanModel.self) private var model
    @Environment(\.openSettings) private var openSettings
    @State private var savingPreset = false
    @State private var presetName = ""

    var body: some View {
        HStack(spacing: Theme.s2) {
            if !model.helperInstalled {
                Button { model.installHelper() } label: {
                    Label(model.installing ? "Installing…" : "Install Helper", systemImage: "lock.shield.fill")
                        .font(Theme.font(12, .semibold))
                        .foregroundStyle(.black.opacity(0.85))
                        .padding(.horizontal, Theme.s3).padding(.vertical, 6)
                        .background(Capsule().fill(Theme.accentGradient))
                }
                .buttonStyle(.plain)
                .disabled(model.installing)
                Text("to change speeds").font(Theme.font(11, .medium)).foregroundStyle(Theme.text3)
            } else if let message = model.message {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                Text(message).font(Theme.font(11, .medium)).foregroundStyle(Theme.text2).lineLimit(2)
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
                    HStack(spacing: 6) {
                        Image(systemName: "square.stack.3d.up.fill").foregroundStyle(Theme.accent)
                        Text(model.activePreset?.name ?? "Custom").foregroundStyle(Theme.text)
                        Image(systemName: "chevron.up.chevron.down").font(.system(size: 8, weight: .bold)).foregroundStyle(Theme.text3)
                    }
                    .font(Theme.font(12, .semibold))
                    .padding(.horizontal, Theme.s3).padding(.vertical, 6)
                    .background(Capsule().fill(Theme.control))
                    .contentShape(Capsule())
                }
                .menuStyle(.button)
                .buttonStyle(.plain)
                .menuIndicator(.hidden)
                .fixedSize()
            }
            Spacer()
            Menu {
                Button("Settings…") { openSettings(); NSApp.activate() }
                Divider()
                Button("Quit Fan Control") { NSApp.terminate(nil) }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(Theme.text2)
                    .frame(width: 28, height: 28)
                    .background(Circle().fill(Theme.control))
                    .contentShape(Circle())
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
        }
        .padding(.horizontal, Theme.s3).padding(.vertical, 10)
        .background(Color.black.opacity(0.28))
        .overlay(alignment: .top) { Rectangle().fill(Theme.cardStroke).frame(height: 1) }
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
            Section("Menu bar") {
                Picker("Temperature", selection: $model.menuBarSensor) {
                    Text("None").tag("")
                    ForEach(model.availableSensors) { Text($0.name).tag($0.id) }
                }
                Toggle("Show fan speed", isOn: $model.menuBarShowsRPM)
            }
            Section("Behaviour") {
                Toggle("Launch at login", isOn: Binding(get: { model.launchAtLogin }, set: { model.launchAtLogin = $0 }))
                Toggle("Keep fan settings when the app quits", isOn: $model.keepRulesOnQuit)
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
            Image(systemName: model.isOn ? "fan.fill" : "fan")
            if let temp { Text(Format.celsius(temp)) }
            if model.menuBarShowsRPM, let rpm { Text(Format.shortRPM(rpm)) }
        }
        .monospacedDigit()
    }
}
