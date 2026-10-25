import AppKit
import FanKit
import SwiftUI

// MARK: design tokens

/// Flat charcoal surfaces, one accent that only means "on", hierarchy from type weight.
enum Theme {
    static let background = Color(red: 0.059, green: 0.067, blue: 0.078)   // #0F1114
    static let header = Color(red: 0.098, green: 0.110, blue: 0.129)       // #191C21
    static let raised = Color(red: 0.137, green: 0.153, blue: 0.180)       // #23272E
    static let selected = Color.white.opacity(0.13)
    static let line = Color.white.opacity(0.07)
    static let footer = Color(red: 0.039, green: 0.043, blue: 0.051)       // #0A0B0D
    static let accent = Color(red: 0.31, green: 0.93, blue: 0.69)          // the "on" green
    static let action = Color(red: 0.04, green: 0.52, blue: 1.0)           // call to action blue
    static let text = Color.white.opacity(0.95)
    static let text2 = Color.white.opacity(0.62)
    static let text3 = Color.white.opacity(0.40)

    /// Saira Semi Condensed: squared, technical letterforms; digits keep a constant width so live numbers do not jitter.
    static func font(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        let name = switch weight {
        case .bold, .heavy, .black: "SairaSemiCondensed-Bold"
        case .semibold: "SairaSemiCondensed-SemiBold"
        case .medium: "SairaSemiCondensed-Medium"
        default: "SairaSemiCondensed-Regular"
        }
        return .custom(name, fixedSize: size).monospacedDigit()
    }

    static let width: CGFloat = 300
    static let pad: CGFloat = 16
    static let maxBodyHeight: CGFloat = 360
}

enum Format {
    static func rpm(_ v: Double) -> String { v < 50 ? "Off" : Int(v.rounded()).formatted() }
    static func shortRPM(_ v: Double) -> String { v < 50 ? "off" : v >= 1000 ? String(format: "%.1fk", v / 1000) : "\(Int(v))" }
    static func celsius(_ v: Double) -> String { String(format: "%.0f°", v) }

    static func heat(_ c: Double) -> Color {
        switch c {
        case ..<55: return Theme.text3
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
        case .speed(let share): return share >= 0.995 ? "Max" : "Speed \(Int((share * 100).rounded()))%"
        case .sensor(let id, let start, let full):
            let name = model.availableSensors.first { $0.id == id }?.name ?? id
            return "\(name.replacingOccurrences(of: "CPU ", with: "")) \(Int(start))–\(Int(full))°"
        }
    }
}

// MARK: controls

/// Compact glass segmented control: a frosted track with a translucent, highlighted tile that slides.
struct Segmented<Value: Hashable>: View {
    let options: [(Value, String)]
    let selection: Value?
    let onSelect: (Value) -> Void
    @Namespace private var highlight

    var body: some View {
        HStack(spacing: 0) {
            ForEach(options, id: \.0) { value, title in
                let selected = value == selection
                Button { withAnimation(.snappy(duration: 0.22)) { onSelect(value) } } label: {
                    Text(title)
                        .font(Theme.font(11, selected ? .semibold : .medium))
                        .foregroundStyle(selected ? Theme.text : Theme.text3)
                        .padding(.horizontal, 11)
                        .padding(.vertical, 3)
                        .background {
                            if selected {
                                Capsule()
                                    .fill(.white.opacity(0.16))
                                    .overlay(Capsule().strokeBorder(
                                        LinearGradient(colors: [.white.opacity(0.45), .white.opacity(0.06)], startPoint: .top, endPoint: .bottom),
                                        lineWidth: 0.75))
                                    .shadow(color: .black.opacity(0.35), radius: 3, y: 1)
                                    .matchedGeometryEffect(id: "tile", in: highlight)
                            }
                        }
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(2)
        .glassTrack()
        .fixedSize()
    }
}

extension View {
    /// Round glass surface; `tint` colours the glass (used for the power button when on).
    @ViewBuilder func glassCircle(tint: Color? = nil) -> some View {
        if #available(macOS 26.0, *) {
            glassEffect(tint.map { Glass.regular.tint($0) } ?? .regular, in: .circle)
        } else {
            background(.ultraThinMaterial, in: Circle())
                .background(Circle().fill(tint ?? .clear))
                .overlay(Circle().strokeBorder(
                    LinearGradient(colors: [.white.opacity(0.35), .white.opacity(0.04)], startPoint: .top, endPoint: .bottom), lineWidth: 0.75))
        }
    }

    /// Liquid Glass on macOS 26+, frosted material with a hairline highlight before that.
    @ViewBuilder func glassTrack() -> some View {
        if #available(macOS 26.0, *) {
            glassEffect(.regular, in: .capsule)
        } else {
            background(.ultraThinMaterial, in: Capsule())
                .overlay(Capsule().strokeBorder(
                    LinearGradient(colors: [.white.opacity(0.18), .white.opacity(0.03)], startPoint: .top, endPoint: .bottom), lineWidth: 0.75))
        }
    }
}

/// Thin track slider; reports values in 0...1.
struct SpeedSlider: View {
    let value: Double
    let onChange: (Double) -> Void

    var body: some View {
        GeometryReader { geo in
            let knob: CGFloat = 16
            let x = (geo.size.width - knob) * CGFloat(value)
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.raised).frame(height: 4)
                Capsule().fill(Theme.accent).frame(width: x + knob / 2, height: 4)
                Circle().fill(.white).frame(width: knob, height: knob)
                    .shadow(color: .black.opacity(0.4), radius: 2, y: 1)
                    .offset(x: x)
            }
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { g in
                let v = (g.location.x - knob / 2) / max(1, geo.size.width - knob)
                onChange((Double(max(0, min(1, v))) * 100).rounded() / 100)
            })
        }
        .frame(height: 20)
    }
}

struct Chip: View {
    let title: String
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(Theme.font(11, selected ? .semibold : .medium))
                .foregroundStyle(selected ? Theme.text : Theme.text3)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 5)
                .background(RoundedRectangle(cornerRadius: 6).fill(selected ? Theme.selected : Theme.raised))
        }
        .buttonStyle(.plain)
    }
}

/// Two-handle temperature range: fans start speeding up at the left handle and reach full speed at the
/// right one. A tick shows where the sensor is now.
struct TemperatureRange: View {
    let start: Double
    let full: Double
    let now: Double?
    let onChange: (Double, Double) -> Void

    static let bounds = 30.0...105.0
    private let knob: CGFloat = 16

    var body: some View {
        VStack(spacing: 6) {
            GeometryReader { geo in
                let width = geo.size.width - knob
                let x = { (t: Double) in width * CGFloat((t - Self.bounds.lowerBound) / (Self.bounds.upperBound - Self.bounds.lowerBound)) }
                ZStack(alignment: .leading) {
                    Capsule().fill(Theme.raised).frame(height: 4).padding(.horizontal, knob / 2)
                    Capsule().fill(Theme.accent).frame(width: max(0, x(full) - x(start)), height: 4).offset(x: x(start) + knob / 2)
                    if let now {
                        Capsule().fill(.white).frame(width: 2, height: 12)
                            .offset(x: x(min(max(now, Self.bounds.lowerBound), Self.bounds.upperBound)) + knob / 2 - 1)
                            .animation(.easeOut(duration: 0.6), value: now)
                    }
                    handle.offset(x: x(start))
                        .gesture(drag(width) { onChange(min($0, full - 5), full) })
                    handle.offset(x: x(full))
                        .gesture(drag(width) { onChange(start, max($0, start + 5)) })
                }
                .frame(maxHeight: .infinity)
                .coordinateSpace(name: "range")
            }
            .frame(height: 20)
            HStack {
                Text("from \(Int(start))°").foregroundStyle(Theme.text2)
                Spacer()
                if let now { Text("now \(Int(now.rounded()))°").foregroundStyle(Theme.text3) }
                Spacer()
                Text("max at \(Int(full))°").foregroundStyle(Theme.text2)
            }
            .font(Theme.font(11, .medium))
        }
    }

    private var handle: some View {
        Circle().fill(.white).frame(width: knob, height: knob).shadow(color: .black.opacity(0.4), radius: 2, y: 1)
    }

    private func drag(_ width: CGFloat, _ set: @escaping (Double) -> Void) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .named("range")).onChanged { g in
            let share = Double(max(0, min(1, (g.location.x - knob / 2) / max(1, width))))
            set((Self.bounds.lowerBound + share * (Self.bounds.upperBound - Self.bounds.lowerBound)).rounded())
        }
    }
}

/// Small pill that switches a fan between Auto, Speed and Sensor.
struct ModeMenu: View {
    let selection: Setting.Kind?
    let onSelect: (Setting.Kind) -> Void

    var body: some View {
        Menu {
            ForEach(Setting.Kind.allCases) { kind in
                Button { onSelect(kind) } label: {
                    if kind == selection { Label(kind.rawValue, systemImage: "checkmark") } else { Text(kind.rawValue) }
                }
            }
        } label: {
            HStack(spacing: 5) {
                Text(selection?.rawValue ?? "Mixed")
                Image(systemName: "chevron.down").font(.system(size: 8, weight: .bold)).foregroundStyle(Theme.text3)
            }
            .font(Theme.font(11, .semibold))
            .foregroundStyle(selection == nil || selection == .auto ? Theme.text2 : Theme.text)
            .padding(.horizontal, 9).padding(.vertical, 3)
            .glassTrack()
            .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
    }
}

/// Mode controls applied to one or more fans. `compact` leaves out the mode switch (the caller shows a
/// ModeMenu) and the speed presets, so per-fan rows stay one control tall.
struct SettingControls: View {
    @Environment(FanModel.self) private var model
    let fans: [FanReading]
    var compact = false
    /// Shown on the same line as the mode switch.
    var title: String?

    var body: some View {
        let current = Setting.common(fans, model: model)
        VStack(alignment: .leading, spacing: 12) {
            if !compact {
                HStack {
                    if let title { Text(title.uppercased()).font(Theme.font(11, .semibold)).tracking(1.4).foregroundStyle(Theme.text3) }
                    Spacer(minLength: 8)
                    Segmented(options: Setting.Kind.allCases.map { ($0, $0.rawValue) }, selection: current?.kind) { select($0) }
                }
            }
            switch current {
            case nil:
                if !compact { note("Fans are set differently. Pick a mode to link them.") }
            case .auto?:
                if !compact { note(fans.count > 1 ? "macOS is controlling both fans." : "macOS is controlling this fan.") }
            case .speed(let share)?:
                speed(share)
            case .sensor(let id, let start, let full)?:
                sensor(id: id, start: start, full: full)
            }
        }
    }

    private func note(_ text: String) -> some View {
        Text(text).font(Theme.font(12)).foregroundStyle(Theme.text3)
    }

    private func apply(_ setting: Setting) { Self.apply(setting, to: fans, model: model) }
    private func select(_ kind: Setting.Kind) { Self.select(kind, fans: fans, model: model) }

    @MainActor static func apply(_ setting: Setting, to fans: [FanReading], model: FanModel) {
        model.setRules(Dictionary(uniqueKeysWithValues: fans.map { ($0.id, setting.rule(for: $0)) }))
    }

    /// Switching mode starts from sensible values: the current speed, or a 50–85° curve on the hottest core.
    @MainActor static func select(_ kind: Setting.Kind, fans: [FanReading], model: FanModel) {
        switch kind {
        case .auto: apply(.auto, to: fans, model: model)
        case .speed: apply(.speed(max(0.3, fans.map(\.load).max() ?? 0.5)), to: fans, model: model)
        case .sensor: apply(.sensor(id: "cpu-hot", start: 50, full: 85), to: fans, model: model)
        }
    }

    @ViewBuilder private func speed(_ share: Double) -> some View {
        HStack(spacing: 12) {
            SpeedSlider(value: share) { apply(.speed($0)) }
            Text("\(Int((share * 100).rounded()))%")
                .font(Theme.font(13, .semibold))
                .foregroundStyle(Theme.text)
                .frame(width: 38, alignment: .trailing)
        }
        if !compact {
            HStack(spacing: 6) {
                ForEach([("Low", 0.0), ("50%", 0.5), ("75%", 0.75), ("Max", 1.0)], id: \.0) { name, value in
                    Chip(title: name, selected: abs(share - value) < 0.01) { apply(.speed(value)) }
                }
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
            HStack(spacing: 5) {
                Text("Follows").foregroundStyle(Theme.text3)
                Text(model.availableSensors.first { $0.id == id }?.name ?? id).foregroundStyle(Theme.text)
                Image(systemName: "chevron.down").font(.system(size: 8, weight: .bold)).foregroundStyle(Theme.text3)
            }
            .font(Theme.font(12, .medium))
            .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        TemperatureRange(start: start, full: full, now: model.celsius(id)) { apply(.sensor(id: id, start: $0, full: $1)) }
    }
}

// MARK: panel (window and menu bar)

struct CompactPanel: View {
    @Environment(FanModel.self) private var model
    /// The window draws its own close and minimise dots; the menu bar panel has none.
    var inWindow = false
    /// Debug snapshots render without the scroll view, which image renderers cannot draw.
    var scrolls = true
    @State var open: String?
    @State private var bodyHeight: CGFloat = 200

    var body: some View {
        VStack(spacing: 0) {
            Header(inWindow: inWindow)
            Group {
                if scrolls {
                    ScrollView {
                        sections.onGeometryChange(for: CGFloat.self, of: \.size.height) { bodyHeight = $0 }
                    }
                    .scrollIndicators(.never)
                    .frame(height: min(bodyHeight, Theme.maxBodyHeight))
                } else {
                    sections
                }
            }
            .background(Theme.background)
            .clipShape(SlantedTab())
            .background(Theme.header)   // shows through the slanted corner
            Footer()
        }
        .frame(width: Theme.width)
        .fixedSize(horizontal: false, vertical: true)   // the window is exactly as tall as the content
        .background(Theme.background)
        .environment(\.colorScheme, .dark)
    }

    private var sections: some View {
        VStack(alignment: .leading, spacing: 0) {
            if model.fans.count > 1 {
                SettingControls(fans: model.fans, title: "Both fans")
                    .padding(.horizontal, Theme.pad).padding(.top, 22).padding(.bottom, Theme.pad)
                Rectangle().fill(Theme.line).frame(height: 1)
            }
            Row(id: "fans", open: $open, title: model.fans.count > 1 ? "Each fan" : "Fan",
                detail: model.fans.count > 1 && Setting.common(model.fans, model: model) != nil ? "Same for both"
                    : model.fans.map { Setting(model.rule($0.id), fan: $0).summary(model) }.joined(separator: " · ")) {
                ForEach(model.fans) { fan in
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(alignment: .center, spacing: 4) {
                            Text(fan.name.replacingOccurrences(of: " Fan", with: "")).font(Theme.font(14, .semibold)).foregroundStyle(Theme.text)
                            Text("fan").font(Theme.font(14)).foregroundStyle(Theme.text2)
                            Text(Format.rpm(fan.rpm) + (fan.rpm >= 50 ? " rpm" : ""))
                                .font(Theme.font(12)).foregroundStyle(Theme.text3).padding(.leading, 6)
                            Spacer()
                            ModeMenu(selection: Setting(model.rule(fan.id), fan: fan).kind) { SettingControls.select($0, fans: [fan], model: model) }
                        }
                        SettingControls(fans: [fan], compact: true)
                    }
                    .padding(.bottom, fan.id == model.fans.last?.id ? 0 : 6)
                }
            }
            Rectangle().fill(Theme.line).frame(height: 1)
            Row(id: "temps", open: $open, title: "Temperatures",
                detail: model.celsius("gpu").map { "GPU \(Format.celsius($0))" } ?? "") {
                VStack(spacing: 9) {
                    ForEach(model.sensors) { s in
                        HStack {
                            Text(s.name).font(Theme.font(12)).foregroundStyle(Theme.text2)
                            Spacer()
                            Text(String(format: "%.0f°", s.celsius)).font(Theme.font(12, .medium))
                                .foregroundStyle(s.celsius >= 75 ? Format.heat(s.celsius) : Theme.text)
                        }
                    }
                }
            }
        }
    }
}

/// The lower panel's top edge steps down on the left at an angle, like Windscribe's Locations tab.
struct SlantedTab: Shape {
    var step: CGFloat = 14, run: CGFloat = 26, inset: CGFloat = 92

    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: rect.minX, y: rect.minY + step))
        p.addLine(to: CGPoint(x: rect.minX + inset, y: rect.minY + step))
        p.addLine(to: CGPoint(x: rect.minX + inset + run, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        p.closeSubpath()
        return p
    }
}

private struct Header: View {
    @Environment(FanModel.self) private var model
    let inWindow: Bool

    var body: some View {
        let setting = Setting.common(model.fans, model: model)
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                MainMenu()
                Text("fancontrol").font(Theme.font(21, .bold)).tracking(-0.4).foregroundStyle(Theme.text)
                Spacer()
                if inWindow { WindowDots() }
            }
            .frame(height: 28)
            HStack(alignment: .top, spacing: 8) {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 8) {
                        Text(model.isOn ? "ON" : "OFF")
                            .font(Theme.font(11, .bold)).tracking(1)
                            .foregroundStyle(model.isOn ? Theme.accent : Theme.text)
                            .padding(.horizontal, 9).padding(.vertical, 3)
                            .background(Capsule().fill(model.isOn ? Theme.accent.opacity(0.14) : Theme.raised))
                        Text(model.isOn && model.onBattery && model.autoOnBattery ? "On battery · macOS decides"
                             : model.isOn ? (model.activePreset?.name ?? setting?.summary(model) ?? "Custom") : "macOS decides")
                            .font(Theme.font(16, .medium))
                            .foregroundStyle(model.isOn ? Theme.accent : Theme.text2)
                            .lineLimit(1)
                    }
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(model.celsius("cpu-hot").map(Format.celsius) ?? "–")
                            .font(Theme.font(30, .bold))
                            .contentTransition(.numericText())
                            .animation(.snappy, value: Int(model.celsius("cpu-hot") ?? 0))
                        Text("CPU").font(Theme.font(30))
                    }
                    .foregroundStyle(Theme.text)
                }
                .padding(.top, 14)
                Spacer(minLength: 0)
                PowerButton().padding(.top, 2)
            }
            HStack(spacing: 6) {
                Image(systemName: "fan")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.text2)
                    .symbolEffect(.rotate, options: .repeat(.continuous).speed(1.2), isActive: model.fans.contains { $0.rpm >= 50 })
                Text(model.fans.map { "\($0.name.replacingOccurrences(of: " Fan", with: "")) \(Format.rpm($0.rpm))" }.joined(separator: "  ·  "))
                    .font(Theme.font(13)).foregroundStyle(Theme.text2)
                Spacer()
                Text(model.celsius("gpu").map { "GPU \(Format.celsius($0))" } ?? "")
                    .font(Theme.font(13)).foregroundStyle(Theme.text2)
            }
            .padding(.top, 14)
            .padding(.bottom, 18)
        }
        .padding(.horizontal, Theme.pad)
        .padding(.top, 12)
        .background { if inWindow { WindowDragArea() } }
        .background(Theme.header)
    }
}

/// Hamburger menu: presets, settings, quit.
private struct MainMenu: View {
    @Environment(FanModel.self) private var model
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        Menu {
            ForEach(model.presets) { preset in
                Button { model.apply(preset) } label: {
                    if preset.id == model.activePresetID { Label(preset.name, systemImage: "checkmark") } else { Text(preset.name) }
                }
            }
            Divider()
            Button("Open Window") { PanelWindow.shared.show() }
            Button("Settings…") { openSettings(); NSApp.activate() }
            Button("Quit Fan Control") { NSApp.terminate(nil) }
        } label: {
            Image(systemName: "line.3.horizontal")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(Theme.text2)
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
    }
}

/// Minimise and close, drawn top-right like Windscribe (the window is borderless, so it has no system buttons).
private struct WindowDots: View {
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 8) {
            dot(Color(red: 1.0, green: 0.74, blue: 0.18), glyph: "minus") { PanelWindow.shared.minimize() }
            dot(Color(red: 1.0, green: 0.37, blue: 0.34), glyph: "xmark") { PanelWindow.shared.close() }
        }
        .onHover { hovering = $0 }   // like macOS: hovering the group reveals both glyphs
    }

    private func dot(_ color: Color, glyph: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Circle().fill(color)
                .frame(width: 12, height: 12)
                .overlay {
                    if hovering {
                        Image(systemName: glyph)
                            .font(.system(size: 7, weight: .heavy))
                            .foregroundStyle(.black.opacity(0.55))
                    }
                }
        }
        .buttonStyle(.plain)
    }
}

/// Solid white button. Turning on spins a green arc around it while the helper takes over, then the
/// green ring closes; turning off unwinds the ring.
private struct PowerButton: View {
    @Environment(FanModel.self) private var model
    @State private var pressed = false
    @State private var fill: CGFloat = 0
    @State private var connecting = false
    @State private var spin = 0.0

    private let size: CGFloat = 58, ring: CGFloat = 2

    var body: some View {
        Button(action: toggle) {
            ZStack {
                Color.clear.glassCircle()
                Circle().inset(by: -ring / 2 - 3)
                    .trim(from: 0, to: fill)
                    .stroke(Theme.accent.opacity(0.75), style: StrokeStyle(lineWidth: ring, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                if connecting {
                    Circle().inset(by: -ring / 2 - 3)
                        .trim(from: 0, to: 0.28)
                        .stroke(AngularGradient(colors: [Theme.accent.opacity(0), Theme.accent], center: .center,
                                                startAngle: .degrees(0), endAngle: .degrees(100)),
                                style: StrokeStyle(lineWidth: ring, lineCap: .round))
                        .rotationEffect(.degrees(spin))
                }
                Image(systemName: "power")
                    .font(.system(size: 21, weight: .bold))
                    .foregroundStyle(model.isOn && !connecting ? Theme.accent.opacity(0.9) : Theme.text2)
                    .animation(.easeInOut(duration: 0.4), value: model.isOn)
            }
            .frame(width: size, height: size)
            .padding(7)
            .shadow(color: .black.opacity(0.3), radius: 5, y: 2)
            .scaleEffect(pressed ? 0.94 : 1)
            .animation(.spring(duration: 0.2), value: pressed)
        }
        .buttonStyle(.plain)
        .onLongPressGesture(minimumDuration: .infinity, pressing: { pressed = $0 }, perform: {})
        .help(model.helperInstalled ? (model.isOn ? "Hand the fans back to macOS" : "Use your fan settings") : "Install the helper first")
        .onAppear { fill = model.isOn ? 1 : 0 }
        .onChange(of: model.isOn) { _, on in
            guard !connecting else { return }   // presets and fan controls switch it too: follow without the spin
            withAnimation(.easeInOut(duration: 0.45)) { fill = on ? 1 : 0 }
        }
    }

    private func toggle() {
        guard model.helperInstalled else { model.installHelper(); return }
        if model.isOn {
            model.togglePower()
            withAnimation(.easeInOut(duration: 0.4)) { fill = 0 }
            return
        }
        connecting = true
        fill = 0
        spin = 0
        withAnimation(.linear(duration: 1.0)) { spin = 720 }
        model.togglePower()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            connecting = false
            withAnimation(.easeOut(duration: 0.5)) { fill = 1 }
        }
    }
}

/// A row with a round chevron that expands its content; one open at a time.
private struct Row<Content: View>: View {
    let id: String
    @Binding var open: String?
    let title: String
    let detail: String
    @ViewBuilder let content: Content

    var body: some View {
        let isOpen = open == id
        VStack(alignment: .leading, spacing: 14) {
            Button { withAnimation(.snappy(duration: 0.25)) { open = isOpen ? nil : id } } label: {
                HStack(spacing: 10) {
                    Text(title).font(Theme.font(17)).foregroundStyle(Theme.text)
                    Spacer()
                    if !isOpen { Text(detail).font(Theme.font(12)).foregroundStyle(Theme.text3).lineLimit(1) }
                    Image(systemName: "chevron.down")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(Theme.text)
                        .rotationEffect(.degrees(isOpen ? 180 : 0))
                        .frame(width: 22, height: 22)
                        .glassCircle()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if isOpen { content.transition(.opacity) }
        }
        .padding(.horizontal, Theme.pad).padding(.vertical, 12)
    }
}

private struct Footer: View {
    @Environment(FanModel.self) private var model
    @State private var savingPreset = false
    @State private var presetName = ""

    var body: some View {
        HStack(spacing: 8) {
            if !model.helperInstalled {
                Text("Helper not installed").font(Theme.font(12)).foregroundStyle(Theme.text2)
                Spacer()
                Button { model.installHelper() } label: {
                    Text(model.installing ? "Installing…" : "Install helper")
                        .font(Theme.font(12, .semibold)).foregroundStyle(.white)
                        .padding(.horizontal, 12).padding(.vertical, 5)
                        .background(Capsule().fill(Theme.action))
                }
                .buttonStyle(.plain)
                .disabled(model.installing)
            } else if model.helperOutdated {
                Text("Helper update available").font(Theme.font(12)).foregroundStyle(Theme.text2)
                Spacer()
                Button { model.installHelper() } label: {
                    Text(model.installing ? "Updating…" : "Update helper")
                        .font(Theme.font(12, .semibold)).foregroundStyle(.white)
                        .padding(.horizontal, 12).padding(.vertical, 5)
                        .background(Capsule().fill(Theme.action))
                }
                .buttonStyle(.plain)
                .disabled(model.installing)
            } else if let message = model.message {
                Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 11)).foregroundStyle(.orange)
                Text(message).font(Theme.font(11)).foregroundStyle(Theme.text2).lineLimit(2)
                Spacer()
            } else {
                Circle().fill(model.helperRunning ? Theme.accent : Theme.text3).frame(width: 6, height: 6)
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
                    HStack(spacing: 5) {
                        Text(model.activePreset?.name ?? "Custom").foregroundStyle(Theme.text)
                        Image(systemName: "chevron.up.chevron.down").font(.system(size: 8, weight: .bold)).foregroundStyle(Theme.text3)
                    }
                    .font(Theme.font(12, .medium))
                    .contentShape(Rectangle())
                }
                .menuStyle(.button)
                .buttonStyle(.plain)
                .menuIndicator(.hidden)
                .fixedSize()
                Spacer()
                Text(model.fans.allSatisfy { $0.rpm < 50 } ? "Fans idle" : model.fans.map { Format.shortRPM($0.rpm) }.joined(separator: " / ") + " rpm")
                    .font(Theme.font(12)).foregroundStyle(Theme.text3)
            }
        }
        .padding(.horizontal, Theme.pad).frame(height: 38)
        .background(Theme.footer)
        .overlay(alignment: .top) { Rectangle().fill(Theme.line).frame(height: 1) }
        .alert("Save Preset", isPresented: $savingPreset) {
            TextField("Name", text: $presetName)
            Button("Save") { model.saveCurrentAsPreset(named: presetName); presetName = "" }
            Button("Cancel", role: .cancel) { presetName = "" }
        }
    }
}

// MARK: minimised tile

/// What the Dock shows for the minimised panel: a square tile in the panel's style with live readings.
struct MinimizedTile: View {
    @Environment(FanModel.self) private var model

    var body: some View {
        GeometryReader { geo in
            let s = geo.size.width / 128   // drawn for 128 pt, scaled to the Dock's tile size
            VStack(spacing: 6 * s) {
                Image(nsImage: StatusIcon.image)
                    .renderingMode(.template)
                    .resizable()
                    .frame(width: 30 * s, height: 30 * s)
                    .foregroundStyle(model.isOn ? Theme.accent : Theme.text2)
                Text(model.celsius("cpu-hot").map(Format.celsius) ?? "–")
                    .font(Theme.font(34 * s, .bold))
                    .foregroundStyle(Theme.text)
                Text(model.fans.allSatisfy { $0.rpm < 50 } ? "fans idle" : model.fans.map { Format.shortRPM($0.rpm) }.joined(separator: " / "))
                    .font(Theme.font(13 * s, .medium))
                    .foregroundStyle(Theme.text2)
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .background(RoundedRectangle(cornerRadius: 26 * s, style: .continuous).fill(Theme.header))
            .overlay(RoundedRectangle(cornerRadius: 26 * s, style: .continuous).strokeBorder(.white.opacity(0.12), lineWidth: 1.5 * s))
            .padding(6 * s)
        }
    }
}

// MARK: window dragging

/// Empty header space moves the window (the borderless panel has no title bar to grab).
struct WindowDragArea: NSViewRepresentable {
    final class DragView: NSView {
        override func mouseDown(with event: NSEvent) { window?.performDrag(with: event) }
        override var mouseDownCanMoveWindow: Bool { true }
    }

    func makeNSView(context: Context) -> NSView { DragView() }
    func updateNSView(_ nsView: NSView, context: Context) {}
}

// MARK: settings

struct SettingsView: View {
    @Environment(FanModel.self) private var model

    var body: some View {
        @Bindable var model = model
        Form {
            Section("Behaviour") {
                Toggle("Launch at login", isOn: Binding(get: { model.launchAtLogin }, set: { model.launchAtLogin = $0 }))
                Toggle("Use Auto on battery", isOn: $model.autoOnBattery)
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
