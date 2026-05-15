# Whistt Architecture

Internal architecture of the Whistt push-to-talk app for macOS, built on the OpenAI Realtime WebSocket.

## 1. Module layout

SwiftPM provides the `WhisttCore` library and the `realtime-probe` CLI; the Xcode `Whistt` app shares its common logic through `WhisttCore`. Tests and the CLI only consume the pure-Foundation portion that does not touch AVFoundation/AppKit.

```mermaid
flowchart TB
    subgraph SPM["Package.swift (SwiftPM)"]
        direction TB
        Core["WhisttCore<br/>(library)"]
        Probe["realtime-probe<br/>(executable)"]
    end

    subgraph CoreFiles["WhisttCore sources (pure Foundation)"]
        direction TB
        EnvLoader["EnvLoader.swift"]
        Keychain["KeychainStore.swift"]
        Proto["RealtimeProtocol.swift"]
        WS["RealtimeWS.swift"]
    end

    subgraph App["Whistt macOS app (Xcode target)"]
        direction TB
        WhisttApp["WhisttApp.swift"]
        AppDelegate["AppDelegate.swift"]
        HotKey["HotKeyManager.swift"]
        Agent["WhisperNativeAgent.swift"]
        Typing["TypingEmulator.swift"]
        Log["WhisttLog.swift"]
    end

    subgraph Tests["Tests/WhisttCoreTests"]
        direction TB
        EnvTests["EnvLoaderTests"]
        ProtoTests["RealtimeProtocolTests"]
    end

    Core --> CoreFiles
    Probe --> Core
    App --> CoreFiles
    Tests --> Core
```

## 2. Responsibilities and callback wiring

`AppDelegate` is the orchestrator. `HotKeyManager` callbacks drive `WhisperNativeAgent`, and the transcript delta/final stream is dispatched to the chosen output sink (typing or clipboard).

```mermaid
flowchart TB
    User((User))
    WhisttApp["WhisttApp<br/>SwiftUI @main"]
    AppDelegate["AppDelegate<br/>NSStatusItem / Menu / Orchestrator"]
    HotKey["HotKeyManager<br/>CGEventTap"]
    Agent["WhisperNativeAgent"]
    AVEng["AVAudioEngine<br/>+ AVAudioConverter"]
    WS["RealtimeWS"]
    Proto["RealtimeProtocol<br/>encode / decode"]
    Typing["TypingEmulator<br/>CGEvent unicode"]
    Clipboard["ClipboardOutput<br/>NSPasteboard"]
    OpenAI[(OpenAI Realtime WS<br/>wss://...?intent=transcription)]

    WhisttApp -- "@NSApplicationDelegateAdaptor" --> AppDelegate
    User -- "⌥+Space hold/release" --> HotKey
    HotKey -- "onStart / onStop" --> AppDelegate
    AppDelegate -- "start / stop / model select" --> Agent
    User -- "microphone" --> AVEng
    Agent --> AVEng
    AVEng -- "pcm16 / 24kHz mono" --> Agent
    Agent -- "sendAudio / sendCommit" --> WS
    WS <-- "append / commit / session events" --> OpenAI
    WS -. "RealtimeEvent.decode" .-> Proto
    Proto -.-> Agent
    Agent -- "onTranscriptDelta" --> AppDelegate
    Agent -- "onTranscriptComplete" --> AppDelegate
    Agent -- "onError" --> AppDelegate
    AppDelegate -- "typing mode: per delta" --> Typing
    AppDelegate -- "clipboard mode: final only" --> Clipboard
    Typing -- "post CGEvent" --> User
    Clipboard -- ".string pasteboard" --> User
```

## 3. Execution sequence (one push-to-talk turn)

```mermaid
sequenceDiagram
    autonumber
    actor U as User
    participant HK as HotKeyManager
    participant AD as AppDelegate
    participant WA as WhisperNativeAgent
    participant WS as RealtimeWS
    participant API as OpenAI Realtime

    U->>HK: hold ⌥+Space (keyDown 49)
    HK->>AD: onStart()
    AD->>WA: start()
    WA->>WS: connect()
    WS->>API: WebSocket open (Bearer apiKey)
    API-->>WS: session.created
    WA->>WS: sendSessionUpdate(model)
    WS->>API: session.update (transcription, pcm16, turn_detection: null)
    API-->>WS: session.updated

    loop while talking
        U->>WA: microphone (AVAudioEngine tap)
        WA->>WA: convert → pcm16/24kHz mono → base64
        WA->>WS: sendAudio(data)
        WS->>API: input_audio_buffer.append
        API-->>WS: transcription delta
        WS-->>WA: RealtimeEvent.delta
        WA-->>AD: onTranscriptDelta(text)
        AD->>U: TypingEmulator.type(delta)
    end

    U->>HK: release ⌥ (flagsChanged)
    HK->>AD: onStop()
    AD->>WA: stop()
    WA->>WA: removeTap, audioEngine.stop()

    alt bytes sent ≥ 4800 (≈100ms)
        WA->>WS: sendCommit()
        WS->>API: input_audio_buffer.commit
        API-->>WS: final transcript
        WS-->>WA: RealtimeEvent.finalTranscript
        WA-->>AD: onTranscriptComplete(full)
        opt clipboard mode
            AD->>U: ClipboardOutput.set(full)
        end
    else too short
        Note over WA: skip commit
    end
    Note over WA,WS: close WS after 3s grace
```

## 4. WhisttCore boundary (testable line)

Files that depend on AVFoundation / AppKit / CoreGraphics are confined to the Xcode target, and only the parts that can be written in pure Foundation are extracted into `WhisttCore`. This is what makes both `swift test` and the `realtime-probe` CLI viable consumers.

```mermaid
flowchart LR
    subgraph Core["WhisttCore (pure Foundation, testable)"]
        direction TB
        Env["EnvLoader"]
        Kchn["KeychainStore<br/>(Security framework)"]
        ProtoTypes["RealtimeProtocol<br/>• RealtimeOutgoingType<br/>• RealtimeIncomingType<br/>• RealtimeSessionUpdate<br/>• RealtimeMessage (encode)<br/>• RealtimeEvent (decode)"]
        WSC["RealtimeWS<br/>(URLSessionWebSocketTask)"]
    end

    subgraph AppOnly["app-only (Xcode target)"]
        direction TB
        A1["WhisttApp"]
        A2["AppDelegate"]
        A3["HotKeyManager"]
        A4["WhisperNativeAgent"]
        A5["TypingEmulator / ClipboardOutput"]
        A6["WhisttLog"]
    end

    subgraph ProbeCLI["realtime-probe CLI"]
        Main["Tools/RealtimeProbe/main.swift"]
    end

    subgraph T["Tests/WhisttCoreTests"]
        T1["EnvLoaderTests"]
        T2["RealtimeProtocolTests"]
    end

    AppOnly -- "import WhisttCore" --> Core
    ProbeCLI -- "import WhisttCore" --> Core
    T -- "@testable import WhisttCore" --> Core
```

## Design highlights

- **Three products**: macOS app proper / `WhisttCore` library / `realtime-probe` CLI. The shared logic (`EnvLoader` / `KeychainStore` / `RealtimeProtocol` / `RealtimeWS`) is extracted into WhisttCore so it can be reused by the CLI and unit tests.
- **API key storage**: The app uses `KeychainStore` (generic-password, service `so.lai.whistt`, account `OPENAI_API_KEY`) as the primary source. Lookup order: `ProcessInfo` env > Keychain > legacy `.env` (auto-migrated into the Keychain on first launch, with a one-time notice shown to the user) > re-entry dialog from the menu bar. The CLI / tests continue to read `.env` via `EnvLoader` (the CLI is unsigned and cannot access the app's Keychain entry).
- **Input trigger**: `HotKeyManager` watches ⌥+Space through `CGEventTap` (`cgSessionEventTap` + `headInsertEventTap`). The Space key is swallowed so it never leaks to the frontmost app.
- **Audio path**: Microphone → `AVAudioEngine.inputNode` tap → `AVAudioConverter` to pcm16/24kHz/mono → base64 → `input_audio_buffer.append` over `RealtimeWS` at 10–20 messages/s. `audioAppend` is on the hot path, so it builds the JSON via string interpolation instead of `JSONSerialization`.
- **WS protocol**: Endpoint is `wss://api.openai.com/v1/realtime?intent=transcription`. The URL `model=` query parameter targets *conversation* models, so we do not use it; the transcription model goes into `session.audio.input.transcription.model`. `turn_detection: null` forces manual commit.
- **Stop handling**: `audioEngine.stop()` → if at least 4800 bytes (≈100ms) have been sent, emit `input_audio_buffer.commit`. The WS is closed after a 3-second grace period to allow the final transcript to arrive.
- **Output modes**: Typing mode emits each delta into the frontmost app via `CGEvent` Unicode input. Clipboard mode writes only the final transcript to `NSPasteboard`, so clipboard-history tools don't capture intermediate state.
- **Testability boundary**: AVFoundation / AppKit code lives in the app target; only pure-Foundation code is separated into WhisttCore. This is what enables both `swift test` and CLI validation.
