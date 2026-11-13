# hex Exact

An experimental hex voice app: its screens are built in [Exact](https://github.com/expo/exact), Expo's Rust app framework (pre-alpha), and a small Swift shell around them holds what Exact leaves out today: the WebRTC call, the camera, Siri and the Live Activities. It installs beside the stable [hex voice](https://github.com/AVGVSTVS96/hex-voice) app as its own app, `com.shahidy.hexexact`.

```
┌──────────── shell/ (Swift, UIKit) ─────────────┐
│ Call      WebRTC to hex's voice server          │
│ Tone      your voice's pitch, for the orb       │
│ Media     the camera and Photos                 │
│ CallHex   Siri: "Call hex in hex Exact"         │
│ AskHex    Siri: Ask hex (as the stable app)     │
│ Activity  the call's and Ask hex's Live         │
│           Activities                            │
│                                                 │
│   ┌──────── Exact session (app/) ──────────┐    │
│   │ *.contract  every screen               │    │
│   │ app.ts      hex's data, the call       │    │
│   │ modules/apple/Hex.swift  the bridge,   │    │
│   │             the orb, hex's photos      │    │
│   └────────────────────────────────────────┘    │
└─────────────────────────────────────────────────┘
screen → shell: start, mute, end, share, attach, retry (the Hex module)
shell → screen: the call's state, captions, levels and tone
hexexact://go/<path> opens a screen; hexexact://demo[/<path>] a demo call
```

- `app/` is the Exact app. Exact's own delivery updates its screens (the Contract plan and assets) over the air; TypeScript data code and the shell need a new build.
- `shell/` is the Swift app (`project.yml`, generated with xcodegen), which links ExactKit and the Exact embed build of `app/`.
- `scripts/sim` builds for the simulator and screenshots each pose; `scripts/ship` builds both on the Mac, signs with the paid team and puts it on its install link.
- `docs/build.md` is how it fits together; `docs/parity.md` is the stable app, screen by screen.
