# Leitmotif

Your iPhone's own data traffic, sung as a solo melody. It's the third voice alongside [Aether Wave](https://github.com/samuelling/aether), which plays the radio room, and Bellweathered, which plays the sky.

Every app on a phone has to look up a server's name (`instagram.com`, `api.spotify.com`, `app-measurement.com`) before it can talk to it. Leitmotif hears every one of those lookups, even while you're in other apps, and gives each service its own short musical motif. Instagram always sounds like Instagram. Over a day your habits turn into recurring themes, the way a character in an opera gets a leitmotif.

## How it listens

Think of reading a house from the street. You can't see inside, but two things give it away:

- **The address book.** Leitmotif installs an on-device "VPN" that carries only one thing: the phone's name lookups (DNS). The tunnel claims a single made-up address, `10.111.0.53`, and tells iOS to use it as the resolver. Each lookup goes there, Leitmotif notes the name, passes the question to a real resolver (Cloudflare, Quad9 or Google, your choice), and hands the answer back. All other traffic goes out exactly as it would without Leitmotif. The tunnel never sees a byte of your messages, video or browsing.
- **The water meter.** The app also reads the phone's total bytes in and out over Wi-Fi and cellular from the system's interface counters. That tells it how hard the phone is talking right now, not to whom.

Names live only in memory, never on disk, and nothing is sent anywhere except the lookups to the resolver you chose. If the app stops asking for five minutes, the tunnel closes itself and the phone's DNS goes back to normal.

## How the traffic becomes music

| Traffic | Music |
|---|---|
| Each service's domain (`cdninstagram.com`), hashed | Its leitmotif: 2 to 4 notes, starting on a chord tone, with a fixed contour and rhythm. The same in every session and on every phone |
| Subdomains (`api.`, `cdn.`, `www.`) | Family resemblance: same motif, last note varied |
| Apps and the web | Sung by the soloist in the middle register |
| Apple and system chatter (`apple.com`, `icloud.com`) | The same voice, an octave down and softer: the phone murmuring to itself |
| Trackers, analytics and ads | Tiny high "whisper" blips on the off-sixteenths, panned wide |
| A burst of lookups (opening an app fires 20 to 50) | A backlog: the soloist talks faster and says less, two notes per name, and the oldest names get dropped |
| The same service again while it's still queued | Merged, not repeated |
| Download rate | Loudness, brightness and vibrato depth |
| Upload rate | Breath: the phone exhaling |
| Heavy traffic with no new names (a stream, a download) | A low hum on the chord root every couple of bars |
| Silence | Rests |

The soloist is one monophonic, legato voice: a sine with a little triangle through a soft lowpass, portamento between notes, delayed vibrato and breath noise. It sits in a dotted-eighth echo and a hall. Notes are scheduled on a beat clock owned by the audio thread, so they land on the eighth-note grid even while the app is in the background.

The tracker list is a small hand-picked set plus a few name patterns like `analytics.` and `telemetry.`. It's enough to hear the pattern, but it isn't a blocklist.

## Playing with the duo

Aether and Bellweathered lead and Leitmotif follows. It listens on the same nearby link the duo already uses and never sends anything:

- **Key and scale** come from Bellweathered, or from Aether if Bellweathered isn't there.
- **Tempo** comes from Aether.
- **The current chord** comes from Aether, so each motif starts on a tone of the chord Aether's pad is holding.

iOS drops nearby connections when an app goes to the background, which is where Leitmotif spends its life. So it latches what it last heard: key, scale and tempo stay until it hears otherwise, and it falls back to the tonic for chords. Open Leitmotif now and then to re-sync. The header shows what it's following and how long ago it heard it. With no duo around, or with **Follow the duo** off, it uses its own key, scale and tempo from Settings.

### Aether and Bellweathered

Listening needs the current Aether repo: its shared `DuoLink.swift` treats any app other than the two leads as a *listener*. The leads still pair with each other exactly as before, both invite listeners into their sessions, and a listener never invites or sends. Each lead's Settings › Duo shows "Listening in: Leitmotif" while it's connected. `Duo/` here is an identical copy of Aether's `Shared/DuoLink.swift` and `DuoControls.swift`, so change them together. Builds of Aether or Bellweathered from before this change still play together, but with Leitmotif nearby Bellweathered may refuse Aether's invite, so rebuild both.

## Install on your iPhone

The tunnel is a Network Extension, so this needs the paid Apple Developer Program. A free Apple ID can't sign it.

1. Open `Leitmotif.xcodeproj` in Xcode 16 or newer.
2. For **both** targets (**Leitmotif** and **LeitmotifTunnel**), open **Signing & Capabilities** and set **Team**. Each should show **Network Extensions → Packet Tunnel**. If Xcode says the profile is missing the capability, click **+ Capability → Network Extensions**, tick **Packet Tunnel** on both targets, and build again.
3. Choose the **Leitmotif** scheme and your iPhone, then press **▶ Run**.
4. Tap **Listen**. iOS asks *"Leitmotif Would Like to Add VPN Configurations"*. Allow it and enter your passcode. A VPN badge appears in the status bar while it listens.
5. Allow local-network access when asked, so it can find the duo.
6. Switch to other apps and use your phone. Headphones or AirPlay recommended.

**Stop** closes the tunnel and stops the sound. You can also switch it off in **Settings › VPN**.

## Notes and limits

- **What it can't hear.** Apps that encrypt their own lookups bypass the tunnel. That includes DNS-over-HTTPS in some browsers and apps with a hard-coded resolver. With iCloud Private Relay on, Safari may resolve names through the relay instead. You'll hear fewer names from those, which is itself part of the commentary.
- **DNS caching.** The phone remembers answers for a while, so a service you use constantly is looked up only every few minutes. Its motif returns like a refrain, not on every tap.
- **One VPN at a time.** If you use a real VPN, Leitmotif replaces it while listening.
- **Oversized answers.** DNS over TCP, used only for very large answers, isn't handled. Those rare lookups fail once, and the phone retries.
- **IPv6-only networks.** On some carriers the chosen resolver can't synthesize IPv6 addresses for IPv4-only sites. If something misbehaves on cellular, stop Leitmotif.
- **The water meter.** The interface counters are old BSD counters that iOS still exposes. If they ever read zero, the meter shows "—" and the music uses a fixed middle level.
- **App Store.** Apple's guidelines (5.4) require VPN apps to be published by an organization, not an individual developer. Running it from Xcode and internal TestFlight are fine.

## Code map

- `LeitmotifTunnel/PacketTunnelProvider.swift`: the tunnel. Claims the made-up resolver address, notes each lookup, forwards it over UDP to the chosen resolver with fallbacks, and answers the app's "anything new?" messages.
- `LeitmotifTunnel/DNSPacket.swift`: just enough IPv4, UDP and DNS to read a question and wrap an answer, with checksums.
- `Shared/Wire.swift`: the messages between app and tunnel, plus the resolver choices.
- `Leitmotif/Tunnel.swift`: installs, starts and stops the VPN profile, and polls the tunnel about four times a second.
- `Leitmotif/Meter.swift`: Wi-Fi and cellular byte counters, giving smoothed up and down rates.
- `Leitmotif/Score.swift`: domain grouping, the app/system/tracker split, and motifs from a stable hash (FNV-1a plus SplitMix64).
- `Leitmotif/LeitmotifModel.swift`: the conductor. Ingests lookups, manages the backlog, schedules motifs and whispers onto the grid, and follows the duo.
- `Leitmotif/MotifDSP.swift`: the soloist and whisper voices, and the lock-free note rings on the audio thread's beat clock.
- `Leitmotif/MotifEngine.swift`: the AVAudioEngine graph (delay → hall). It mixes with other audio and keeps running in the background.
- `Leitmotif/LeitmotifApp.swift`: main screen (voice orb, meters, the ledger of lookups with each motif drawn as a tiny piano roll) and settings.
- `Duo/`: the shared duo link, identical to the Aether repo's `Shared/` copies.
- `AppStore/make_icon.py`: the icon, a periodic-table tile matching the other two: Lm, element 121, mass [53] for the DNS port.
- `.github/workflows/build.yml`: compiles both targets, unsigned, on every push.
