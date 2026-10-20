# Third-Party Notices

Hushhh is MIT-licensed (see `LICENSE`). It builds on the following projects, each under its own license.

## Compiled into the app

| Component | License | Source |
| --- | --- | --- |
| QVAC TranscribePsy engine (parakeet.cpp) | Apache-2.0 | https://github.com/tether-ai-research/qvac-transcribepsy |
| ggml (bundled with QVAC) | MIT | https://github.com/ggml-org/ggml |
| dr_wav (bundled with QVAC) | Unlicense or MIT-0 | https://github.com/mackron/dr_libs |
| WhisperKit | MIT | https://github.com/argmaxinc/WhisperKit |
| swift-argument-parser (a WhisperKit dependency) | Apache-2.0 | https://github.com/apple/swift-argument-parser |

The QVAC engine is fetched at a pinned commit by `scripts/build-qvac.sh`; its `LICENSE` and `NOTICE` files (which list the licenses of its own bundled dependencies) are included in that checkout and must accompany any distribution of the compiled engine.

## Downloaded at runtime (not included in this repository)

| Model | License | Source |
| --- | --- | --- |
| TranscribePsy-250M-EU-sub (GGUF) | Apache-2.0 | https://huggingface.co/qvac/TranscribePsy-250M-EU-sub-gguf |
| Whisper models, Core ML conversions | MIT | https://huggingface.co/argmaxinc/whisperkit-coreml |

## Apache-2.0 notice

Portions of this product are derived from the QVAC TranscribePsy engine, Copyright 2026 QVAC contributors, licensed under the Apache License, Version 2.0 (https://www.apache.org/licenses/LICENSE-2.0).
