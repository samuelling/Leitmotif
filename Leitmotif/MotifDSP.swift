import Foundation

/// Control surface shared between the main thread and the audio thread, in the same style as
/// Aether's `DroneParams`: plain aligned stores, no locks, no allocation on the audio thread.
///
/// Notes travel in two rings, each scheduled on a beat clock that the audio thread owns, so
/// they land on the grid sample-accurately however late the main thread runs (it may be in
/// the background behind another app). The main thread *stages* a note into a slot and
/// *publishes* it on its next tick, so the audio thread never sees a slot half-written.
final class MotifParams {
    static let ring = 64

    enum G: Int, CaseIterable {
        case master, bpm
        case bright         // 0…1  download level: louder, brighter, more vibrato
        case breath         // 0…1  upload level: air in the tone
        case whisperGain
    }

    // Lead ring: one monophonic, legato voice
    let lBeat: UnsafeMutablePointer<Double>
    let lFreq: UnsafeMutablePointer<Float>
    let lVel: UnsafeMutablePointer<Float>
    let lDur: UnsafeMutablePointer<Float>       // beats the note is held
    let lPan: UnsafeMutablePointer<Float>
    // Whisper ring: tiny high blips for trackers
    let wBeat: UnsafeMutablePointer<Double>
    let wFreq: UnsafeMutablePointer<Float>
    let wVel: UnsafeMutablePointer<Float>
    let wPan: UnsafeMutablePointer<Float>
    /// [0] lead published, [1] whisper published (main writes);
    /// [2] lead consumed, [3] whisper consumed (audio writes).
    let counts: UnsafeMutablePointer<Int>
    /// [0] the audio thread's beat clock. [1] lead loudness, [2] whisper loudness (for the UI).
    let clock: UnsafeMutablePointer<Double>

    private let g: UnsafeMutablePointer<Float>
    // Main-thread bookkeeping
    private var stagedLead = 0
    private var stagedWhisper = 0

    init() {
        func f(_ v: Float) -> UnsafeMutablePointer<Float> {
            let p = UnsafeMutablePointer<Float>.allocate(capacity: MotifParams.ring)
            p.initialize(repeating: v, count: MotifParams.ring)
            return p
        }
        func d() -> UnsafeMutablePointer<Double> {
            let p = UnsafeMutablePointer<Double>.allocate(capacity: MotifParams.ring)
            p.initialize(repeating: 0, count: MotifParams.ring)
            return p
        }
        lBeat = d(); lFreq = f(440); lVel = f(0); lDur = f(1); lPan = f(0)
        wBeat = d(); wFreq = f(1760); wVel = f(0); wPan = f(0)
        counts = UnsafeMutablePointer<Int>.allocate(capacity: 4)
        counts.initialize(repeating: 0, count: 4)
        clock = UnsafeMutablePointer<Double>.allocate(capacity: 3)
        clock.initialize(repeating: 0, count: 3)
        g = UnsafeMutablePointer<Float>.allocate(capacity: G.allCases.count)
        g.initialize(repeating: 0, count: G.allCases.count)
        g[G.bpm.rawValue] = 72
        g[G.whisperGain.rawValue] = 1
    }

    deinit {
        [lFreq, lVel, lDur, lPan, wFreq, wVel, wPan, g].forEach { $0.deallocate() }
        lBeat.deallocate(); wBeat.deallocate(); counts.deallocate(); clock.deallocate()
    }

    subscript(_ k: G) -> Float {
        get { g[k.rawValue] }
        set { g[k.rawValue] = newValue }
    }

    var nowBeat: Double { clock[0] }

    // MARK: Main thread

    /// Make last tick's staged notes visible to the audio thread. Call first thing each tick.
    func publish() {
        counts[0] = stagedLead
        counts[1] = stagedWhisper
    }

    @discardableResult
    func stageLead(beat: Double, freq: Double, vel: Double, beats: Double, pan: Float) -> Bool {
        guard stagedLead - counts[2] < MotifParams.ring - 1 else { return false }
        let i = stagedLead % MotifParams.ring
        lBeat[i] = beat; lFreq[i] = Float(freq); lVel[i] = Float(vel); lDur[i] = Float(beats); lPan[i] = pan
        stagedLead += 1
        return true
    }

    @discardableResult
    func stageWhisper(beat: Double, freq: Double, vel: Double, pan: Float) -> Bool {
        guard stagedWhisper - counts[3] < MotifParams.ring - 1 else { return false }
        let i = stagedWhisper % MotifParams.ring
        wBeat[i] = beat; wFreq[i] = Float(freq); wVel[i] = Float(vel); wPan[i] = pan
        stagedWhisper += 1
        return true
    }
}

/// The soloist: one breathy, singing lead (sine and a little triangle through a soft lowpass,
/// with portamento between legato notes, delayed vibrato and breath noise), plus four tiny
/// "whisper" voices that tick quietly over the top whenever a tracker phones home.
final class MotifDSP {
    private let sr: Float
    private let p: MotifParams
    private let N = MotifParams.ring

    private var beat: Double = 0
    private var lTail = 0
    private var wTail = 0
    private var master: Float = 0

    // Lead voice
    private var ph: Float = 0
    private var freq: Float = 440
    private var target: Float = 440
    private var env: Float = 0
    private var stage = 0                 // 0 idle, 1 attack, 2 sustain, 3 release
    private var hold = 0                  // samples left before release
    private var vel: Float = 0
    private var velNow: Float = 0
    private var gl: Float = 0.7, gr: Float = 0.7
    private var vibPh: Float = 0
    private var vibRamp: Float = 0
    private var lp: Float = 0
    private var n1: Float = 0, n2: Float = 0
    private var noise: UInt32 = 22_222
    private var bright: Float = 0
    private var breath: Float = 0

    // Whisper voices
    private static let wv = 4
    /// Per-voice state as raw buffers (no array copy-on-write checks on the audio thread).
    private let wPh: UnsafeMutablePointer<Float>
    private let wF: UnsafeMutablePointer<Float>
    private let wEnv: UnsafeMutablePointer<Float>
    private let wVel: UnsafeMutablePointer<Float>
    private let wL: UnsafeMutablePointer<Float>
    private let wR: UnsafeMutablePointer<Float>
    private var wNext = 0

    private let atk: Float, dec: Float, rel: Float, glide: Float, vibIn: Float, wDec: Float
    private let twoPi = 2 * Float.pi

    init(sampleRate: Float, params: MotifParams) {
        sr = sampleRate
        p = params
        atk = 1 - expf(-1 / (0.030 * sampleRate))
        dec = 1 - expf(-1 / (0.400 * sampleRate))
        rel = expf(-1 / (0.220 * sampleRate))
        glide = 1 - expf(-1 / (0.055 * sampleRate))
        vibIn = 1 - expf(-1 / (0.45 * sampleRate))
        wDec = expf(-1 / (0.075 * sampleRate))
        func buf(_ v: Float) -> UnsafeMutablePointer<Float> {
            let b = UnsafeMutablePointer<Float>.allocate(capacity: MotifDSP.wv)
            b.initialize(repeating: v, count: MotifDSP.wv)
            return b
        }
        wPh = buf(0); wF = buf(1760); wEnv = buf(0); wVel = buf(0); wL = buf(0.7); wR = buf(0.7)
    }

    deinit {
        [wPh, wF, wEnv, wVel, wL, wR].forEach { $0.deallocate() }
    }

    @inline(__always) private func rand() -> Float {
        noise = noise &* 1_664_525 &+ 1_013_904_223
        return Float(Int32(bitPattern: noise)) / Float(Int32.max)
    }

    private func startLead(_ i: Int, bpm: Float) {
        target = max(40, p.lFreq[i])
        vel = p.lVel[i]
        if env < 0.03 {                  // from silence: no glide, vibrato starts over
            freq = target
            vibRamp = 0
        }
        stage = 1
        hold = Int(max(0.05, p.lDur[i] * 60 / bpm * 0.92) * sr)
        let pan = max(-1, min(1, p.lPan[i]))
        let a = (pan + 1) * Float.pi / 4
        gl = cosf(a); gr = sinf(a)
    }

    private func startWhisper(_ i: Int) {
        let v = wNext
        wNext = (wNext + 1) % MotifDSP.wv
        wF[v] = p.wFreq[i]
        wVel[v] = p.wVel[i]
        wEnv[v] = 1
        wPh[v] = 0
        let pan = max(-1, min(1, p.wPan[i]))
        let a = (pan + 1) * Float.pi / 4
        wL[v] = cosf(a); wR[v] = sinf(a)
    }

    func render(frames: Int, left L: UnsafeMutablePointer<Float>, right R: UnsafeMutablePointer<Float>) {
        guard frames > 0 else { return }
        let bpm = max(30, min(200, p[.bpm]))
        let beatStep = Double(bpm) / 60 / Double(sr)
        let lHead = p.counts[0], wHead = p.counts[1]
        let mTarget = p[.master]
        let brightT = p[.bright], breathT = p[.breath]
        let wGain = p[.whisperGain]
        var peak: Float = 0, wPeak: Float = 0

        for n in 0..<frames {
            beat += beatStep
            if lTail < lHead, p.lBeat[lTail % N] <= beat {
                startLead(lTail % N, bpm: bpm)
                lTail += 1
            }
            if wTail < wHead, p.wBeat[wTail % N] <= beat {
                startWhisper(wTail % N)
                wTail += 1
            }
            master += (mTarget - master) * 0.0004
            bright += (brightT - bright) * 0.0002
            breath += (breathT - breath) * 0.0002
            velNow += (vel - velNow) * 0.003

            // Lead envelope
            switch stage {
            case 1:
                env += (1.05 - env) * atk
                if env >= 1 { env = 1; stage = 2 }
                hold -= 1
            case 2:
                env += (0.78 - env) * dec
                hold -= 1
                if hold <= 0 { stage = 3 }
            case 3:
                env *= rel
                if env < 0.0001 { env = 0; stage = 0 }
            default:
                break
            }
            if stage == 1, hold <= 0 { stage = 3 }

            var l: Float = 0, r: Float = 0
            if stage != 0 {
                freq += (target - freq) * glide
                vibRamp += (1 - vibRamp) * vibIn
                vibPh += 5.2 / sr
                if vibPh >= 1 { vibPh -= 1 }
                let cents = (8 + 26 * bright) * vibRamp
                let f = freq * (1 + 0.000578 * cents * sinf(twoPi * vibPh))
                ph += f / sr
                if ph >= 1 { ph -= 1 }
                let tri = ph < 0.5 ? 4 * ph - 1 : 3 - 4 * ph
                let tone = sinf(twoPi * ph) + bright * (0.32 * tri + 0.14 * sinf(2 * twoPi * ph))
                let fc = min(9000, f * (1.6 + 6 * bright))
                lp += (tone - lp) * min(1, twoPi * fc / sr)
                let w = rand()
                n1 += (w - n1) * 0.35
                n2 += ((w - n1) - n2) * 0.5            // a soft high hiss
                let air = n2 * (0.06 + 0.5 * breath)
                let s = (lp * 0.55 + air) * env * velNow
                l = s * gl
                r = s * gr
                peak = max(peak, env * velNow)
            }

            // Whispers
            for v in 0..<MotifDSP.wv where wEnv[v] > 0.0005 {
                wPh[v] += wF[v] / sr
                if wPh[v] >= 1 { wPh[v] -= 1 }
                let e = wEnv[v] * wEnv[v]
                let s = (sinf(twoPi * wPh[v]) * 0.6 + rand() * 0.25 * wEnv[v]) * e * wVel[v] * 0.22 * wGain
                l += s * wL[v]
                r += s * wR[v]
                wEnv[v] *= wDec
                wPeak = max(wPeak, e * wVel[v])
            }

            L[n] = tanhf(l * master * 1.2)
            R[n] = tanhf(r * master * 1.2)
        }

        p.clock[0] = beat
        p.clock[1] = Double(peak)
        p.clock[2] = Double(wPeak)
        p.counts[2] = lTail
        p.counts[3] = wTail
    }
}
