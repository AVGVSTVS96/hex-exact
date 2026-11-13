# AI Elements Persona assets

These are the original Rive assets distributed by [AI Elements Persona](https://elements.ai-sdk.dev/components/persona), downloaded on September 15, 2026. They are bundled unchanged so native Release builds work offline.

Source component: [6a9d5b1822ff](https://raw.githubusercontent.com/vercel/ai-elements/6a9d5b1822ffb10bba4bd97175f01edd7d8651cd/packages/elements/src/persona.tsx). `manifest.json` records each original URL, byte size, and SHA-256 digest. The asset filenames are shortened locally; `opal.riv` is the upstream `orb-1.2.riv`.

AI Elements is Copyright 2023 Vercel, Inc., Apache License 2.0. The upstream notice is retained in `LICENSE.ai-elements` and the full license is in `LICENSE-2.0.txt`. The native and web renderers are adaptations: local asset loading, native Rive bindings, colors chosen in settings, reduced motion, paused previews, and the existing Opal default.

## Runtime details

All six files were decoded in the Rive WebGL2 runtime. Every file has a state machine named `default` and boolean inputs `listening`, `thinking`, `speaking`, and `asleep`. Idle clears these four inputs. Other inputs are left untouched.

| Variant  | Upstream file    | View model | Color                     |
| -------- | ---------------- | ---------- | ------------------------- |
| Obsidian | obsidian-2.0.riv | `color`    | Chosen in settings, white |
| Mana     | mana-2.0.riv     | `color`    | Original blue             |
| Opal     | orb-1.2.riv      | None       | Original mix or a hue     |
| Halo     | halo-2.0.riv     | `color`    | Chosen in settings, white |
| Glint    | glint-2.0.riv    | `color`    | Chosen in settings, white |
| Command  | command-2.0.riv  | `color`    | Chosen in settings, white |

The 2.0 view model only controls color. Conversation states use the four state-machine booleans, as in the upstream component. Opal also has a numeric `color` state-machine input: 2 to 9 pick red, orange, yellow, green, teal, blue, purple and pink, and other values keep its original mix. Native views bind their own view model instance, because the auto-bound one drops color for every 2.0 file but Halo, and the first advance after binding writes the file's color back, so the renderer re-applies the chosen color when that happens. Web uses `@rive-app/react-webgl2`, since Canvas does not render all blur effects in these assets.

The native renderer loads files only when requested and shares at most six decoded files for the app process lifetime. Each rendered view has its own state machine and data model. Switching variants remounts only that view, and a cancelled load cannot update its replacement. The call controller and microphone are independent of this visual.
