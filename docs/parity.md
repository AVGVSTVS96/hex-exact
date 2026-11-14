# hex-voice → hex-exact parity inventory

Source: `~/Developer/hex-voice` at `b406d5e3`. Server: `~/hex/.hex/channels/voice` (`server.ts`, `README.md`, `style.ts`). The app has a single route, `src/app/index.tsx` (rendered through `src/app/_layout.tsx`). Every screen, sheet and panel is drawn by `src/call/call-screen.tsx`, and a reducer in `src/call/screen.ts` decides what is open.

## 0. Cross-cutting

### 0.1 Transport and auth
| Item | Detail |
|---|---|
| Base URL / token | `EXPO_PUBLIC_HEX_URL`, `EXPO_PUBLIC_HEX_TOKEN`, sent as `Authorization: Bearer <token>`. Siri reads the same values from Info.plist keys `HexURL`/`HexToken` (`plugins/with-siri.js`). |
| Client | `src/hex/client.ts`. Read timeout 90 s, watch timeout 120 s, write timeout 60 s, upload timeout 300 s. Status < 500 throws `RefusedError(status)`; anything else becomes a plain error. The error message is the server's `{error:{message}}` or its raw text, capped at 300 chars. |
| Network errors | Unreachable: "Cannot reach hex. Check that Tailscale is on, then try again." Bad response shape: "hex sent <path> in a shape this app can't read (<field>)". No URL set: "Set EXPO_PUBLIC_HEX_URL…". |
| Long-poll pattern | `src/hooks/use-watch.ts`: `GET <path>?after=<version>` repeats forever. The server holds each request up to 25 s. Polling pauses while the app is backgrounded, and after an error it waits 2 s and retries. State is `waiting`, `current` or `offline`. `useAnswer` does one-shot fetches keyed by `(id, boardVersion)`. |
| Offline cache | AsyncStorage `kept:<key>` holds `tasks`, `finished`, `asks`, `task-counts`, `sends`. `calls` and `call:<id>` (finished calls only) are also cached. Lists render from cache, then refresh. |
| Server routes (`server.ts` `routes()`) | `/session`, `/calls*`, `/settings`, `/activity`, `/tasks*`, `/asks*`, `/stuck/*`, `/fresh/*`, `/media*`. Also `/phone` (POST, server-only; the app never calls it) and `/twilio/*` (phone calls, not the app). |

### 0.2 Device-local preferences (AsyncStorage)
| Key | Values | Default |
|---|---|---|
| `live.voice` | one of 22 voice ids (`src/live/voices.ts`) | `marin` |
| `live.persona` | obsidian, mana, opal, halo, glint, command | `opal` |
| `live.personaColor` | `#RRGGBB`, one of 8 presets or a custom colour from the colour picker | `#FFFFFF` |
| `live.opalPalette` | `original`, `2`…`9` | `original` |
| `live.reaction` | off / subtle (0.07) / lively (0.16) | `subtle` |
| `live.sounds`, `live.haptics` | on/off | on |

Drafts are stored in iOS `Settings` under key `HexDrafts` (`src/hooks/use-draft.ts`), keyed `ask:<id>` and `thread:<id>`. Drafts carry over from an ask's earlier ids (`ask.was`).

### 0.3 Haptics map (all gated by the Haptics preference, iOS only)
| Event | Haptic |
|---|---|
| Toggling the toolbar, crossing the orb drag threshold, page moves | selection |
| Orb landing | soft impact |
| Primary call button | light impact |
| Mute | selection |
| Call goes live | success notification |
| Call ends | soft impact |
| An agent task finishes during a call | soft impact |
| Swipe-delete a call | medium impact |
| Install update | medium impact |
| Tasks: answer/act/dismiss | tap; undo/read/open: tick (`tasks/parts.tsx` `feel`) |

### 0.4 Deep links (scheme `hexvoice://`, read in `src/app/index.tsx`)
| Param | Effect |
|---|---|
| `?tasks[=<taskId>]&stage=all\|needs\|working\|done\|quiet` | open Tasks, optionally on a task or tab |
| `?open=settings\|calls` | open that panel |
| `?demo=call` | demo call (§13) |
| `?report=pose` | write pose JSON to `Settings` keys `HexPose`/`HexPoseLog` (debug) |
| `?split=first\|second&share=0.x&size=regular` | simulated Split View (§14) |
| `?update=demo` | show the update toast with a fake build |

### 0.5 Native modules and plugins
| Module/plugin | What it does | Used by |
|---|---|---|
| `modules/pose` (`PoseView`, `PoseRootViewController`) | Reports `{regular, bar: left/right, fold rect, occlusions[]}` from iOS 27.1 traits and reserved regions. Rotation is locked to portrait except on iPad or Duo (detected by near-square screen or vertical bar edge). | layout everywhere |
| `modules/column` (`ColumnView`, SwiftUI) | Duo side column: tools at top, call buttons at foot, placed around occlusions | §14 |
| `modules/pages` (`PagesView`, SwiftUI) | Tasks pages one-up or two-up from the given width; emits `onPaired` | Tasks on Duo |
| `modules/rows` (`Fits` = ViewThatFits, `EvenRow`, `Lane`) | adaptive rows; "This week" lane chart | Tasks |
| `modules/shots` (`ShotsView`) | row of authed pictures at their shapes; tap opens Quick Look full screen (swipe, pinch) | ask cards, chat |
| `modules/markdown` (`MarkdownView`, Textual) | chat markdown: line breaks kept, Discord `-# ` small lines, links reported back via `onLink` | thread, ask "From…", pinned |
| `modules/voice-tone` (C audio tap) | pitch/tone of the mic at 30 Hz; drives orb squash and stretch | orb |
| `modules/call-interruptions` | AVAudioSession interruption began/ended (ignores appWasSuspended) | pause and resume a call |
| `modules/escape` | hardware Esc key; closes Tasks | Tasks |
| `plugins/with-call-audio.js` | WebRTC audio session: `videoChat` mode, mixWithOthers, defaultToSpeaker, allowBluetoothHFP | call audio |
| `plugins/with-activity-orbs.js` | copies `assets/live-activity/Orbs.xcassets` (one PNG per persona/colour) into the widget target | Live Activity |
| `plugins/with-siri.js` + `plugins/siri/*` | Ask hex App Intent, Skills bundle, Ask Live Activity | §12 |
| `plugins/with-rive-legacy.js` | Rive legacy backend (input setters) | orb |
| `plugins/without-push.js` | strips the `aps-environment` entitlement | — |
| Info.plist | `UIBackgroundModes: audio`; mic and camera usage strings; photo-library permission off (picker only) | — |
| npm | react-native-webrtc, expo-widgets (Live Activity), @expo/ui (SwiftUI hosts: BottomSheet, Menu, List, SwipeActions, GlassEffectContainer, Toggle, Picker, TextField, ShareLink), @rive-app/react-native, expo-camera, expo-image-picker, expo-audio, expo-haptics, expo-updates, reanimated/gesture-handler | — |

There is **no keep-awake**. The call survives lock and background through background audio mode. Android stops the call when the app is backgrounded; iOS does not.

---

## 1. Call screen (home): orb / persona / stage

**Files:** `src/call/call-screen.tsx`, `call.ts` (state → labels/buttons), `orb.tsx`, `stage.ts` (geometry), `glide.ts` (orb ↔ transcript drag), `card.ts`, `src/screens/orb-rest.ts`, `src/components/persona/*` (Rive), `src/motion.ts`.

**What the user sees**
- Full-screen dark or light stage with a large animated orb in the middle. Toolbar at the top: Calls (left), and a Tasks+Settings capsule (right) with an accent dot when something needs you.
- Accessibility label of the orb gives the status:

| State | Label |
|---|---|
| idle | "Ready to start a conversation" |
| connecting | "Connecting" |
| reconnecting | "Reconnecting" |
| ending | "Ending conversation" |
| live | "Conversation active" |
| muted | "Microphone muted" |
| hex muted | "hex muted" |
| both muted | "Microphone and hex muted" |
| call elsewhere | e.g. "You called hex, on your phone" |

- Orb state (Rive inputs listening/thinking/speaking/asleep), from `personaOf`:

| Situation | Orb state |
|---|---|
| no call | idle |
| connecting, reconnecting or ending | thinking |
| speaking (output level > 0.035) | speaking |
| hex muted or mic muted | idle |
| otherwise | listening |

- Orb motion:
  - Breathes while idle (scale and opacity loop).
  - Wakes with a spring when live (half-wake while connecting).
  - Reacts to the caller's voice: scale from input level, plus vertical shift and squash/stretch from the native voice tone, scaled by the "Reacts to you" amount.
  - Reduced motion turns all of this off.
- Phone layout (`pulls`): drag the screen or orb vertically to glide the orb into a small docked button bottom-left and reveal the transcript. Rubber-band, 35 % commit line, flick > 500 pt/s, haptic tick at the line, soft haptic on landing. A tap on the docked orb glides back. A "Show transcript" docked glass button sits where the orb docks.
- iPad (regular, no fold): the `pad` layout. In landscape the orb sits on the left half and words on the right. In portrait the orb is at the top and words below. Panes (Calls 360 pt, Tasks 2/3 width) open beside, and the orb plus controls dock into the remaining space at the foot.
- Large text size for words on iPad.
- Orb scales down to fit above the footer, and to ≤ 96 pt when the Tasks sheet is over it during a call.
- Persona fallback if Rive fails: the text "Visual unavailable".

**Native:** Rive (6 `.riv` assets, data-binding colour for obsidian/halo/glint/command, a numeric palette input for opal), Reanimated, Gesture Handler, voice-tone module, haptics.

**Duo:** see §14.

## 2. Captions / live transcript

**Files:** `src/components/transcript.tsx`, `src/ui/turn.tsx`, `src/live/session.ts` (`caption()`).

- Shows the live call's turns: you right-aligned, hex left-aligned.
- Deltas append to the last turn of the same role unless the gap is over 2 s; turns are sorted by `start_ms`; the last 200 are kept.
- Newly arrived characters render tertiary, warm up to secondary at 120 ms and settle to primary at 240 ms.
- Follows the bottom unless you scroll up (40 pt slack).
- Top and bottom gradient fades.
- Text is selectable.
- Empty state: "Your conversation will appear here." (centred on iPad, at the end on phone).
- Interleaves **call ask cards** (§7) and **sent media** (§8) by time.
- After a call ends, the last call's words stay on screen until the next call.

**Data channel (WebRTC data channel `oai-events`, JSON)**

| Direction | Event |
|---|---|
| server → app | `session.started` |
| server → app | `session.input_transcript.delta {delta, start_ms?, end_ms?}` (you) |
| server → app | `session.output_transcript.delta {…}` (hex) |
| server → app | `session.input_audio.muted` / `unmuted {client_event_id}` |
| server → app | `session.closed {reason?}` |
| server → app | `error {error.message}` (logged, call continues) |
| app → server | `session.input_audio.mute` / `unmute {event_id}` |
| app → server | `session.close {event_id:"close-you-app"}` |

Server allow-list: `APP_HEARS` in `server.ts:2943`; allowed client events at `server.ts:3045`.

## 3. Call lifecycle, controls (mute, end/start, menu)

**Files:** `src/components/call-controls.tsx`, `src/call/use-call.tsx`, `src/live/session.ts`, `src/live/transport.ts`, `src/call/footer.tsx`, `src/hooks/use-call-feedback.ts`, `src/components/call-menu.tsx`.

**Controls (SwiftUI glass buttons in a GlassEffectContainer)**
- **Primary button**, by state:

| State | Icon | Label | Notes |
|---|---|---|---|
| start | waveform | "Start conversation" | |
| retry | waveform | "Retry conversation" | after an error |
| cancel | × | "Cancel connection" | shows spinner |
| end | × | "End conversation" | |
| ending | waveform | "Ending conversation" | spinner, disabled |

  Disabled until the voice preference has loaded. Starting closes a sliding Calls drawer.
- **Mute button**: only appears during a call; a spacer holds its place otherwise; enabled only when live and on this phone.

| State | Icon | Label |
|---|---|---|
| none | mic | "Mute microphone" |
| app muted or interrupted | mic.slash | "Unmute microphone" |
| hex muted | speaker.slash | "hex muted, mute microphone" |

- Sizes: regular (mute 60 / call 64), compact (48 / 52), tool (48 / 48). Laid out as a row or a column.

**Footer lines under the orb** (`footerOf`)

| Situation | Line |
|---|---|
| Ended | ENDINGS line + length, e.g. "You hung up · 3 min". Red for dropped / couldn't connect. |
| Elsewhere | "<where> · <started>" |
| Interrupted | "Paused while another app has the audio" |
| hex muted | "hex muted · say "unmute"" |
| Errors | red alert text |
| Failure to send | "Not sent · …" |

Endings: you / hex / dropped / expired / no-connect / no-answer / busy.

**Session flow (`LiveSession`)**
1. getUserMedia (audio) → RTCPeerConnection with no ICE servers → data channel `oai-events`.
2. Create the offer and wait for ICE gathering (10 s limit, else "Could not establish an audio route…").
3. `POST /session {sdp, voice, from:"app", about?}` → `{session:{id}, transport:{sdp}}` (201).
   - `about` is a task id or `"asks"`.
   - Set the remote answer and wait for `session.started`; if it doesn't arrive within 25 s: "The voice session did not start…".
4. Elapsed timer from `session.started`. Mic/speaker levels come from `getStats` every 120 ms (only while the app is in the foreground).
5. **Mute**:
   - Disable the track first, then send `session.input_audio.mute` with `event_id: mute-N`.
   - Wait for the matching `…muted` confirmation; resend every 5 s until confirmed.
   - On unmute, re-enable the track only after the server confirms.
6. **Interruption** (phone call, Siri):
   - Mute the track and send mute `interruption-N`.
   - `POST /calls/<id>/moments {kind:"paused"|"resumed"}` (204; 409 if not live).
   - The server records it and tells the voice to wait.
   - Tapping mute while interrupted resumes the call.
7. **Reconnect**:
   - Triggers: peer `failed`, `disconnected` for more than 7 s, data channel closed, or `session.closed` with reason expired / connection_lost / remote_hangup.
   - Status goes to `reconnecting` and the app calls `POST /session {sdp, from:"app", continues:<callId>}`.
   - Backoff 0, 1, 2, 4, 8 s, giving up after 150 s ("The connection to hex was lost.").
   - 410 means the call is gone and it ends as dropped.
   - The transcript timeline shifts so new turns continue the old clock.
8. **End**:
   - Send `session.close` and wait up to 1.5 s for `session.closed`.
   - If not confirmed: `DELETE /session {sessionId}` (204).
   - If that fails too: error "Audio stopped, but the server could not confirm session closure…".
   - Hex hanging up (`session.closed`) ends with `hex`; `expired` ends as `expired`.
9. Sounds and haptics: `connect.wav` and a success haptic on going live; `end.wav` and a soft haptic on ending (if enabled). Sounds play with `keepAudioSessionActive`.
10. Android uses `InCallManager` with the speaker route. iOS uses with-call-audio defaults.

**Call elsewhere** (`src/hooks/use-call-elsewhere.ts`)
- `GET /activity` reports a live `call` id the app isn't holding (e.g. a phone call), so the app shows it live.
- The words come from `GET /calls/<id>?after=` and the clock from `record.started`.
- Status reads "You called hex, on your phone", for example. The End button calls `DELETE /session {sessionId}`.
- Mute is disabled.

**Call menu** (`call-menu.tsx`, a SwiftUI glass `Menu` with "…" icon) on a past call:
- "Share transcript": a ShareLink with transcript text from `transcriptText()`.
- "Delete call": destructive; hidden for the live call.

**Server endpoints**

| Method | Path | Body | Response |
|---|---|---|---|
| POST | `/session` | `{sdp, voice?, from:"app", about?, continues?}` | 201 with the OpenAI session JSON (`session.id`, `transport.sdp`). 503 if no OpenAI key, 400 if no sdp, 502 if OpenAI unreachable, OpenAI's own status if refused, 410 when `continues` names a call that is gone. |
| DELETE | `/session` | `{sessionId}` | 204 |
| POST | `/calls/:id/moments` | `{kind:"paused"\|"resumed", text?}` | 204; 409 if not live |

## 4. Agent line (live "hex is working…" ticker)

**Files:** `src/components/agent-line.tsx`, `src/hooks/use-agent-line.ts`, `src/live/agents.ts`.

- One 22 pt row above the footer, shown only during a call.
- Left mark: a spinning arc while running, a checkmark when done, a red ! when failed.
- Text ticks in and out (rise/fade 250 ms). It shows the first running task's `line`, else its `text` in secondary (waiting).
- Right label: destination plus "+N" more running.
- When a task finishes it shows done/failed for 2.4 s with a soft haptic.
- Tap: opens Tasks on the **Working** tab. VoiceOver live region.
- Endpoint: `GET /activity?after=<v>` → `{version, call: id|null, tasks:[{id, state: running|done|failed, text, to?, line?}], asks:[CallCard]}`. Tasks include other working board threads (`elsewhere()`).

## 5. Calls sidebar / past calls / call transcript

**Files:** `src/components/calls-sidebar.tsx`, `src/call/drawer.ts`, `src/components/past-call-bar.tsx`, `src/components/call-transcript.tsx`, `src/hooks/use-calls.ts`, `src/live/calls.ts`.

**Sidebar ("Calls")**
- Opened by the toolbar clock button or a swipe from the left edge (20 pt edge zone). Closed by swiping left or tapping the peeking stage.
- Drawer spring. On phone it slides the stage and the stage peeks 72 pt; on iPad it sits beside at 360 pt; it can also sit over.
- Groups: Today / Yesterday / Earlier (headers only when more than one group).
- Row content:
  - Name: title, else preview, else "A quiet call".
  - Time: time of day, or weekday, or date; "Now" if live.
  - Source glyph when not from the app: globe, phone in/out, headphones.
  - Meta: length · tasks, or "naming…" for 10 min after the end, plus ending short text (red if bad); live: "Live now". The selected row is highlighted.
- Swipe left reveals a red trash button (64 pt); swiping past 180 pt deletes. Optimistic removal, restored on failure with "Not deleted · …". The VoiceAction "Delete call" does the same. A live call can't be swiped.
- Empty state: "No calls yet" with "When a call ends, it lands here…".
- Offline empty state: "Can't reach hex" with the Tailscale hint.
- Offline with a cache: banner "Can't reach hex. These are kept on this device."
- A call that just ended in the app is added locally (`useEndedCall`) before the server lists it.

**Past call view** (tap a row)
- The stage's words area becomes a past-call bar plus a full transcript.
- Bar: name, then "Today, 3:04 PM · 12 min" or "Live now". During a call there is a "● Back to your call" link (or a toolbar back button on Duo). "…" menu (§3).
- Transcript content:
  - Source line: "You called from the app · 3:04 PM".
  - Wrap-up (§6).
  - Turns, plus task markers (running/done/failed with clock), plus marks (paused/resumed/warned/muted/unmuted/stopped with clock) and media thumbnails.
  - Ending line: phone.down icon, "<ending> · m:ss".
- Loading spinner while fetching. On failure: "hex didn't answer, so this call can't open yet."
- Tap the orb to leave the past call (non-pull layouts).

**Endpoints**

| Method | Path | Response |
|---|---|---|
| GET | `/calls?after=` | `{version, live?, calls:[{id, started, ended?, end?, from, voice?, title?, reason?, why?, summary?, waiting?[], seconds, tasks, preview}]}` |
| GET | `/calls/:id?after=` | `{…fields, turns:[{who: you\|voice, at, text}], tasks:[{id, state, at, text}], moments:[{at, kind, text, media?}], version?}` |
| DELETE | `/calls/:id` | 204; 404; 409 if live |

## 6. Wrap-up

**Files:** `src/components/wrap-up.tsx`, `src/call/footer.tsx`.

- After a call ends, once the server has `title` / `summary` / `waiting`, the footer under the orb fades in:
  - Title (headline).
  - Summary, or "hex called because: <why>". Up to 4 lines when centred.
  - "Waiting on you" with accent bullets (up to 3 under the orb), then "N more in Tasks", which opens Tasks on **Needs you**.
- Tap: opens that past call.
- The same block appears at the top of a past-call transcript (not truncated, selectable).
- Data: `CallSummary.title/summary/waiting/why` from `/calls`.

## 7. Asks during a call (call-ask cards)

**Files:** `src/components/call-ask.tsx`, `src/components/transcript.tsx` (interleave), `src/hooks/use-asks.ts` (`answerAsk`).

- Hex puts an open question on screen during a call (server tool `ask`). It arrives in `/activity` `asks[]` as `{at, ask: Ask, answer?, sent?}` and shows as a card in the transcript at its time.
- Card content:
  - Topic link "<topic> ›", which opens Tasks on that task.
  - Optional tag chip.
  - The question.
  - Option pills (hex's pick is highlighted with "hex's pick").
  - Link pills "<label> ↗".
  - Hint "Tap, or just say it".
  - Multi-select variant: "Pick one or more", toggling pills, plus an "Answer" / "Answer with N" button.
- While sending: "Sending <label>…", other options dimmed. Failure: red "Not sent · …".
- Answered card collapses to "✓ Sent <answer> to <topic> and cleared its Telegram buttons. One place was out of reach…". Its text comes from `reachedBy`.
- An answer given by voice (`card.answer` from the server) replaces the card too.
- Endpoint: `POST /asks/:id/answer {label} | {labels:[…]}, media?:[ids]` → `Sent {thread, topic, settled, missed}`. 400 if empty; 409 on failure. The server tells the call's Claude.

## 8. Media: camera, add media, thumbs, shares

**Files:** `src/components/media/{add-media,call-add,camera,thumb,sent,waiting,pictures}.tsx`, `src/live/{media,shares}.ts`, `src/call/use-call.tsx` (`Sending` context), `src/hooks/use-media.ts`.

- **Add button**: during a live call, a docked glass "+" next to the docked orb ("Send a photo or video"). Elsewhere it is a "+" circle in composers.
  - It is a SwiftUI `Menu` with **Camera** and **Photos**.
  - Max 4 items per send (`MOST`); clips up to 60 s.
- **Photos**: system picker (no library permission). Images and videos, multi-select, compatible representation, H.264 720p export. Too long: alert "Videos up to a minute".
- **Camera** (a SwiftUI BottomSheet with medium/large detents, dark, black background, bevel border, hosting RN `CameraView`):
  - Tap the shutter for a photo (quality 0.8). Hold 280 ms to record video: red progress ring over 60 s, a "● m:ss" timer, release to stop.
  - Video is 720p and muted while a call holds the mic.
  - Flip camera button. "Hold for video" hint.
  - Review: photo preview, "Retake", and a round "↑" button labelled Send (in a call) or Add (in a composer).
  - Permission denied: "Allow hex to use the camera in Settings." plus an "Open Settings" link.
- **Sending during a call**:
  - Optimistic thumbnails appear in the transcript right-aligned with "Sending".
  - `POST /media` (raw bytes, Content-Type `image/jpeg|png|heic|…|video/mp4|quicktime`) → 201 `{id, kind: photo|video}`. 415 for a bad type, 422 if processing fails.
  - Then `POST /calls/:id/media {media:[ids]}` → 204; 400 for bad ids; 409 if the call isn't live, which shows alert "The call has ended / What you picked wasn't sent."
  - On failure: "Not sent · <why> · Tap to try again" (retries the whole batch).
  - The server records `photo`/`video` moments and the voice says it's having a look.
- **Thumb**: aspect from the image clamped to 3:4…4:3, bevel edge, a play badge for video. Authed source `GET /media/:id` (photo, or a still from the video).
- **Album**: 1 photo full width, otherwise a 2-up square grid.
- **Waiting strip**: thumbnails in composers with a × remove button each.
- **Pictures/Shots**: native row of authed images (asks' screenshots and pictures, chat pictures with `shape`). Taller than 1:2 shows its top; tap opens Quick Look.

## 9. Tasks

**Entry points**
- Toolbar Tasks button. Label: "Tasks, N need you, M working". An accent dot shows while Tasks is closed and needs > 0.
- Agent line → Working tab.
- Wrap-up "N more in Tasks" → Needs you.
- Call ask topic link.
- Deep link.
- Esc key closes it.

**Containers** (`src/components/tasks-sheet.tsx`, `tasks-pane.tsx`, `src/screens/duo-tasks.tsx`)

| Device | Container |
|---|---|
| Phone | SwiftUI BottomSheet. Large detent; during a call medium+large with the background interactive up to medium, so the call stays usable. |
| iPad | side pane beside the stage (`TasksPane`, keyboard-avoiding Host) |
| Duo | `TasksPage` in the page area, with a swipe-from-left-edge back gesture |

**Navigation** (`src/components/tasks/pages.ts`)
- Stack levels: `list → topic → thread → steps`, plus `check`, `picks → pick`.
- Shapes:
  - `one`: one page at a time, slide transitions.
  - `columns`: ≥ 900 pt wide; list 360–440 pt plus a detail page.
  - `panes`: Duo, two pages side by side if each half ≥ 380 pt.
- In wide shapes the first topic opens automatically.
- Back labels: Call / Tasks / <topic> / Steps / Last check / hex's picks / Question. On Duo the back button moves into the toolbar.

**Tasks endpoints**

| Method | Path | Response / body |
|---|---|---|
| GET | `/tasks?after=` | `{version, tasks:[TaskRow], finished:[{id, title, topic, app, proof, at, run?, link?}]}`. TaskRow = `{id, app, name, place, state: needs\|working\|done\|failed\|idle, running, line, since, at, track:[{at, state}], link?, agents:[{id, label, state, who?, since?, end?, line?, result?, link?}]}` |
| GET | `/tasks/summary?after=` | `{version, needs, working, yours?}` (toolbar badge) |
| GET | `/tasks/:id?after=` | Task `{…row, needs?, pin?, lately:[{at, state, text}], steps:[{id?, at, end?, kind, text, state?, detail?, result?, agent?, brief}], plan:[{text, state}], agents:[…+steps]}` **or** a Page `{id, app, name, place, at?, line?, link?, pin?}` |
| GET | `/tasks/:id/chat?after=` | `{version, sends, total, turns:[{from: me\|hex, text, media?:[{id, kind, shape?}]}], waiting:[{key, text, at}]}` |
| POST | `/tasks/:id/chat` | `{text, key:"app-…", media?:[ids]}` → 204; 400; 409 if not writable |
| POST | `/tasks/:id/stop` | 204; 409 |
| POST | `/tasks/:id/talk` | 204; 409 "No call is live" |

**Asks endpoints**

| Method | Path | Response / body |
|---|---|---|
| GET | `/asks?after=` | `{version, asks:[Ask], stuck:[{id, app, title, why, action, mark: paused\|failed, at, request?, sent?}], fresh:[{id, app, topic, title, line, at, read}], check:{at, why, fixed, flagged}\|null}`. Ask = `{id, kind, task, app, topic, at, question, context?, why?, options:[{label, value?, pick?, shot?, shape?, detail?}], multiple?, pictures?:[{id, shape?}], links?:[{label, url}], places:[{app, place, task?, call?, link?}], tag?, was?:[ids]}`; `decided:[Ask & {decided, why, took?}]`, what hex decided in the last week: what the check handed back to it, and the picks it took (hex server since AVGVSTVS96/hex#369, picks with `VOICE_TAKES_PICKS=1`) |
| GET | `/asks/check` | `{at, why, read:{what: n}, fixed:[{title, text, did?}], flagged:[…]}`; 404 if no check yet |
| GET | `/asks/:id/words` | `{place, at?, text}` (the original message); 404 |
| GET | `/asks/:id/shots/:n` | image |
| POST | `/asks/:id/answer` | → Sent |
| POST | `/asks/:id/note` | `{text, media?}` → Sent |
| POST | `/asks/:id/dismiss` | → Sent |
| POST | `/asks/:id/undo` | → 204 |
| POST | `/stuck/:id/act` | → 204 |
| POST | `/fresh/:id/read` | → 204 |
| POST | `/asks/talk` | → 204; 409 |

Errors on these return 409 with a message.

### 9.1 Task list (`tasks/list.tsx`, `list-head.tsx`, `rows.tsx`, `inbox.tsx`, `src/live/inbox.ts`)
- **Header**: "Tasks" large title plus a search button. Tabs (capsules with counts): **All · Needs you · Working · Done · Quiet**. The Needs count is accent coloured; counts show "–" while loading.
  - Wide layout puts title, tabs and search in one row (Fits).
  - Default tab: Needs if any, else Working.
- **Entries**, merged and ranked needs > working > done > quiet:
  - asks;
  - task threads (excluding ones that only appear as asks unless working);
  - stuck items;
  - fresh results (unread, or less than a day old);
  - finished tasks (less than a day old).
  - Grouped by topic as **Project rows**: mark plus name plus count chip plus time plus headline. A headline starting "API Error" becomes "Stopped: the server was limiting requests" or "Stopped on an API error" in red.
  - All tab: stage headers between groups. Done tab: one row per finished item.
- **Search**: glass field "Tasks, topics, questions" with a cancel ×. Matches every word across topic, place and text. Results show topic heads plus EntryRows with a "why" snippet and the matched words bolded. Empty: "Nothing matches".
- **EntryRow kinds**:
  - **Ask row**: question, inline answer pills, swipe-right = hex's pick, swipe-left = "Not needed" plus place tiles. Answered rows fold to "label → topic" with Undo / Send again.
  - **Task row**: line, time, "N agents".
  - **Stuck row**: title, why, action pill (or "Sent to hex"); swipe = action.
  - **Fresh row**: title: line, "Mark read" (swipe = Read).
  - **Finished row**: title plus proof.
  - Trailing swipe actions open place tiles (Telegram/T3/Buzz/Discord/server, call, link) in brand colours.
- **Picks strip** (Needs tab, more than one pick): "hex picked for N questions" → Picks page.
- **Check strip** (Needs tab): "Checked 3:04 PM · fixed 2 · flagged 1" → Last check.
- **Go through them with hex**: a capsule at the foot of the Needs tab when there are open asks. In a call it does `POST /asks/talk`; otherwise it starts a call with `about:"asks"`.
- **States**:
  - Loading spinner.
  - Offline with cache: "Last from hex · waiting for an update".
  - Unreachable: "Can't reach hex. Trying again…".
  - Empty per tab: "Nothing from hex yet", "Nothing waits on you", "Nothing is working", "Nothing done in the last day", "Nothing is quiet".
- Feeds the live counts back to the toolbar badge.

### 9.2 Task / topic page (`tasks/task-page.tsx` `Detail`, `Asked`, `DonePage`)
- **Header**:
  - Title (place or name).
  - Subtitle: "[parent ·] N need you · working for 12 min" / "waiting on you since …" / "done 3:04 PM".
  - Trailing "Talk it through" phone.and.waveform button: in a call it does `POST /tasks/:id/talk`, otherwise it starts a call with `about:<taskId>`.
  - "Open in <App>" place tile door, which deep-links to Telegram/Discord/Buzz/T3. If that fails, the Places row shows "<App> isn't on this iPhone".
- **Sections**, in order:
  1. **Needs you**: ask cards (§9.3).
  2. **Needs you** (threads waiting without an ask): need text plus "Waiting on you since …".
  3. **Working**: a live "Now: <step>" row with timer → Steps, then a horizontal scroll of cards for other working threads and agents.
  4. **Last run**: 3 newest steps plus "N agents · names" → Steps.
  5. **Pinned** (§9.7).
  6. **Messages** preview: the last 2 turns → Thread.
  7. **Places** (§9.8).
  8. **This week**: lane chart (native `Lane`; log time scale over a week; working spans; failure ticks).
  9. **Lately**: state history.
- **Foot**: a "Message <title>" field → thread composer (hidden when paired beside). Or the **Reply composer** when replying to an ask.
- **Asked** page (a topic with only asks): title topic, subtitle "N need you" or "N here", ask cards plus other rows.
- **Done page**: "Done · 3:04 PM", ✓ title, a **Proof** section (text plus link rows ↗), and a **Project** link to the run.
- Empty right pane in wide layouts: "Pick a project", or a spinner.

### 9.3 Ask cards (`tasks/ask-card.tsx`)
- Card shows:
  - Time and a "Not needed" pill.
  - Question (tap folds or unfolds) and context.
  - "From <place> · time" collapsible original message (markdown, `/asks/:id/words`).
  - Link pills.
  - Screenshots / pictures (Shots).
- **Answers**:
  - ≤ 3 short options: an even row of pills.
  - Otherwise full-width option blocks; hex's pick is tinted with ✦ "hex's pick".
  - Shot options: small pills under the screenshots.
  - Multiple: checkbox options plus "Answer with N".
- **Answer in your own words** row (shows the draft if any) opens the **Reply composer** at the page foot:
  - "Replying to <question>" with × (keeps the draft).
  - "+" media (up to 4).
  - Multiline field (3–5 lines).
  - **Send as note**: `POST /asks/:id/note`; then "Sent to <topic> as a note. The question is still open."
  - **Answer**: answer with your words or media.
  - Blur with nothing typed closes the composer.
- Swipe left → Not needed (`/dismiss`).
- Answered card: ✓ question, answer, **Undo** pill.
  - "One place was out of reach and still asks it" plus "Send again" (re-sends the same answer).
  - Failure text.
- Optimistic: an answer hides the card at once. Sends go one at a time per ask. Failures roll back with "Not answered / Not put away / Not undone / Not sent again · …".

### 9.4 Thread (messages) (`tasks/thread.tsx`, `said.tsx`, `src/hooks/use-chat.ts`, `src/live/chat.ts`)
- Header: "Messages" or the place name, the Talk button, the door, and a subtitle with state and time. When paired beside, a plain "Messages · N".
- Scroll anchored to the bottom.
  - "Earlier messages are in <App>" when `total` > the 100 turns shown.
  - Empty: "Nothing said here yet".
  - Your turns are right bubbles with media; hex turns are full-width markdown with pictures and albums.
  - `(label) text` from you renders as an event caption ("Asked Siri · …", "Voice message" shown as plain you).
- Pending sends: dimmed bubble with "Sending". Failure: "Not sent · Tap to try again", or the refusal text with no retry on 4xx.
- Pending clears once the message appears in `waiting` (key ends with `:<key>`) or in turns.
- Working row: "● <current step> · time · Steps ›".
- **Composer**:
  - "+" media.
  - Field "Message <title>" (draft saved).
  - Send ↑. When the thread is running and the field is empty, the button becomes **Stop** ■ (`POST /tasks/:id/stop`).
  - Shown only if `chat.sends`; otherwise just bottom space.
  - Opening via "Message …" focuses the field after 350 ms.

### 9.5 Trace / Steps (`tasks/trace.tsx`)
- Header "Steps", subtitle "<place> · <App> · working for N / state".
- **Plan**: "done of total" with done/working/pending marks.
- **Agents**: count summary such as "2 working · 1 done".
  - Each agent row: state mark, label, "who · time", newest line while working.
  - Tap expands: result (red if failed), its own steps, "Open in T3 Code ↗".
  - Retried stopped agents collapse under "N earlier tries, stopped".
- **Steps** (newest first), grouped into turns by `say` steps:
  - Turn header "Now" / "Since its last message" / said time, with step count and duration; it folds.
  - Step rows: kind icon (think/say/plan/run/read/edit/search/web/agent/tool), text (3 lines for think/say), duration or time, a live ellipsis for running steps, red for failed.
  - Tap expands detail (4 lines) and result (6 lines, monospace).
- Empty: "No steps yet" / "Steps show while it works".
- Loading/gone: spinner, or "These steps aren't there any more."

### 9.6 hex's picks (`tasks/picks.tsx`)
- **Picks page**:
  - "hex's picks", subtitle "N questions · M for later".
  - Rows: topic · tag, question, an answer tag (✦ pick / ✓ other / 🕒 "Decide later").
  - Foot: "Answer N questions" (prominent when > 0). Sends all chosen answers, then goes back.
  - Excludes asks tagged `money`. Empty: "Nothing left to take".
- **Pick page** (a single question):
  - Question title.
  - "Why hex picks X" accent box (`ask.why`).
  - "Your answer" option cards with detail, plus "Decide later".
  - Screenshots.
  - "What it's about" (context).
  - "From the thread" (words plus links, including "Open <place>").
  - Answered: "This question is answered".

### 9.7 Pinned (`tasks/pinned.tsx`, `src/live/pinned.ts`)
- Parses the thread's pinned status post (`task.pin`) into sections.
  - Headings: bold or `Title:`, or known words (done/running/waiting on you/known/next/links…).
  - Sections get a mark. Done sections start folded as "Title · N ⌄".
  - Items: bullets with emoji marks (✅ ❌ 🔄 ❓), links (tap opens ↗), code fences in monospace boxes, plain markdown lines.

### 9.8 Places (`tasks/places.tsx`)
- "Places · N": the task and its sibling threads with the same name.
- Each row: brand tile, place name, "<App> · time [· no link]" or red "<App> isn't on this iPhone".
- External ↗ (deep link) or internal › (opens that task). "Show N more threads" after 5.
- Tile glyphs and colours: Telegram paperplane, T3 `</>`, Buzz bolt, Discord bubbles, server terminal. Call tiles use a waveform; link tiles use ↗. Unlinked tiles are a ghost outline.

### 9.9 Last check (`tasks/last-check.tsx`)
- "Last check", subtitle "3:04 PM · why".
- A stats card of `read` counts.
- "Fixed on its own" (✓ notes) and "For you to look at" (needs notes: title, text, did).
- Data: `GET /asks/check`.

### 9.10 Marks (`tasks/mark.tsx`)
- Round state badges: needs, asks, pick, working (animated), done, read, failed, paused, stopped, pending, idle.
- Tints: needs, asks, working, failed, settled. Count chips use the same tints.

### 9.11 Inbox "pages" model
- Page ids: `<taskId>`, `topic:<name>`, `done:<finishedId>`.
- `homeOf` maps a sub-thread to its main thread.

## 10. Voice settings sheet

**Files:** `src/components/voice-settings.tsx`, `persona-colors.tsx`, `selection-carousel.tsx`, `settings-list.tsx`, `src/hooks/{use-talk,use-voice-preview,use-call-preferences,use-persona-preference,use-voice-preference}.ts`, `src/live/{talk,voices,voice-previews}.ts`, `assets/voices/*.m4a`.

Opened from the toolbar sliders button ("Voice and appearance settings").

**Page 1: Settings**
- **Persona carousel**: swipe between the 6 orbs with a live preview orb that reacts like a phrase when you change reaction.
- **Colour swatches** (8 presets, light-mode variants such as White → "Ink"). A colour picker after them for a custom colour. For opal, 9 palette swatches. For mana: "Mana keeps its own color".
- **Reacts to you** picker: Off / Subtle / Lively.
- **Voice** row: shows "Marin · Friend · Brisk" and opens page 2.
- **Call sounds** toggle and **Haptics** toggle.

**Page 2: Voice** (slides in; back button "Back", or the toolbar back on Duo)
- **Voice carousel** of 22 voices, each with an accent label or "Swipe to hear each voice".
- Each swipe plays that voice's bundled preview (expo-audio, ducks others, plays in silent mode). Tapping replays it.
- Locked during a call: "End the conversation to change voices." While loading: "Loading your voice…".
- **Personality** picker (Default, Friend, Brief, Warm, Playful) and **Pace** (Relaxed, Normal, Brisk). Options come from the server.
- **Your words**: a row opens a 260 pt sheet with "Your words", a ✓ Done button, and a text field (≤ 600 chars, placeholder "Short answers, no recaps. Talk like a friend."). Saved on close.
- Footer: "For every call, phone calls too." or an error ("Can't reach hex right now." / "hex didn't save that. Try again.").

**Endpoints**

| Method | Path | Body | Response |
|---|---|---|---|
| GET | `/settings` | — | `{settings:{voice?, personality?, pace?, words?}, personalities:[{id, label}], paces:[{id, label}]}` |
| PUT | `/settings` | any of `{voice, personality, pace, words}` | the same shape; 400 if invalid |

- Voice sync: if the server has no voice yet, the app pushes its local one; if the server has a different voice, it overrides local.
- Writes are serialized and optimistic. A live call hears changes after it stops talking (server side).

**Presentation**
- Phone: a sheet with two detents (appearance height, voice height).
- iPad: a form sheet, one detent, with carousel and rows side by side when wide.
- Split: page sheet.
- Duo: placed in the Duo page area (`SettingsPlace`). Unfolded landscape gives two panes (persona left, rows right); folded uses a 40 % persona share. It shares the area with Tasks; the front-most one shows.
- Persona Rive files preload on open.

## 11. Update toast and app updates

**Files:** `src/components/update-toast.tsx`, `src/hooks/use-app-updates.ts`, `src/hex/index.ts` (`installLink`), `updates/store.mts` (server).

**OTA (JS)**
- `expo-updates` checks and fetches each time the app comes to the foreground.
- A pending update reloads when the app returns from the background with no live call.
- Server: `GET <updates>/manifest` (Expo protocol).

**Native build**
- Long-poll `GET <updates>/install/latest.json?after=<version>` → `{version, runtime?, install?}`. It holds up to 60 s.
- If `runtime` ≠ the current runtime version, show the toast.

**Toast** (SwiftUI glass capsule)
- Content: ⬇ "Update ready" with **Install**, or **End call & install** during a call. A × "Not now" hides it for that version.
- Tap: medium haptic, end the call if one is live, then open `hangar://update/<bundleId>`, falling back to the `install` URL.
  - Shows "Installing build N" with a spinner. Returns to ready when the app becomes active again.
  - On failure: "Install didn't start · Try again".
- Placement:
  - Top of the stage; at the foot when Settings or Calls is open; above "Go through them" when Tasks is open.
  - On Duo it stays on the half before the hinge.

## 12. Live Activity (call) and Siri "Ask hex"

### 12.1 Call Live Activity
**Files:** `src/live/call-activity.tsx` (expo-widgets `createLiveActivity`, SwiftUI-in-JS), `src/hooks/use-call-activity.ts`, `src/live/activity-orb.ts`, `assets/live-activity/Orbs.xcassets`, `plugins/with-activity-orbs.js`.

- Starts when the call is connecting.
- States: connecting, live, muted, ended. Reconnecting shows as connecting.
- **Banner**: orb image (the persona/colour/palette chosen, as a PNG asset), "hex", and a subtitle (count-up timer or "Connecting"). Mute (mic / mic.slash) and End (×) buttons sit in circles.
- **Dynamic Island**: compact leading orb; compact trailing is the timer or a mic.slash; expanded leading is orb plus title; expanded trailing is the controls; minimal is the orb.
- Buttons send `target: "mute"|"end"`, which `addUserInteractionListener` routes to toggleMute / end.
- On end it updates to state `ended` with the outcome ("You hung up · 3:12"; red if bad) and lingers 2 min. Leftovers from a previous launch are ended immediately at start.

### 12.2 Siri: Ask hex
**Files:** `plugins/siri/AskHex.swift`, `AskAttributes.swift`, `AskActivity.swift`, `Skills.skillsbundle/Skills/ask-hex/SKILL.md`, `plugins/with-siri.js`.

**Intent and skill**
- App Intent "Ask hex" with a `request` parameter (prompt "What should I ask hex?").
- Implements ProgressReportingIntent and LiveActivityIntent; LongRunning and Cancellable on iOS 27; ToolIntent on iOS 27.3 and Xcode 27.3.
- Skill instructions: pass the words verbatim, wait, read the reply aloud, and carry out the "For Siri to do:" lines (Focus, alarms, Shortcuts) on the phone.

**Flow**
1. Find the Siri topic.
   - Use the cached `UserDefaults siriTopic` if present.
   - Otherwise `GET /tasks`, find `place=="Siri" && where=="Telegram"`. If none: "hex has no Siri topic…".
2. `POST /tasks/<topic>/chat {text:"(asked Siri: reply once, starting with #siri-<id>, …) <words>", key:"app-siri-<id>"}`. 409 gives "hex's Siri topic isn't taking messages right now…".
3. Long-poll `GET /tasks/<topic>/chat?after=` until a hex turn contains the tag. Return the text with the tag stripped, spoken as the dialog.
4. Meanwhile, long-poll `GET /tasks/<topic>?after=` and show the newest step's `brief`.
5. Give up after 10 min: "hex has been on it for ten minutes and still hasn't answered."
6. Unreachable: "Can't reach hex. Check that Tailscale is on."

**Ask Live Activity**
- Hex icon, a title, and a line showing the step or your words.
- Titles: "Asking hex", "Waiting for hex", "hex is working on it", "hex answered".
- A progress ring fills along `t/(t+10)`.
- **Stop** button (`StopAsk` intent) → `POST /tasks/<topic>/stop`, but only once hex has taken the message.
- Dynamic Island: icon plus words, with Stop in expanded; compact and minimal show the ring.

**Chat rendering:** `(asked Siri…)` turns show as an "Asked Siri" event in thread views (`src/live/chat.ts`).

## 13. Demo call

**Files:** `src/live/demo-call.ts`, `src/app/_layout.tsx`, `src/call/use-call.tsx`.

- `hexvoice:///?demo=call` swaps in a fake transport and API that start automatically.
- `session.started` fires, then 4 scripted caption lines (at 4, 9, 22 and 26 s on the call clock).
- Mute echoes `…muted` / `…unmuted`; close echoes `session.closed`.
- Output level is a constant 0.2, so the orb "speaks".
- Call id `demo`. No server traffic for the session itself; other watches still hit the server.
- Used for screenshots: `tasks&demo=call` and `call-live` states in `scripts/duo-states`.

## 14. Layout: toolbar, keyboard, iPad, Duo, split view

**Files:** `src/screens/layout.ts`, `window.ts`, `side-column.tsx`, `split-view.tsx`, `duo-tasks.tsx`, `src/call/stage.ts`, `card.ts`, `src/components/screen-toolbar.tsx`, `tasks-button.tsx`, `toolbar-back.ts`, `src/hooks/use-keyboard-up.ts`, `src/ui/host.tsx`, `src/ui/scroll.tsx`, `modules/{pose,column,pages,rows}`.

### 14.1 Toolbar
- Glass buttons:
  - **Calls** (clock icon): selected while the drawer is open.
  - A capsule holding **Tasks** (list icon, accent needs-dot, bouncy) and **Settings** (sliders).
  - On Duo, an animated **Back** ("Back to <x>") published by whichever page is in front: Tasks levels, Settings voice page, or a past call's "your call".
- Phone: a row at the top. Duo folded or flat with a fold: a row in the band beside the status bar (between occlusions). Duo with a side column: a vertical column.
- The toolbar shifts with the card when the Calls drawer or Tasks pane moves it (`barOf`).

### 14.2 Stage card
- With Calls or Tasks beside, the stage becomes a rounded card (continuous corners, hairline border) pushed aside (`cardOf`).
- The orb, transcript, footer, agent line and controls interpolate between their open / beside-Calls / beside-Tasks positions.

### 14.3 Keyboard
- `useKeyboardUp` listens for keyboardWillShow/Hide events from this app only.
- Every SwiftUI Host ignores the keyboard unless it holds a field (`avoids="keyboard"`: Tasks pages and pane) or presents a sheet (`avoids="system"`).
- All RN ScrollViews dismiss the keyboard on drag; SwiftUI lists use `scrollDismissesKeyboard("immediately")`.
- Typing in Tasks on the Duo top-and-bottom fold moves Tasks into the upper half (`typing` page) and drops "transcript beside".
- The Duo side-column call buttons fade and disable while the keyboard is up.
- Text selection is disabled on the page where you're typing (`Selectable`).
- Composers shrink bottom padding while typing.

### 14.4 Room and window model
- `roomOf(pose, size, insets)` → `{size, insets, regular, bar?, fold?, occlusions}`.
- The fold counts only if both sides are at least 320 pt. It is reduced to a line `{x}` or `{y}`. Angle is ignored, so half-open lays out like flat.

### 14.5 Stage kinds (`stageLayout`)

| Kind | When | Behaviour |
|---|---|---|
| `single` | phone | orb centre, pull-to-read, Tasks as a sheet, Calls drawer slides |
| `pad` | regular, no fold, no column | split (landscape) or stacked (portrait); Calls and Tasks beside; inline docks |
| `split` | regular landscape, or fold on x | orb on the left half, words right of the fold (+8 pt), controls bottom-right |
| `stacked` | fold on y | orb above the fold, words below it |

### 14.6 iPhone Duo specifics
- **Side column** (`bar` left/right; `SideColumn` + `ColumnView`): tools at the top under occlusions, call buttons at the foot above occlusions. Compact sizes when the window is under 520 pt tall.
- **Duo Tasks** (`DuoTasks`, `useDuoTasks`):
  - Tasks open as a page in the content area.
  - During a call the orb docks small (34 pt) in the column or band with an m:ss clock under or next to it. Tapping the docked orb closes Tasks.
  - Row-band layouts put compact call controls in the band (`rowControls`).
- **Transcript beside Tasks** toggle (rectangle.split icon, "Transcript beside Tasks"): offered during a call when the fold allows.
  - Vertical fold: Tasks on one side, live transcript on the other.
  - Horizontal fold: transcript above, Tasks below.
- **Pages**: Tasks uses `PagesView` with two pages side by side when each half ≥ 380 pt (`meet` offsets for the hinge). Swipe from the left edge goes back.
- **Settings**: shares the Duo page area with Tasks; one is in front; two panes in landscape.
- **Update toast**: kept off the hinge.
- **Calls placement**: slide if the window is narrow; beside (360 pt) if the rest ≥ 320 pt, below the band; full width over if not in a call.
- **Rotation**: `PoseRootViewController` allows all orientations on Duo and iPad, portrait only on a normal iPhone.

### 14.7 Split View / Stage Manager
- Real Split View: layout reads the window's Room, never the device pose.
- Simulated (`SplitView`, `?split=`): the app gets `share` of the width next to a grey stand-in. Compact unless `size=regular`. Settings becomes a page sheet.

## 15. Other behaviours
- **Optimistic and failure model** (`use-failures.ts`): each action shows inline "<Verb> · <reason>" in red under the item. Opening a link that fails gives "No app on this device opens this link".
- **App state**: watches pause in the background. Call stats stop in the background (levels go to zero). Android ends the call in the background.
- **Accessibility**: labels on every control; VoiceOver delete action on call rows; live region on the agent line; alerts on errors; reduced-motion fallbacks for the orb, drawer and glide.
- **Theme**: follows system dark/light (`userInterfaceStyle: automatic`); the persona colour has light variants.
- **Debug**: `?report=pose` pose log.

---

## 16. Order a user would notice things missing (most important first)
1. Start/end a voice call over WebRTC with hex (offer → `/session`, data-channel close), with mic audio working while locked or backgrounded.
2. The orb (Rive persona) reacting to connecting, listening, speaking and idle.
3. Live captions/transcript.
4. Mute (with server confirmation) and the connecting/ending states; error and retry messages.
5. Reconnecting / carrying the call on after drops; pausing on phone or Siri interruptions.
6. Tasks list with Needs you / Working tabs, the toolbar badge, and answering ask cards (pills, hex's pick, Not needed, Undo).
7. Ask cards inside the live call transcript (tap to answer).
8. Agent line ("hex is working…") and connect/end sounds and haptics.
9. Call Live Activity / Dynamic Island with mute and end.
10. Calls sidebar plus past-call transcript and wrap-up (summary, "Waiting on you").
11. Task page (header, Talk it through, Working, Last run, Lately, Places, door links) and thread messages with composer and Stop.
12. Sending photos and videos (camera, picker) in a call and in threads; thumbnails with retry.
13. Voice settings: voice picker with previews, personality, pace, your words; persona/colour/reaction; sounds and haptics toggles.
14. Siri "Ask hex" plus its Live Activity.
15. Update toast (native build install via hangar) and OTA reload.
16. Steps/trace page, hex's picks, last check, pinned post parsing, search, "Go through them with hex".
17. Duo-specific layout: side column, fold-aware split/stacked stage, docked orb in Tasks, transcript beside Tasks, two-page Tasks, Settings in the page area, toast off the hinge.
18. iPad pane layouts, Split View, Esc to close Tasks, offline cached lists, drafts kept across launches.
19. Call elsewhere (watching and ending a phone call from the app), share/delete a call, demo call, pose debug report.
