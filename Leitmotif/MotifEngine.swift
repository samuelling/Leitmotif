import AVFoundation

/// AVAudioEngine graph:
///
///   MotifDSP ── dotted-eighth delay ── hall ── main out
///
/// The session mixes with other audio, so Leitmotif can keep singing quietly under whatever
/// you're doing (music, a video, a call's ringtone…), and the "audio" background mode keeps
/// it running while you're in other apps.
final class MotifEngine {
    let params = MotifParams()

    private let engine = AVAudioEngine()
    private let delay = AVAudioUnitDelay()
    private let reverb = AVAudioUnitReverb()
    private var source: AVAudioSourceNode?
    private var dsp: MotifDSP?
    private var wantsRunning = false
    private var stopToken = 0
    private var observers: [NSObjectProtocol] = []
    private var lastDelay = 0.0
    private var lastWet = -1.0

    var isRunning: Bool { engine.isRunning }

    init() {
        delay.delayTime = 0.625
        delay.feedback = 32
        delay.lowPassCutoff = 2600
        delay.wetDryMix = 18
        reverb.loadFactoryPreset(.largeHall)
        reverb.wetDryMix = 34
        [delay, reverb].forEach { engine.attach($0) }

        let nc = NotificationCenter.default
        observers.append(nc.addObserver(forName: AVAudioSession.interruptionNotification,
                                        object: nil, queue: .main) { [weak self] note in
            guard let self,
                  let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  AVAudioSession.InterruptionType(rawValue: raw) == .ended else { return }
            self.resumeIfNeeded()
        })
        observers.append(nc.addObserver(forName: .AVAudioEngineConfigurationChange,
                                        object: engine, queue: .main) { [weak self] _ in
            self?.resumeIfNeeded()
        })
    }

    deinit { observers.forEach { NotificationCenter.default.removeObserver($0) } }

    /// Echo on a dotted eighth of the tempo; the busier the phone, the wetter the room.
    func setSpace(bpm: Double, busy: Double) {
        let t = 45 / max(30, bpm)
        if abs(t - lastDelay) > 0.01 {
            lastDelay = t
            delay.delayTime = t
        }
        let wet = 14 + 16 * max(0, min(1, busy))
        if abs(wet - lastWet) > 0.5 {
            lastWet = wet
            delay.wetDryMix = Float(wet)
            reverb.wetDryMix = Float(28 + 14 * max(0, min(1, busy)))
        }
    }

    func start() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
        try session.setActive(true)
        if source == nil { buildGraph() }
        wantsRunning = true
        stopToken += 1
        params[.master] = 1
        if !engine.isRunning { try engine.start() }
    }

    /// Fade out, let the hall ring, then pause.
    func stop() {
        wantsRunning = false
        params[.master] = 0
        stopToken += 1
        let token = stopToken
        DispatchQueue.main.asyncAfter(deadline: .now() + 4.0) { [weak self] in
            guard let self, token == self.stopToken, !self.wantsRunning else { return }
            self.engine.pause()
        }
    }

    private func resumeIfNeeded() {
        guard wantsRunning, !engine.isRunning else { return }
        try? AVAudioSession.sharedInstance().setActive(true)
        try? engine.start()
    }

    private func buildGraph() {
        var sampleRate = engine.outputNode.outputFormat(forBus: 0).sampleRate
        if sampleRate <= 0 { sampleRate = 48_000 }
        guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2) else { return }
        let dsp = MotifDSP(sampleRate: Float(sampleRate), params: params)
        let node = AVAudioSourceNode(format: format) { _, _, frameCount, ablPointer in
            let buffers = UnsafeMutableAudioBufferListPointer(ablPointer)
            guard buffers.count >= 2,
                  let l = buffers[0].mData?.assumingMemoryBound(to: Float.self),
                  let r = buffers[1].mData?.assumingMemoryBound(to: Float.self) else { return noErr }
            dsp.render(frames: Int(frameCount), left: l, right: r)
            return noErr
        }
        engine.attach(node)
        engine.connect(node, to: delay, format: format)
        engine.connect(delay, to: reverb, format: format)
        engine.connect(reverb, to: engine.mainMixerNode, format: format)
        engine.mainMixerNode.outputVolume = 0.9
        engine.prepare()
        source = node
        self.dsp = dsp
    }
}
