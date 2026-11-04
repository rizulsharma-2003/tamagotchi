# Widgets and Live Activities

**Desktop widget: shipped.** MacTamagotchi includes a WidgetKit extension (small and medium sizes:
"Mochi & Claude") that shows a picture of the scene and what Claude is doing. Add it from the widget
gallery (right-click the desktop › Edit Widgets, or Notification Center › Edit Widgets) and search for
MacTamagotchi. The app refreshes it when the status changes, at most once a minute (widgets have a
reload budget); otherwise it refreshes every 15 minutes. It is built by `scripts/build-app.sh` from
`Widget/MacTamagotchiWidgets.swift`, because SwiftPM can't build app extensions.

**Live Activities on the iPhone: built (testing build).** A Mac app can't start Live Activities itself
(see below), so the iPhone companion **Mochi Pocket** (`iOS/MochiPocket.xcodeproj`) carries them. The Mac
starts, updates and ends them through Apple's push service.

## How Mochi gets onto the iPhone

```
Claude Code ─hooks─▶ MacTamagotchi ─(APNs, liveactivity)─▶ Mochi Pocket's Live Activity (Lock Screen, Dynamic Island)
                        ▲                                        │
                        └──── iCloud key-value storage ◀─────────┘
                              (same Apple ID, same team: the iPhone shares its push addresses)
```

- **Linking through iCloud.** Mochi Pocket writes its push-to-start token, and each Live Activity's update
  token, to iCloud key-value storage (`CZDJF6N2RH.com.insideedge.mochi`). The Mac app is signed with the same
  team and the same key-value identifier, and reads them. There is no pairing step and no server.
- **Delivery.** `LiveActivityPlanner` (core) turns the Claude sessions into a phase (working, waiting,
  done, error, idle). `PhoneController` (app) starts the activity with push-to-start when Claude begins
  working, then updates it. Phase changes go out at priority 10 with an alert for "needs you", "finished"
  and "snag"; routine changes go out at most every 8 seconds at priority 5. The activity ends a few minutes
  after Claude finishes and stays on the Lock Screen 3 minutes. **End It** in Settings takes it off at once
  (a dismissal date in the past), and it stays away until Claude's next prompt or until Claude needs you.
  Every end also leaves a `macEnded` note in iCloud ({at, since, dismissAt}), and Mochi Pocket closes that
  turn's activity (or older ones) itself the next time it runs.
  The Mac follows the phone's own list of running activities (the keys of `updateTokens`): when the list
  empties, for example because you swiped the activity away or the app was reinstalled, the Mac stops
  assuming one is showing, and a new one starts with Claude's next turn. When an activity it didn't know
  about reports in, the Mac takes it over. **Send a Test** always starts a fresh activity. That covers the case where the Mac never learned the activity's update address (iOS can't
  wake an app that was swiped away to pass it on). Each push is authenticated with an ES256 JWT made from the team's APNs auth key
  (`APNsToken`), which is kept in the Keychain.
- **Art.** Live Activities can't run the Mac's renderers or continuous animation, so `MacTamagotchi
  --render-live-activity <dir>` renders the scenes and the pixel sprites into `iOS/Shared/Art.xcassets`.
  Pose changes still animate with each update, and the timer ticks live.

## Building and installing (testing)

1. `xcodebuild -project iOS/MochiPocket.xcodeproj -scheme MochiPocket -destination id=<iPhone UDID>
   -allowProvisioningUpdates build`, then `xcrun devicectl device install app --device <UDID> …/MochiPocket.app`.
   This is a development build signed by the team; it needs no App Store Connect record or TestFlight.
2. The Mac app needs the team's macOS profile for the shared key-value store. `Signing/MacSigning.xcodeproj`
   creates it (`xcodebuild … -allowProvisioningUpdates -allowProvisioningDeviceRegistration`). Then run
   `TEAM_ID=CZDJF6N2RH MAC_PROFILE=<profile> SIGN_IDENTITY=<Apple Development identity> scripts/build-app.sh`.
3. Create an APNs auth key (developer.apple.com › Keys) and choose its `.p8` in Settings › iPhone.
   Development builds use the APNs sandbox.

## Animation where views can't animate

Live Activities are rendered as snapshots by the system, so `TimelineView` and `withAnimation` don't run there.
Tried and dropped: a bitmap-font timer trick (frames as digits of a font driven by `Text(timerInterval:)`).
It works inside apps, but on iOS 27 the Lock Screen and Dynamic Island draw nothing for custom-font timers,
not even the vector outlines.

What works:
- Ten pose images per phase (`scene-<phase>-<k>`, `patch-<phase>-<k>`, rendered by `--render-live-activity`).
  The content state carries a `frame` number, and the system animates the change between poses on each
  update.
- While Claude works, the Mac sends a quiet update every 6 seconds (priority 5) on top of real changes, so
  Mochi and Patch keep moving.
- The app's test activity keeps moving for about 25 seconds after you leave the app (a background task).

## Mochi's room on the iPhone

Mochi Pocket runs its own `CompanionWorld` (the core library builds for iOS) and draws it with the Mac's
`SceneRenderer`. The room, its themes, furniture and holiday decorations, Mochi and the companion are the
same code as the Mac panel. The two devices follow each other through iCloud key-value storage:
- **`macLook`** (`PetLook`): names, colours, accessories, theme, room and friendship level, from Mac to phone.
- **`macClaude`** (`ClaudeMirror`): phase and tool category only. The phone replays it as simulated events
  (never kept, never counted), so its companion works when Claude works on the Mac. It also says whether
  the Mac is resting, so Mochi naps on the phone while it does, and wakes when the Mac is in use again.
- **`phoneInteraction` / `macInteraction`:** pet, play and treat, in both directions, guarded against echo.

On the phone the companion is always at the desk.

## Claude's summaries and replies

Off by default: Settings › iPhone › *Send Claude's summaries to my iPhone* on the Mac.
- **Collecting:** while the setting is on, the hook helper includes Claude's closing message on Stop and the
  name of each file an editing tool changes (`summary`, `file`). `SessionReports` gathers a turn's files
  until Claude stops.
- **Summarizing:** a one-off `claude -p --model haiku --tools "" --setting-sources project
  --no-session-persistence` (`TurnSummarizer`) turns the message, the files and the last three notes on that
  session into `{done, session, next}`. It takes about 3–4 seconds. If Claude Code isn't available, the start
  of Claude's message is used instead.
- **Notification:** an ordinary push (`apns-push-type: alert`, category `claude-turn`, one thread per session)
  to the phone's push address, which the app shares as `deviceToken`. Its **Reply** action sends your words
  without opening the app. When summaries are on, the Live Activity's "finished" update is quiet, so the
  phone buzzes once. *Only notify me when I'm away from this Mac* skips the push while the Mac has had input
  in the last 3 minutes.
- **Session cards:** `macSessions` (`PhoneSessions`) lists up to six live sessions with their phase, the last
  summary, the changed files and up to two suggested next requests. Each card has a Reply field. iCloud can
  take minutes to deliver it (it slows down busy stores), so each notification also carries its card: the
  app folds it in as the notification lands, or from Notification Center when the app next opens. A list
  read again from iCloud never overrides newer news from a notification. The Mac writes Claude's live status
  (`macClaude`) at most every 4 seconds for a new phase and every 20 seconds for a new tool, to keep iCloud
  quick.
- **Replies:** `phoneCommand` carries `project` and `session`. The Mac asks the helper Claude to pass the words
  on unchanged. If it picked that project's only live session (the one replied to) and the message still
  carries your words, no second approval is asked; otherwise the usual approval card appears on both devices.

## Mochi Pocket's screens

The main screen has the room, Pet/Play/Treat/Type, any approval waiting, *Claude on your Mac* (the session
cards) and recent requests. The gear opens Settings: the Lock Screen and Dynamic Island preview with the
test buttons, notification status, and how the phone is linked with the Mac.

## Talking to Mochi on the iPhone

Press and hold Mochi in the room. It stays on its spot and turns to listen: the head swivels so its right ear
and shoulder come forward, that ear stands tall with its inside showing, the other folds back, and sound
waves arrive at the listening ear (`ListeningPose`; `MacTamagotchi --render-listening <dir>` draws it frame
by frame). A tap cancels, and a Mac that doesn't answer within 45 seconds times out. Letting go waits at most
2 seconds for the last words. Speech is turned into text
on the phone with SpeechAnalyzer. Let go, and the words go to the Mac through the same iCloud key-value
storage:
- **Command:** `phoneCommand` {id, text, at}. The Mac runs it through Ask Mochi exactly as if it were typed
  there.
- **Answer:** the Mac writes `macReply` {id, state, text}.
- **Approval:** if the Mac needs approval for a message to a Claude session, `macApproval` shows the
  Send/Cancel card on the phone too. `phoneApproval` carries the answer; the first device to answer wins.

A round trip takes a few seconds to about 15 seconds, depending on iCloud.

Kept the same from the earlier analysis: the Mac can't host Live Activities itself.

## What the platform allows (checked against the installed SDKs)

- `ActivityKit.framework` ships in the macOS 27 SDK, but every API in its macOS interface
  (`Activity.request(…)`, `ActivityAuthorizationInfo`, updates, push tokens) is marked
  `@available(macOS, unavailable)` (73 declarations, none available). The same holds for Mac Catalyst.
- Since macOS 26, the Mac **displays** Live Activities that originate on a nearby iPhone (via the iPhone
  Mirroring / Continuity path). The Mac renders the iPhone app's Live Activity UI; it does not let Mac apps
  start their own.
- So any Live Activity must be started and updated by an **iOS app**.

## What an iPhone companion would need

| Area | Requirement |
|---|---|
| App | A separate iOS app target with a Widget Extension that defines `ActivityAttributes` (session label, phase, small static character art) and the Lock Screen / Dynamic Island / Mac-mirrored presentations |
| Data path | The iPhone has to learn about Mac events. Options: (a) **ActivityKit push notifications** — needs an APNs provider (a server holding the push key), which contradicts “no backend”; (b) a **local network** link (Bonjour + `Network.framework`) from the Mac app to the iPhone app — updates arrive only while the iOS app can run (foreground, or briefly in the background), so updates would be unreliable; (c) CloudKit — needs iCloud, sends data off-device, and still can't update a Live Activity from the background without push |
| Pairing | Explicit pairing between the Mac app and the phone (e.g. a QR code with a per-device key) and authenticated, encrypted transport for option (b) |
| Signing | Apple Developer Program membership, App IDs with the Push Notifications capability (for (a)), provisioning for both apps |
| Privacy | Only the minimal fields already shown in the menu bar (project label, phase, completion/waiting state) — never tool names or messages |

## Recommendation

Do not ship this as part of the core product. If you want it later, the least-compromising design is
option (a) with a tiny, self-hosted push relay that receives only `{session label, phase}` from your
Mac, accepting that this adds a server. Everything needed on the Mac side is already isolated
(`CompanionWorld.menuBarStatus` and `SessionSnapshot.statusLine`), so the companion would only add
a new output, not change the core.
