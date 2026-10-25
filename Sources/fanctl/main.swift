import FanKit
import Foundation

// fanctl: status and manual control from the terminal, and the root helper's control loop.

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

func log(_ message: String) {
    let stamp = ISO8601DateFormatter().string(from: Date())
    FileHandle.standardError.write(Data("\(stamp) \(message)\n".utf8))
}

let usage = """
usage:
  fanctl status                         fans and temperatures
  fanctl set <left|right|all|N> <rpm>   hold a fan at a speed (root)
  fanctl auto [left|right|all|N]        give fans back to macOS (root)
  fanctl daemon                         apply the app's rules every second (root, run by launchd)
  fanctl install --user <name>          install the helper service (root)
  fanctl uninstall                      remove the helper service and restore automatic fans (root)
"""

func fanIndexes(_ arg: String, count: Int) -> [Int] {
    switch arg.lowercased() {
    case "all": return Array(0..<count)
    case "left": return count > 0 ? [0] : []
    case "right": return count > 1 ? [1] : []
    default:
        guard let n = Int(arg), (0..<count).contains(n) else { fail("unknown fan '\(arg)'; use left, right, all or 0..\(count - 1)") }
        return [n]
    }
}

func requireRoot() { if geteuid() != 0 { fail("this command needs root: run it with sudo") } }

func pad(_ s: String, _ width: Int) -> String { s.padding(toLength: max(width, s.count), withPad: " ", startingAt: 0) }

func status(_ smc: SMC) {
    for f in smc.fans() {
        print(pad(f.name, 10) + String(format: " %5.0f rpm  target %5.0f  range %4.0f–%4.0f  ", f.rpm, f.target, f.minimum, f.maximum) + (f.manual ? "manual" : "auto"))
    }
    for s in SensorReader(smc: smc).readings() {
        print(pad(s.name, 24) + String(format: " %5.1f °C", s.celsius))
    }
}

// MARK: helper control loop

final class Daemon {
    let smc: SMC
    let sensors: SensorReader
    var config = HelperConfig()
    var configStamp: Date?
    var overheated = false
    var onBattery = false
    /// Temperatures smoothed over time, per sensor id, so short spikes do not make the fans hunt.
    var smoothed: [String: Double] = [:]
    /// Fans a sensor rule has spun up; they are released 3° below the start temperature, not at it.
    var engaged: Set<Int> = []
    var lastTick = Date()
    let hotLimit = 100.0, coolAgain = 90.0   // above this the helper hands control back to macOS
    let release = 3.0                        // °C below the start temperature before a fan goes back to macOS
    let rampUp = 400.0, rampDown = 250.0     // rpm per second in sensor mode

    init(smc: SMC) { self.smc = smc; sensors = SensorReader(smc: smc) }

    func reloadIfChanged() {
        let stamp = (try? FileManager.default.attributesOfItem(atPath: Paths.config)[.modificationDate]) as? Date
        guard stamp != configStamp else { return }
        configStamp = stamp
        config = HelperConfig.load() ?? HelperConfig()
        let summary = config.rules.sorted { $0.key < $1.key }.map { "fan \($0.key): \($0.value)" }.joined(separator: ", ")
        log("rules: \(summary.isEmpty ? "all auto" : summary)\(config.autoOnBattery ? " (auto on battery)" : "")")
    }

    /// Rising temperatures are followed within ~3 s so heat gets a quick response; falling ones over ~10 s.
    func smooth(_ dt: Double) {
        var ids: Set<String> = []
        for rule in config.rules.values { if case .sensor(let id, _, _) = rule { ids.insert(id) } }
        for id in ids {
            guard let raw = sensors.celsius(id) else { continue }
            guard let previous = smoothed[id] else { smoothed[id] = raw; continue }
            let tau = raw > previous ? 3.0 : 10.0
            smoothed[id] = previous + (raw - previous) * (1 - exp(-dt / tau))
        }
    }

    func tick() {
        let now = Date()
        let dt = min(5, max(0.1, now.timeIntervalSince(lastTick)))
        lastTick = now
        reloadIfChanged()
        smooth(dt)

        let hottest = sensors.celsius("cpu-hot") ?? 0   // the safety check uses the raw reading
        if !overheated && hottest >= hotLimit { overheated = true; log(String(format: "CPU at %.0f °C: handing fans to macOS", hottest)) }
        if overheated && hottest < coolAgain { overheated = false; log("cooled down: rules resumed") }
        let battery = config.autoOnBattery && Power.onBattery
        if battery != onBattery { onBattery = battery; log(battery ? "on battery: fans handed to macOS" : "on power: rules resumed") }

        for fan in smc.fans() {
            let rule = overheated || onBattery ? .auto : config.rules[fan.id] ?? .auto
            var target: Double?
            var ramped = false
            switch rule {
            case .sensor(let id, let start, let full):
                if let t = smoothed[id], t >= (engaged.contains(fan.id) ? start - release : start) {
                    engaged.insert(fan.id)
                    target = curveRPM(celsius: t, start: start, full: full, fan: fan)
                    ramped = true
                } else {
                    engaged.remove(fan.id)
                }
            case .constant(let rpm):
                engaged.remove(fan.id)
                target = min(max(rpm, fan.minimum), fan.maximum)
            case .auto:
                engaged.remove(fan.id)
            }
            do {
                if var rpm = target {
                    if ramped {
                        // Start from where the fan is (macOS's speed when taking over), then move gradually.
                        let from = fan.manual ? fan.target : max(fan.rpm, fan.minimum)
                        let step = (rpm > from ? rampUp : rampDown) * dt
                        if abs(rpm - from) > step { rpm = from + (rpm > from ? step : -step) }
                    }
                    if !fan.manual || abs(fan.target - rpm) >= 20 { try smc.setFan(fan.id, rpm: rpm) }
                } else if fan.manual {
                    try smc.setAuto(fan.id)
                }
            } catch {
                log("fan \(fan.id): \(error)")
            }
        }
    }

    func run() -> Never {
        let restore: @convention(c) (Int32) -> Void = { _ in
            if let smc = try? SMC() { smc.setAllAuto() }
            exit(0)
        }
        signal(SIGTERM, restore)
        signal(SIGINT, restore)
        try? String(HelperInfo.version).write(toFile: Paths.helperVersion, atomically: true, encoding: .utf8)
        chmod(Paths.helperVersion, 0o644)
        log("helper \(HelperInfo.version) started")
        while true {
            tick()
            Thread.sleep(forTimeInterval: 1)
        }
    }
}

// MARK: install

@discardableResult
func run(_ path: String, _ args: [String]) -> Int32 {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: path)
    p.arguments = args
    p.standardOutput = FileHandle.nullDevice
    p.standardError = FileHandle.nullDevice
    try? p.run()
    p.waitUntilExit()
    return p.terminationStatus
}

func install(user: String) {
    requireRoot()
    guard let pw = getpwnam(user) else { fail("unknown user '\(user)'") }
    let uid = pw.pointee.pw_uid, gid = pw.pointee.pw_gid
    let fm = FileManager.default
    let me = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath().path

    run("/bin/launchctl", ["bootout", "system/\(Paths.label)"])
    do {
        try fm.createDirectory(atPath: "/Library/PrivilegedHelperTools", withIntermediateDirectories: true)
        if me != Paths.helper {
            if fm.fileExists(atPath: Paths.helper) { try fm.removeItem(atPath: Paths.helper) }
            try fm.copyItem(atPath: me, toPath: Paths.helper)
        }
        chown(Paths.helper, 0, 0); chmod(Paths.helper, 0o755)

        try fm.createDirectory(atPath: Paths.configDirectory, withIntermediateDirectories: true)
        chown(Paths.configDirectory, uid, gid); chmod(Paths.configDirectory, 0o755)
        if !fm.fileExists(atPath: Paths.config) { try HelperConfig().save() }
        chown(Paths.config, uid, gid); chmod(Paths.config, 0o644)

        let plist: [String: Any] = [
            "Label": Paths.label,
            "ProgramArguments": [Paths.helper, "daemon"],
            "RunAtLoad": true,
            "KeepAlive": true,
            "StandardErrorPath": Paths.log,
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try data.write(to: URL(fileURLWithPath: Paths.launchDaemon), options: .atomic)
        chown(Paths.launchDaemon, 0, 0); chmod(Paths.launchDaemon, 0o644)
    } catch {
        fail("install failed: \(error.localizedDescription)")
    }
    guard run("/bin/launchctl", ["bootstrap", "system", Paths.launchDaemon]) == 0 else { fail("the helper could not be started") }
    print("helper installed")
}

func uninstall() {
    requireRoot()
    run("/bin/launchctl", ["bootout", "system/\(Paths.label)"])
    for path in [Paths.launchDaemon, Paths.helper, Paths.configDirectory] { try? FileManager.default.removeItem(atPath: path) }
    (try? SMC())?.setAllAuto()
    print("helper removed; fans are automatic")
}

// MARK: main

var args = Array(CommandLine.arguments.dropFirst())
guard let command = args.first else { print(usage); exit(0) }
args.removeFirst()

let smc: SMC
do { smc = try SMC() } catch { fail("\(error)") }

switch command {
case "status":
    status(smc)
case "set":
    requireRoot()
    guard args.count == 2, let rpm = Double(args[1]) else { fail(usage) }
    for i in fanIndexes(args[0], count: smc.fanCount) {
        do { try smc.setFan(i, rpm: rpm) } catch { fail("\(error)") }
    }
    Thread.sleep(forTimeInterval: 0.3)
    status(smc)
case "auto":
    requireRoot()
    for i in fanIndexes(args.first ?? "all", count: smc.fanCount) {
        do { try smc.setAuto(i) } catch { fail("\(error)") }
    }
    status(smc)
case "daemon":
    requireRoot()
    Daemon(smc: smc).run()
case "install":
    guard args.count == 2, args[0] == "--user" else { fail(usage) }
    install(user: args[1])
case "uninstall":
    uninstall()
default:
    fail(usage)
}
