import AppKit
import CoreGraphics
import Foundation

// Pets for Mac v2.3: a click-through overlay that hosts the
// pet factory's cast on the MacBook screen. Third screen of
// the pets platform, after Pane and Flint. Same contract as
// the Flint renderer: the coordinator (nimolo-mcp)
// writes directive files into ~/.config/nimolo (pet-<name>:
// event=, seq=, scale=) and this app only reads them; every
// second it writes back pet-status (one line per pet:
// "name=present state=.. x=.. y=.. held=.. falling=.." or
// "name=absent") so the coordinator tracks pets in realtime,
// not just per move.
//
// v2 makes the Mac screen exploit its own hardware, the way
// Pane exploits touch:
//  - the window is full-screen and ignores mouse events
//    outright (the v1 posture); the mouse is watched through
//    global event monitors, which observe clicks meant for
//    other apps without ever activating this app or taking
//    key-window focus. (v2.0's first cut made the window
//    mouse-active with per-pet hit-testing; that stole
//    keyboard focus from other apps and was reverted the
//    same day it shipped. Never make this window key.)
//  - click a pet for Pane's tap reactions (wake, greet,
//    turn-and-walk, switch activity, same cycle);
//  - drag a pet anywhere on screen; on release gravity
//    drops it back to the Dock, with a bounce on a hard
//    landing and a squash either way, then ambient resumes;
//  - animation is physical: a stride-synced bob while
//    walking (Pane's 180ms frame cadence), breathing at
//    idle / sit / sleep, and floating Z's over a sleeper.
// v2.2 deepens the physics (Nic's ask): the whole body is on
// springs. Walking leans into the stride and rocks at the
// stride phase, with one smooth bob per stride instead of a
// doubled-frequency bounce. While held, the body follows
// the pointer on a spring (lag and overshoot) and tilts on
// a pendulum spring driven by its velocity, legs swinging
// in the travel direction at speed. Release keeps the
// spring's velocity, so a flick throws him; a high drop is
// a panic fall (arm-up pose, sway, speed stretch) until the
// landing squash and bounce settle the swing.
// v2.7 sizes pets by kind: Carbon renders at half the
// humans' height everywhere his geometry is computed
// (PET_REL_SCALE), with his stride length scaled to match,
// so his legs keep the same cadence per body length.
// v2.3 adds the social layer: pets on this screen notice
// each other. A greet event with company present becomes a
// walk-over and a short conversation (the greeter's "?"
// answered by a word: "hey" from the humans, "mrrp" from
// the cat), and two pets who bump into each other while
// wandering stop and talk the same way, with a per-pair
// cooldown so it stays an event.
// Ambient behaviour is the shared state machine (walk,
// idle, peace, sit, sleep, same probabilities everywhere)
// plus the shared roaming events: arrive/depart at the
// edges, portal in/out at centre, and the greet.

let PET_NAMES = ["lucas", "mike", "carbon"]

// Pets Next: the roster is whatever the bundle carries.
// The coordinator's registry is the cast list; the app
// renders any pet whose frames were bundled at build time,
// so adding a cast member is a frames drop, not a code edit.
func rosterNames() -> [String] {
    guard let base = Bundle.main.resourceURL?
        .appendingPathComponent("frames"),
        let dirs = try? FileManager.default
            .contentsOfDirectory(atPath: base.path) else {
        return PET_NAMES
    }
    let found = dirs.filter { name in
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(
            atPath: base.appendingPathComponent(name).path,
            isDirectory: &isDir) && isDir.boolValue
    }.sorted()
    return found.isEmpty ? PET_NAMES : found
}
// Per-pet relative size, the same platform definition the
// coordinator's registry carries (pets-mcp "scale"): Carbon
// is a cat, and a cat stands half as tall as a person, on
// every screen. Nic, Oct 15.
let PET_REL_SCALE: [String: CGFloat] = ["carbon": 0.5]
let BASE_PT: CGFloat = 45        // sprite height at scale 1
let WALK_SPEED: CGFloat = 95     // points per second
let POLL_S: Double = 0.5
let STATUS_S: Double = 1.0
let GRAVITY: CGFloat = 2400      // points per second^2
let BOUNCE_MIN: CGFloat = 560    // impact speed that earns a bounce
let BOUNCE_KEEP: CGFloat = 0.32  // fraction of impact speed kept

func configDir() -> URL {
    let env = ProcessInfo.processInfo.environment["PETS_MAC_DIR"]
    if let env = env, !env.isEmpty { return URL(fileURLWithPath: env) }
    return FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".config/nimolo")
}

enum PetState: String {
    case walk, idle, peace, sit, sleep, greet, exit, enter
    case portalOut = "portal_out", portalIn = "portal_in", hidden
    case held, falling, approach
}

final class Pet {
    let name: String
    var images: [String: NSImage] = [:]
    var state: PetState = .hidden
    var present = false
    var x: CGFloat = 100
    var y: CGFloat = 0           // height above the Dock, points
    var vx: CGFloat = 0          // horizontal velocity, points/sec
    var vy: CGFloat = 0          // vertical velocity, points/sec
    var targetX: CGFloat = 0     // drag target (pointer) while held
    var targetY: CGFloat = 0
    var angle: CGFloat = 0       // body tilt, radians, + is CCW
    var angleVel: CGFloat = 0
    var speed: CGFloat = 0       // smoothed speed, for frame choice
    var panicFall = false        // high drop: arm-up falling pose
    var talkText: String?        // speech bubble override ("hey", "mrrp")
    var approachName: String?    // pet he is walking over to meet
    var seekX: CGFloat?          // window-play target (pet.x) while walking
    var dir: CGFloat = 1
    var stateUntil = Date.distantPast
    var portalStart = Date.distantPast
    var squashStart = Date.distantPast
    var alpha: CGFloat = 1
    var tapCycle = 0
    var heldState: PetState = .idle  // state when the drag began
    var lastSeq: Int = -1
    var lastMtime: Date = .distantPast
    // An arrival waiting on its art pack (v2.9): the
    // event is re-applied once the frames land.
    var pendingArrival: (event: String, text: String?)?
    // Stride phase, advanced by DISTANCE actually
    // travelled (pi per 17.1pt step-frame), so the legs,
    // the body bob and the ground can never drift apart
    // the way a wall-clock step index could.
    var walkPhase: CGFloat = 0
    // Stride length scales with body size: a half-height
    // cat takes half-length steps at the same ground speed,
    // so the legs, bob and ground stay in step at his size.
    var stride: CGFloat { 17.1 * (PET_REL_SCALE[name] ?? 1) }
    init(name: String) { self.name = name }

    func frame(_ now: Date) -> NSImage? {
        // 8-frame cycles (v2.5): walkPhase advances pi per 17.1pt
        // stride; frames change every half-stride (pi/2), so a full
        // 8-pose cycle spans the same distance the 4-pose cycle did.
        let step = Int(walkPhase / (.pi / 2)) % 8
        switch state {
        case .walk, .enter, .exit, .approach:
            if dir > 0 { return images["walk_r\(step)"] }
            return images["walk_l\(step)"]
        case .portalOut:
            if portalStart == .distantPast {
                if dir > 0 { return images["walk_r\(step)"] }
                return images["walk_l\(step)"]
            }
            return images["idle"]
        case .peace: return images["peace"]
        case .sit: return images["sit"]
        case .sleep: return images["sleep"]
        case .held:
            // Dragged fast, his legs swing in the direction
            // of travel; dragged slowly, he just dangles.
            if speed > 260 {
                if vx >= 0 { return images["walk_r\(step)"] }
                return images["walk_l\(step)"]
            }
            return images["idle"]
        case .falling:
            // A real drop gets the arm-up pose (the peace
            // frame); a short hop stays idle.
            return images[panicFall ? "peace" : "idle"]
        default: return images["idle"]
        }
    }
}

final class PetView: NSView {
    var pets: [Pet] = []
    var scale: Int = 2
    var groundY: CGFloat = 0      // view y of the Dock's top edge
    var petH: CGFloat { BASE_PT * CGFloat(scale) }
    // One pet's display height: the layer height scaled by
    // the pet's relative size (the cat is half height).
    func petH(_ pet: Pet) -> CGFloat {
        petH * (PET_REL_SCALE[pet.name] ?? 1)
    }
    func centreX(_ pet: Pet) -> CGFloat {
        bounds.width / 2 - petH(pet) / 2
    }

    // The pet's on-screen rect, with every animation
    // transform applied: stride bob, breathing, falling
    // stretch, landing squash. Hit-testing uses this same
    // rect, so what Nic sees is exactly what he can grab.
    func visualRect(_ pet: Pet, _ now: Date) -> NSRect {
        var sx: CGFloat = 1
        var sy: CGFloat = 1
        var bob: CGFloat = 0
        let t = now.timeIntervalSince1970
        switch pet.state {
        case .walk, .enter, .exit, .approach:
            // One smooth rise per stride (two steps: a step
            // is 0.18s at 95 pt/s, so a stride is ~34 points).
            // v2.0's abs(sin) doubled this frequency at full
            // amplitude and read as a vibration, not a gait.
            let phase = pet.walkPhase
            bob = (1 - cos(phase)) / 2 * 2.6
            sy -= 0.022 * (0.5 + 0.5 * cos(phase))  // footfall dip
        case .idle:
            let s = CGFloat(sin(t * 2 * .pi / 3.0))
            sy = 1 + 0.016 * s; sx = 1 - 0.008 * s
        case .sit:
            let s = CGFloat(sin(t * 2 * .pi / 3.6))
            sy = 1 + 0.010 * s; sx = 1 - 0.005 * s
        case .sleep:
            let s = CGFloat(sin(t * 2 * .pi / 4.2))
            sy = 1 + 0.026 * s; sx = 1 - 0.012 * s
        case .held:
            sy = 1.03 + min(0.05, pet.speed / 6000)
        case .falling:
            sy = 1 + min(0.13, abs(pet.vy) / 7000)
            sx = 1 - min(0.05, abs(pet.vy) / 16000)
        default:
            break
        }
        if pet.squashStart != .distantPast {
            let e = CGFloat(now.timeIntervalSince(pet.squashStart))
            if e < 0.35 {
                // Damped squash: flattened on impact, one
                // overshoot wobble, then settled.
                let osc = exp(-9 * e) * cos(22 * e)
                sy -= 0.24 * osc
                sx += 0.19 * osc
            }
        }
        let w = petH(pet) * sx
        let h = petH(pet) * sy
        return NSRect(x: pet.x + (petH(pet) - w) / 2,
                      y: groundY + pet.y + bob, width: w, height: h)
    }

    // No hit-testing and no mouse handlers here on purpose:
    // the window ignores mouse events, and the delegate
    // picks pets from global-monitor coordinates instead.

    override func draw(_ dirty: NSRect) {
        let now = Date()
        for pet in pets {
            let portalActive = pet.present &&
                (pet.state == .portalIn ||
                 (pet.state == .portalOut && pet.portalStart != .distantPast))
            if portalActive { drawPortal(pet, now) }
            guard pet.present else { continue }
            if pet.state == .portalOut && pet.portalStart != .distantPast &&
               now.timeIntervalSince(pet.portalStart) >= 0.5 { continue }
            guard let img = pet.frame(now) else { continue }
            let rect = visualRect(pet, now)
            drawPet(img, in: rect, angle: pet.angle, alpha: pet.alpha)
            if pet.state == .greet { drawBubble(pet, rect) }
            if pet.state == .sleep { drawZs(pet, rect, now) }
        }
    }

    // Draw a sprite rotated about its bottom-centre anchor,
    // so leans and swings pivot at the feet, not the middle.
    func drawPet(_ img: NSImage, in rect: NSRect,
                 angle: CGFloat, alpha: CGFloat) {
        if abs(angle) < 0.001 {
            img.draw(in: rect, from: .zero, operation: .sourceOver,
                     fraction: alpha)
            return
        }
        guard let ctx = NSGraphicsContext.current else { return }
        ctx.saveGraphicsState()
        let t = NSAffineTransform()
        t.translateX(by: rect.midX, yBy: rect.minY)
        t.rotate(byRadians: angle)
        t.translateX(by: -rect.width / 2, yBy: 0)
        t.concat()
        img.draw(in: NSRect(x: 0, y: 0, width: rect.width,
                            height: rect.height),
                 from: .zero, operation: .sourceOver, fraction: alpha)
        ctx.restoreGraphicsState()
    }

    func drawZs(_ pet: Pet, _ rect: NSRect, _ now: Date) {
        // Three Z's per 2.4s cycle, rising off the sleeper's
        // head, growing and fading, like Pane's but smooth.
        let base = NSColor(red: 74/255, green: 127/255,
                           blue: 165/255, alpha: 1)
        for i in 0..<3 {
            let ph = (now.timeIntervalSince1970 / 2.4
                      + Double(i) / 3).truncatingRemainder(dividingBy: 1)
            let size = CGFloat(11 + ph * 9)
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.boldSystemFont(ofSize: size),
                .foregroundColor: base.withAlphaComponent(
                    CGFloat(1 - ph * 0.85)),
            ]
            let s = "Z" as NSString
            s.draw(at: NSPoint(
                x: rect.maxX - 12 + CGFloat(ph) * 16,
                y: rect.maxY - 10 + CGFloat(ph) * 38),
                withAttributes: attrs)
        }
    }

    func drawPortal(_ pet: Pet, _ now: Date) {
        let elapsed = now.timeIntervalSince(pet.portalStart)
        var open = 1.0
        if pet.state == .portalIn {
            if elapsed < 0.3 { open = elapsed / 0.3 }
            else if elapsed > 0.8 { open = 0 }
        } else {
            if elapsed < 0.3 { open = elapsed / 0.3 }
            else if elapsed > 0.6 { open = max(0, (1.0 - elapsed) / 0.4) }
        }
        if open <= 0 { return }
        let cx = centreX(pet) + petH(pet) / 2
        let top = groundY + petH(pet) * 1.06
        let halfW = petH(pet) * 0.322 * CGFloat(open)
        diamond(cx: cx, top: top, bottom: groundY, halfW: halfW,
                color: NSColor(red: 74/255, green: 127/255,
                               blue: 165/255, alpha: 1))
        diamond(cx: cx, top: groundY + (top - groundY) * 0.82,
                bottom: groundY + (top - groundY) * 0.18,
                halfW: halfW * 0.55,
                color: NSColor(red: 138/255, green: 186/255,
                               blue: 211/255, alpha: 1))
    }

    func diamond(cx: CGFloat, top: CGFloat, bottom: CGFloat,
                 halfW: CGFloat, color: NSColor) {
        let mid = (top + bottom) / 2
        let path = NSBezierPath()
        path.move(to: NSPoint(x: cx, y: top))
        path.line(to: NSPoint(x: cx + halfW, y: mid))
        path.line(to: NSPoint(x: cx, y: bottom))
        path.line(to: NSPoint(x: cx - halfW, y: mid))
        path.close()
        color.setStroke()
        path.lineWidth = 2
        path.stroke()
    }

    func drawBubble(_ pet: Pet, _ rect: NSRect) {
        // "?" for a solo greet or a tap; a word when pets are
        // talking to each other ("hey", "mrrp", "purrr").
        let text = pet.talkText ?? "?"
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.boldSystemFont(ofSize: text.count > 1 ? 13 : 17),
            .foregroundColor: NSColor(red: 0x1C/255, green: 0x1C/255,
                                      blue: 0x1E/255, alpha: 1),
        ]
        let s = text as NSString
        let size = s.size(withAttributes: attrs)
        let bw = max(46, size.width + 20), bh: CGFloat = 30
        var bx = rect.maxX - bw - 4
        bx = max(4, min(bx, bounds.width - bw - 4))
        let by = rect.maxY + 12
        let r = NSRect(x: bx, y: by, width: bw, height: bh)
        NSColor(white: 0.96, alpha: 1).setFill()
        NSBezierPath(roundedRect: r, xRadius: 8, yRadius: 8).fill()
        let tail = NSBezierPath()
        tail.move(to: NSPoint(x: bx + 10, y: by))
        tail.line(to: NSPoint(x: bx + 22, y: by))
        tail.line(to: NSPoint(x: bx + 13, y: by - 9))
        tail.close()
        NSColor(white: 0.96, alpha: 1).setFill()
        tail.fill()
        s.draw(at: NSPoint(x: bx + (bw - size.width) / 2,
                           y: by + (bh - size.height) / 2),
               withAttributes: attrs)
    }
}


// MARK: event bus client
//
// The realtime channel to the coordinator (its base URL is
// resolved at BusClient.base): publishes this screen's live state
// once a second and holds an SSE subscription for intents,
// which then arrive in milliseconds instead of on the next
// file poll. Auth is a dedicated bus token in
// ~/.config/nimolo/bus-token; the MCP origin secret never
// leaves the coordinator host. The file channel stays live underneath:
// every directive is both written to a file and published,
// seq dedupe makes whichever arrives second a no-op, and
// if the bus is down the files carry on alone.
final class BusClient: NSObject, URLSessionDataDelegate {
    weak var owner: AppDelegate?
    private var token: String?
    private var session: URLSession?
    private var buffer = Data()
    private var publishTimer: Timer?

    func start(owner: AppDelegate) {
        self.owner = owner
        let path = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/nimolo/bus-token")
        token = (try? String(contentsOf: path, encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let token, token.count >= 24 else { return }
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 0
        cfg.timeoutIntervalForResource = 0
        session = URLSession(configuration: cfg, delegate: self,
                             delegateQueue: nil)
        subscribe()
        publishTimer = Timer.scheduledTimer(
            withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.publish()
        }
    }

    // The coordinator's base URL: ~/.config/nimolo/bus-host if
    // present, else $NIMOLO_BUS_URL, else a local coordinator.
    static let base: String = {
        let cfg = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/nimolo/bus-host")
        if let saved = try? String(contentsOf: cfg, encoding: .utf8) {
            let trimmed = saved.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
        }
        if let env = ProcessInfo.processInfo.environment["NIMOLO_BUS_URL"],
           !env.isEmpty { return env }
        return "http://127.0.0.1:7891"
    }()

    private func request(_ path: String) -> URLRequest? {
        guard let token,
              let url = URL(string: BusClient.base + path)
        else { return nil }
        var r = URLRequest(url: url)
        r.setValue(token, forHTTPHeaderField: "X-Bus-Token")
        return r
    }

    private func subscribe() {
        guard var r = request("/bus/stream?screen=macbook")
        else { return }
        r.httpMethod = "GET"
        session?.dataTask(with: r).resume()
    }

    private func publish() {
        guard let owner, var r = request("/bus/publish") else { return }
        var petsObj: [String: Any] = [:]
        for pet in owner.pets {
            if pet.present {
                petsObj[pet.name] = [
                    "present": true, "state": pet.state.rawValue,
                    "x": Int(pet.x), "y": Int(pet.y),
                    "held": pet.state == .held ? 1 : 0,
                    "falling": pet.state == .falling ? 1 : 0]
            } else {
                petsObj[pet.name] = ["present": false]
            }
        }
        let body: [String: Any] = ["screen": "macbook", "pets": petsObj]
        r.httpMethod = "POST"
        r.httpBody = try? JSONSerialization.data(withJSONObject: body)
        URLSession.shared.dataTask(with: r) { _, _, _ in }.resume()
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask,
                    didReceive data: Data) {
        buffer.append(data)
        while let range = buffer.range(of: Data("\n\n".utf8)) {
            let chunk = buffer.subdata(in: 0..<range.lowerBound)
            buffer.removeSubrange(0..<range.upperBound)
            guard let text = String(data: chunk, encoding: .utf8)
            else { continue }
            for line in text.split(separator: "\n") {
                guard line.hasPrefix("data: ") else { continue }
                let json = Data(line.dropFirst(6).utf8)
                guard let obj = try? JSONSerialization.jsonObject(
                        with: json) as? [String: Any],
                      let petName = obj["pet"] as? String,
                      let event = obj["event"] as? String,
                      let dseq = obj["directive_seq"] as? Int
                else { continue }
                var text: String?
                if let extra = obj["extra"] as? String,
                   extra.hasPrefix("text=") {
                    text = String(extra.dropFirst(5))
                }
                DispatchQueue.main.async { [weak self] in
                    guard let owner = self?.owner
                    else { return }
                    let pet = owner.ensurePet(petName)
                    guard dseq > pet.lastSeq else { return }
                    pet.lastSeq = dseq
                    owner.applyEvent(pet, event, text: text)
                }
            }
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    didCompleteWithError error: Error?) {
        // Reconnect with a pause; the file channel covers
        // the gap, so this never has to be heroic.
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
            [weak self] in self?.subscribe()
        }
    }
}


// MARK: dynamic art (v2.9)
//
// Art lives on the coordinator as per-pet packs (profile
// mac-240: the 20 frame PNGs + a manifest, served at
// /packs/<pet>/mac-240/). The bundle seeds the resident
// cast; any other pet's frames are pulled into
// ~/.config/nimolo/art/<pet> when it arrives and evicted
// when the coordinator sends evict_art (its disable).
// A pet with no art anywhere simply never appears:
// honest absence over wrong art. Per-pet relative scale
// for pulled pets still comes from PET_REL_SCALE; the
// intent payload carries the registry scale and wiring
// it through is a follow-up.
final class ArtStore {
    static let frameKeys = ["idle", "peace", "sit", "sleep"]
        + (0..<8).map { "walk_r\($0)" }
        + (0..<8).map { "walk_l\($0)" }
    private var inFlight: Set<String> = []

    static func cacheDir(_ pet: String) -> URL {
        configDir().appendingPathComponent("art")
            .appendingPathComponent(pet)
    }

    static func loadImages(_ pet: String) -> [String: NSImage] {
        var out: [String: NSImage] = [:]
        let bundle = Bundle.main.resourceURL?
            .appendingPathComponent("frames")
            .appendingPathComponent(pet)
        for dir in [cacheDir(pet), bundle].compactMap({ $0 }) {
            for key in frameKeys {
                if out[key] == nil,
                   let img = NSImage(contentsOf: dir
                        .appendingPathComponent("\(key).png")) {
                    out[key] = img
                }
            }
            if out.count >= frameKeys.count { break }
        }
        return out
    }

    func pull(_ pet: String, done: @escaping (Bool) -> Void) {
        if inFlight.contains(pet) { return }
        inFlight.insert(pet)
        let token = (try? String(
            contentsOf: configDir()
                .appendingPathComponent("bus-token"),
            encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        func get(_ path: String, _ cb: @escaping (Data?) -> Void) {
            guard let url = URL(string: BusClient.base + path)
            else { cb(nil); return }
            var r = URLRequest(url: url)
            r.setValue(token, forHTTPHeaderField: "X-Bus-Token")
            URLSession.shared.dataTask(with: r) { data, resp, _ in
                cb((resp as? HTTPURLResponse)?.statusCode == 200
                    ? data : nil)
            }.resume()
        }
        get("/packs/\(pet)/mac-240/manifest.json") { [weak self] data in
            guard let self, let data,
                  let man = try? JSONSerialization.jsonObject(
                    with: data) as? [String: Any],
                  let files = man["files"] as? [[String: Any]]
            else {
                DispatchQueue.main.async {
                    self?.inFlight.remove(pet); done(false) }
                return
            }
            let names = files.compactMap { $0["path"] as? String }
            if names.isEmpty {
                DispatchQueue.main.async {
                    self.inFlight.remove(pet); done(false) }
                return
            }
            var remaining = names.count
            var ok = true
            for name in names {
                get("/packs/\(pet)/mac-240/\(name)") { fdata in
                    DispatchQueue.main.async {
                        if let fdata {
                            let dir = ArtStore.cacheDir(pet)
                            try? FileManager.default
                                .createDirectory(
                                    at: dir,
                                    withIntermediateDirectories: true)
                            try? fdata.write(to: dir
                                .appendingPathComponent(name))
                        } else { ok = false }
                        remaining -= 1
                        if remaining == 0 {
                            self.inFlight.remove(pet)
                            done(ok)
                        }
                    }
                }
            }
        }
    }

    func evict(_ pet: String) {
        try? FileManager.default.removeItem(
            at: ArtStore.cacheDir(pet))
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    var window: NSWindow!
    var view: PetView!
    var pets: [Pet] = []
    var legacySeq: Int = -1
    var legacyMtime: Date = .distantPast
    var lastStatus = Date.distantPast
    var lastTick = Date()
    // Drag bookkeeping (one mouse, one pet at a time).
    var dragPet: Pet?
    var grabDX: CGFloat = 0   // pointer offset from the pet's origin
    var grabDY: CGFloat = 0
    var downPoint = NSPoint.zero
    var downTime = Date.distantPast
    var dragMoved = false
    var pairCooldown: [String: Date] = [:]  // "lucas|mike" -> next allowed meet
    var bus: BusClient?
    let art = ArtStore()
    // Window-aware play (v2.8): where the frontmost
    // window sits, so pets can gather under it.
    var winAnchor: CGFloat? = nil   // window centre x, view coords
    var winOwner: String = ""
    var winOwnerPID: pid_t = 0
    var lastWinSample = Date.distantPast

    func applicationDidFinishLaunching(_ note: Notification) {
        loadFrames()
        let frame = fullFrame()
        view = PetView(frame: NSRect(origin: .zero, size: frame.size))
        view.pets = pets
        view.groundY = groundOffset()
        window = NSWindow(contentRect: frame, styleMask: .borderless,
                          backing: .buffered, defer: false)
        window.contentView = view
        window.backgroundColor = .clear
        window.isOpaque = false
        window.hasShadow = false
        window.level = .floating
        window.collectionBehavior = [.canJoinAllSpaces, .stationary]
        // The window must never take mouse or keyboard focus:
        // it ignores mouse events entirely, and the pets are
        // picked through global event monitors (below), which
        // cannot activate this app. See the header comment.
        window.ignoresMouseEvents = true
        window.orderFrontRegardless()
        installMouseMonitors()
        bus = BusClient()
        bus?.start(owner: self)
        NotificationCenter.default.addObserver(
            self, selector: #selector(screensChanged),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil)
        Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) {
            [weak self] _ in self?.tick()
        }
    }

    @objc func screensChanged() {
        window.setFrame(fullFrame(), display: true)
        view.groundY = groundOffset()
    }

    func fullFrame() -> NSRect {
        guard let screen = NSScreen.main else {
            return NSRect(x: 0, y: 0, width: 1440, height: 900)
        }
        return screen.frame
    }

    // The ground line: the top of a visible bottom Dock
    // (visibleFrame excludes it); with the Dock hidden or on
    // a side, pets walk the screen's bottom edge instead.
    func groundOffset() -> CGFloat {
        guard let screen = NSScreen.main else { return 0 }
        return max(0, screen.visibleFrame.minY - screen.frame.minY)
    }

    func loadFrames() {
        var names = Set(rosterNames())
        let artRoot = configDir().appendingPathComponent("art")
        if let dirs = try? FileManager.default
            .contentsOfDirectory(atPath: artRoot.path) {
            names.formUnion(dirs)
        }
        for name in names.sorted() {
            let pet = Pet(name: name)
            pet.x = 140 + CGFloat(pets.count) * 300
            pet.dir = pets.count % 2 == 0 ? 1 : -1
            pet.images = ArtStore.loadImages(name)
            pets.append(pet)
        }
    }

    // Pets are created on demand (v2.9): a directive or
    // intent naming a pet the app has never seen makes
    // its Pet here, frameless until its art is pulled.
    func ensurePet(_ name: String) -> Pet {
        if let pet = pets.first(where: { $0.name == name }) {
            return pet
        }
        let pet = Pet(name: name)
        pet.x = 140 + CGFloat(pets.count) * 300
        pet.dir = pets.count % 2 == 0 ? 1 : -1
        pet.images = ArtStore.loadImages(name)
        pets.append(pet)
        view?.pets.append(pet)
        return pet
    }

    // The pets worth polling directive files for: every
    // known pet plus any pet-<name> file on disk, so a
    // first directive for an unknown pet is still read.
    func directivePets() -> [Pet] {
        var names = Set(pets.map { $0.name })
        let dir = configDir()
        if let files = try? FileManager.default
            .contentsOfDirectory(atPath: dir.path) {
            for f in files where f.hasPrefix("pet-")
                && f != "pet-status" && f != "pet-status.tmp" {
                names.insert(String(f.dropFirst(4)))
            }
        }
        return names.sorted().map { ensurePet($0) }
    }

    // MARK: mouse (Pane's taps, translated to the mouse)

    var mouseMonitors: [Any] = []

    // Global monitors observe the mouse events other apps
    // receive; they never activate this app and cannot take
    // key-window focus, so typing in other apps is safe by
    // construction. The tradeoff: the app underneath also
    // sees the click that grabs a pet. Accepted; the pets
    // live on the Dock strip, and a stolen keyboard was not.
    func installMouseMonitors() {
        let mask: NSEvent.EventTypeMask = [
            .leftMouseDown, .leftMouseDragged, .leftMouseUp]
        if let mon = NSEvent.addGlobalMonitorForEvents(
            matching: mask, handler: { [weak self] event in
                guard let self = self else { return }
                switch event.type {
                case .leftMouseDown: self.petMouseDown()
                case .leftMouseDragged: self.petMouseDragged()
                case .leftMouseUp: self.petMouseUp()
                default: break
                }
            }) {
            mouseMonitors.append(mon)
        }
    }

    // Pointer position in view coordinates, from the global
    // (bottom-left of the main screen) mouse location. The
    // window is the full main screen, so this is a pure
    // origin shift.
    func mouseLoc() -> NSPoint {
        let m = NSEvent.mouseLocation
        let f = window.frame
        return NSPoint(x: m.x - f.minX, y: m.y - f.minY)
    }

    func petMouseDown() {
        let loc = mouseLoc()
        let now = Date()
        for pet in pets.reversed() where pet.present {
            if view.visualRect(pet, now).contains(loc) {
                dragPet = pet
                grabDX = loc.x - pet.x
                grabDY = loc.y - view.groundY - pet.y
                downPoint = loc
                downTime = now
                dragMoved = false
                pet.heldState = pet.state
                pet.state = .held
                pet.targetX = pet.x
                pet.targetY = pet.y
                pet.vx = 0
                pet.vy = 0
                pet.panicFall = false
                return
            }
        }
    }

    func petMouseDragged() {
        guard let pet = dragPet else { return }
        let loc = mouseLoc()
        if hypot(loc.x - downPoint.x, loc.y - downPoint.y) > 5 {
            dragMoved = true
        }
        guard dragMoved else { return }
        // Only the target moves with the pointer; the pet's
        // body follows on a spring in update(), which is what
        // gives the lag, the overshoot and the swing.
        pet.targetX = min(max(loc.x - grabDX, 0),
                          view.bounds.width - view.petH(pet))
        pet.targetY = min(max(loc.y - view.groundY - grabDY, 0),
                          view.bounds.height - view.groundY - view.petH(pet))
    }

    func petMouseUp() {
        guard let pet = dragPet else { return }
        dragPet = nil
        let quick = Date().timeIntervalSince(downTime) < 0.5
        if !dragMoved && quick {
            // A click, not a drag: Pane's tap reactions. A
            // pet caught mid-air and clicked just gets dropped.
            if pet.y > 4 {
                pet.state = .falling
                pet.panicFall = pet.y > 130
                pet.vx = 0
                pet.vy = 0
            } else {
                tapReact(pet)
            }
            return
        }
        // Released after a real drag: gravity takes it, and
        // the spring's velocity goes with it, so a flick
        // throws him. A high release is a panic fall.
        pet.state = .falling
        pet.panicFall = pet.y > 130
    }

    // Pane's tap cycle, verbatim: a tap always wakes a
    // sleeper; otherwise greet, turn-and-walk, or jump to a
    // different activity, rotating.
    func tapReact(_ pet: Pet) {
        let now = Date()
        let kind: Int
        if pet.heldState == .sleep { kind = 0 }
        else {
            kind = pet.tapCycle % 3
            pet.tapCycle += 1
        }
        switch kind {
        case 0:
            pet.state = .greet
            pet.talkText = nil
            pet.stateUntil = now.addingTimeInterval(1.8)
        case 1:
            pet.dir = -pet.dir
            pet.state = .walk
            pet.stateUntil = now.addingTimeInterval(Double.random(in: 4...7))
        default:
            if pet.heldState == .walk {
                pet.state = .peace
                pet.stateUntil = now.addingTimeInterval(2.4)
            } else if pet.heldState == .sit {
                pet.state = .walk
                pet.stateUntil = now.addingTimeInterval(Double.random(in: 4...7))
            } else {
                pet.state = .sit
                pet.stateUntil = now.addingTimeInterval(Double.random(in: 4...7))
            }
        }
    }

    // MARK: social (pets meeting each other on this screen)

    func replyFor(_ pet: Pet) -> String {
        if pet.name == "carbon" {
            return ["mrrp", "meow", "purrr", "mrrrow"].randomElement()!
        }
        return ["hey", "sup", "yo", "o/", "!"].randomElement()!
    }

    // Two pets talk: they face each other, the initiator gets
    // the "?" and the other answers with a word. The pair
    // then goes quiet for a while so it stays an event, not
    // a loop.
    func pairedGreet(_ a: Pet, _ b: Pet, _ now: Date) {
        a.dir = b.x >= a.x ? 1 : -1
        b.dir = -a.dir
        a.approachName = nil
        if (a.name == "carbon") != (b.name == "carbon") {
            let human = a.name == "carbon" ? b : a
            let cat = a.name == "carbon" ? a : b
            human.state = .peace
            human.stateUntil = now.addingTimeInterval(1.8)
            human.talkText = nil
            cat.state = .greet
            cat.stateUntil = now.addingTimeInterval(1.8)
            cat.talkText = "purrr"
            pairCooldown[[a.name, b.name].sorted()
                .joined(separator: "|")] =
                now.addingTimeInterval(35)
            return
        }
        a.state = .greet
        a.stateUntil = now.addingTimeInterval(1.8)
        a.talkText = "?"
        b.state = .greet
        b.stateUntil = now.addingTimeInterval(1.8)
        b.talkText = replyFor(b)
        pairCooldown[[a.name, b.name].sorted().joined(separator: "|")] =
            now.addingTimeInterval(35)
    }

    func nearestOther(_ pet: Pet) -> Pet? {
        var best: Pet?
        var bestD = CGFloat.greatestFiniteMagnitude
        for other in pets where other !== pet && other.present
            && other.state != .hidden && other.state != .exit {
            let d = abs(other.x - pet.x)
            if d < bestD { bestD = d; best = other }
        }
        return best
    }

    // A greet event (a tap reaction calls tapReact instead):
    // with company on screen, he walks over to the nearest
    // pet first and they talk; alone, it is the solo bubble.
    func greetEvent(_ pet: Pet, _ now: Date) {
        guard let other = nearestOther(pet) else {
            pet.state = .greet
            pet.stateUntil = now.addingTimeInterval(1.8)
            pet.talkText = nil
            return
        }
        if abs(other.x - pet.x) <= view.petH(pet) * 1.15 {
            pairedGreet(pet, other, now)
        } else {
            pet.state = .approach
            pet.approachName = other.name
            pet.dir = other.x >= pet.x ? 1 : -1
        }
    }

    // Wandering paths cross: when two ambient pets bump into
    // each other, they stop and talk (cooldown permitting).
    func checkBumpMeets(_ now: Date) {
        for i in pets.indices {
            for j in pets.indices where j > i {
                let a = pets[i], b = pets[j]
                guard a.present, b.present,
                      a.y == 0, b.y == 0,
                      [.walk, .idle].contains(a.state),
                      [.walk, .idle].contains(b.state),
                      abs(a.x - b.x) < (view.petH(a) + view.petH(b)) / 2 * 0.95
                else { continue }
                let key = [a.name, b.name].sorted().joined(separator: "|")
                if let until = pairCooldown[key], now < until { continue }
                pairedGreet(a, b, now)
            }
        }
    }

    // MARK: directives

    func parseDirective(_ url: URL) -> [String: String] {
        guard let text = try? String(contentsOf: url, encoding: .utf8)
        else { return [:] }
        var out: [String: String] = [:]
        for line in text.split(separator: "\n") {
            let parts = line.split(separator: "=", maxSplits: 1)
            if parts.count == 2 {
                out[String(parts[0])] = String(parts[1])
                    .trimmingCharacters(in: .whitespaces)
            }
        }
        return out
    }

    func pollDirectives() {
        let dir = configDir()
        let fm = FileManager.default
        for pet in directivePets() {
            let url = dir.appendingPathComponent("pet-\(pet.name)")
            guard let attrs = try? fm.attributesOfItem(atPath: url.path),
                  let mtime = attrs[.modificationDate] as? Date
            else { continue }
            if mtime == pet.lastMtime && pet.lastSeq >= 0 { continue }
            pet.lastMtime = mtime
            let kv = parseDirective(url)
            guard let seq = Int(kv["seq"] ?? ""), seq > pet.lastSeq
            else { continue }
            pet.lastSeq = seq
            if let sc = Int(kv["scale"] ?? ""), (1...4).contains(sc) {
                setScale(sc)
            }
            if let event = kv["event"], !event.isEmpty {
                applyEvent(pet, event, text: kv["text"])
            }
        }
        // legacy combined file (pet): pet=, event=, seq=
        let url = dir.appendingPathComponent("pet")
        if let attrs = try? fm.attributesOfItem(atPath: url.path),
           let mtime = attrs[.modificationDate] as? Date,
           mtime != legacyMtime || legacySeq < 0 {
            legacyMtime = mtime
            let kv = parseDirective(url)
            if let seq = Int(kv["seq"] ?? ""), seq > legacySeq {
                legacySeq = seq
                if let sc = Int(kv["scale"] ?? ""), (1...4).contains(sc) {
                    setScale(sc)
                }
                if let name = kv["pet"],
                   let pet = Optional(ensurePet(name)),
                   let event = kv["event"], !event.isEmpty {
                    applyEvent(pet, event)
                }
            }
        }
    }

    // Remote verification, mirroring Flint's SIGUSR1 capture:
    // when a file named "snapshot" appears in the config dir,
    // render just the Dock strip to snapshot.png next to it
    // and remove the trigger. Works even with the physical
    // display asleep.
    func pollSnapshot() {
        let dir = configDir()
        let trigger = dir.appendingPathComponent("snapshot")
        guard FileManager.default.fileExists(atPath: trigger.path)
        else { return }
        try? FileManager.default.removeItem(at: trigger)
        let strip = NSRect(
            x: 0, y: view.groundY, width: view.bounds.width,
            height: min(view.petH + 90,
                        view.bounds.height - view.groundY))
        guard let rep = view.bitmapImageRepForCachingDisplay(
            in: strip) else { return }
        view.cacheDisplay(in: strip, to: rep)
        if let data = rep.representation(using: .png, properties: [:]) {
            try? data.write(to: dir.appendingPathComponent("snapshot.png"))
        }
    }

    func setScale(_ sc: Int) {
        view.scale = sc
    }

    func applyEvent(_ pet: Pet, _ event: String,
                    text: String? = nil) {
        if event == "evict_art" {
            // The pet was disabled: off screen now, and
            // its pulled art goes back to the store.
            if dragPet === pet { dragPet = nil }
            pet.present = false
            pet.state = .hidden
            pet.pendingArrival = nil
            pet.images = [:]
            art.evict(pet.name)
            return
        }
        let arrivals = ["portal_in", "arrive_left", "arrive_right"]
        if arrivals.contains(event), pet.images.isEmpty {
            // No art on this screen: pull the pack, then
            // arrive. If the pull fails the pet stays
            // absent rather than appearing frameless.
            pet.pendingArrival = (event, text)
            art.pull(pet.name) { [weak self, weak pet] ok in
                guard let self, let pet else { return }
                let pending = pet.pendingArrival
                pet.pendingArrival = nil
                if ok, let pending {
                    pet.images = ArtStore.loadImages(pet.name)
                    applyEvent(pet, pending.event,
                               text: pending.text)
                }
            }
            return
        }
        let now = Date()
        // A coordinator event ends any drag or fall cleanly.
        if dragPet === pet { dragPet = nil }
        pet.y = 0
        pet.vx = 0
        pet.vy = 0
        pet.angle = 0
        pet.angleVel = 0
        pet.panicFall = false
        switch event {
        case "arrive_left":
            pet.present = true; pet.alpha = 1
            pet.x = -view.petH(pet) + 8; pet.dir = 1; pet.state = .enter
        case "arrive_right":
            pet.present = true; pet.alpha = 1
            pet.x = view.bounds.width - 8; pet.dir = -1; pet.state = .enter
        case "depart_left":
            if pet.present { pet.dir = -1; pet.state = .exit }
        case "depart_right":
            if pet.present { pet.dir = 1; pet.state = .exit }
        case "portal_in":
            pet.present = true
            pet.x = view.centreX(pet); pet.alpha = 0
            pet.portalStart = now; pet.state = .portalIn
        case "portal_out":
            if pet.present {
                pet.portalStart = .distantPast
                pet.state = .portalOut
            }
        case "greet":
            if pet.present { greetEvent(pet, now) }
        case "say":
            // Direct speech: the bubble shows the given
            // words, sized to reading time. No walk-over:
            // being addressed is not a meeting.
            if pet.present, let text, !text.isEmpty {
                pet.state = .greet
                pet.talkText = String(text.prefix(48))
                let secs = min(5.0, max(2.0,
                    1.2 + 0.32 * Double(text.count)))
                pet.stateUntil = now.addingTimeInterval(secs)
            }
        default:
            break
        }
    }

    // MARK: simulation

    func pickAmbient(_ pet: Pet, _ now: Date) {
        pet.talkText = nil
        pet.approachName = nil
        pet.seekX = nil
        let r = Int.random(in: 0..<100)
        switch r {
        case ..<42:
            pet.state = .walk
            pet.stateUntil = now.addingTimeInterval(Double.random(in: 5...10))
            // Window-aware play (v2.8): walks gravitate to
            // the frontmost window. A quarter of walks go
            // there on purpose and sit under it a while.
            if let anchor = winAnchor {
                let h = view.petH(pet)
                if Int.random(in: 0..<4) == 0 {
                    pet.seekX = min(max(anchor - h / 2, 4),
                                    view.bounds.width - h - 4)
                    pet.stateUntil = now.addingTimeInterval(14)
                } else if Bool.random() {
                    pet.dir = anchor >= pet.x + h / 2 ? 1 : -1
                }
            }
        case ..<62:
            pet.state = .idle
            pet.stateUntil = now.addingTimeInterval(Double.random(in: 2...4.5))
        case ..<74:
            pet.state = .peace
            pet.stateUntil = now.addingTimeInterval(2.4)
        case ..<89:
            pet.state = .sit
            pet.stateUntil = now.addingTimeInterval(Double.random(in: 4...8))
        default:
            pet.state = .sleep
            pet.stateUntil = now.addingTimeInterval(Double.random(in: 7...13))
        }
    }

    func update(_ pet: Pet, dt: CGFloat, now: Date) {
        let w = view.bounds.width
        let h = view.petH(pet)
        let step = WALK_SPEED * dt
        // Smoothed speed drives frame choice (legs swinging
        // while dragged fast, panic pose on a fast fall).
        let instSpeed: CGFloat
        switch pet.state {
        case .held, .falling: instSpeed = hypot(pet.vx, pet.vy)
        case .walk, .enter, .exit, .approach: instSpeed = WALK_SPEED
        default: instSpeed = 0
        }
        pet.speed += (instSpeed - pet.speed) * min(1, dt * 10)
        // Body tilt: every state has a target lean, and the
        // angle is a spring, so it lags, overshoots and
        // settles instead of snapping. Walking leans into the
        // stride with a rock at the stride phase; being
        // dragged, the body trails the hand; falling, it
        // trails the throw and sways.
        var tiltTarget: CGFloat = 0
        var tiltK: CGFloat = 90
        var tiltC: CGFloat = 13
        switch pet.state {
        case .walk, .enter, .exit, .approach:
            tiltTarget = -pet.dir * 0.055 + sin(pet.walkPhase) * 0.028
        case .held:
            tiltTarget = max(-0.5, min(0.5, -pet.vx * 0.00045))
            tiltK = 55; tiltC = 7.5
        case .falling:
            let sway = sin(now.timeIntervalSince1970 * 9) * 0.05
                * min(1, abs(pet.vy) / 800)
            tiltTarget = max(-0.3, min(0.3, -pet.vx * 0.0002)) + sway
            tiltK = 30; tiltC = 5
        default:
            break
        }
        pet.angleVel += (tiltK * (tiltTarget - pet.angle)
                         - tiltC * pet.angleVel) * dt
        pet.angle += pet.angleVel * dt
        switch pet.state {
        case .walk:
            // Window play: a seeking pet heads for its
            // target under the frontmost window and sits.
            if let sx = pet.seekX {
                if abs(sx - pet.x) <= 6 {
                    pet.x = sx
                    pet.seekX = nil
                    pet.state = .sit
                    pet.stateUntil = now.addingTimeInterval(
                        Double.random(in: 4...8))
                    break
                }
                pet.dir = sx >= pet.x ? 1 : -1
            }
            // Real walking surges: push off, glide, land.
            // Speed breathes with the stride phase while
            // the phase advances by the distance covered,
            // so feet plant instead of skating.
            let dx = pet.dir * WALK_SPEED
                * (1 + 0.22 * sin(pet.walkPhase)) * dt
            pet.x += dx
            pet.walkPhase += abs(dx) / pet.stride * .pi
            if pet.x <= 4 { pet.x = 4; pet.dir = 1 }
            if pet.x >= w - h - 4 { pet.x = w - h - 4; pet.dir = -1 }
            if now >= pet.stateUntil { pickAmbient(pet, now) }
        case .idle, .peace, .sit, .sleep, .greet:
            if now >= pet.stateUntil { pickAmbient(pet, now) }
        case .approach:
            guard let name = pet.approachName,
                  let other = pets.first(where: { $0.name == name }),
                  other.present else {
                pet.state = .greet
                pet.stateUntil = now.addingTimeInterval(1.2)
                break
            }
            pet.dir = other.x >= pet.x ? 1 : -1
            pet.x += pet.dir * step
            pet.walkPhase += step / pet.stride * .pi
            if abs(other.x - pet.x) <= h * 1.05 {
                pairedGreet(pet, other, now)
            }
        case .held:
            // Spring toward the pointer: stiff enough to
            // follow, loose enough to lag and overshoot.
            let k: CGFloat = 110, c: CGFloat = 15
            pet.vx += (k * (pet.targetX - pet.x) - c * pet.vx) * dt
            pet.vy += (k * (pet.targetY - pet.y) - c * pet.vy) * dt
            pet.x += pet.vx * dt
            pet.y += pet.vy * dt
            pet.walkPhase += abs(pet.vx) * dt / pet.stride * .pi
            if pet.y < 0 { pet.y = 0; pet.vy = 0 }
        case .falling:
            pet.vy -= GRAVITY * dt
            pet.y += pet.vy * dt
            pet.x += pet.vx * dt
            pet.vx *= max(0, 1 - 0.6 * dt)  // a whisper of air drag
            if pet.x <= 2 { pet.x = 2; pet.vx = abs(pet.vx) * 0.5 }
            if pet.x >= w - h - 2 {
                pet.x = w - h - 2; pet.vx = -abs(pet.vx) * 0.5
            }
            if abs(pet.vy) > 650 { pet.panicFall = true }
            if pet.y <= 0 {
                pet.y = 0
                let impact = -pet.vy
                pet.squashStart = now
                pet.angleVel -= pet.vx * 0.004  // landing skid tips him
                pet.vx = 0
                pet.panicFall = false
                if impact > BOUNCE_MIN {
                    pet.vy = impact * BOUNCE_KEEP
                } else {
                    pet.vy = 0
                    pickAmbient(pet, now)
                }
            }
        case .enter:
            pet.x += pet.dir * step
            pet.walkPhase += step / pet.stride * .pi
            if (pet.dir > 0 && pet.x >= 60) ||
               (pet.dir < 0 && pet.x <= w - h - 60) {
                pet.state = .walk
                pet.stateUntil = now.addingTimeInterval(4)
            }
        case .exit:
            pet.x += pet.dir * step
            pet.walkPhase += step / pet.stride * .pi
            if pet.x <= -h || pet.x >= w {
                pet.present = false
                pet.state = .hidden
            }
        case .portalOut:
            if pet.portalStart == .distantPast {
                let cx = view.centreX(pet)
                if pet.x < cx - 4 { pet.dir = 1; pet.x += step; pet.walkPhase += step / pet.stride * .pi }
                else if pet.x > cx + 4 { pet.dir = -1; pet.x -= step; pet.walkPhase += step / pet.stride * .pi }
                else {
                    pet.portalStart = now
                    pet.stateUntil = now.addingTimeInterval(1.0)
                }
            } else {
                let el = now.timeIntervalSince(pet.portalStart)
                if el < 0.5 {
                    pet.alpha = 1 - CGFloat(el / 0.5)
                } else {
                    pet.present = false
                    pet.alpha = 1
                    if now >= pet.stateUntil { pet.state = .hidden }
                }
            }
        case .portalIn:
            let el = now.timeIntervalSince(pet.portalStart)
            if el < 0.4 { pet.alpha = 0 }
            else if el < 0.9 { pet.alpha = CGFloat((el - 0.4) / 0.5) }
            else {
                pet.alpha = 1
                pet.state = .greet
                pet.stateUntil = now.addingTimeInterval(1.8)
            }
        case .hidden:
            break
        }
    }

    func tick() {
        pollDirectives()
        pollSnapshot()
        sampleWindow(now: Date())
        let now = Date()
        let dt = CGFloat(min(0.1, now.timeIntervalSince(lastTick)))
        lastTick = now
        for pet in pets where pet.present || pet.state != .hidden {
            update(pet, dt: dt, now: now)
        }
        checkBumpMeets(now)
        if now.timeIntervalSince(lastStatus) >= STATUS_S {
            lastStatus = now
            writeStatus()
        }
        view.needsDisplay = true
    }

    // Window-aware play (v2.8): sample the frontmost
    // window's geometry (never its content) every 1.5 s.
    // CGWindowList bounds need no extra permission; the
    // window title is never read. The strip window is
    // never made key or active for this (v2.0 rule).
    func sampleWindow(now: Date) {
        if now.timeIntervalSince(lastWinSample) < 1.5 { return }
        lastWinSample = now
        let opts: CGWindowListOption = [.optionOnScreenOnly,
                                        .excludeDesktopElements]
        guard let list = CGWindowListCopyWindowInfo(
                opts, kCGNullWindowID) as? [[String: Any]]
        else { return }
        let myPID = ProcessInfo.processInfo.processIdentifier
        for w in list {
            if (w[kCGWindowLayer as String] as? Int ?? -1) != 0 {
                continue
            }
            let pid = w[kCGWindowOwnerPID as String] as? pid_t ?? 0
            if pid == myPID || pid == 0 { continue }
            guard let b = w[kCGWindowBounds as String]
                    as? [String: CGFloat],
                  let bw = b["Width"], let bx = b["X"],
                  bw >= 120, (b["Height"] ?? 0) >= 80
            else { continue }
            winAnchor = bx + bw / 2 - fullFrame().minX
            if pid != winOwnerPID {
                let had = winOwnerPID != 0
                winOwnerPID = pid
                winOwner = w[kCGWindowOwnerName as String]
                    as? String ?? ""
                if had { windowChanged(now) }
            }
            return
        }
        winAnchor = nil
    }

    // The frontmost app changed: the pet nearest the
    // window looks up for a beat.
    func windowChanged(_ now: Date) {
        guard let anchor = winAnchor else { return }
        let cands = pets.filter {
            $0.present && ($0.state == .idle || $0.state == .sit)
        }
        if let p = cands.min(by: {
            abs($0.x - anchor) < abs($1.x - anchor) }) {
            p.state = .peace
            p.stateUntil = now.addingTimeInterval(1.6)
        }
    }

    func writeStatus() {
        let dir = configDir()
        try? FileManager.default.createDirectory(
            at: dir, withIntermediateDirectories: true)
        var lines: [String] = []
        for pet in pets {
            if pet.present {
                let held = pet.state == .held ? 1 : 0
                let falling = pet.state == .falling ? 1 : 0
                lines.append("\(pet.name)=present state=\(pet.state.rawValue) x=\(Int(pet.x)) y=\(Int(pet.y)) held=\(held) falling=\(falling)")
            } else {
                lines.append("\(pet.name)=absent")
            }
        }
        if let anchor = winAnchor {
            lines.append("window=anchor:\(Int(anchor)) owner:\(winOwner)")
        } else {
            lines.append("window=none")
        }
        let tmp = dir.appendingPathComponent("pet-status.tmp")
        let fin = dir.appendingPathComponent("pet-status")
        try? (lines.joined(separator: "\n") + "\n")
            .write(to: tmp, atomically: false, encoding: .utf8)
        try? FileManager.default.replaceItemAt(fin, withItemAt: tmp)
    }
}

let delegate = AppDelegate()
let app = NSApplication.shared
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
