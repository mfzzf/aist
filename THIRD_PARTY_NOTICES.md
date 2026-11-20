# Third-party notices

## Cicada (知了)

Parts of Aist's live meeting transcription are adapted from [Cicada](https://github.com/wquguru/cicada)
by wquguru, licensed under the Apache License 2.0
(<https://www.apache.org/licenses/LICENSE-2.0>):

- `Sources/AistCore/HeardText.swift` — tidying recognised lines and rejoining sentences cut at a pause (from `HeardText.swift`)
- `Sources/AistCore/MeetingEndWatch.swift` — deciding when a meeting is over (from `MeetingEnd.swift`)
- `Sources/AistMac/CallWatcher.swift` — which meeting apps are reading a microphone (from `MicUsers.swift`)
- `Sources/AistMac/LiveTranscriber.swift` — streaming SpeechAnalyzer input, cutting long lines, spoken-language detection
  (from `ListenEngine.swift`, `AudioRouter.swift`, `LanguageDetector.swift`)

These files were modified for Aist: two speakers (microphone and system audio) on one meeting timeline,
microphone-echo removal, different thresholds for Chinese, and Aist's own settings and UI.

## FluidAudio

Telling the voices in a recording apart (`Sources/AistAudio/VoiceSeparator.swift`) uses
[FluidAudio](https://github.com/FluidInference/FluidAudio) by FluidInference, licensed under the
Apache License 2.0 (<https://www.apache.org/licenses/LICENSE-2.0>). Only its diarizer is built in.

## pyannote speaker-diarization-community-1 (Core ML)

The models that do it are downloaded on first use, not shipped with the app:
[FluidInference/speaker-diarization-coreml](https://huggingface.co/FluidInference/speaker-diarization-coreml),
a Core ML conversion by FluidInference of
[pyannote/speaker-diarization-community-1](https://huggingface.co/pyannote/speaker-diarization-community-1)
by pyannoteAI, licensed under Creative Commons Attribution 4.0 International
(<https://creativecommons.org/licenses/by/4.0/>). Aist fetches the files unmodified, from Hugging Face
or a mirror of it, and checks each against its SHA-256 (`Sources/AistAudio/SpeakerModels.swift`).
