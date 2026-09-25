// displaytint — software white-point tint + soft dimming for every display.
//
// Applies a per-channel gain to each display's gamma table so the desktop
// white point lands at a chosen color temperature, identically on every
// panel. A lightweight daemon re-applies after display reconfigurations and
// whenever the config file changes, because macOS wipes gamma tables on
// sleep/wake and display changes.

import AppKit

// MARK: - Config

struct Config: Codable {
    struct Override: Codable {
        var temperature: Double?
        var brightness: Double?
    }

    var enabled: Bool?
    var temperature: Double?
    var brightness: Double?
    var displays: [String: Override]?

    var on: Bool { enabled ?? true }
    var kelvin: Double { temperature ?? 5000 }
    var globalBrightness: Double { min(max(brightness ?? 1.0, 0.01), 1.0) }

    static var url: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/displaytint/config.json")
    }

    static func load() -> Config {
        guard let data = try? Data(contentsOf: url),
              let cfg = try? JSONDecoder().decode(Config.self, from: data) else { return Config() }
        return cfg
    }

    func save() {
        try? FileManager.default.createDirectory(at: Self.url.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? enc.encode(self) { try? data.write(to: Self.url, options: .atomic) }
    }

    // Key matches if it equals "builtin" on the built-in panel, or is a
    // case-insensitive substring of the display's localized name.
    func override(for name: String, builtin: Bool) -> Override? {
        guard let map = displays else { return nil }
        if builtin, let o = map["builtin"] { return o }
        return map.first { key, _ in
            key != "builtin" && name.lowercased().contains(key.lowercased())
        }?.value
    }
}

// MARK: - Displays

struct Display {
    let id: CGDirectDisplayID
    let name: String
    let builtin: Bool
    let width: Int
    let height: Int
}

func currentDisplays() -> [Display] {
    var ids = [CGDirectDisplayID](repeating: 0, count: 32)
    var count: UInt32 = 0
    guard CGGetActiveDisplayList(UInt32(ids.count), &ids, &count) == .success else { return [] }
    var names: [CGDirectDisplayID: String] = [:]
    for screen in NSScreen.screens {
        if let n = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber {
            names[n.uint32Value] = screen.localizedName
        }
    }
    return (0..<Int(count)).map { i in
        let id = ids[i]
        return Display(id: id,
                       name: names[id] ?? "Display 0x\(String(id, radix: 16))",
                       builtin: CGDisplayIsBuiltin(id) != 0,
                       width: CGDisplayPixelsWide(id),
                       height: CGDisplayPixelsHigh(id))
    }
}

// MARK: - Temperature → gains
// Tanner Helland's blackbody approximation, returned as sRGB-encoded
// channel gains in 0...1. 6500K ≈ (1, 1, 1) since that is the sRGB white.

func kelvinGains(_ kelvin: Double) -> (r: Double, g: Double, b: Double) {
    let t = min(max(kelvin, 1000), 12000) / 100.0
    var r: Double
    var g: Double
    var b: Double
    if t <= 66 {
        r = 255
        g = 99.4708025861 * log(t) - 161.1195681661
    } else {
        r = 329.698727446 * pow(t - 60, -0.1332047592)
        g = 288.1221695283 * pow(t - 60, -0.0755148492)
    }
    if t >= 66 {
        b = 255
    } else if t <= 19 {
        b = 0
    } else {
        b = 138.5177312231 * log(t - 10) - 305.0447927307
    }
    func cl(_ v: Double) -> Double { min(max(v, 0), 255) / 255 }
    return (cl(r), cl(g), cl(b))
}

// MARK: - Apply
// The gamma table scales each channel's encoded output: out = gain * v.
// Temperature gains go on in the encoded domain directly (they are sRGB
// colors); brightness is a linear-light factor, so it is encoded first.

// Encoded-channel maxima a display should be showing under cfg.
func expectedTop(_ d: Display, cfg: Config) -> (Float, Float, Float) {
    let ov = cfg.override(for: d.name, builtin: d.builtin)
    let kelvin = ov?.temperature ?? cfg.kelvin
    let bright = min(max(ov?.brightness ?? cfg.globalBrightness, 0.01), 1.0)
    let g = kelvinGains(kelvin)
    let dim = pow(bright, 1.0 / 2.2)
    return (Float(min(g.r * dim, 1)), Float(min(g.g * dim, 1)), Float(min(g.b * dim, 1)))
}

func apply(_ d: Display, cfg: Config) -> String {
    let ov = cfg.override(for: d.name, builtin: d.builtin)
    let kelvin = ov?.temperature ?? cfg.kelvin
    let bright = min(max(ov?.brightness ?? cfg.globalBrightness, 0.01), 1.0)
    let t = expectedTop(d, cfg: cfg)
    let err = CGSetDisplayTransferByFormula(d.id,
                                            0, t.0, 1,
                                            0, t.1, 1,
                                            0, t.2, 1)
    if err != .success {
        return "\(d.name): error \(err.rawValue)"
    }
    return String(format: "%@ → %.0fK × %.2f  (r %.3f  g %.3f  b %.3f)",
                  d.name, kelvin, bright, t.0, t.1, t.2)
}

func neutralize(_ d: Display) {
    CGSetDisplayTransferByFormula(d.id, 0, 1, 1, 0, 1, 1, 0, 1, 1)
}

func readback(_ id: CGDirectDisplayID) -> (Float, Float, Float)? {
    var rMin = Float(), rMax = Float(), rG = Float()
    var gMin = Float(), gMax = Float(), gG = Float()
    var bMin = Float(), bMax = Float(), bG = Float()
    guard CGGetDisplayTransferByFormula(id, &rMin, &rMax, &rG, &gMin, &gMax, &gG,
                                        &bMin, &bMax, &bG) == .success else { return nil }
    return (rMax, gMax, bMax)
}

// MARK: - Daemon

func log(_ s: String) {
    let df = DateFormatter()
    df.dateFormat = "yyyy-MM-dd HH:mm:ss"
    print("\(df.string(from: Date())) \(s)")
    fflush(stdout)
}

func mtime(_ path: String) -> Date? {
    (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date
}

final class DirtyFlag {
    private let lock = NSLock()
    private var value = false
    func set() { lock.lock(); value = true; lock.unlock() }
    func take() -> Bool { lock.lock(); defer { lock.unlock() }; let v = value; value = false; return v }
}

var dirty = DirtyFlag()
var lastMtime: Date?
var cachedCfg: Config?

let pidURL = Config.url.deletingLastPathComponent().appendingPathComponent("daemon.pid")

func daemonPid() -> pid_t? {
    guard let s = try? String(contentsOf: pidURL, encoding: .utf8),
          let p = pid_t(s.trimmingCharacters(in: .whitespacesAndNewlines)) else { return nil }
    return kill(p, 0) == 0 ? p : nil
}

// CG reconfiguration callbacks arrive on an internal thread; funnel them
// through this flag back to the run loop.
func daemonTick() {
    let m = mtime(Config.url.path)
    if m != lastMtime {
        lastMtime = m
        cachedCfg = Config.load()
        dirty.set()
    }
    guard let cfg = cachedCfg else { return }
    let forced = dirty.take()
    for d in currentDisplays() {
        if cfg.on {
            // Self-healing: macOS wipes gamma tables out from under us on
            // plug/unplug — sometimes after the last reconfiguration
            // callback — so verify each second and reapply on drift.
            let want = expectedTop(d, cfg: cfg)
            let drifted = readback(d.id).map {
                abs($0.0 - want.0) > 0.002 || abs($0.1 - want.1) > 0.002 || abs($0.2 - want.2) > 0.002
            } ?? true
            if forced || drifted {
                log(apply(d, cfg: cfg))
            }
        } else if forced {
            neutralize(d)
            log("\(d.name) → neutral")
        }
    }
}

func daemonMain() {
    try? String(ProcessInfo.processInfo.processIdentifier)
        .write(to: pidURL, atomically: true, encoding: .utf8)
    let timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in daemonTick() }
    RunLoop.main.add(timer, forMode: .default)
    let status = CGDisplayRegisterReconfigurationCallback({ _, _, _ in dirty.set() }, nil)
    log(status == .success
        ? "daemon started (pid \(ProcessInfo.processInfo.processIdentifier))"
        : "reconfiguration callback registration failed: \(status.rawValue)")
    daemonTick()
    RunLoop.main.run()
}

// MARK: - CLI

func usage() {
    print("""
    displaytint — match your displays' white point in software

    usage:
      displaytint list                        show displays + live gamma readback
      displaytint set <kelvin> [brightness]   set tint (saved to config)
      displaytint on | off                    enable / disable the saved tint
      displaytint status                      config + live gamma readback
      displaytint daemon                      run the reapply daemon (LaunchAgent)

    config: \(Config.url.path)  (the daemon picks up edits within ~3s)
    """)
}

let args = Array(CommandLine.arguments.dropFirst())
let rest = args.dropFirst()

switch args.first ?? "" {
case "list":
    for d in currentDisplays() {
        let f = readback(d.id).map { String(format: " — gamma max r %.3f g %.3f b %.3f", $0.0, $0.1, $0.2) } ?? ""
        print("\(d.id)  \(d.builtin ? "builtin" : "external")  \(d.width)x\(d.height)  \(d.name)\(f)")
    }
case "set":
    guard let k = Double(rest.first ?? ""), (1000...12000).contains(k) else {
        print("usage: displaytint set <kelvin 1000-12000> [brightness 0.01-1.0]")
        exit(2)
    }
    var cfg = Config.load()
    cfg.temperature = k
    cfg.enabled = true
    if let b = Double(rest.dropFirst().first ?? "") {
        cfg.brightness = min(max(b, 0.01), 1.0)
    }
    cfg.save()
    print("saved \(Int(k))K to \(Config.url.path)")
    if daemonPid() != nil {
        print("daemon is running — it will apply within ~1s")
    } else {
        for d in currentDisplays() { print(apply(d, cfg: cfg)) }
    }
case "on":
    var cfg = Config.load()
    cfg.enabled = true
    cfg.save()
    if daemonPid() != nil {
        print("daemon is running — it will apply within ~1s")
    } else {
        for d in currentDisplays() { print(apply(d, cfg: cfg)) }
    }
case "off":
    var cfg = Config.load()
    cfg.enabled = false
    cfg.save()
    if daemonPid() != nil {
        print("daemon is running — it will neutralize within ~1s")
    } else {
        for d in currentDisplays() {
            neutralize(d)
            print("\(d.name) → neutral")
        }
    }
case "status":
    let cfg = Config.load()
    print("config: \(Config.url.path)")
    print("enabled: \(cfg.on)  temperature: \(Int(cfg.kelvin))K  brightness: \(String(format: "%.2f", cfg.globalBrightness))")
    if let m = cfg.displays, !m.isEmpty {
        for (k, o) in m { print("override \(k): \(o)") }
    }
    for d in currentDisplays() {
        let f = readback(d.id).map { String(format: "r %.3f  g %.3f  b %.3f", $0.0, $0.1, $0.2) } ?? "?"
        print("\(d.name): gamma max \(f)")
    }
case "lut":
    for d in currentDisplays() {
        var red = [Float](repeating: 0, count: 256)
        var green = [Float](repeating: 0, count: 256)
        var blue = [Float](repeating: 0, count: 256)
        var n: UInt32 = 0
        let err = CGGetDisplayTransferByTable(d.id, 256, &red, &green, &blue, &n)
        if err != .success {
            print("\(d.name): table read error \(err.rawValue)")
            continue
        }
        let i = Int(n) - 1
        print("\(d.name): table[\(n)] top  r \(red[i])  g \(green[i])  b \(blue[i])   mid  r \(red[128])  g \(green[128])  b \(blue[128])")
    }
case "daemon":
    daemonMain()
default:
    usage()
    exit(args.isEmpty ? 0 : 2)
}
