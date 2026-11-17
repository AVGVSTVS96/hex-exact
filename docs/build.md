# Building hex Exact

hex Exact is the hex voice app rebuilt in Exact. Exact draws every screen; a small Swift shell
holds what Exact leaves out today (the WebRTC call, Siri, the Live Activity). `docs/plan.md` is
what done means and who builds which part; `docs/parity.md` is the stable app, screen by screen.

```
┌──────────── shell/ (Swift) ─────────────────────────────┐
│ Call.swift     WebRTC to hex, captions, levels           │
│ Bridge.swift   the call ⇄ NotificationCenter             │
│ Activity, CallHex, Siri/   Live Activity, Siri           │
│   ┌──────── app/ (Exact) ─────────────────────────┐      │
│   │ app.contract   routes, all data, all actions   │      │
│   │ *.contract     one screen each                 │      │
│   │ app.ts, data/  hex's endpoints, the call       │      │
│   │ modules/apple/Hex.swift  bridge half + hex-orb │      │
│   └────────────────────────────────────────────────┘      │
└──────────────────────────────────────────────────────────┘
```

## Files and who owns them

| File | What | Owner |
|---|---|---|
| `app/app.contract` | routes, every resource, mutation and action, the screen switch | shared: add, don't reshape |
| `app/shapes.contract` | every shape hex answers in | shared |
| `app/parts.contract` | the design system: surfaces, marks, chips, place tiles, section heads (`StageHead`) and "Show N more" (`ShowMore`), words for times and endings | shared |
| `app/data/*.ts`, `app/app.ts` | hex's endpoints (`hex.ts` is the client and the long poll) | shared |
| `app/call.contract` | Home: the orb, captions, the call's asks, agent line, controls, toolbar | foundation, then (c) for the orb |
| `app/home.contract` | Home with no call on: hex's face and live line, Needs you, Working on, what hex decided; on a book fold the page a row opens beside | Muse (1) |
| `app/needs.contract` (Needs you in full), `tasks.contract`, `task.contract`, `thread.contract`, `steps.contract`, `picks.contract`, `pick.contract`, `last-check.contract`, `ask.contract` (a question's card and own-words reply), `inbox.contract` (the ranked list of everything), `rows.contract` (its rows and swipes), `said.contract` (what was answered or sent from here), `app.tamber` (hex's colours) | all of parity §9 | (a) Tasks |
| `app/calls.contract`, `past-call.contract`, `wrap-up.contract`, `settings.contract`, `voice.contract`, `words.contract`, a new `toast.contract` | §5, 6, 10, 11 | (b) Calls, settings, toast |
| `shell/**`, `app/modules/apple/Hex.swift` | Live Activity, reconnect, interruptions, sounds, camera and photos, the orb | (c) Swift side |

Each screen is a component whose root is its route's keyed `column`; the root passes it what it
shows. Exact allows resources and mutations only in the root, so a screen that needs more data
gets a new prop. Its own `state` (a draft, a chosen option) stays in the screen.

## What the root gives you

**Routes** (`hexexact://go/<path>` opens any): `/` Home · `/needs` · `/feed/:id` (a Feed story) ·
`/ideas/:id` · `/goals/:id` · `/decided` · `/calls` · `/calls/:id` · `/tasks` ·
`/tasks/t/:id` · `/tasks/t/:id/messages` · `/tasks/t/:id/steps` · `/tasks/picks` ·
`/tasks/picks/:id` · `/tasks/check` · `/settings` · `/settings/voice` · `/settings/voice/words`.

**Resources**, live without timers: `activity`, `counts`, `calls`, `tasks`, `asks` follow hex
through Exact's long poll (`exactLongPoll` on `?after=<version>`, `data/hex.ts` `watch`); `task`
and `chat` follow the open task; `record` the open call (live ones follow, ended ones read once);
`check`, `settings`, `words` are read while their screen is open. `call` and `captions` come from
the shell through the native module (`native.watch`), so they change the moment the call does.
`viewport` (Duo segments, posture, safe areas, keyboard) and `clock`; `now`/`offset` tick each
minute.

**Actions**: `startCall(about)`, `toggleMute`, `endCall`, `talk(about)` (into the live call, or a
new call about it); `answer`, `answerMany`, `answerAll` (picks), `note`, `dismiss`, `undo`,
`act` (stuck), `markRead` (fresh), `showWords`; `message`, `stop`; `removeCall`; `setSetting`
(voice, personality, pace, words on hex) and the phone's own `setPersona`, `setPersonaColor`,
`setReaction`, `setSounds`, `setHaptics` (persisted); `open(path)`, `openTasks(tab)`,
`openTask(id)`, `back`, `home`. Each write's reply is its mutation slot (`answered`, `noted`…):
read `pending(x)` and the reply's `error`.

**Media** goes as ids from `POST /media`: every send takes a `media` list. The camera and Photos
are the shell's (shell/Shell/Media.swift); `media.contract` has the parts:

```
AddMedia(menu, label, glass, size, disabled, add)   "+" with a Camera / Photos menu
Waiting(media, remove)                              what waits in a composer, each with ×
Album(media, width) · Thumb(media, width, square)   pictures (the hex-media view: authed, tap to look)
```

**Questions** look the same everywhere: `AskCard` (ask.contract) sits flat on the page, in a
`section background-color="transparent"`, and every answer on the task page, the pick page and the
call is an `AnswerRow`. **hex decided** is `asks.decided`, the last week of what hex decided
itself: questions it answered with its own pick (`took`; money ones stay in Needs you) and ones
its check handed back to it, each with its reason. hex's server makes that call, so Home, Tasks
and their counts agree without a rule of their own. `undo` on a decided one puts it back on Needs
you, and hex won't take it again.

A composer passes its key (`thread:<id>`, `ask:<id>`): root `attach(key, source)` picks and
uploads, `attached` (Media[]) holds them while `attachedTo == key`, `detach(id)` takes one out.
Its send passes `attached.map(m => m.id)` when `attachedTo` is its key, and clears `attached`.
In the call, `share(source)` sends into the live call; the shell shows them among the captions
(`Caption.media`, `note`: sending / why not), and `reshare(key)` tries again.

## The bridge

```
Contract ── callCommand(op) ──▶ app.ts ── native.later ──▶ Hex.swift ─HexCallCommand─▶ Bridge ─▶ Call
Call ─▶ Bridge ─HexCallState / HexCaptions─▶ Hex.swift ── changed("call") ──▶ app.ts ──▶ call, captions
Call ─▶ Bridge ─HexCallLevels (8/s)─▶ hex-orb (native view; levels never cross into Contract)
Screen ─HexPose─▶ Hex.swift ── changed("pose") ──▶ app.ts ──▶ pose (bar side, fold, cutouts)
```

Exact's viewport gives the Duo's segments and safe areas; the shell's `Screen` (the window's root)
adds what the stable app's Pose module read: which side the system bars take (the 84-pt column on
the cover screen and the book fold), the fold, and what the cameras cover. Home and `CallDock` place
the toolbar and the call's buttons from it (call.contract `barOf`, `columnTopOf`, `bandOf`).

`app/modules/apple/Hex.swift` is the app's Exact native module. An embed build doesn't build
modules, so the shell builds it as the `ExactModules` framework from the same file plus Exact's
seam (`scripts/module-glue.mjs`); ExactKit loads it by that name. A plain `bun exact.mjs ios`
builds it too, with no shell: the call stays idle.

New call facts (interrupted, reconnecting, elapsed…) go into `Bridge.stateChanged` and the
`CallState` shape together; `data/call.ts` maps them.

## Build, check, screenshot

All from the machine hex runs on (server or twin), in this folder:

```sh
cd app && EXACT=~/Developer/exact-src/exact bun exact.mjs contract build app.contract --json --errors-only
scripts/sim / /tasks /settings                 # simulator build on the Mac, shots in every pose
BUILT=1 POSES=open-up APPEARANCES="dark light" scripts/sim /calls   # reuse the last build
scripts/sim scripts/flows/answer.flow          # a flow: taps, types, swipes, folds, a shot per step
scripts/phone                                  # a picture of the real Duo's screen
scripts/responds                               # does it answer taps? scripts/ship and publish ask first
scripts/ship                                   # new install link on the Duo
scripts/publish                                # screens only, over the air
cd app && bun exact.mjs test web               # app.test.contract, about 3 minutes
```

The install link and the update stream are `https://updates.<tailnet>/hex-exact/`, a name that
follows hex between the server and the twin. Each machine serves the same folder there, which
Syncthing keeps alike (folder `exact`):
`sudo tailscale serve --service=svc:updates --set-path=/hex-exact --bg ~/.local/share/hex-exact/link`.
Builds up to 125 have the server's own name baked in, so they hear of updates only while the server answers.

`app.test.contract` drives the main flows without hex or the shell (Home, the screens it opens,
what Settings keeps on the phone); its tests read no hex data, so they pass offline. On the server
Exact's web build prints "built" and then never exits (the app's data keeps a timer alive in its
build-time realm), so `exact test web` waits forever: run it with an `EXACT` whose
`host/web-js/build.mjs` ends in `process.exit(0);` until Exact exits there itself.

`scripts/sim` shoots into `~/hex/scratch/hex-exact/shots/<commit>/`, in poses `cover-up` (folded),
`cover-side`, `open-up` (book fold) and `open-side` (laptop fold). A flow (`scripts/flows/*.flow`,
its commands at the top of `scripts/uitests/Flows.swift`) is played by XCUITest, finding controls
by `testId`; each `shoot` lands in `<flow>/`, with what failed in `notes.txt` and the testIds on
screen in `tree-*.txt`. The simulator's app talks to hex through `scripts/standin.mjs` on the Mac:
reads reach hex, writes never do, and each run lists what it would have sent. Check `memory_pressure` on the Mac
before a build; builds share it with other work. Commit to main, signed, small.

## Where Exact can't (yet)

Checked line by line against Exact's main (`ac889988`, Nov 15) and the pin (`7722882`). None is
lifted by main, so the pin stays: moving costs the `app.tamber` → `app.forma` rename,
`answerOpenURL` → `openURLAnswer` in `App.swift`, Rust 1.99 and a new install for everyone.

- Over the air, Exact sends screens (Contract and assets), and Exact's docs say it sends a signed
  TypeScript bundle too when its grants match the installed build; untried here, so a data change
  still goes by `scripts/ship` until an `app.ts`-only `scripts/publish` is seen on the Duo. Swift
  always needs `scripts/ship`.
- A long poll's mapper can't touch storage, so it notes each answer and a second read keyed on the
  poll's version (`keep`, data/kept.ts) writes it to app storage; a launch that can't reach hex
  shows the kept Tasks, questions, counts and Calls until it can.
- `openURL` in an embedded session goes to the shell, which opens links out (Telegram, T3 Code)
  and says whether they opened (`openURL(url, "opened")`, how "isn't on this iPhone" shows).
- Exact has no colour well (`input type="color"`), so the custom persona colour is the module's
  `hex-color` view, iOS's `UIColorWell`.
- Exact's sounds follow the silent switch (its audio session is app-wide and stays `ambient`, so
  it can't take the call's audio), so voice previews are the shell's: `callCommand("preview")`
  plays the stable app's m4a with a `playback` session, only between calls.
- The update toast hears of a build from hangar's server-sent `apps` events while the app is in
  front; a dropped stream comes back the next time the app does.
- An `image` can't carry hex's token, so hex's photos and videos are the module's `hex-media`
  view (media.contract `Thumb`, `Album`): it fetches with the token and opens Quick Look on a tap.
  Exact could instead `fetch(…, { exactBodyTo: "app:/…" })` with the token and show the file
  (`image src="app:/…"`); Quick Look would stay the module's.
- The orb is the stable app's six Rive personas, drawn by RiveRuntime in the module
  (`hex-orb persona= tint= palette= reaction=`); a plain `exact ios` build has no Rive and draws
  hex's own sphere instead.
- The camera, Photos, the call's Live Activity, its sounds and Siri are the shell's: Exact has no
  camera capture, and the call outlives the screen. Exact's own Live Activities can't follow a
  call the shell holds while the screen sleeps.
- iOS pushes a list's detail rather than splitting until LLP 1127, so Tasks beside its page (the
  Duo opened like a book, a window 900 wide) is two panes in the Tasks route, the page beside on
  the second segment; its thread, Steps and picks still push over both.
- Root `state` holds only strings, numbers and bools, so what was answered, put away or sent from
  here, hex's picks as left, and drafts are lines of tab-separated fields (`said.contract`).
  Exact's grammar documents `state` holding lists and records, at the pin too; only `persist` keeps
  to scalars and lists of them. Unchecked in a build here.
- A phone's Tasks is a sheet that stops at half height during a call, but the call under it
  stays dimmed and untouchable: Exact's sheets have no undimmed detent (the stable app's
  `largestUndimmedDetent` at medium). Exact main (after the pin) lets a `dialog` sheet's backdrop
  be transparent, but it still takes the touches.
