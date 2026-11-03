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
