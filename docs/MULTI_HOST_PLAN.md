# Multi-host Mochi Link rooms: design

> **Status: PARKED (2026-11-07).** The user doesn't want multi-host support for now and will bring it back with a better plan. Don't implement any of this unless they ask. Kept as a reference only.

**Status:** design for review, 2026-11-07. No code has been written for it yet.
**What it is:** one Mochi Link room that holds a Mac **and** a Windows PC (or several of each), so the iPhone and the
Android phone pair once and see every computer.
**Builds on:** [MOCHI_LINK_PLAN.md](MOCHI_LINK_PLAN.md) (4.1 "More than one host", 4.4 protocol, 4.6.1 push), the
relay's README (`~/Documents/developer/mochi-link`), [SPRINT_2.md](SPRINT_2.md) (W5 Copy Cloud Settings on Windows,
W6 Live Activity from a PC, W23 agent on Windows) and [SPRINT_3.md](SPRINT_3.md) (the Mac / PC switcher, Live
Activity v2, B1 approvals from the phone).

Device ids in the examples:

| Device | Role | Example id | Example name |
|---|---|---|---|
| Mac | host | `dev_IPArsdaxyR5EovoO` | BELPL-LT-636 |
| PC | host | `dev_Pc7wQm2LxN9sKd4T` | DESKTOP-7 (the real PC's name will differ) |
| iPhone | pocket | `dev_AvoLUptZQ-Qz_oZG` | iPhone |
| Android | pocket | `dev_Rm3242aZ8bYc1D0e` | realme RMX3242 |
| Mochi Cloud | cloud | `dev_Cl0udX9q8W7e6R5t` | Mochi Cloud |

In frames, `…` stands for ciphertext, nonces, secrets or room ids. Values shown as "opened" are the sealed inner JSON
(`{"v": <value>}` in the box, as today).

---

## 0. Decisions at a glance

| Question | Decision | Section |
|---|---|---|
| How a second computer joins | A host already in the room makes an invite for role `host` ("Add a Computer…"). The other computer pastes the link ("Join Another Computer…") and joins as a host. It never creates a second room. | 3 |
| A PC that already has its own room | Before switching, the join proves update access with the new credential. Then it swaps credentials and deletes the old room. Updates keep working, because any device of a room can read the feed. | 3.3 |
| Who can invite and remove | Any host can invite (phones, computers, Mochi Cloud) and can remove any device. "Unpair" becomes **Leave This Room** while another computer is in it. Deleting the room for everyone takes an explicit confirmation, which the relay also requires. | 3.4, 3.5 |
| State keys | Per-computer keys `claude.<device>`, `sessions.<device>`, `approval.<device>` and per-device `done.<device>`, following the relay's existing `done.<device>` pattern (`.`, not `@`: `@` isn't allowed in key names). One shared `look`, `agent` and `cloud`. Two new shared host keys: `room` and `laLease`. | 4 |
| The pet's look | One shared `look`. A computer that joins adopts the room's look. Any computer writes it when you change Mochi there, and the last edit wins. Friendship never goes down. | 4.3 |
| Main computer | `room.primary`, else the oldest host (your Mac). It keeps writing today's single keys for phones that haven't updated, and it answers their commands. | 2 |
| Commands | Each command goes to one computer: `to: [deviceId]` on the envelope, plus `host` inside the sealed command. The target is the computer that owns the session or notification. If there's none, it's your pick in the computer switcher. If you haven't picked, it's **Auto**: the online computer you used most recently. | 5 |
| Live Activity | One activity, driven by whoever holds `laLease`. A free lease goes to the first computer that needs it. "Needs you" on another computer takes over. A handover is an update, never a second activity, and a timestamp watermark in the lease keeps updates in order. The PC seals with K_la exactly as the Mac does. | 6 |
| Agent and Mochi Cloud | One agent computer per room (`room.agentHost`; by default the main computer, and only the Mac has an agent today). One Mochi Cloud device per room. Computers don't fail over to each other: Mochi Cloud covers a sleeping agent computer, as it does today. | 7 |
| Relay | Additive release 1.4.0: scoped keys enforced per writer and deleted with their device; `room` and `laLease`; the Link `client` version in the device list; a guard on deleting a room that holds other computers; 12 devices per room. No new role. The protocol stays at 1. | 9 |
| Old apps | Old phones keep working: they see the room as if only the main computer were in it. Old computers can't join a multi-host room, because the join flow checks. | 10 |

---

## 1. Today, and what breaks with a second computer

Each computer makes its own room. The Mac makes one when you pair the first phone (`LinkController.showCode`). The
PC makes one quietly at first launch, so it can check for updates (`LinkHost.ensureRoom`). A phone holds one
credential and one room key, so pairing it with the PC takes it out of the Mac's room.

Some multi-host groundwork already exists:

- The relay allows any number of hosts, lets any host invite and remove, refuses to remove the last host
  (`409 last_host`) and resolves `to: ["host"]` to every host.
- It already has one per-device state key, `done.<device>`, which only that device may put and which is deleted when
  the device is revoked. The apps don't use it yet.
- Alerts carry the sender's id in the clear and authenticated: `mochi.from` in the iPhone's push, and `LinkAlert.from` on
  Android.
- `LinkPeerNames.hosts` and `hostList` (Swift and Dart) sort and name several computers, and the iPhone has a
  `-demoLink both` screen (a Mac asleep and a PC online).

But if the PC joined the Mac's room with today's code:

| What | What would happen (from the code) |
|---|---|
| `look` | `PhoneSync` writes the PC's look, with friendship 0 and an empty room, on every reconnect. The Mac rewrites its own whenever it changes. The phones' room flips between the two. |
| `claude`, `sessions` | Both computers put the same keys, every few seconds while Claude works. The phones show whichever was written last, so each computer's session list keeps replacing the other's. |
| `command` | The phones send `to: ["host"]` (`LinkKey.relayTargets`), so **both computers run every request** in Ask Mochi and both reply. The phone shows the last reply. |
| `approval` / `verdict` | There's one `approval` key: one computer's card replaces the other's, and `clearApproval` on one clears the other's. |
| `macDone` / `phoneDone` | These already have two writers (the iPhone and Android both write `phoneDone`). The relay keeps only the last, so a computer that was offline sees one phone's marks at `sync` and misses the other's. A second host does the same to `macDone`. |
| Live Activity | Both computers read the iPhone's `updateTokens` and push to the same activity, each with its own timestamp counter. iOS ignores whichever looks older, the Lock Screen flips between computers, and either one's `end` closes it. |
| Unpair | `LinkController.unpair` and `LinkHost.unpair` delete the whole room, cutting off the other computer and every phone. |
| Mochi Cloud | Copy Cloud Settings adds a new `cloud` device every time and never removes the old one. A room holds at most 8 devices. |
| Wording | A phone names "the" computer (`LinkPeerNames.host`), and its status pill shows only that one. |

---

## 2. Concepts

| Term | Meaning |
|---|---|
| **Hosts, in order** | The room's devices with role `host`, in the relay's order (the order they joined; the relay's `devices` list is in rowid order). Every device sees the same order. |
| **Main computer** (primary) | `room.primary` if it names a host in the room, otherwise the **oldest host**. In your room that's the Mac. It writes the legacy single keys while the room has phones that haven't updated (4.6), and it handles commands that don't name a computer (5.2). If it leaves, the next-oldest host takes over automatically. |
| **Agent computer** | `room.agentHost` if it names a host that can run the agent, otherwise the main computer. Only this computer runs agent checks, briefings and meeting nudges, and only it writes `agent` and agent news (7). |
| **Scoped key** | A state key with one writer per device: `<base>.<deviceId>`, for example `sessions.dev_Pc7wQm2LxN9sKd4T` (29 characters; the relay's limit is 64 of `[A-Za-z0-9_.-]`). Only that device may put it; the relay deletes it when the device is removed. |
| **Addressed message** | `to: ["<deviceId>"]` on the envelope, **and** the same id as `host` inside the sealed value. The relay routes on the first. The computer checks the second, which the relay can't change. |
| **Link client version 2** | A client that understands scoped keys and addressed commands. It says so in `hello` (`"client": 2`), and the relay lists it per device (9). Today Dart sends `client: 1` and Swift sends nothing; both count as 1. |

---

## 3. Joining a second computer

### 3.1 Invite: "Add a Computer…"

Settings › Phones on the Mac and on the PC gets a second button next to **Pair a Phone…**: **Add a Computer…**.
(The tab could be renamed **Devices**, as MOCHI_LINK_PLAN.md 4.2 always called it; see the open questions.) It asks
the relay for an invite limited to role `host`:

```
POST /v1/rooms/3e46…/invites
Authorization: Bearer dev_IPArsdaxyR5EovoO.…
{"role":"host"}

201 {"invite":"Qe0kT1…","expiresAt":1793800700,"role":"host"}
```

The sheet shows the link with **Copy Link**, its QR code (for a webcam scan later), and "Works once, until 14:12":

```
mochi://pair?v=1&relay=mochi-link.spike01.workers.dev&room=3e46…&invite=Qe0kT1…&key=…&name=BELPL-LT-636&as=host
```

- `as=host` is new and optional. Today's parsers (Swift `PairingCode.init?(url:)`, Dart `PairingCode`) ignore
  parameters they don't know, so old apps aren't affected. A phone that reads `as=host` says *"This code adds a
  computer. To pair this phone, use Pair a Phone… on your Mac or PC."* without calling the relay. An old phone that
  tries anyway gets `403 invite_role` and shows its usual error.
- The link holds the room key K. The invite expires after 10 minutes and works once, but **K doesn't expire**. So the
  sheet says: "Paste this on your other computer directly, not in a chat or an email." (See the open questions about a
  safer desktop-to-desktop code.)
- The sheet closes itself when the relay announces a new `host` (`devices` frame, `change: "joined"`), the way it
  already closes when a phone joins.

### 3.2 Join: "Join Another Computer…"

On the other computer, Settings › Phones › **Join Another Computer…** opens a paste field. The steps, in order:

| # | Step | If it fails |
|---|---|---|
| 1 | Parse the link. It must be a valid version-1 code with `as=host` or no `as`. | "That isn't a Mochi link." Nothing changes. |
| 2 | **Look at this computer's current room.** If it holds phones or Mochi Cloud, the confirmation names them: *"Your iPhone and Mochi Cloud are paired with this PC. They'll have to pair again with BELPL-LT-636."* Rooms can't be merged, because each has its own K. | |
| 3 | Confirm: *"Join BELPL-LT-636's Mochi? This PC takes on BELPL-LT-636's Mochi (name and look), and your phones will see both computers."* | Cancel: nothing changes. |
| 4 | `POST /join` with role `host` (frames below). | Show the relay's reason (expired, used, `room_full`). Nothing changes. |
| 5 | **Check the room before switching.** Ask for the device list (`/send` with op `devices`). Every other host must report `client` 2 or more. The relay keeps the last `client` each device said, so a sleeping computer that is already updated still counts. | *"Update Mochi on BELPL-LT-636 first, then open it once so it connects."* Then remove itself from the new room (`DELETE /devices/<self>`) and keep the old room. |
| 6 | **Check update access** (Windows): `GET /v1/rooms/<new>/updates/windows/manifest` with the new credential. 200, 404 (nothing published) and 503 (`updates_unavailable`) all count as access. | On 401 or a network error: remove itself from the new room, keep the old one, and say so. |
| 7 | Save the new credential (DPAPI on Windows, Keychain on the Mac), replacing the old one in one write. | Remove itself from the new room and keep the old one (this is what `_makeRoom` already does when saving fails). |
| 8 | Switch `LinkHost` (Windows) or `MochiLink.use` (Mac) to the new credential, adopt the room's `look` (4.3), and start publishing its own scoped keys. | |
| 9 | Delete the old room with the old credential (`DELETE /v1/rooms/<old>`). If that fails (offline), keep the old credential in a second slot, `pendingDelete`, try once more at the next launch, then forget it. Rooms nobody touches are deleted after 90 days anyway. | |

```
POST /v1/rooms/3e46…/join
{"invite":"Qe0kT1…","role":"host","platform":"windows","name":"DESKTOP-7"}

201 {"room":"3e46…","device":"dev_Pc7wQm2LxN9sKd4T","secret":"…","role":"host"}
```

Every connected device then gets:

```json
{"v":1,"op":"devices","at":1793800120,"change":"joined","device":"dev_Pc7wQm2LxN9sKd4T","devices":[
  {"id":"dev_IPArsdaxyR5EovoO","role":"host","platform":"macOS","name":"BELPL-LT-636","app":"5.1","client":2,"online":true,"push":false,"created":1793700001,"lastSeen":1793800098},
  {"id":"dev_AvoLUptZQ-Qz_oZG","role":"pocket","platform":"iOS","name":"iPhone","app":"5.1","client":2,"online":false,"push":true,"created":1793700100,"lastSeen":1793799000},
  {"id":"dev_Rm3242aZ8bYc1D0e","role":"pocket","platform":"android","name":"realme RMX3242","app":"1.4","client":2,"online":true,"push":true,"created":1793700200,"lastSeen":1793800090},
  {"id":"dev_Cl0udX9q8W7e6R5t","role":"cloud","platform":"cloud","name":"Mochi Cloud","app":null,"client":null,"online":false,"push":false,"created":1793700300,"lastSeen":1793796400},
  {"id":"dev_Pc7wQm2LxN9sKd4T","role":"host","platform":"windows","name":"DESKTOP-7","app":null,"client":null,"online":false,"push":false,"created":1793800120,"lastSeen":1793800120}]}
```

The join is symmetric: a Mac can join a PC's room the same way, for someone who started on Windows. The Mac doesn't use
its room for updates, so step 6 is skipped there.

### 3.3 Moving a PC that already has its own room (update access)

The Windows updater asks `LinkHost.ensureRoom()` for a credential on every check (`update_feed.dart`). The relay lets
**any device of a room, of any role**, read `/updates/{platform}/…` (`allowUpdate` in `room.ts`). So:

- **After the join,** `ensureRoom()` returns the joined room's credential, and the feed works with it. Step 6 above
  checks that before anything is switched. The relay doesn't need to change.
- **If the PC is later removed, or the room is deleted,** its socket closes with 4001 or 4004 and the status becomes
  `removed`. `ensureRoom()` already makes a fresh room of its own in that case, so updates carry on. What's new is the
  explanation: Settings says *"This PC was removed from BELPL-LT-636's room. It has its own room again for updates.
  Join again…"*
- **Rollback** is the same path: **Leave This Room** on the PC (3.5) removes it from the shared room, and
  `ensureRoom()` makes it a room of its own.

### 3.4 Who can invite

| Device | Pair a Phone | Add a Computer | Copy Cloud Settings |
|---|---|---|---|
| Any host (Mac or PC) | yes | yes | yes, but it **replaces** the room's one Mochi Cloud device (7.1) |
| Phones, Mochi Cloud | no (the relay refuses: `forbidden`) | no | no |

No new limits are needed: 20 invites an hour per room covers all three kinds.

### 3.5 Removing a computer, leaving, deleting the room

| Action | Where | Relay call | What happens |
|---|---|---|---|
| **Remove…** another device (phone, computer, Mochi Cloud) | Settings › Phones › device list, on any host | `DELETE /v1/rooms/{room}/devices/{id}` | As today. A removed computer sees 4001; a PC then makes its own room for updates (3.3). |
| **Leave This Room** | Any host, when the room has **another host** | `DELETE /v1/rooms/{room}/devices/{self}` | The room, the phones and the other computer carry on. A Mac becomes unpaired (`LocalLinkStore`); a PC makes its own room for updates. |
| **Unpair** | The room's **only** host | `DELETE /v1/rooms/{room}` | As today: the room is deleted and everyone has to pair again. |
| **Delete the Room for Everyone…** | Any host, under an "Advanced" disclosure | `DELETE /v1/rooms/{room}?confirm=everyone` | Everything goes. The relay refuses a plain `DELETE` while another host is in the room (9). |

- **The main computer leaves:** the next-oldest host becomes the main computer at once (2). If old phones are still in
  the room, it starts writing the legacy keys.
- **The agent computer leaves:** `room.agentHost` names a missing device, so the main computer is the agent computer
  again. Settings › Agent says *"Mochi's agent now runs on this Mac."*
- **K isn't rotated.** Rotating it (MOCHI_LINK_PLAN.md 4.2, step 6) isn't built. A removed computer still knows K but
  no longer has a credential, which is already the case for removed phones. Rotation stays future work.

---

## 4. State keys

### 4.1 Per key

| Key today | Multi-host key | Writer | How readers combine it | Legacy key kept? |
|---|---|---|---|---|
| `look` | **`look`** (shared) | Any host, when the user changes Mochi there or its own progress changes (4.3) | Everyone applies the latest one | It is the same key |
| `claude` | **`claude.<host>`** | Each host | Phones work out one **effective mirror** (4.4) | The main computer writes `claude` with its own mirror, while needed (4.6) |
| `sessions` | **`sessions.<host>`** | Each host | Phones show **one list of every computer's sessions**, each labelled with its computer (4.4) | The main computer writes `sessions` with its own list, while needed |
| `agent` | **`agent`** (shared) | The agent computer and Mochi Cloud | Unchanged: the newest `updatedAt` wins, merged with `AgentPending.merging` | It is the same key |
| `cloud` | **`cloud`** (shared) | The host where you saved the trigger; at launch only the agent computer writes it again | The latest one | It is the same key |
| `approval` | **`approval.<host>`**, as a list | Each host | Phones show each request, labelled with its computer (4.5) | The main computer writes `approval` (one object) for its own first request, while needed |
| `macDone`, `phoneDone` | **`done.<device>`** (the relay already supports it) | Every host and phone, each its own list | Everyone takes in the union (4.5) | The main computer writes `macDone` and phones write `phoneDone`, while needed |
| `pushToStart`, `updateTokens`, `deviceToken`, `tokensSavedAt` | unchanged | The iPhone | Every host reads them: the Live Activity is the room's, not one computer's (6) | — |
| — | **`room`** (new, shared) | Any host, when you change a room setting | The latest one | — |
| — | **`laLease`** (new, shared) | The host that drives the Live Activity (6) | Hosts follow it | — |

**Value encoding:** a scoped key is encoded like its base key. `sessions.*` and `done.*` are JSON strings, like
`sessions` and `macDone` (`storedAsJsonString` in Dart, `JSONEncoder.stableString` in Swift). `claude.*`,
`approval.*`, `room` and `laLease` are dictionaries. New Swift values use `stableString` (sorted keys), or
structural comparison, for their "changed?" checks, so the rate-limit bug of 2026-11-05 can't come back.

**Checking the writer:** after opening a scoped key, readers check that the envelope's `from` (part of the associated
data) equals the key's suffix, and drop it otherwise. The relay enforces the same rule (9). The client check also
holds against a relay that can't be trusted.

### 4.2 What a phone receives (a `sync` excerpt)

```json
{"v":1,"op":"sync","at":1793800130,"room":"3e46…","device":"dev_AvoLUptZQ-Qz_oZG","role":"pocket","minClientVersion":1,
 "state":[
  {"v":1,"op":"put","key":"claude.dev_IPArsdaxyR5EovoO","id":"…","from":"dev_IPArsdaxyR5EovoO","at":1793800090,"nonce":"…","box":"…"},
  {"v":1,"op":"put","key":"claude.dev_Pc7wQm2LxN9sKd4T","id":"…","from":"dev_Pc7wQm2LxN9sKd4T","at":1793800121,"nonce":"…","box":"…"},
  {"v":1,"op":"put","key":"done.dev_AvoLUptZQ-Qz_oZG","id":"…","from":"dev_AvoLUptZQ-Qz_oZG","at":1793790000,"nonce":"…","box":"…"},
  {"v":1,"op":"put","key":"laLease","id":"…","from":"dev_IPArsdaxyR5EovoO","at":1793800090,"nonce":"…","box":"…"},
  {"v":1,"op":"put","key":"look","id":"…","from":"dev_IPArsdaxyR5EovoO","at":1793700500,"nonce":"…","box":"…"},
  {"v":1,"op":"put","key":"room","id":"…","from":"dev_IPArsdaxyR5EovoO","at":1793800125,"nonce":"…","box":"…"},
  {"v":1,"op":"put","key":"sessions.dev_IPArsdaxyR5EovoO","id":"…","from":"dev_IPArsdaxyR5EovoO","at":1793800088,"nonce":"…","box":"…"},
  {"v":1,"op":"put","key":"sessions.dev_Pc7wQm2LxN9sKd4T","id":"…","from":"dev_Pc7wQm2LxN9sKd4T","at":1793800121,"nonce":"…","box":"…"}],
 "queue":[], "devices":[…], "presence":[…]}
```

Opened values:

```jsonc
// claude.dev_Pc7wQm2LxN9sKd4T: today's ClaudeMirror plus `activeAt`
{"phase":"working","category":"edit","resting":false,"at":1793800121,"activeAt":1793800100}

// sessions.dev_Pc7wQm2LxN9sKd4T: today's PhoneSessions, unchanged (a JSON string on the wire)
{"enabled":true,"updatedAt":1793800121,"sessions":[
  {"id":"5b1e…","project":"web-app","phase":"working","phaseSince":1793800020,"files":[]}]}

// room
{"primary":"dev_IPArsdaxyR5EovoO","agentHost":"dev_IPArsdaxyR5EovoO","by":"dev_IPArsdaxyR5EovoO","at":1793800125}

// done.dev_AvoLUptZQ-Qz_oZG: today's AgentDoneList (a JSON string on the wire)
{"ids":{"mail:18c2":1793789950}}
```

- `activeAt` is new: the last time someone used that computer or Claude did something there, rounded down to the
  minute. A host rewrites it when it moves forward by at least 5 minutes, or when `resting` flips, so it doesn't add
  a write every minute. It drives the Auto target (5.1).
- `room` fields are optional. If one is missing, its default applies (main computer = oldest host; agent computer =
  main computer). `by` is only for display ("changed on DESKTOP-7").

### 4.3 The pet's look: one shared identity

The room has **one** Mochi. Its look is the shared `look` key, in today's `PetLook` shape.

| Field | Who decides |
|---|---|
| `petName`, `companionName`, `petColor`, `petAccessory`, `companionAccessory`, `deskAccessory`, `theme`, `seasonal` | **The last edit wins.** A host writes `look` when you change one of these in its Settings. Every host applies incoming identity fields to its own settings, as the phones already do (`PetLook.apply`). |
| `friendshipLevel` | **It never goes down.** A writer puts `max(its own level, the level in the room's current look)`. Only the Mac tracks friendship today; Windows will after G1 (Sprint 2). |
| `room` (furniture) | A host that has furniture (the Mac; Windows after W18) writes its own. Any other host copies the room's current value. |

Rules:

1. **Joining:** the newcomer adopts the room's look and writes nothing. The confirmation (3.2) says so.
2. **No echoes:** a host never writes `look` because it applied someone else's. On the Mac, `publishShared` compares
   with the room's current `look` (after applying it) instead of its own last write. It writes only when the
   comparison differs because of a local edit or progress.
3. Settings on the PC and on the Mac say: *"Mochi is shared with BELPL-LT-636 and your phones. Changes here show
   everywhere."*

Two edits within the same second end with whichever the relay stored last. Every device then converges on that one,
because the relay applies puts in order and a device ignores incoming values for a key while its own write to it is
unacknowledged (`pendingStateKeys`).

### 4.4 Combining sessions and Claude's state on the phones

**Sessions list:**

1. For each host H (in host order): use `sessions.H` if it exists. If it doesn't, **and H is the main computer**, use
   the legacy `sessions`; that's what a new phone does with an old computer. Otherwise H has no list.
2. Take the cards from every list with `enabled: true`, keyed by `(host, id)`, and tag each one with its host.
3. Sort: needs you (`waiting`) first, then `working`, `error`, `done`, `idle`. Within each, newest `phaseSince`
   first. Keep at most 6 per computer and 8 in all.
4. Cards that arrived with notifications (`MacLink.merge`, `pushed` cards) take their host from the alert's
   `mochi.from`.
5. A computer with `enabled: false` gets one line: *"Your PC doesn't share summaries (PC › Settings › Phones)."*
6. The computer tag (*"PC"*, *"Mac"*) shows only when the room has two or more hosts.

**Effective mirror** (what the companion in the phone's room acts out):

1. Look at the `claude.H` of each host that's **online**. A host that has been offline for up to 2 minutes still
   counts (a network blip). For the main computer, fall back to the legacy `claude` as above.
2. Rank the phases: `waiting` 5, `working` 4, `error` 3, `done` 2, `idle` 1, `none` 0. Take the highest. On a tie,
   take the newest `at`. Its `category` comes along.
3. `resting` is true only when **every** online host is resting, so Mochi sleeps on the phone only when you've left
   all your computers. With no host online, keep the last value, as today.

### 4.5 Approvals and done marks

**Approvals:** `approval.<host>` holds a list, ready for Sprint 3's B1 (several of Claude's permission prompts at
once):

```json
{"requests":[{"id":"approval-1","command":"cmd-1","target":"session-1","project":"web-app",
              "message":"Run the tests and push.","at":1793800100}]}
```

Today the Mac has at most one request, so the list has one item. Clearing an approval puts `{"requests":[]}`. A phone
shows one card per request, newest first, labelled *"Your PC asks: Send to Claude in web-app?"*. It answers with a
`verdict` addressed to that host (5.4). Requests older than 120 seconds are hidden, as today.

**Done marks:** every device puts its own list as `done.<me>`. It's the same list it shares today: its own marks plus
the marks it has taken in, trimmed to a week. Everyone takes in every `done.*`, plus the legacy `macDone` and
`phoneDone`, with the existing "taken in once" rule (`DoneMarks.takeIn` on Android, `UpdatesStore` on the iPhone,
`AgentController.phoneDoneChanged` on the Mac), so an undo still sticks. This also fixes the existing problem with two
phones (section 1). Mochi Cloud doesn't mark items done; the relay refuses `done.*` from it.

### 4.6 Backward compatibility: the legacy keys

**Rule:** the **main computer** writes the legacy keys `claude`, `sessions`, `approval` and `macDone`, using **its
own values only**, while any phone in the room reports `client` < 2, or no client at all. Phones keep writing
`phoneDone` next to `done.<me>` while any host reports `client` < 2.

- **An old phone in a multi-host room** sees the room as if only the main computer were in it. It shows that
  computer's look, Claude, sessions and approvals, and its commands (`to: ["host"]`, no `host` inside) are answered
  only by the main computer (5.2). That's exactly today's behaviour.
- **An old phone in a one-computer room** sees no change at all: that computer is the main one.
- **A new phone with an old computer** (a one-computer room): the old computer writes only legacy keys, and the
  fallback in 4.4 reads them as the main computer's.
- **Old computers in a multi-host room** aren't allowed: the join checks every host's `client` (3.2, step 5). The
  Mac sends no `client` today, so an un-updated Mac blocks the PC from joining. That's the intended order.
- **Before the first `sync`:** a host doesn't know yet whether it's the main computer, so it doesn't write legacy keys
  until the relay's device list has arrived.
- **Ending it:** once every device reports client 2, the legacy writes stop by themselves. Later, the relay's
  `MIN_CLIENT_VERSION` goes to 2 (old apps then say "please update"), and the legacy readers can be deleted.

---

## 5. Commands, replies and verdicts

### 5.1 Which computer gets a command

The phone decides, in this order:

| # | Situation | Target |
|---|---|---|
| 1 | A reply to a **session card** | The card's host. |
| 2 | **Reply** on a notification | The alert's sender: `userInfo["mochi"]["from"]` on the iPhone (the notification extension leaves `mochi` in place), `LinkAlert.from` on Android (with Sprint 2's A8). |
| 3 | An answer to an **approval** | The host in the approval's key. |
| 4 | **Check now** / agent questions from the Updates screen | The agent computer if it's online, else Mochi Cloud (as today: `checkNowUsesCloud`, `askCloudIfMacSilent`). |
| 5 | The user picked a computer in the **computer switcher** | That computer. The choice lasts until the app has been in the background for 30 minutes. |
| 6 | Otherwise: **Auto** | Among online hosts, prefer those **in use** (`resting: false`), then the newest `activeAt`, then the main computer, then host order. If no host is online, use the one seen most recently (`lastSeen`); the request waits there. |

Cases 1 to 3 are never re-routed: a session lives on one computer.

**The switcher** (Sprint 3's "computer switcher") shows only when the room has two or more hosts. It's a chip above
the composer, **To: Auto (Mac) ▾**. Its menu lists *Auto*, *BELPL-LT-636 (Mac)* and *DESKTOP-7 (PC) · away*. Each
exchange in "Recently" shows its target ("→ PC"). Siri, "Hey Google" and the Lock Screen use rule 6.

**When the target is away:** the exchange says *"Waiting for your PC (asleep since 2:02 PM)"* and offers **Send to Mac
instead**, which sends a new command with a new id. A computer ignores commands older than 180 seconds (`readCommands`
on the Mac, `_command` on the PC), so a queued copy that arrives later doesn't run twice.

### 5.2 Frames

```json
{"v":1,"op":"send","key":"command","id":"7f3c…","to":["dev_Pc7wQm2LxN9sKd4T"],"ttl":600,"at":1793800200,"nonce":"…","box":"…"}
```

Opened:

```json
{"id":"7f3c…","text":"Run the tests","at":1793800200,"typed":true,"host":"dev_Pc7wQm2LxN9sKd4T","project":"web-app","session":"5b1e…"}
```

**A computer runs a command only if** `host` equals its own id, **or** `host` is missing (an old phone) **and** it's
the main computer. Any other command is acknowledged, logged ("command for another computer") and dropped. A new
phone never sends a command to every host. The relay refuses a `to` that names a phone or Mochi Cloud (`forbidden`),
and a device that isn't in the room (`bad_target`). On `bad_target`, the phone asks for the device list again and
says *"That computer isn't in this room any more."*

### 5.3 Replies

These are unchanged: `reply` goes `to: ["pocket"]`, and every phone matches its own exchanges by `id` and ignores the
rest. (Replying only to the phone that asked would need the command's `from` in Swift's `LinkStore`; that's an
optional clean-up, not needed here.) The phone counts a reply from host H as "H was seen" (`macSeenAt` becomes per
host).

### 5.4 Verdicts and interactions

- A **verdict** goes to the host that asked, with `host` inside:
  `{"id":"approval-1","allow":true,"at":1793800230,"host":"dev_IPArsdaxyR5EovoO"}`, `to: ["dev_IPArsdaxyR5EovoO"]`.
- A pet, play or treat from a phone (**`phoneInteraction`**) goes to `["host"]`, so every computer's Mochi reacts:
  it's one pet.
- A pet, play or treat on a computer (**`macInteraction`**) goes to `["pocket","host"]`, so the other computer's Mochi
  reacts too. A computer that's resting ignores it. The relay already allows this (`macInteraction` has no target
  rule).

---

## 6. The iPhone Live Activity with two computers

Mochi Pocket shows **one** activity. The relay sends `update` and `end` to every update token the iPhone registered,
whoever sends them. So exactly one computer at a time may push to it, and handovers must keep the activity and its
timestamps in order.

### 6.1 The lease

`laLease` is a shared host key. It's never cleared; releasing it sets `holder` to null, so the timestamp watermark
and the dismissal survive between turns.

```json
{"holder":"dev_IPArsdaxyR5EovoO","phase":"working","since":1793800020,"ts":1793800290,"ttl":90,"at":1793800290,"dismissedAt":1793790000}
```

| Field | Meaning |
|---|---|
| `holder` | The host that drives the activity; null when free. |
| `phase` | The phase the holder is showing (`working`, `waiting`, `done`, `error`, `idle`). It's rewritten whenever the phase changes. |
| `since` | When the holder's current turn or wait began (the activity's `since`). |
| `ts` | The highest APNs `timestamp` the holder has sent so far (the watermark). |
| `ttl` | Seconds the lease lasts without renewal. Each receiver counts them from when **it** received the lease, so the two computers' clocks don't matter. |
| `dismissedAt` | When you ended it by hand (Settings › End It on any computer, or by swiping it away on the iPhone). No computer starts a new activity for a turn that began before this. |

### 6.2 Rules

Each host evaluates these on its 2-second tick, using its own planner state (`LiveActivityPlanner.state`), the lease,
presence, the other hosts' `claude.<host>` phases, and the iPhone's `updateTokens`:

| Situation | What the host does |
|---|---|
| **Lease free** (holder null; holder offline per presence; holder no longer in the room; or more than `ttl` since this host received the lease) and this host's state is `working` or `waiting` (today's start rule), started after `dismissedAt` | **Take the lease:** put `laLease` with itself as holder. If an activity is running (`updateTokens` isn't empty), send an `update` at priority 10. Otherwise send a `start`. |
| **Held by another host** and this host's phase outranks the lease's phase (`waiting` > `working` > `error` > `done` > `idle`), and the lease's phase isn't `waiting` | **Take over:** put `laLease`, then send an `update` at priority 10. This is how "your PC needs you" replaces "Mac: working". |
| **Held by another host**, anything else | Push nothing. |
| **This host holds it** and still has something to show | Drive it as the Mac does today (updates on phase changes, quiet motion every 6 seconds). Renew the lease when 30 seconds have passed or the phase changed. |
| **This host holds it** and has nothing more to show (the planner returns nil) | If another **online** host's `claude.<host>` is `working` or `waiting`: release (holder null) **without ending**, and that host takes the lease on its next tick and sends an update. Otherwise: send `end` (dismissed after 180 seconds) and `activityEnded`, then release. |
| **This host just lost the lease** (it received a lease with another holder) | Stop at once. Never send `end` or `activityEnded` after losing the lease. |
| **End It** (Settings) on any host | That host puts `laLease` with holder null and `dismissedAt` = now, and sends `end` with `dismissAfter: -60` itself. The old holder sees the new lease and stops. |
| The iPhone reports the activity gone (`updateTokens` emptied after the activity started, today's check) | Every host sees the same pocket state. The holder releases with `dismissedAt` = now. |
| An activity is running, the holder has been offline for more than 5 minutes, and no host wants the activity | The main computer sends `end` and `activityEnded`, then releases. This cleans up after a Mac that went to sleep mid-turn. |

**Two hosts taking a free lease at the same moment:** both put `laLease`, and the relay stores them in some order.
The host whose put came first receives the other's put and stops. The host whose put came second ignores the first
host's put, because it arrives while its own write is still unacknowledged (`pendingStateKeys`; `_pendingStateKeys`
in Dart), and then gets its ack. Both end up on the relay's last value. At worst, one extra update goes out.

### 6.3 Timestamps across computers

iOS ignores a Live Activity push whose `timestamp` isn't newer than the last one. Each computer keeps its own counter
(`nextTimestamp` on the Mac: `max(last + 1, now)`), and their clocks can differ. So:

- The holder writes its newest `timestamp` into `laLease.ts` whenever it renews or changes phase (at least every 30
  seconds).
- A host that takes the lease uses `max(its own next, lease.ts + 60)` for its first push, then counts on from there.
  The 60 seconds cover anything the old holder sent after its last renewal. (Check on the device that iOS accepts a
  timestamp a little in the future; see the tests in 12.3.)

### 6.4 What goes in the activity

The holder's planner state, with a computer label when the room has two or more hosts. The label goes into the
**sealed** detail, so the push still holds nothing readable: `title` "Claude needs you", detail
"PC · web-app · 3 tools" (the project only if that computer's "show project names" setting is on, as today). The
attributes' `petName` and `companionName` come from the shared look, so they're the same whichever computer starts
the activity.

### 6.5 The Windows host's pushes (Sprint 2 W6)

The Dart port does exactly what the Mac does in `LinkPush.liveActivity`:

- `K_la = HKDF-SHA256(K, info "mochi-link/v1 live-activity", 32 bytes)`. Dart already has
  `LinkCrypto.liveActivityKey`.
- Seal `{"title":…, "detail":…}` with AES-256-GCM under K_la, associated data `mochi-link/v1|live-activity|detail`,
  and write it as `content-state.sealed = "<nonce>.<box>"` (base64url without padding). Set `content-state.title` to
  the pet's name and drop `detail`. If there's an `alert`, set its title to the pet's name and its body to "Claude
  needs you" ("<pet name> is watching Claude work" on `start`).
- Send it with the new `RelayLink.sendLiveActivity`, mirroring `RelayLinkStore.sendLiveActivity`: a waiting `update`
  is replaced by a newer one in the outbox, while `start` and `end` always go.

```json
{"v":1,"op":"send","key":"liveActivity","id":"…","to":["pocket"],"ttl":600,"at":1793800300,
 "push":{"kind":"liveactivity","priority":10,"collapse":"live-activity"},
 "apns":{"event":"update","timestamp":1793800350,
         "content-state":{"phase":"waiting","title":"Mochi","since":1793800290,"frame":4,"sealed":"<nonce>.<box>"},
         "alert":{"title":"Mochi","body":"Claude needs you"}}}
```

Sealed plaintext (opened by the widget with K_la): `{"title":"Claude needs you","detail":"PC · web-app"}`.

The port also brings over `LiveActivityState`, `LiveActivityPlanner` (`focus`, `phase`, `state`) and
`LiveActivityPayload` (`start`, `update`, `end`), plus `PhoneController`'s start, update and end logic and its
6-second motion updates, all behind the lease. The relay doesn't change: its collapse window is per phone, so it covers
both computers, and priority-10 takeovers bypass it.

**Later (Sprint 3 A5, "Live Activity v2: per computer"):** one activity per computer would need `attributes.host`, and
a relay field that sends an `update` to one activity's token instead of all of them. The lease design doesn't block
that; it would only make the lease per computer.

---

## 7. Mochi Cloud and the agent

### 7.1 One Mochi Cloud device per room

- **Copy Cloud Settings**, on the Mac today and the PC with W5, invites and joins a fresh cloud device as today, and
  only then **removes every other `cloud` device in the room** (`DELETE /devices/<id>` for each), so a failed join
  never leaves the room without one. The message says: *"Copied. This replaces Mochi Cloud's old key: paste it into
  the environment now, or Mochi Cloud stops reaching your phones."* This also fixes today's issue of a new device on
  every click.
- The cloud device belongs to the room, not to a computer. A PC that joins the Mac's room **changes nothing in Mochi
  Cloud's environment**: same room, same credential.
- Mochi Cloud itself doesn't change. It puts `agent` and sends `alert` to `["pocket"]`, and both still work.

### 7.2 Which computer runs the agent

| | Agent computer (`room.agentHost`, default: the main computer) | Any other computer |
|---|---|---|
| Scheduled checks, morning briefing, meeting nudges, Gmail mark-read | yes | no |
| Puts `agent`, sends agent-news alerts | yes | no |
| Writes `cloud` again at launch | yes | no (only when you save or remove a trigger there) |
| Shows the Pending card | its own | the room's `agent`, read-only ("from your Mac") |
| ✓ done | `done.<me>`; it takes in everyone's and marks mail read | `done.<me>`; the agent computer takes it in |
| Settings › Agent | as today, plus **Run Mochi's agent on: [BELPL-LT-636 (Mac) ▾]** | *"Mochi's agent runs on your Mac for this room."* plus the same picker (once that computer has an agent: W23) |

- **Only one agent per room**, so there are no duplicate notifications and no split memory.
- **No automatic failover between computers.** When the agent computer sleeps, Mochi Cloud's routine covers, as it
  does today. The picker is a deliberate choice.
- **Handing over** (you move the agent to the PC): the new agent computer seeds its `AgentMemory` before its first
  check. Items on the room's current `agent` card count as already told, and every `done.*` is taken in, so it
  doesn't announce everything again.
- **Phones:** "Check now" goes to the agent computer if it's online, else to Mochi Cloud (5.1, case 4).

---

## 8. Presence and wording

All of this lives in `LinkPeerNames` (Swift, `TamagotchiCore/Link/LinkPeerNames.swift`) and its Dart twin
(`mochi_link/lib/src/link_names.dart`), with shared cases in `link-spec/multihost/names.json` (12.3).

**New helpers:**

- `computerLabels(peers, me)` maps each host to its short label: "Mac" or "PC", or the computer's own name when two
  hosts are the same kind.
- `roomPill(peers, me, since:)` builds the phone's status pill (examples below).
- `computer(id, peers)` returns the `LinkHostName` of a given host, for card tags and "Waiting for your PC".

### 8.1 Phone wording

| Room | Status pill | Settings › Mochi Link |
|---|---|---|
| Mac only, online | Mac online | Paired with BELPL-LT-636 (Mac) |
| Mac and PC, both online | Mac and PC online | Paired with BELPL-LT-636 (Mac) and DESKTOP-7 (PC) |
| Mac online, PC asleep | Mac online · PC away | … "DESKTOP-7 (PC) is away since 9:10 AM: what you send it waits for it." |
| Both asleep | Mac and PC away | "Your computers aren't connected right now. What you send waits for them." |
| Two Macs | MacBook Pro online · Mac mini away | names instead of kinds |
| Three computers | 2 of 3 computers online | the list |

**Elsewhere on the phone:**

- Session cards: a "PC" tag.
- Approvals: *"Your PC asks: …"*.
- Exchanges: "→ PC".
- Unpair: *"Unpair from BELPL-LT-636 and DESKTOP-7?"*.
- Unpaired by a computer: close code 4004 (the room was deleted) says *"Your Mochi room was deleted. Scan a new code
  to pair again."*; 4001 (this phone was removed) says *"This iPhone was removed from your Mochi room."* The relay
  doesn't say which computer did it, so neither message names one.

### 8.2 Computer wording

| Where | Text |
|---|---|
| Device list (Mac and PC) | "This Mac · main computer", "DESKTOP-7 · Windows · online", "iPhone · iOS · away since 2:02 PM", "realme RMX3242 · Android", "Mochi Cloud". Each other device has **Remove…**. |
| Header | *"In this room: your PC, your iPhone and realme RMX3242, and Mochi Cloud."* |
| Finished-turn alert from a computer, in a room with two or more hosts | Subtitle *"Claude finished on your PC"* instead of "Claude finished" (inside the sealed alert). |
| The PC's Settings after joining | *"This PC is in BELPL-LT-636's Mochi room."* **Leave This Room…** |
| Leave confirmation | *"Leave BELPL-LT-636's room? Your phones stay paired with BELPL-LT-636. This PC keeps working on its own and keeps getting updates."* |

---

## 9. Relay changes (mochi-link 1.4.0)

Every change is additive: old clients never use the new keys, and the protocol stays at 1.

| # | Change | Details |
|---|---|---|
| R1 | **Scoped state keys** | `SCOPED_STATE_KEYS = {done: ["host","pocket"], claude: ["host"], sessions: ["host"], approval: ["host"]}` in `protocol.ts`. `checkPut` splits a key at its first `.`: if the base is scoped, the role must be allowed **and the suffix must equal the device's own id**. Otherwise it's `forbidden` ("A device may only put its own `sessions.<device>`."). `done.` keeps its current behaviour. A scoped base with no suffix (`claude`, `sessions`, `approval`) stays a legacy host key. |
| R2 | **Removal cleans up scoped keys** | `revoke` deletes every `<base>.<target>` key from the target device (today it deletes only `done.<target>` and the pocket's push keys). |
| R3 | **`room` and `laLease`** | New entries in `STATE_KEYS`, host only. |
| R4 | **`client` in the device list** | Keep `hello.client` (an integer) in a new `devices.client` column (schema 3; `migrate()` adds the column). List it in `devices` and `sync`. |
| R5 | **Guard on deleting a room** | `DELETE /v1/rooms/{room}` while another host is in the room returns `409 other_hosts` ("Another computer is in this room. Leave it instead, or add ?confirm=everyone."), unless `?confirm=everyone` is given. This protects the PC and the phones from an old Mac build's Unpair. |
| R6 | **12 devices per room** | `MAX_DEVICES` goes from 8 to 12. Two computers, three phones, Mochi Cloud and room for a guest phone. |
| R7 | Docs, tests, version | README (scoped keys, new keys, `client`, the delete guard), `VERSION = "1.4.0"`, and `scripts/e2e.mjs` with two hosts. |

**Not changed, on purpose:**

- **No new role and no primary on the relay.** The main computer is computed by the apps from the device order and
  `room`; the relay doesn't need to know.
- **Routing** already does what's needed: `to: [deviceId]` for `command` and `verdict` (hosts only), and for `alert`
  and `liveActivity` (phones only). Only `alert` and `liveActivity` are pushed. Computers are never pushed; a command
  waits in the computer's queue.
- **Push:** the per-phone collapse window for Live Activity updates is shared by both computers, which is what we want.
  Android Live Activity delivery through FCM stays Sprint 2's A1.
- **Updates:** any device of a room can still read the feed. Nothing changes for the PC's update access.
- **Invite limits** stay at 20 an hour per room. The relay already lets any host invite any role, and the rate limit
  stays per device, so each computer has its own budget.
- `liveActivity`: a frame from any host is already allowed.

Example refusal:

```json
{"v":1,"op":"error","at":1793800400,"code":"forbidden","message":"A device may only put its own `sessions.<device>`.",
 "id":"…","key":"sessions.dev_IPArsdaxyR5EovoO"}
```

---

## 10. Compatibility

| Phone | Computer(s) | Works? |
|---|---|---|
| old | one new computer | Yes, exactly as today: the main computer writes the legacy keys. |
| new | one old computer | Yes: the legacy keys are read as the main computer's (4.4). Commands carry `to: [id]` and `host`; the old computer ignores `host`. |
| new | one new computer | Yes, with scoped keys. Legacy writes stop once every phone is new. |
| old | two new computers | Yes, as if only the main computer existed. Its requests go to the main computer. |
| any | an old computer next to a new one | Not allowed: the join flow refuses until every computer is updated (3.2, step 5). |
| Mochi Cloud (unchanged) | any | Yes. |

---

## 11. Migration for your setup

**Today:**

- **Room A**, the Mac's: BELPL-LT-636 (host), the iPhone and the realme RMX3242 (pockets), and Mochi Cloud.
- **Room B**, the PC's: the PC alone, made at first launch so it can update itself. It has no phones.

**Goal:** the PC joins room A and room B goes away. Nothing changes for the phones or Mochi Cloud.

| # | Who | Step | Check |
|---|---|---|---|
| 1 | Claude | Deploy relay 1.4.0. | `GET /v1/health` says `1.4.0`; the relay tests and `npm run e2e` (with two hosts) pass. |
| 2 | Claude, then you | Install the new Mac build. Relaunch Mochi if asked. | Settings › Phones lists the iPhone, the Realme and Mochi Cloud, as before. |
| 3 | Claude, then you | Install the new Mochi Pocket on the iPhone (devicectl) and on the Realme (adb). Open each once. | Each shows "Mac online"; Recently and Waiting for you work as before. |
| 4 | Claude, then you | Publish the new Mochi for Windows (`scripts/release-windows.sh`). On the PC, Mochi offers **Restart to Update**: accept. It updates through room B, as today. | PC › Settings › About shows the new version. |
| 5 | You | On the Mac: Settings › Phones › **Add a Computer…** › **Copy Link**. | A code that works for 10 minutes. |
| 6 | You | On the PC: Settings › Phones › **Join Another Computer…** Paste the link and press **Join**. In the UTM VM, the clipboard is shared once the SPICE guest tools are installed. Otherwise, put the link in a file in a folder the VM shares, and delete the file afterwards. | The PC says *"Joined BELPL-LT-636's Mochi. Updates still come from your relay."* The Mac's sheet closes with "DESKTOP-7 joined". Mochi on the PC takes the Mac's name and look. |
| 7 | You | Check on the phones. | The pill reads "Mac and PC online". Settings › Mochi Link lists both computers. |
| 8 | You | Start a Claude turn **on the PC**. | Its card appears on both phones with a "PC" tag. The iPhone's Live Activity shows "PC · …" if the Mac isn't already showing one. |
| 9 | You | On a phone, set **To: PC** and send "hello". Then reply to the PC session from its notification. | The PC answers; the Mac doesn't. The reply reaches that session on the PC. |
| 10 | You | While the Mac's Claude works, make the PC's Claude ask for something. | The Live Activity switches to "PC · needs you". |
| 11 | You | PC › Settings › About › **Check for Updates**. | "Up to date", not an authorization error. |
| 12 | You (optional) | Settings › Phones on the Mac: if Mochi Cloud is listed more than once, remove the extra entries. | One Mochi Cloud. Its environment needs no change. |

**Rollback:** PC › Settings › Phones › **Leave This Room…**. The PC goes back to a room of its own (updates keep
working). The Mac, the phones and Mochi Cloud don't notice anything except the PC disappearing from the list.

**If steps are done out of order:** joining before the Mac is updated is refused in step 6 (*"Update Mochi on
BELPL-LT-636 first"*). Phones that aren't updated still work, but they see only the Mac (10).

---

## 12. Implementation plan

Sizes follow SPRINT_2.md: **S** is under one session, **M** is one to two, **L** is three or more.

### 12.1 Work items

**Relay** (`~/Documents/developer/mochi-link`)

| # | Item | Size |
|---|---|---|
| L1 | Scoped keys: `checkPut`, `SCOPED_STATE_KEYS`, cleanup in `revoke` (R1, R2) | S |
| L2 | `room` and `laLease` (R3) | S |
| L3 | `hello.client` stored and listed; schema 3 migration (R4) | S |
| L4 | Room-delete guard (R5); `MAX_DEVICES` 12 (R6) | S |
| L5 | README, e2e with two hosts, 1.4.0, deploy (R7) | S |

**Shared spec** (`link-spec/`, copied into the relay as today)

| # | Item | Size |
|---|---|---|
| F1 | Value fixtures for the new shapes: `room.json`, `laLease.json`, `approvalRequests.json`, `claude.json` with `activeAt`, `command.json` and `verdict.json` with `host`. Written by the Swift tests (`MOCHI_WRITE_LINK_FIXTURES=1`), read by Dart. | S |
| F2 | **Decision cases** in `link-spec/multihost/`, written by hand because they *are* the spec: `primary.json`, `targets.json`, `mirror.json`, `sessions.json`, `done.json`, `lease.json`, `names.json` (format in 12.3). | M |
| F3 | `link-spec/fixtures/liveActivity.json`: K, K_la, a fixed nonce, a `LiveActivityState`, the expected `sealed` string, and the expected `apns` objects for start, update and end. | S |

**Swift core** (`Sources/TamagotchiCore/Link/`)

| # | Item | Size |
|---|---|---|
| C1 | `LinkKey` scopes (`.shared` / `.perDevice`) and the new keys `room` and `laLease`. `LinkStore` gains `values(_:) -> [deviceId: Any]` for scoped keys and `send(_:for:to:)`. `set` on a scoped key writes `<key>.<me>`. `RelayLinkStore` keeps scoped values, checks `from` against the suffix, clears scoped keys missing from a `sync`, and carries its own scoped values on re-pairing. `hello` sends `client: 2`. `LocalLinkStore` follows. | M |
| C2 | `LinkRoom.swift` (new, pure): main computer, agent computer, Auto target, merged sessions, effective mirror, done union, legacy-write decision. `LiveActivityLease` (new, pure): the 6.2 rules as a function of (me, lease, presence, my state, others' phases, `updateTokens`, now) returning take, take over, drive, release, end or idle. | M |
| C3 | `LinkPeerNames`: `computerLabels`, `roomPill`, `computer(id:)` (8) | S |
| C4 | `PairingCode` `as`; `LinkPairing.leave` (self-remove); `deleteRoom(confirmEveryone:)` | S |

**Mac** (`Sources/App`)

| # | Item | Size |
|---|---|---|
| M1 | `PhoneController`: scoped `claude`, `sessions` and `approval`; legacy keys only as the main computer and while needed; the command rule (5.2); verdicts by id; `done.<me>` and taking in `done.*`; `activeAt`; interactions to `["pocket","host"]`; the alert subtitle "on your Mac" in rooms with two or more hosts | M |
| M2 | `PhoneController`: the Live Activity lease (6.2), the timestamp watermark, takeover updates, release without end, the computer label in the sealed detail | M |
| M3 | `LinkController` + `PhoneSettingsView`: Add a Computer…, Join Another Computer…, the device list with Remove…, Leave vs Unpair vs Delete for Everyone | M |
| M4 | Look: apply the room's identity fields, no echoes, friendship as a max (4.3) | S |
| M5 | `AgentController`: run only on the agent computer; write `cloud` again only there; Copy Cloud Settings replaces the cloud device; seed memory on handover; the "Run Mochi's agent on" picker writes `room` | S |

**iPhone** (`iOS/MochiPocket`)

| # | Item | Size |
|---|---|---|
| I1 | `MacLink` / `PhoneWorld` / `UpdatesStore`: sessions and approvals per computer (through `LinkRoom`), the effective mirror, `done.*`, a per-host `macSeenAt` | M |
| I2 | Routing: the computer switcher, session and notification replies to their computer (`mochi.from`), verdicts to their host, Siri using Auto, "Send to Mac instead" | S–M |
| I3 | Wording (8.1); a phone that reads `as=host` explains it | S |

**Dart `mochi_link`** (`flutter/packages/mochi_link`)

| # | Item | Size |
|---|---|---|
| D1 | `LinkKey` scopes and the new keys; `RelayLink` scoped values, `from` check, `send(to:)`, `client: 2` | M |
| D2 | `link_room.dart`: a port of `LinkRoom` and `LiveActivityLease`, passing every `link-spec/multihost` case | M |
| D3 | `link_names.dart` parity (8) | S |
| D4 | `link_push.dart`: `LinkPush.liveActivity` and `RelayLink.sendLiveActivity`, passing F3 | S |
| D5 | `LinkPairing`: join as a host, `leave`, delete with confirmation | S |

**Android** (`flutter/apps/mochi_pocket`)

| # | Item | Size |
|---|---|---|
| P1 | `PocketModel`: merged sessions, mirror and approvals; routing and the switcher; verdicts to their host; `done.*`; Reply from a notification to `LinkAlert.from` (with Sprint 2's A8) | M |
| P2 | Wording; Settings lists the computers; a phone that reads `as=host` explains it | S |

**Windows** (`flutter/apps/mochi_desktop`)

| # | Item | Size |
|---|---|---|
| H1 | `LinkHost`: Add a Computer…, the join flow (3.2, including the update check and swapping credentials), deleting the old room with `pendingDelete`, Leave vs Unpair, the "removed, own room again" message | M |
| H2 | `PhoneSync`: scoped writes, legacy keys only as the main computer, the command rule, adopting and writing `look` (4.3), `activeAt`, interactions to `["pocket","host"]` | M |
| H3 | The Live Activity from the PC, behind the lease (6.5; this is Sprint 2's **W6**) | M |
| H4 | Copy Cloud Settings, one Mochi Cloud per room (Sprint 2's **W5**) | S |
| H5 | Settings wording (8.2) | S |

**Mochi Cloud:** no change.

### 12.2 Order, so nothing breaks along the way

Each milestone ships on its own. After every step, one-computer rooms behave exactly as before.

| Milestone | Items | Why in this order | About |
|---|---|---|---|
| **MH1: Two computers, one room** | 1. L1–L5 (relay first: an older relay would refuse the new keys with `unknown_key`). 2. F1, F2, C1–C4, D1–D3, D5 (libraries; no behaviour change by themselves). 3. I1–I3 and P1–P2 (phones read both new and legacy keys). 4. M1, M3, M4 (the Mac writes both). 5. H1, H2, H5 (Windows). 6. The migration (11). | In MH1 the Mac stays the only Live Activity driver (the PC has no Live Activity yet), and the only agent. | 9–11 sessions |
| **MH2: Live Activity from either computer** | F3, D4, C2's lease (if not already in MH1), M2, H3 | The Mac's lease code ships first and takes a free lease when it's alone, which changes nothing. Then the PC starts competing for it. | 3 sessions |
| **MH3: Room settings and the agent** | M5, H4, the main-computer and agent pickers on both computers, the approvals list used for real by Sprint 3's B1 | Needs Windows' agent (W23) before the agent picker matters. | 1–2 sessions |

The PC must not join until every device runs the MH1 builds. The join check (3.2, step 5) enforces this for the
computers. Phones that aren't updated still work (10).

### 12.3 Tests

**Relay** (Vitest, `test/relay.test.ts`, `test/push.test.ts`, plus a new `test/multihost.test.ts`):

- A host may put `sessions.<itself>`. It's refused `sessions.<other host>` (`forbidden`). A pocket is refused
  `claude.<itself>`. A cloud device is refused every scoped key. The legacy `sessions` is still accepted from a host.
- Removing a host deletes its `claude.*`, `sessions.*`, `approval.*` and `done.*`; the next `sync` doesn't contain
  them.
- `room` and `laLease` are host only.
- `hello.client` appears in `devices` and `sync`, and a schema-2 room migrates to schema 3.
- Deleting a room with two hosts gives `409 other_hosts`; with `?confirm=everyone` it's deleted. With one host it's
  deleted as before. The last-host rule is unchanged.
- Two hosts and two pockets: a `command` with `to: [hostB]` reaches only host B, live and queued. `to: ["host"]`
  reaches both. A `verdict` goes to its host. `liveActivity` from both hosts shares the per-phone 5-second window, and
  priority 10 goes at once.
- 12 devices fit; the 13th is `room_full`.
- `scripts/e2e.mjs` runs the two-host story against the deployed relay.

**Shared decision cases** (`link-spec/multihost/*.json`): every case runs in Swift (`LinkRoomTests`) and in Dart
(`link_room_test.dart`), so both implementations make the same decisions:

```json
{"cases":[
  {"name":"auto prefers the computer in use",
   "input":{"me":"dev_AvoLUptZQ-Qz_oZG",
            "peers":[{"id":"dev_IPArsdaxyR5EovoO","role":"host","platform":"macOS","online":true},
                     {"id":"dev_Pc7wQm2LxN9sKd4T","role":"host","platform":"windows","online":true}],
            "mirrors":{"dev_IPArsdaxyR5EovoO":{"phase":"idle","resting":true,"activeAt":1793790000},
                       "dev_Pc7wQm2LxN9sKd4T":{"phase":"idle","resting":false,"activeAt":1793800100}}},
   "expect":{"target":"dev_Pc7wQm2LxN9sKd4T"}}]}
```

- **`primary.json`:** the oldest host; `room.primary` overriding it; an unknown `room.primary`; the main computer
  leaving.
- **`targets.json`:** the table in 5.1, including an offline-only room.
- **`mirror.json`:** ranking, ties, `resting` across hosts, the legacy fallback.
- **`sessions.json`:** merging, caps, disabled hosts, legacy fallback, pushed cards.
- **`done.json`:** union with "taken in once".
- **`lease.json`:** every row of 6.2, the simultaneous take, the timestamp watermark.
- **`names.json`:** every row of 8.1.

**Swift:**

- `LinkTests`: scoped keys through `RelayLinkStore` (a fake socket): storage, `from` check, `sync` clearing, carrying
  over on re-pairing, and `client: 2` in `hello`.
- `PhoneTests`: legacy keys only as the main computer and only while needed; the command rule; look without echoes.
- The lease state machine with a fake clock: handover, release without end, End It.

**Dart:**

- `mochi_link`: `relay_link_test` (scoped keys), `fixtures_test` (F1, F3), `link_room_test` (F2), `link_names_test`.
- `mochi_desktop` `link_test`: the join flow with a fake `LinkApi`. Cover a good join, an expired invite, an old Mac
  in the room (refused, leaves the new room), updates answering 401 (leaves, keeps the old room), the vault failing,
  the old room's deletion failing (`pendingDelete`), and removal followed by `ensureRoom` making a new room.
- `PhoneSync` with scoped writes and the command rule.
- `mochi_pocket` `pocket_model_test`: merging and routing.

**Live** (against the deployed relay, in a throwaway room deleted at the end):

- Extend `MOCHI_LINK_LIVE=… swift test --filter LiveRelayTests` and `mochi_link`'s `live_test.dart` into one story
  with a Swift host, a Dart host and a Dart pocket. Cover addressed commands, the lease handover, and a removal
  clearing scoped keys.
- `mochi_desktop`'s `live_update_test.dart`: after joining another room, the manifest still loads.

**On the devices** (screenshots, as SPRINT_2.md asks):

- Run the migration checklist (11).
- On the iPhone: a Live Activity handover Mac → PC ("needs you") → PC done → Mac continues. Confirm that iOS accepts
  the takeover timestamps (6.3) and that the Lock Screen shows "PC · …".
- An alert from the PC on Android, labelled "on your PC".
- End It on the PC stops the Mac from starting a new activity for the same turn.

---

## 13. Edge cases

| Case | Behaviour |
|---|---|
| Two Macs, or two PCs | Labels use the computers' names ("MacBook Pro", "Mac mini") instead of the kind (8). |
| The same Claude session id on two computers | Cards are keyed by (computer, id), so they can't collide. |
| A command to a computer that's asleep | It waits on the relay. The phone says so and offers to send it elsewhere. A copy that arrives more than 180 seconds late is ignored. |
| A command to a computer that was removed | `bad_target`: the phone refreshes the device list and says the computer isn't in the room. |
| The main computer goes to sleep | Nothing moves: it stays the main computer, and old phones wait for it as they do today. New phones use the other computer. |
| The main computer leaves | The next-oldest host takes over at once (it starts writing legacy keys if any phone still needs them). |
| The Live Activity holder sleeps mid-turn | Presence frees the lease. Another computer with work takes over with an update. If nobody has work, the main computer ends it after 5 minutes. |
| Clock skew between the computers | Lease expiry is measured locally from when the lease was received. Timestamps use the watermark (6.3). |
| Both computers edit Mochi's look at once | The last stored edit wins everywhere (4.3). |
| A phone scans an "Add a Computer" code | It explains that the code is for a computer, before calling the relay. |
| The PC's own room had phones | The join names them, and they have to pair again (rooms can't merge, because each has its own K). |
| Joining while offline, or the relay refuses | Nothing changes. The old room and credential stay. |
| An old Mac build's Unpair in a multi-host room | The relay answers `409 other_hosts`, and the old app forgets the pairing locally (it ignores the error). The Mac stays listed as an offline device until someone removes it. The room, the PC and the phones carry on. |
| Room full | 12 devices (R6). The join says `room_full` and suggests removing an old device. |
| The agent computer is removed | The main computer becomes the agent computer and Settings says so. |
| Summaries off on one computer only | That computer's `enabled: false` gives one line on the phone; the other's cards still show. |
| `phoneInteraction` while one computer is resting | Its Mochi stays asleep; the other reacts. |
| Rate limits | Each computer has its own budget (6,000 frames an hour). Legacy writes add at most one frame per scoped write, and only while old phones remain. The lease adds about two frames a minute while a computer drives the Live Activity. |

---

## 14. Open questions for you

1. **Main computer:** the oldest computer (your Mac) by default, and you can change it in Settings. OK?
2. **Editing Mochi's look:** from either computer, with the last edit winning (recommended)? Or only from the main
   computer?
3. **Default target:** Auto, meaning the online computer you used most recently (recommended)? Or a fixed default
   computer in the phone's Settings?
4. **Live Activity takeover:** should "needs you" on the other computer replace a "working" activity (recommended)?
   Or should the activity stay with whoever started it until that turn ends?
5. **Agent failover:** no automatic failover from the Mac to the PC; Mochi Cloud covers while the Mac sleeps
   (recommended). Or should the PC run the agent when the Mac has been asleep for, say, an hour?
6. **Getting the link to the other computer:** the link contains the room key. For now: paste it directly (the VM's
   shared clipboard). Later, a webcam QR scan on the PC, or a two-part code that keeps K out of chats and email. Is
   paste-only acceptable for MH1?
7. **The relay guard on deleting a room** while another computer is in it (R5): agree?
8. **Pets across computers:** should petting Mochi on the Mac make the PC's Mochi react too (proposed), or only the
   phones'?
9. **Rename the "Phones" tab to "Devices"** on both computers, now that it also holds computers?
10. **12 devices per room** instead of 8: agree?
