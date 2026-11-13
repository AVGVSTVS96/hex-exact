# Building hex Exact

hex Exact is the hex voice app rebuilt in Exact. Exact draws every screen; a small Swift shell
holds what Exact leaves out today (the WebRTC call, Siri, the Live Activity). `docs/parity.md` is
the stable app, screen by screen: it is what done means.

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
| `app/parts.contract` | the design system: surfaces, marks, chips, place tiles, words for times and endings | shared |
| `app/data/*.ts`, `app/app.ts` | hex's endpoints (`hex.ts` is the client and the long poll) | shared |
| `app/call.contract` | Home: the orb, captions, the call's asks, agent line, controls, toolbar | foundation, then (c) for the orb |
| `app/tasks.contract`, `task.contract`, `thread.contract`, `steps.contract`, `picks.contract`, `pick.contract`, `last-check.contract` | all of parity §9 | (a) Tasks |
| `app/calls.contract`, `past-call.contract`, `wrap-up.contract`, `settings.contract`, `voice.contract`, `words.contract`, a new `toast.contract` | §5, 6, 10, 11 | (b) Calls, settings, toast |
| `shell/**`, `app/modules/apple/Hex.swift` | Live Activity, reconnect, interruptions, sounds, camera and photos, the orb | (c) Swift side |

Each screen is a component whose root is its route's keyed `column`; the root passes it what it
shows. Exact allows resources and mutations only in the root, so a screen that needs more data
gets a new prop. Its own `state` (a draft, a chosen option) stays in the screen.

## What the root gives you

**Routes** (`hexexact://go/<path>` opens any): `/` Home · `/calls` · `/calls/:id` · `/tasks` ·
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
```

`app/modules/apple/Hex.swift` is the app's Exact native module. An embed build doesn't build
modules, so the shell builds it as the `ExactModules` framework from the same file plus Exact's
seam (`scripts/module-glue.mjs`); ExactKit loads it by that name. A plain `bun exact.mjs ios`
builds it too, with no shell: the call stays idle.

New call facts (interrupted, reconnecting, elapsed…) go into `Bridge.stateChanged` and the
`CallState` shape together; `data/call.ts` maps them.

## Build, check, screenshot

All from the server, in this folder:

```sh
cd app && EXACT=~/Developer/exact-src/exact bun exact.mjs contract build app.contract --json --errors-only
scripts/sim / /tasks /settings                 # simulator build on the Mac, shots in every pose
BUILT=1 POSES=open-up APPEARANCES="dark light" scripts/sim /calls   # reuse the last build
scripts/ship                                   # new install link on the Duo
scripts/publish                                # screens only, over the air
```

`scripts/sim` shoots into `~/hex/scratch/hex-exact/shots/<commit>/`, poses `cover-up` (folded),
`open-up` (book fold), `open-side` (laptop fold), `cover-side`. Check `memory_pressure` on the Mac
before a build; builds share it with other work. Commit to main, signed, small.

## Where Exact can't (yet)

- Over the air, Exact sends screens (Contract and assets), not `app.ts` or the shell: a data or
  Swift change needs `scripts/ship`.
- A long poll's mapper can't touch storage, so lists aren't kept offline yet; a failed read keeps
  its last answer while the app runs.
- `openURL` in an embedded session goes to the shell, which opens links out (Telegram, T3 Code).
- Exact has no colour well (`input type="color"`), so Settings offers the eight preset colours
  and Opal's nine palettes, without the stable app's custom colour.
- Voice previews are Exact sound effects (WAV, 10 s at most), converted from the stable app's
  m4a files into `assets/voices/`. Exact's audio session is app-wide (`audio_session` in
  app.json); it stays the default `ambient`, so previews follow the silent switch, because a
  `playback` session could take the shell's call audio away mid-call.
- An `image` can't carry hex's token, so hex's photos and videos are the module's `hex-media`
  view (media.contract `Thumb`, `Album`): it fetches with the token and opens Quick Look on a tap.
- The orb is the stable app's six Rive personas, drawn by RiveRuntime in the module
  (`hex-orb persona= tint= palette= reaction=`); a plain `exact ios` build has no Rive and draws
  hex's own sphere instead.
- The orb's squash and stretch with the pitch of Bassim's voice (the stable app's C audio tap on
  the mic) isn't here: WebRTC owns the mic in the shell, so the orb follows its input level only.
- The camera, Photos, the call's Live Activity, its sounds and Siri are the shell's: Exact has no
  camera capture, and the call outlives the screen. Exact's own Live Activities can't follow a
  call the shell holds while the screen sleeps.
