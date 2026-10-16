import Foundation

// MARK: - The phone's interface counters

/// Running totals for one group of network interfaces (32-bit, they wrap every 4 GiB).
struct IfCounts {
    var rxB: UInt32 = 0, txB: UInt32 = 0, rxP: UInt32 = 0, txP: UInt32 = 0

    /// Change since `old`, with wrapping subtraction (handles one wrap between readings).
    func minus(_ old: IfCounts) -> IfDelta {
        IfDelta(rxB: Double(rxB &- old.rxB), txB: Double(txB &- old.txB),
                rxP: Double(rxP &- old.rxP), txP: Double(txP &- old.txP))
    }
}

struct IfDelta {
    var rxB = 0.0, txB = 0.0, rxP = 0.0, txP = 0.0
    var bytes: Double { rxB + txB }
    var packets: Double { rxP + txP }
    /// An interface vanishing (Wi-Fi off) shrinks a sum and looks like a giant wrap.
    var plausible: Bool { rxB < 200_000_000 && txB < 200_000_000 }
}

/// The phone's link-level counters by kind of link, from the BSD interface table.
///  • wifi: en*   • cell: pdp_ip*   • p2p: awdl*/llw* (AirDrop, Handoff, AirPlay, and the
///    duo link itself, which is why gait mode ignores it).
struct Counters {
    var wifi = IfCounts(), cell = IfCounts(), p2p = IfCounts()

    static func read() -> Counters? {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return nil }
        defer { freeifaddrs(head) }
        var c = Counters()
        var p: UnsafeMutablePointer<ifaddrs>? = first
        while let ifa = p {
            defer { p = ifa.pointee.ifa_next }
            guard let addr = ifa.pointee.ifa_addr, addr.pointee.sa_family == UInt8(AF_LINK),
                  let raw = ifa.pointee.ifa_data else { continue }
            let name = String(cString: ifa.pointee.ifa_name)
            let d = raw.assumingMemoryBound(to: if_data.self).pointee
            func add(_ g: inout IfCounts) {
                g.rxB &+= d.ifi_ibytes; g.txB &+= d.ifi_obytes
                g.rxP &+= d.ifi_ipackets; g.txP &+= d.ifi_opackets
            }
            if name.hasPrefix("en") { add(&c.wifi) }
            else if name.hasPrefix("pdp_ip") { add(&c.cell) }
            else if name.hasPrefix("awdl") || name.hasPrefix("llw") { add(&c.p2p) }
        }
        return c
    }
}

// MARK: - Bursts and symbols

/// One burst of traffic: activity bounded by ~200 ms of quiet (or cut at 4 s, so a long
/// stream becomes a run of large bursts).
struct Burst {
    var start: TimeInterval
    var end: TimeInterval
    var up = 0.0          // bytes sent
    var down = 0.0        // bytes received
    var packets = 0.0
    var cellBytes = 0.0

    var bytes: Double { up + down }
    var duration: Double { max(0, end - start) }
    var meanPacket: Double { packets > 0 ? bytes / packets : 0 }
    var onCell: Bool { cellBytes > bytes / 2 }
}

/// The gait alphabet: direction × size, six letters. Like Morse, a single letter means little;
/// it's the words (the last three letters) that become motifs.
struct GaitSymbol: Equatable {
    var up: Bool          // the phone mostly sent (↑) or mostly received (↓)
    var size: Int         // 0 small, 1 medium, 2 large

    /// Size bins, in bytes per burst. First guesses: tune them from a recorded traffic log.
    static let smallBelow = 8_000.0
    static let largeFrom = 250_000.0

    init(_ b: Burst) {
        up = b.up > b.down
        size = b.bytes < GaitSymbol.smallBelow ? 0 : (b.bytes < GaitSymbol.largeFrom ? 1 : 2)
    }

    var text: String { (up ? "↑" : "↓") + ["s", "M", "L"][size] }
}

/// Watches the counters ~15 times a second and reports each finished burst.
/// Peer-to-peer links are left out: they carry the duo's own messages, and Leitmotif
/// shouldn't sing about itself.
final class GaitSensor {
    /// Bytes in one ~67 ms sample that count as "active" (a couple of small packets).
    static let activeBytes = 600.0
    static let quietSamplesToEnd = 3
    static let maxBurst = 4.0

    var onBurst: ((Burst) -> Void)?
    /// Every raw sample (for the traffic log): time, Wi-Fi, cellular and peer-to-peer deltas.
    var onSample: ((TimeInterval, IfDelta, IfDelta, IfDelta) -> Void)?

    private var last: Counters?
    private var current: Burst?
    private var quiet = 0

    func reset() {
        last = nil
        current = nil
        quiet = 0
    }

    func sample(now: TimeInterval) {
        guard let c = Counters.read() else { return }
        defer { last = c }
        guard let l = last else { return }
        let w = c.wifi.minus(l.wifi), m = c.cell.minus(l.cell), p = c.p2p.minus(l.p2p)
        guard w.plausible, m.plausible, p.plausible else { return }
        onSample?(now, w, m, p)

        let bytes = w.bytes + m.bytes
        let packets = w.packets + m.packets
        if bytes >= GaitSensor.activeBytes && packets >= 2 {
            if current == nil { current = Burst(start: now, end: now) }
            current!.up += w.txB + m.txB
            current!.down += w.rxB + m.rxB
            current!.packets += packets
            current!.cellBytes += m.bytes
            current!.end = now
            quiet = 0
            if now - current!.start >= GaitSensor.maxBurst { finish() }
        } else if current != nil {
            quiet += 1
            if quiet >= GaitSensor.quietSamplesToEnd { finish() }
        }
    }

    private func finish() {
        if let b = current { onBurst?(b) }
        current = nil
        quiet = 0
    }
}

// MARK: - Traffic log (the probe)

/// Writes every raw sample to a CSV in the app's Documents folder (visible in the Files app),
/// for tuning the burst thresholds and size bins against real use.
final class TrafficLog {
    let url: URL
    private let handle: FileHandle
    private var buffer = ""
    private var lines = 0
    private let t0: TimeInterval

    init?(now: TimeInterval) {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd-HHmmss"
        guard let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else { return nil }
        url = dir.appendingPathComponent("leitmotif-traffic-\(f.string(from: Date())).csv")
        let header = "t,wifi_rx_bytes,wifi_tx_bytes,wifi_rx_pkts,wifi_tx_pkts,cell_rx_bytes,cell_tx_bytes,cell_rx_pkts,cell_tx_pkts,p2p_rx_bytes,p2p_tx_bytes\n"
        guard FileManager.default.createFile(atPath: url.path, contents: header.data(using: .utf8)),
              let h = try? FileHandle(forWritingTo: url) else { return nil }
        h.seekToEndOfFile()
        handle = h
        t0 = now
    }

    func write(_ t: TimeInterval, _ w: IfDelta, _ m: IfDelta, _ p: IfDelta) {
        func i(_ x: Double) -> String { String(Int(x)) }
        buffer += String(format: "%.3f", t - t0)
        buffer += ",\(i(w.rxB)),\(i(w.txB)),\(i(w.rxP)),\(i(w.txP)),\(i(m.rxB)),\(i(m.txB)),\(i(m.rxP)),\(i(m.txP)),\(i(p.rxB)),\(i(p.txB))\n"
        lines += 1
        if lines % 30 == 0 { flush() }
    }

    func close() {
        flush()
        try? handle.close()
    }

    private func flush() {
        guard !buffer.isEmpty, let d = buffer.data(using: .utf8) else { return }
        handle.write(d)
        buffer = ""
    }
}
