# Developing Hushhh

## Build

Requirements: Apple silicon, macOS 14+, Xcode 26, and `brew install cmake xcodegen`.

```bash
xcodegen generate
open Hushhh.xcodeproj        # ⌘R
```

The first build fetches the QVAC engine at a pinned commit into `Vendor/qvac-transcribepsy` and compiles it into `Vendor/build-qvac/libparakeet_bundle.a`. This takes about a minute and is skipped afterwards; `FORCE=1 scripts/build-qvac.sh` rebuilds it. On first launch, onboarding asks for permissions and downloads a model into `~/Library/Application Support/Hushhh/Models`.

## Signing and forks

Out of the box the app is ad-hoc signed, so anyone can build it. macOS ties Accessibility permission to the app's signature, though, and an ad-hoc build asks again after every rebuild. To sign with your own Apple developer team, create `Config/Local.xcconfig` (git-ignored):

```
DEVELOPMENT_TEAM = ABCDE12345
CODE_SIGN_STYLE = Automatic
CODE_SIGN_IDENTITY = Apple Development
HUSHHH_BUNDLE_PREFIX = com.example     // forks: use your own, so permissions and Keychain items don't clash
```

Hushhh uses the hardened runtime without the App Sandbox (it needs Accessibility and an event tap), so it can't be distributed through the Mac App Store. To share a build outside the store, sign it with a Developer ID certificate and notarize it.

## How it works

- A session event tap catches Caps Lock (as F18): press once to start and again to finish. Hold-to-talk is optional. Esc cancels. Tab polishes, when enabled. The tap only reacts to those keys.
- Audio is captured at 16 kHz and re-transcribed every ~300 ms, so the ghost text fills in as you speak. Caps Lock runs a final pass over the whole recording and pastes the result in one step, so a single undo removes it.
- With **live typing** on (Settings › General), each word is typed into the field once it has stayed the same for the commit delay (3 s by default). Esc and Tab then replace that typed text only in apps that let Hushhh select it and confirm it matches.
- **Finding the cursor.** Hushhh uses the first method that works for the app, and checks each later position against its own estimate:
  1. Accessibility character positions (most native apps, Chrome, Safari).
  2. A web editor's own caret element (Google Docs).
  3. Laying the field's text out itself at the field's real width (Superhuman, Edge's address bar).
  4. The terminal grid (Ghostty).
  5. A bubble below the line or by the pointer (Google Slides, full-screen terminal apps).
- Ghost text is drawn with TextKit in a non-activating panel, so the app you're typing in keeps focus. When the app doesn't report its font family, Hushhh identifies it from where each character sits. Once the text wraps onto a second line, a backdrop in the page's own colour appears behind it.

## Developer diagnostics

These only run when `HUSHHH_DEV=1` is set:

```bash
APP=build/DerivedData/Build/Products/Debug/Hushhh.app/Contents/MacOS/Hushhh
HUSHHH_DEV=1 $APP --transcribe speech.wav --engine qvac   # or whisper; add --download to fetch the model
HUSHHH_DEV=1 $APP --demo-overlay                          # cycles the overlay through its states
HUSHHH_DEV=1 $APP --polish "some dictated text"           # runs the configured polish provider
HUSHHH_DEV=1 $APP --probe-focus out.log --bundle <id>     # logs what an app reports (includes the end of its text)
HUSHHH_DEV=1 $APP --align-test --bundle <id> --phase draw --no-move --ghost "words"
                                                          # draws red ghost text at that app's cursor (--hero: as users see it)
```

## Alignment results

Alignment is checked by drawing red ghost text at an app's cursor, typing the same text for real, and comparing screenshots. The offset is in points; 0 means pixel-perfect. These are the author's last results, on macOS 26 with the app versions of October 2026; other versions may differ.

| App | How the cursor is found | Offset (left / top / bottom) |
| --- | --- | --- |
| TextEdit | Accessibility positions | 0 / 0 / 0 |
| Notes | Accessibility positions | ≤0.5 |
| Terminal | Accessibility positions, cell-sized monospaced font | 0 / 0.5 / 0 |
| Excel | Cell frame + text measured in the cell's font (Aptos Narrow) | 0 / 0 / 0 |
| Chrome text box | Accessibility positions + font identified from character positions | 0.5 / 0.5 / 0.5 |
| Google Docs | Docs' `kix-cursor-caret` element, Arial | 0.5 / 0 / 0.5 |
| Ghostty | Terminal grid from screen text + config | 0.5 / 0 / 0 |
| Messages (compose) | Accessibility positions | 0.5 / 1 / 1 |
| WhatsApp (message box, search) | Accessibility positions | 0 / 0 / 0 |
| Edge address bar | Text laid out in the field, 7 pt inset | 0.5 / 1 / 0.5 |
| Safari text box | Accessibility (WebKit's zero-length caret; its character boxes are rounded) | 0.5 / 0 / 0 |
| Safari address bar | Accessibility positions | 0 / 0 / 0 |
| Google Slides | Not exposed: bubble by the pointer | — |

## Layout

```
Hushhh/App        app entry, preferences, permissions, diagnostics
Hushhh/Core       dictation controller, hotkey + Caps Lock remap, audio, live transcriber, caret lookup, text insertion, polish
Hushhh/Engines    SpeechEngine protocol, QVAC (Obj-C++ bridge) and Whisper engines, model downloads
Hushhh/UI         overlay, menu bar, Settings window, onboarding
Config            build settings; put your signing identity in Config/Local.xcconfig
scripts           build-qvac.sh fetches and builds the QVAC engine
docs              README images and this guide
```
