# hex Exact

An experimental hex voice app: its screen is built in [Exact](https://github.com/expo/exact), Expo's Rust app framework (pre-alpha), and a small Swift shell around it holds what Exact leaves out today: the WebRTC call, Siri and the Live Activity. It installs beside the stable [hex voice](https://github.com/AVGVSTVS96/hex-voice) app as its own app, `com.shahidy.hexexact`.

```
┌──────────── shell (Swift, UIKit) ────────────┐
│ Call       WebRTC to hex's voice server       │
│ CallHex    Siri: "Call hex in hex Exact"      │
│ AskHex     Siri: Ask hex (as the stable app)  │
│ Activity   the call's Live Activity           │
│                                               │
│   ┌──────── Exact session (app/) ────────┐    │
│   │ app.contract  the screen             │    │
│   │ app.ts        reads hex's calls      │    │
│   └──────────────────────────────────────┘    │
└───────────────────────────────────────────────┘
screen → shell: openURL("hexexact://call" | "…/mute" | "…/end")
shell → screen: navigate("/call/<status>/<mic>" | "/failed/<why>")
```

- `app/` is the Exact app. Exact's own delivery updates its screen (the Contract plan and assets) over the air; TypeScript data code isn't delivered over the air by Exact yet.
- `shell/` is the Swift app (`project.yml`, generated with xcodegen), which links ExactKit and the Exact embed build of `app/`.
- `scripts/ship` builds both on the Mac, signs with the paid team and puts it on its install link.
