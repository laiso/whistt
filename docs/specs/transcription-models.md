# Transcription Models

This specification defines the transcription models exposed by Whistt.

## Supported models

| Provider | Model | Delivery | Reference price/hour |
|---|---|---|---:|
| OpenAI | `gpt-transcribe` | Final transcript after the push-to-talk turn is committed | $0.27 |
| OpenAI | `gpt-live-transcribe` | Final transcript after the push-to-talk turn is committed | $1.02 |
| Google Gemini | `gemini-3.5-transcribe-live` | Revisable interim results kept internal; final transcript is inserted | approx. $0.54 |
| Meta | `muse-voice-transcribe-1.0` | Final transcript only | $0.18 |
| xAI | `xai-streaming-stt` | Revisable interim results kept internal; final transcript is inserted | $0.20 |
| Microsoft Azure | `mai-transcribe-2` | Final transcript only; preview | $0.10* |

## Requirements

- The model menu shall expose only the models in the supported-model table.
- The first model in the table, `gpt-transcribe`, shall be the default.
- A saved or environment-provided model that is not supported shall fall back to the default and a stale saved value shall be replaced.
- Whistt shall use one output path for every supported model: interim events remain internal and only the completed transcript is inserted once.
- Both `gpt-transcribe` and `gpt-live-transcribe` shall commit audio when push-to-talk ends and use that final-only output path.
- Real-time cursor insertion from transcript deltas is outside the current output contract. It may be added separately for models that provide append-safe deltas; see GitHub issue #17.
- Whistt shall not expose `gpt-realtime-whisper`.
- Model selection controls shall present a flat list whose rows show vendor, model name, and reference price in US dollars per audio hour. Delivery semantics shall not be used as section headings. Prices are informational and shall not be treated as billing guarantees.
- Adding or replacing a model requires confirmation that its production API accepts Whistt's audio format and push-to-talk lifecycle.
