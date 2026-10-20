# Privacy

Hushhh is built so that what you say stays on your Mac unless you choose otherwise.

- **Audio** is captured only while you dictate, processed on your Mac, and never saved or sent anywhere.
- **Speech models** are downloaded once from Hugging Face (`huggingface.co`). The QVAC model is pinned to a specific commit and checked against its SHA-256 before it's used.
- **Polish (optional, off by default).** If you turn it on in Settings › Polish and press Tab, the dictated text, and only that text, is sent to the provider you choose:
  - **Claude Code:** runs `claude -p` on your Mac with your Claude Code login; the text goes to Anthropic.
  - **OpenAI or OpenRouter:** the text goes to that service, using your API key.
  - **Custom endpoint:** any OpenAI-compatible server. A local server such as Ollama or LM Studio keeps the text on your Mac.

  API keys are stored in the macOS Keychain, usable only on this Mac while it's unlocked, and are only sent over HTTPS (plain HTTP is allowed only for `localhost`).
- **Accessibility.** To place the ghost text, Hushhh reads the focused text field: its text, cursor position and font. This stays in memory and is never stored or sent. Password fields are skipped. When you start dictating in a Chrome-based or Electron app, Hushhh switches on that app's accessibility support, as screen readers do, which can cost the app a little CPU and memory.
- **Keyboard.** Hushhh watches for Caps Lock (remapped to F18 while it runs), Esc and Tab during dictation. It doesn't record any other keys.
- **Clipboard.** Inserting pastes the text, then restores your previous clipboard. If no text field has focus, the dictation is copied to the clipboard and replaces what was there.
- **Diagnostic log (off by default).** Settings › General › Troubleshooting can write cursor positions, field sizes and font names (never your text) to `~/Library/Logs/Hushhh/focus.log`, readable only by you.
- **No telemetry or analytics.** Hushhh makes no network requests other than model downloads and the polish provider you choose.
