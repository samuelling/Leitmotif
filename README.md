# Leitmotif

Your iPhone's own data traffic, sung as a solo melody. It's the third voice alongside [Aether Wave](https://github.com/samuelling/aether), which plays the radio room, and Bellweathered, which plays the sky.

Leitmotif never sees what your phone says or to whom. It reads only how much the phone sends and receives, and in what rhythm. It recognizes habits the way you'd recognize someone in the hallway by their footsteps, not their face. A video stream, a text conversation and an infinite scroll each have a different gait, and each gait gets its own short musical motif. Over a day your habits turn into recurring themes, the way a character in an opera gets a leitmotif.

## How it listens

The phone keeps running totals of bytes and packets, in and out, for each network link. Leitmotif reads them about 15 times a second, for Wi-Fi and cellular. No VPN, no special permission, no names, no content.

- **Bursts.** Traffic is cut into bursts: activity bounded by about 200 ms of quiet, or cut at 4 s so a long stream becomes a run of large bursts.
- **Letters.** Each burst becomes one of six letters, by direction (↑ mostly sent, ↓ mostly received) and size (**s** under 8 KB, **M**, **L** from 250 KB). It's like Morse code: one letter means little on its own.
- **Words.** The last three letters form a word ("↓L ↓L ↓M"), and the word seeds the motif. A recurring pattern always gets the same tune.
- **Ignored on purpose:** peer-to-peer links (AirDrop, AirPlay and the duo's own messages), so Leitmotif doesn't sing about itself.

## How the traffic becomes music

| Traffic | Music |
|---|---|
| A three-letter gait word, hashed | Its motif: 2 to 4 notes, starting on a chord tone, mostly stepwise with the odd leap, a longer last note. The same word always gets the same tune |
| Ordinary bursts | Played by the soloist in the middle register |
| *Bulk*: large received bursts of full-size packets (streams, downloads) | The same voice, an octave down and softer |
| *Chatter*: small bursts of tiny packets (pings, keep-alives, chat) | Pianissimo staccato "whispers" two octaves up, on the off-sixteenths, panned wide |
| A pile-up of bursts | A backlog: the soloist talks faster and says less (two notes per word), and the oldest words get dropped |
| The same word again while it's still queued | Merged, not repeated |
| Download rate | How hard the keys are struck, and how far the felt opens (brightness) |
| Upload rate | Tape dust: hiss and crackle rise as the phone sends |
| Heavy traffic with no new bursts (one long stream) | A low, held chord root every couple of bars |
| Silence | Rests |

The soloist plays a dusty upright piano, the one that used to be Aether's optional arpeggio. It's synthesized from scratch at launch, not recorded: stiff-string overtones, two slightly detuned strings per note, a felt hammer and thump, and a two-stage decay. Each melody note is held for its written length and then damped, like a pianist playing legato. It all sits on tape: slow wow and flutter, a bed of hiss and the odd crackle, a dotted-eighth echo and a medium hall. Notes are scheduled on a beat clock owned by the audio thread, so they land on the eighth-note grid even while the app is in the background.

### Tuning it

The burst threshold and size bins are first guesses. Settings › Traffic log › **Record traffic log** writes the raw counters to a CSV: bytes and packets in and out for Wi-Fi, cellular and peer-to-peer, about 15 times a second. Find it in Files › On My iPhone › Leitmotif, or use the share button. It holds no names and no content. Use your phone normally for an hour, then set `GaitSensor.activeBytes` and `GaitSymbol.smallBelow` / `largeFrom` from the real distributions.

## Playing with the duo

Aether and Bellweathered lead and Leitmotif follows. It listens on the same nearby link the duo already uses and never sends anything:

- **Key and scale** come from Bellweathered, or from Aether if Bellweathered isn't there.
- **Tempo** comes from Aether.
- **The current chord** comes from Aether, so each motif starts on a tone of the chord Aether's pad is holding.

iOS drops nearby connections when an app goes to the background, which is where Leitmotif spends its life. So it latches what it last heard: key, scale and tempo stay until it hears otherwise, and it falls back to the tonic for chords. Open Leitmotif now and then to re-sync. The header shows what it's following and how long ago it heard it. With no duo around, or with **Follow the duo** off, it uses its own key, scale and tempo from Settings.

The duo code (`Duo/`) is an identical copy of the Aether repo's `Shared/DuoLink.swift` and `DuoControls.swift`, so change them together. It treats any app other than the two leads as a *listener*: both leads invite it, it never invites or sends, and each lead's Settings › Duo shows "Listening in: Leitmotif".

## Install on your iPhone

1. Open `Leitmotif.xcodeproj` in Xcode 16 or newer.
2. Click the blue **Leitmotif** project icon, go to **Signing & Capabilities**, and set **Team**.
3. Choose your iPhone and press **▶ Run**.
4. Tap **Listen**, and allow local-network access when asked so it can find the duo.
5. Switch to other apps and use your phone. Headphones or AirPlay recommended.

## Notes and limits

- **Whole-phone, not per-app.** The counters cover the whole phone, so two apps talking at once blur into one gait, and background syncing is always somewhere in the mix. The same habit gives similar words on different days, not identical ones.
- **The counters** are old BSD interface counters that iOS still exposes. If they ever read zero, the meter shows "—" and nothing is sung.
- **App Store.** There's no VPN or network extension, so the App Store's VPN rule doesn't apply.

## Code map

- `Leitmotif/Gait.swift`: the interface counters by link type, the burst detector, the six-letter gait alphabet, and the traffic log.
- `Leitmotif/Meter.swift`: smoothed up and down rates, for dynamics and tape dust.
- `Leitmotif/Score.swift`: burst → word → motif, the burst/bulk/chatter voices, and the stable hash (FNV-1a plus SplitMix64).
- `Leitmotif/LeitmotifModel.swift`: the conductor. Takes bursts, manages the backlog, schedules motifs and whispers onto the grid, and follows the duo.
- `Leitmotif/Piano.swift`: the dusty upright, synthesized once at launch (moved here from Aether).
- `Leitmotif/MotifDSP.swift`: plays the piano. Melody and whisper voices with dampers, tape wow, hiss and crackle, the brightness filter, and the lock-free note rings on the audio thread's beat clock.
- `Leitmotif/MotifEngine.swift`: the AVAudioEngine graph (delay → hall). It mixes with other audio and keeps running in the background.
- `Leitmotif/LeitmotifApp.swift`: main screen (voice orb, meters, the list of gait words with each motif drawn as a tiny piano roll) and settings.
- `Duo/`: the shared duo link, identical to the Aether repo's `Shared/` copies.
- `AppStore/make_icon.py`: the icon, a periodic-table tile matching the other two: Lm, element 121, mass [1500], the size of a full packet.
- `.github/workflows/build.yml`: compiles the app, unsigned, on every push.
