# Mochi Link: plan

**Status:** proposal, 2026-11-04. Nothing in this document is built yet.
**What it is:** a replacement for the iCloud key-value link between MacTamagotchi and Mochi Pocket. One small,
end-to-end encrypted relay that connects every Mochi app (Mac, iPhone, later Windows and Android) and Mochi Cloud,
built so the apps can be distributed to anyone, not just to devices on the InsideEdge team.

---

## 1. Why change

Today the Mac and the iPhone talk through iCloud key-value storage (KVS), and pushes go straight from the Mac to
Apple's push service (APNs) with a `.p8` key held on the Mac.

| Problem | Evidence |
|---|---|
| **Slow and throttled.** KVS is built for settings, not messages. | Session cards arrived ~4 min late on 2026-10-29; we had to put cards inside alert pushes (`card`) to get around it. LIVE_ACTIVITY.md says a phone→Mac round trip takes "a few seconds to about 15 seconds, depending on iCloud". |
| **Apple-only, same Apple ID, same developer team.** | The ad-hoc `MacTamagotchi-v4.dmg` can't link with an iPhone. Windows and Android can never read iCloud KVS. |
| **No delivery guarantees.** | KVS keeps only the latest value per key: no queue, no acknowledgements, no "who is online". The iPhone guesses the Mac is away after 15 s of silence. |
| **The push key lives in the Mac app.** | Settings › iPhone › Choose .p8, or `APNS_KEY_FILE` baked into the bundle. You can't hand that key to strangers, and every other user would need their own Apple developer account. |
| **Mochi Cloud needs a separate copy of the push key and the phone's address.** | The routine's environment holds `MOCHI_APNS_KEY_B64` and `MOCHI_DEVICE_TOKEN`, copied by hand from the Mac. |

**Why not use Mochi Cloud itself?** Mochi Cloud is a scheduled Claude Code routine. Each run starts a cloud Claude
session (~18 s, uses plan quota), does one check, sends one push and exits. It keeps nothing between runs and
can't accept messages, so it can't carry live traffic. With Link, Mochi Cloud becomes one more device in the room.

**This reverses an earlier rule.** PRIVACY.md says "There is no server", and LIVE_ACTIVITY.md recommended against a
backend. Link adds a server but keeps that rule's intent: **the server can't read anything** (section 4.3),
stores only the latest state, and deletes rooms that go quiet.

## 2. Goals and non-goals

**Goals**

1. Messages between devices arrive in **under a second** while both apps are open. When an app is in the background,
   a push wakes it.
2. **Works for anyone.** No shared Apple ID, no developer team, no `.p8` on the user's machine. You pair by scanning
   a QR code.
3. **Cross-platform from day one.** The protocol is plain JSON over WebSocket and HTTPS, with standard crypto, so
   Swift, Kotlin, C# and Python clients can all speak it.
4. **End-to-end encrypted.** The relay sees routing metadata, never content.
5. **A safe migration.** iCloud stays as a fallback until Link has proven itself, and the move costs you one QR scan.

**Not in v1:** user accounts and sign-in, sharing a pet between people, a web app, the Mac App Store (the app needs
`~/.claude`, the `claude` CLI and Accessibility, which the sandbox doesn't allow).

## 3. What exists today (inventory)

Every KVS key the apps use. In Link, each one becomes either **state** (the relay keeps only the latest value) or a
**message** (queued until delivered, then dropped).

| KVS key today | Direction | Contents | Link equivalent |
|---|---|---|---|
| `macLook` | Mac → phone | PetLook JSON (names, colours, room) | state `look` |
| `macClaude` | Mac → phone | phase, tool category, `resting` | state `claude` |
| `macSessions` | Mac → phone | PhoneSessions (cards + summaries) | state `sessions` |
| `macAgent` | Mac → phone | AgentPending JSON | state `agent` |
| `macCloud` | Mac → phone | Mochi Cloud fire URL + token | state `cloud` (encrypted like everything else) |
| `macEnded` | Mac → phone | `{at, since, dismissAt}` | message `activityEnded` |
| `macInteraction` / `phoneInteraction` | both | pet/play/treat `{id, kind, at}` | message `interaction` (either way, TTL 90 s) |
| `phoneCommand` | phone → Mac | `{id, text, at, typed, project?, session?}` | message `command` → host (TTL 10 min) |
| `macReply` | Mac → phone | `{id, state, text?, at}` | message `reply` → the device that asked |
| `macApproval` | Mac → phone | pending approval request | state `approval` (cleared when answered) + alert push |
| `phoneApproval` | phone → Mac | verdict `{id, …}` | message `verdict` → host |
| `pushToStart`, `updateTokens`, `deviceToken`, `savedAt` | phone → Mac | APNs addresses | **device registration with the relay.** They never go to the Mac again. |

Push paths today:

- **Mac → APNs:** Live Activity start/update/end (`LiveActivityPayload`, a quiet update every 6 s while Claude
  works), alert pushes for finished turns (`PhoneAlertPayload.turnFinished`) and agent news
  (`PhoneAlertPayload.agentNews`).
- **Mochi Cloud → APNs:** `mochi_cloud.py push()` with its own JWT.
- **The phone's MochiNotifications service extension** already rewrites `quietIfKnown` pushes. That gives us a hook
  for decrypting pushes (4.6).

Code that touches KVS: `Sources/App/Features/Phone/PhoneController.swift`, `iOS/MochiPocket/MacLink.swift`,
`PhoneWorld.swift`, `ActivityCoordinator.swift`, `PhoneNotifications.swift`. Entitlement:
`com.apple.developer.ubiquity-kvstore-identifier` (`Signing/MacTamagotchi.entitlements`,
`iOS/Config/MochiPocket.entitlements`, `scripts/build-app.sh` `KVSTORE_ID`).

## 4. Design

### 4.1 Overview

```
   Mac app (host) ─────┐                                   ┌──── iPhone   (APNs wake-ups)
   Windows app (host) ─┼── WebSocket ─┐             ┌──────┼──── Android  (FCM wake-ups)
                       │              ▼             │      │
                       │      ┌──────────────────┐  │      │
                       │      │    Mochi Link    │──┘      │
                       │      │  relay, one room │── push gateway ── APNs / FCM
                       │      │  per household   │
                       │      └──────────────────┘
                       │              ▲
   Mochi Cloud routine ┴── HTTPS POST ┘   (agent news only)
```

- A **room** is one household: the devices that share one Mochi. The first host (usually the Mac) creates it.
- Each device has a **role**: `host` (Mac, Windows: runs Claude Code, Ask Mochi, the agent), `pocket` (iPhone,
  Android) or `cloud` (Mochi Cloud: can only post agent news and `agent` state).
- Everything that runs Claude (Ask Mochi, approvals, the agent) **stays on the host**. Link only moves messages.

### 4.2 Pairing

1. **Mac:** Settings › Devices › Add a device. If there's no room yet, the Mac creates one (`POST /v1/rooms`), gets
   its own device credential, and generates the **room key K** (32 random bytes, kept in the Keychain and never
   sent to the relay). It then asks for an invite (`POST /v1/rooms/{room}/invites`): a single-use code that
   expires in 10 minutes.
2. **The Mac shows a QR code:**
   `mochi://pair?v=1&relay=<host>&room=<roomId>&invite=<code>&key=<base64url(K)>&name=<Mac name>`
3. **The phone scans it** in Mochi Pocket (Settings › Pair with your Mac), sends `POST /v1/rooms/{room}/join` with
   the invite, and receives its own device credential (`deviceId` and a secret). The relay marks the invite as used
   and tells the room that a device joined. The Mac shows "iPhone joined ✓".
4. **Storage:** the Mac keeps K and its credential in the Keychain. iOS uses a Keychain access group shared by the
   app, MochiNotifications and the Live Activity extension. Android uses the Keystore; Windows uses DPAPI or
   Credential Locker.
5. **Desktop to desktop** (a Mac and a Windows PC, where there may be no camera): use "Copy pairing link" and paste
   it on the other machine.
6. **Removing a device:** Settings › Devices › Remove. The relay revokes that credential immediately, and the host
   rotates K: it sends the new key, encrypted under the old one, only to the devices that remain.

A QR code is a direct visual channel, so no extra fingerprint check is needed. Room IDs and invite codes are 128-bit
random values; guessing them isn't feasible.

### 4.3 Encryption

- **Algorithm:** AES-256-GCM with a 12-byte random nonce. It's available everywhere we need it: CryptoKit,
  Android JCA, .NET `AesGcm`, WebCrypto, and Python `cryptography`.
- **Associated data** (authenticated, not encrypted): `mochi-link/v1|<room>|<key>|<id>|<from>`. A message can't be
  moved to another key, room or sender without failing to decrypt.
- **The relay sees:** room ID, device IDs, roles and platforms, push tokens, key names (`command`, `look`, …),
  message sizes and times.
- **The relay never sees:** what you said, Mochi's answers, Claude's summaries, project names, mail, calendar or
  task details, or the pet's look.
- **Authenticity:** only devices holding K can produce a valid message, so a compromised relay can drop or delay
  messages but can't forge a `command`.
- **Shared test vectors:** `link-vectors.json` holds key, nonce, AD, plaintext and expected ciphertext. Every client
  (Swift, TypeScript, Python, Kotlin, C#) has a test that must reproduce them.

### 4.4 Protocol (v1)

Clients connect with a WebSocket (`GET /v1/rooms/{room}/socket` with `Authorization: Bearer <device credential>`).
Clients that can't hold a socket, such as Mochi Cloud or a script, use `POST /v1/rooms/{room}/send`.

**Envelope** (one JSON object per WebSocket frame):

```json
{
  "v": 1,
  "op": "put | send | ack | hello | sync | presence | devices | register | error",
  "key": "command",
  "id": "01JC…",                     // ULID: sortable, unique; also used to drop duplicates
  "from": "dev_8f…",                // filled in by the relay from the credential, never trusted from the client
  "to": ["host"],                    // a role or device IDs; omitted means everyone else in the room
  "at": 1762243200,
  "ttl": 600,                        // messages only; seconds before the relay drops it undelivered
  "push": {"kind": "alert", "priority": 10, "collapse": "reply-01JC…"},   // optional wake-up hint
  "nonce": "base64url",
  "box": "base64url"                 // AES-GCM ciphertext + tag of the inner JSON
}
```

**Operations**

| op | Who sends it | Meaning |
|---|---|---|
| `hello` | client | first frame: app version, platform, last cursor |
| `sync` | relay | the reply to `hello`: current state for every key + queued messages for this device + `minClientVersion` |
| `put` | client | replace a state key (`look`, `claude`, `sessions`, `agent`, `cloud`, `approval`); everyone else gets it now or at their next `sync` |
| `send` | client | a message; delivered now if the target is connected, otherwise queued (and pushed if `push` is set) |
| `ack` | client | "I've handled message id X"; the relay deletes it from the queue |
| `presence` | relay | who's connected right now (an instant "Mac is asleep" instead of a 15 s guess) |
| `register` | client | push addresses: APNs device token, Live Activity push-to-start and update tokens, FCM token, APNs environment (`sandbox`/`production`) |
| `devices` | relay | the room's device list (for Settings › Devices) |

The relay enforces which roles may send which keys. For example, `command` and `verdict` are allowed only from a
`pocket` or `host` to a `host`, and a `cloud` device may only send `agentNews` and put `agent`. The host checks the
same rules again after decrypting, using `from` from the associated data.

**Versioning:** the `/v1/` path plus `v` in the envelope. The relay's `sync` returns `minClientVersion`, so an old
app can say "please update" instead of misbehaving.

### 4.5 The relay

- **Platform:** a Cloudflare Worker with **one Durable Object per room**. It uses the WebSocket Hibernation API (no
  charge while idle) and SQLite storage. SQLite-backed Durable Objects are on the Workers Free plan.
- **Per-room tables:** `devices(id, role, platform, name, secret_hash, push_tokens, apns_env, created, last_seen)`,
  `state(key, envelope, updated)`, `queue(id, to_device, envelope, expires)`, `invites(code_hash, expires, used)`.
- **Alarms:** expire queued messages and invites, and **delete the room after 90 days without activity**.
- **Limits:** 64 KB per envelope, 8 devices per room, a per-device rate limit (bursts of ~30 messages/s,
  ~2,000/hour), 20 invites per hour per room.
- **Logs:** counts and error codes only, never envelopes.
- **Address:** `link.<your domain>`. A custom domain lets us change the host later without shipping new apps.
- **Repo:** a new `mochi-link` repository (TypeScript, Vitest with `@cloudflare/vitest-pool-workers`).
- **Open source:** consider publishing the relay so others can run their own copy. A "Relay address" setting
  (advanced) makes that possible and gives privacy-minded users a reason to trust it.

### 4.6 Push

The relay holds the push credentials as Worker secrets. **No app ships a push key any more.**

- **`PushGateway` interface** in the relay, with two implementations:
  - **APNs direct:** ES256 JWT, the same scheme as `APNsToken` in TamagotchiCore today. The community library
    `@fivesheepco/cloudflare-apns2` suggests this works from Workers, but **APNs requires HTTP/2, and we haven't
    confirmed that Workers' outbound `fetch` provides it.** That's spike 0.1.
  - **FCM HTTP v1:** needed for Android anyway. FCM can also deliver to iOS, including Live Activity start, update
    and end via `apns.live_activity_token`, so it's the fallback if direct APNs from Workers doesn't work. The cost
    is adding the Firebase SDK to Mochi Pocket.
- **When the relay pushes:** a message with a `push` hint whose target isn't connected, or that should always ping
  (approvals, finished-turn summaries, agent news). State changes don't push; the phone catches up at its next
  `sync`.
- **Alert pushes stay end-to-end encrypted.** The payload carries `box` and `nonce` with `mutable-content: 1`, and
  the existing **MochiNotifications** extension decrypts it and fills in the title and body. If decryption fails, the
  generic fallback text is "Mochi has news". On Android, an FCM *data* message is decrypted by the app, which then
  posts the notification.
- **Live Activity pushes are the one exception.** ActivityKit hands `content-state` straight to the system, and no
  extension runs first. For v1, the content state stays minimal: phase, pose frame, timer start, tool count, and
  the project name only if the existing "show project names" setting allows it. **Spike 0.2:** put ciphertext in
  `content-state` and decrypt it inside the widget view with the key from the shared Keychain group. If that works,
  this exception goes away.
- **Rate:** the Mac sends a quiet Live Activity update every 6 s while Claude works. Through the relay, that's
  ~600 pushes per working hour per user. The relay collapses Live Activity updates per activity (send the newest,
  at most one every 5 s), and distributed builds should use 10–15 s.
- **Keys:** create a new key just for Link, Topic-Specific if the portal offers it. Once Link is live, **revoke the
  keys that were on Macs or baked into builds** (`NZX7W5SU5V`, and `PBGWR4LQA9` in the cloud environment). Any build
  made with `APNS_KEY_FILE` contains its key, so never share those builds.
- **APNs environment:** development builds register as `sandbox`, TestFlight and App Store builds as `production`.
  The relay picks the host from the device's registration.

### 4.7 When a device is away

| Situation | What happens |
|---|---|
| **Mac asleep or off** | Its socket closes and the phone sees "Mac asleep since 14:02" right away (`presence`). Commands queue for 10 min; expired ones get a `reply` saying so when the Mac wakes. "Check now" goes straight to Mochi Cloud when the host is offline (today it waits 15 s). |
| **Mac wakes** | It reconnects on `NSWorkspace.didWakeNotification`, sends `hello`, and receives queued commands and verdicts. Duplicates are dropped by `id` (the `handledCommands` set already exists). |
| **Phone in the background or closed** | No socket (iOS doesn't keep one in the background). Replies, approvals, summaries and agent news arrive as encrypted alert pushes; Live Activity updates as Live Activity pushes. State waits for the next foreground `sync`. |
| **No network** | Clients keep an outbox, retry with backoff, and show "Not connected" in Settings › Devices. |

### 4.8 Mochi Cloud on Link

- Mac Settings › Agent › Mochi Cloud › **Copy Cloud Settings…** creates a `cloud` device in the room and copies
  `MOCHI_LINK_URL`, `MOCHI_LINK_ROOM`, `MOCHI_LINK_DEVICE` (its credential) and `MOCHI_LINK_KEY` (K).
- `mochi_cloud.py send` encrypts the digest and POSTs `send key=agentNews push=alert` plus `put key=agent`. **Every**
  device gets it: the phone as a push, and the Mac, Windows PC or Android phone when they connect.
- Remove `MOCHI_APNS_KEY_B64`, `MOCHI_APNS_KEY_ID`, `MOCHI_TEAM_ID`, `MOCHI_DEVICE_TOKEN`, `MOCHI_TOPIC` and
  `MOCHI_APNS_HOST` from the cloud environment (`MOCHI_TIMEZONE` stays). The routine no longer holds a push key.
- **To check:** whether the cloud environment can install the Python `cryptography` package (stdlib Python has no
  AES-GCM, and `openssl enc` doesn't support GCM). If it can't, the relay could accept the digest over HTTPS
  unencrypted from `cloud` devices only. That's a weaker option, so prefer the package.

### 4.9 Later: same-Wi-Fi fast path

When two devices are on the same network, they can talk directly over Bonjour/mDNS (Network.framework, Android NSD
and Windows DNS-SD all support it), using the same envelopes and the same K, for instant room sync. The relay
remains the source of truth for queues and pushes. This is optional and comes after everything else.

## 5. Distribution

### 5.1 What blocks distribution today

| Blocker | Why it blocks | Fix |
|---|---|---|
| iCloud KVS link | only the same Apple ID on devices signed by the InsideEdge team | Mochi Link (sections 4 and 6) |
| `.p8` push key on the Mac / baked into the app | can't be shipped; other users would need Apple developer accounts | push from the relay (4.6) |
| Mac app signed "Apple Development" + development profile | runs with iCloud only on Macs registered to the team; ad-hoc builds trigger Gatekeeper warnings | **Developer ID** signing + **notarization**. Once KVS is gone the Mac app needs no provisioning profile at all |
| No InsideEdge Developer ID certificate on this Mac (the only one belongs to Sarthak Garg's personal team, which must not be used) | can't notarize | the InsideEdge **Account Holder** creates a "Developer ID Application" certificate |
| Mochi Pocket is a development build | installs on the team's 4 registered iPhones only | **TestFlight**, then the **App Store** (needs App Store Connect access on InsideEdge) |
| Product name "MacTamagotchi — Claude Companion Edition" | "Tamagotchi" is Bandai's trademark; "Claude" is Anthropic's. Neither belongs in a product name | choose a name (e.g. "Mochi") and say "works with Claude Code". **Check the name before any public build** |
| Bundle IDs don't match (`dev.mactamagotchi.MacTamagotchi` vs `com.insideedge.mochi`) | IDs can't change after a store release; Keychain items and settings are tied to them | pick final IDs (e.g. `com.insideedge.mochi.mac`) before the first public build |
| Mochi Cloud runs on your own claude.ai account, connectors and GitHub repo | it's personal by nature | keep it optional (5.6) |

### 5.2 Mac

- **Developer ID + notarization:** `scripts/build-app.sh` already accepts `SIGN_IDENTITY`. Add `--timestamp` and
  a `notarytool submit --wait` + `stapler staple` step, using credentials the user stores once with
  `xcrun notarytool store-credentials`.
- **DMG** with a signed, notarized app; universal (arm64 + x86_64), as the v4 DMG already is.
- **Auto-updates:** Sparkle 2 with an EdDSA-signed appcast hosted on your site or GitHub Releases.
- **Requirements to list on the download page:** macOS 26+ (SpeechAnalyzer) and Claude Code installed and
  logged in.

### 5.3 iPhone

- App Store Connect record for `com.insideedge.mochi` (+ `.LiveActivity`, `.Notifications`), production
  `aps-environment`, and a TestFlight external beta first.
- **App Review:** the app needs a Mac to be useful, so add **"Try without a Mac"** (demo room plus the existing
  demo Live Activity animation) and review notes with a short video of pairing. Usage strings: camera (QR),
  microphone, speech recognition.
- **Privacy:** a privacy policy URL and App Privacy labels (push tokens and device IDs, for app functionality, not
  linked to identity, no tracking). Answer the export-compliance questions (we use standard AES-GCM) and check
  whether a self-classification report applies.

### 5.4 Android and Windows

- **Android:** Kotlin + Jetpack Compose; FCM for wake-ups; Play Console ($25 one-time); notification permission
  on Android 13+. Roles: `pocket`.
- **Windows:** a tray app that does what the Mac app does (Claude Code hooks, Ask Mochi, agent). Claude Code runs
  on Windows, so the hook helper needs a Windows port. Sign it with a code-signing certificate or ship through the
  Microsoft Store. Role: `host`.
- **Shared code:** TamagotchiCore and the renderers are Swift and CoreGraphics. The options are Swift on Windows
  and Android (Swift has official Windows support and an Android SDK effort), Kotlin Multiplatform, or per-platform
  code. The protocol and the next point keep every option open, so **decide when Phase 8 starts.**
- **Art:** export sprite sheets from the Mac renderer (it already renders poses to files, e.g.
  `MacTamagotchi --render-listening <dir>`) so Android and Windows can show the same Mochi on day one without
  porting the drawing code.

### 5.5 Privacy and legal

- Rewrite PRIVACY.md (top paragraph, "never does", and rows 69–74) to say: one relay, end-to-end encrypted, what it
  sees (4.3), retention (latest state only; messages deleted on delivery or after their TTL; rooms deleted after 90
  days of quiet).
- Publish the privacy policy as a web page (App Store and Play require a URL).
- Running a service for other people means having a way to delete a room on request: Settings › Devices ›
  "Delete this Mochi's link" calls `DELETE /v1/rooms/{room}`. Check obligations under India's DPDP Act and the GDPR
  for EU users. E2E encryption and no accounts keep the personal data held to a minimum.

### 5.6 Mochi Cloud for other people

Mochi Cloud needs a claude.ai plan with routines, the user's own connectors and a GitHub repo, so it can't be a
shared service on your account. Options:

1. **Optional, bring your own (recommended):** a guide plus the `mochi-cloud` template repo. The Mac's "Copy Cloud
   Settings…" already produces the environment block, and with Link that block no longer contains a push key.
2. **Mac-only agent** for everyone else: the agent already runs locally whenever the Mac is awake.

### 5.7 Costs (rough, check current prices)

| Item | Cost |
|---|---|
| Cloudflare Workers + Durable Objects | Free tier (100k requests/day; incoming WebSocket messages billed 20:1) covers the beta; Workers Paid is $5/month after that |
| Domain | ~$10–15/year |
| Apple Developer Program | already paid (InsideEdge) |
| Google Play | $25 once |
| Windows code signing | a certificate (~$100–400/year) or the Microsoft Store |
| FCM | free |

A user with Claude working for an hour generates ~600 Live Activity messages, which is ~30 billed requests.

### 5.8 Security

- **Link is a remote control for a computer that runs Claude Code.** The protections:
  - E2E authenticity: no K, no valid command.
  - Replay protection: the `id` dedupe set, freshness checks on `at` (90 s for interactions), and TTLs.
  - Every per-session action still goes through the Mac's approval card, as it does today.
  - Revoke and rotate per device (4.2).
- The Mac shows which device sent a command ("from Rizul's iPhone").
- Credentials are stored per device; only hashes are kept on the relay.
- Abuse: size and rate limits, room caps, quiet-room deletion. Later, if needed, App Attest (iOS) and Play Integrity
  (Android) checks on `join`.

## 6. Code changes

| Where | Change |
|---|---|
| `Sources/TamagotchiCore/Link/` (new; builds for iOS too) | `LinkStore` protocol (state get/put, send, observe, presence), `LinkEnvelope` (Codable), `LinkCrypto` (AES-GCM + AD), `PairingCode` (QR URL parse/format), `LinkKeys` (the key names and roles from section 3), tests + `link-vectors.json` |
| Same | `ICloudLinkStore`: today's behaviour behind the protocol (phase 1) |
| Same | `RelayLinkStore`: `URLSessionWebSocketTask`, outbox, backoff, `hello`/`sync`, presence |
| `Sources/App/Features/Phone/PhoneController.swift` | use `LinkStore` instead of `NSUbiquitousKeyValueStore`; Live Activity and alerts become `send` with a `push` hint instead of direct APNs; remove `signingKey`/`.p8` handling once phase 4 lands |
| `Sources/App/Features/Phone/PhoneSettingsView.swift` | becomes **Settings › Devices**: QR, device list, presence, remove, "Delete link", relay address (advanced) |
| `Sources/App/Features/Agent/` | Copy Cloud Settings… creates a `cloud` device (4.8) |
| `iOS/MochiPocket/MacLink.swift`, `PhoneWorld.swift`, `ActivityCoordinator.swift`, `PhoneNotifications.swift` | use `LinkStore`; tokens go to `register`, not to KVS |
| `iOS/MochiPocket/` (new) | pairing screen with QR scanner (VisionKit `DataScannerViewController`), "Try without a Mac" demo |
| `iOS/MochiNotifications/` | decrypt `box` into title/body (keeps the existing `quietIfKnown` logic) |
| `iOS/Tools/generate_project.py` | Keychain access group for app + extensions, camera usage string; later drop the KVS entitlement |
| `scripts/build-app.sh` | notarization step; later drop `KVSTORE_ID` and the provisioning-profile path |
| `mochi-cloud/mochi_cloud.py` | `send` posts to Link instead of APNs |
| `mochi-link/` (new repo) | the Worker, Durable Object, push gateway, tests |
| Docs | ARCHITECTURE.md, LIVE_ACTIVITY.md, PRIVACY.md, SETUP.md, TROUBLESHOOTING.md, README |

## 7. Phases

"Session" means one working session like the ones so far. Each phase ends with the full test suite green and the
app installed and tried on the real Mac and iPhone.

| # | Phase | Effort | Done when |
|---|---|---|---|
| 0 | **Spikes:** (0.1) APNs from a Worker over HTTP/2, else FCM → iOS incl. Live Activity; (0.2) decrypting Live Activity state in the widget; (0.3) AES-GCM test vectors matching in Swift, TypeScript and Python; (0.4) `cryptography` in the Mochi Cloud environment | ½–1 | each spike has a yes/no answer written into this file |
| 1 | **`LinkStore` refactor** with `ICloudLinkStore`, no behaviour change | 1 | 360+ tests pass; Mac ↔ iPhone works exactly as before |
| 2 | **Relay MVP:** rooms, invites, join, socket, state, queue, presence, HTTP send, limits, alarms; deployed to `workers.dev` | 1–2 | Worker tests pass; two scripted clients exchange encrypted messages |
| 3 | **Pairing + E2E in the apps:** Settings › Devices, QR, Pocket scanner, `RelayLinkStore`; iCloud and Link both on behind a setting (Link wins, iCloud is the fallback) | 1–2 | you scan once; commands and replies arrive in < 1 s; presence shows "Mac asleep" |
| 4 | **Push through the relay:** `register`, encrypted alerts + MochiNotifications decrypt, Live Activity start/update/end, collapse; remove `.p8` from the Mac app | 1–2 | summaries, approvals, agent news and Live Activity work with no key on the Mac |
| 5 | **Mochi Cloud on Link** | ½ | a test fire reaches the phone and the Mac via Link; APNs vars removed from the cloud env |
| 6 | **Turn off iCloud:** remove `ICloudLinkStore`, KVS entitlement and the profile requirement; revoke old push keys; update docs | ½ | the Mac app builds and links with only a Developer ID (or ad-hoc) signature |
| 7 | **Apple distribution:** name + bundle IDs, Developer ID + notarization + Sparkle, TestFlight, privacy policy page, App Store submission | 1–2 of work + Apple review time | a stranger can download the DMG, install Pocket from TestFlight/App Store, scan, and it works |
| 8 | **Android app** (`pocket`): Link client, FCM, sprite-sheet Mochi, room, talk, cards | several | Android pairs with a Mac and does what Pocket does |
| 9 | **Windows app** (`host`): tray app, hook helper port, Ask Mochi, agent, Link host | several | Windows PC pairs with iPhone/Android |
| 10 | **Same-Wi-Fi fast path** (optional) | 1 | room sync is instant on one network |

**Mac + iPhone on Link and ready to distribute is about 7–10 sessions** (phases 0–7), plus waiting on Apple
(certificates, TestFlight review, App Review).

## 8. Risks

| Risk | Mitigation |
|---|---|
| Workers can't speak HTTP/2 to APNs | spike 0.1 first; FCM HTTP v1 handles iOS (incl. Live Activity) and Android; a small container push sender is the last resort |
| Live Activity content can't be E2E | spike 0.2; otherwise keep content minimal and say so in PRIVACY.md |
| App Review rejects an app that needs a Mac | "Try without a Mac" demo + review notes and video |
| Trademark trouble with the name | rename before the first public build |
| Running a service (uptime, incidents, deletion requests) | tiny surface, nothing readable stored, auto-delete, one status check in Settings › Devices; the relay can be swapped via the domain |
| Push budgets and throttling for frequent Live Activity updates | relay-side collapse, 10–15 s cadence in distributed builds, priority 5 for quiet updates |
| One shared room key: a removed device knew the old K | relay revocation + key rotation (4.2) |

## 9. Decisions needed from you

- [ ] **Hosting:** Cloudflare (recommended). Who owns the account (InsideEdge)?
- [ ] **Domain** for the relay (`link.<domain>`).
- [ ] **Product name and bundle IDs** for the public release.
- [ ] **Apple access:** who is the Account Holder of InsideEdge (CZDJF6N2RH)? Needed: Developer ID Application
      certificate, App Store Connect access, a new APNs key for Link.
- [ ] **No accounts in v1** (pairing only). Confirm.
- [ ] **Mochi Cloud for others:** optional bring-your-own guide (recommended) or keep it personal.
- [ ] **Open-source the relay?**
- [ ] **Free or paid?** (paid would need accounts and billing, which changes phase 7).
- [ ] **Android and Windows technology** (decide at phase 8).

## Sources checked

- Cloudflare Durable Objects pricing and free-plan SQLite support:
  <https://developers.cloudflare.com/durable-objects/platform/pricing>,
  <https://developers.cloudflare.com/durable-objects/changelog/>
- Firebase Cloud Messaging Live Activity support: <https://firebase.google.com/docs/cloud-messaging/ios/live-activity>
- APNs client for Workers (community): <https://npmjs.com/package/@fivesheepco/cloudflare-apns2>
