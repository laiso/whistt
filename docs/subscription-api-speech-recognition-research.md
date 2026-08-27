# サブスクリプション API で音声認識するには

## 目的

OpenAI Platform API の従量課金を避け、ユーザーがすでに契約している ChatGPT Plus/Pro などのサブスクリプション枠で、音声認識・音声入力を実現できるかを検証する。

目標は、OpenAI Platform API key による追加課金ではなく、ChatGPT/Codex OAuth token を BYO（Bring Your Own）して、音声入力から AI 応答までをサブスクリプション側の制限・利用枠で扱えるか確認すること。

## 調査結果

### 1. Codex OAuth token で Codex Responses API は叩ける

ChatGPT/Codex OAuth token を使い、以下の endpoint は成功した。

```text
POST https://chatgpt.com/backend-api/codex/responses
```

必要な主なヘッダー:

```http
Authorization: Bearer <codex oauth access token>
chatgpt-account-id: <JWT内のchatgpt_account_id>
originator: <client identifier>
OpenAI-Beta: responses=experimental
accept: text/event-stream
content-type: application/json
```

一方で、通常の OpenAI Platform endpoint は同じ token では失敗した。

```text
POST https://api.openai.com/v1/responses
=> HTTP 401
=> missing scope: api.responses.write
```

したがって、ChatGPT/Codex subscription token は **public OpenAI Responses API 用ではなく、ChatGPT backend の Codex Responses API 用**として扱う必要がある。

### 2. Realtime transcription API は Codex OAuth token だけでは成功確認できなかった

以下を試したが、リアルタイム文字起こし WebSocket としては成功しなかった。

```text
wss://api.openai.com/v1/realtime?intent=transcription
Authorization: Bearer <codex oauth access token>
```

観測結果:

- `oauth-intent`: HTTP 500
- `oauth-modelintent`: WebSocket は開くが `invalid_model`
- `oauth-nada`: WebSocket は開くが `missing_model`
- OAuth token で `/v1/realtime/client_secrets` の mint は HTTP 200 になるが、mint した ephemeral key で WebSocket 接続すると HTTP 500

つまり、Codex OAuth token は一部 Realtime 周辺 endpoint に到達できるが、リアルタイム文字起こし用途として利用可能とは判断できない。

### 3. openai/codex repo には voice / realtime 実装がある

openai/codex には以下の実装が存在する。

- `ThreadRealtimeStart`
- `ThreadRealtimeAppendAudio`
- `ThreadRealtimeTranscriptDelta`
- `ThreadRealtimeTranscriptDone`
- `RealtimeVoice`
- `gpt-realtime-1.5`

主なファイル:

```text
codex-rs/app-server-protocol/src/protocol/v2/realtime.rs
codex-rs/core/src/realtime_conversation.rs
codex-rs/codex-api/src/endpoint/realtime_websocket/*
```

ただし Codex 側実装にも次の制約がある。

```rust
"realtime conversation requires API key auth"
```

コメントでも、ChatGPT/SIWC sessions の realtime auth がまだ API key を要求する一時的状態であることが示されている。

## 課題

### 最大の課題

**ChatGPT subscription OAuth token だけで音声認識 Realtime API を安定して使う方法が確認できていない。**

Codex OAuth token で Codex Responses は使えるが、Realtime transcription は API key 前提に見える。

### 技術課題

1. Codex OAuth token の正式対応範囲が不明
   - `chatgpt.com/backend-api/codex/responses` は使える
   - `api.openai.com/v1/responses` は scope 不足
   - `api.openai.com/v1/realtime` は成功しない

2. Realtime voice 実装は Codex repo にあるが API key auth 前提
   - subscription token で直接使える設計にはまだ見えない

3. Realtime transcription と Codex Responses で endpoint/auth 体系が違う
   - Realtime transcription: `api.openai.com/v1/realtime?intent=transcription`
   - Codex OAuth Responses: `chatgpt.com/backend-api/codex/responses`

4. 音声認識と推論を同じ subscription token で完結できない可能性が高い

5. 従量課金回避という目的に対して、STT 部分だけ API key 課金が残る可能性がある

## 現実的な設計方針

現時点では、音声認識と Codex 推論を分離する。

```text
音声入力 / STT
  -> transcript text
  -> アプリ内入力欄またはプロンプト生成層
  -> Codex OAuth Responses API
```

候補:

1. ローカル STT または OS 標準音声認識で transcript を生成する
2. transcript をアプリ内入力欄へ挿入する
3. ユーザー確認後、Codex OAuth Responses API で推論する

OpenAI Platform API key を使った Realtime transcription は技術的には可能だが、従量課金を避けるという目的からは外れる。

## 結論

- **サブスクリプション token で Codex Responses API は利用可能。**
- **サブスクリプション token だけで Realtime 音声認識を行う方法は未確認。**
- 従量課金を避けるには、音声認識はローカル STT または OS 標準音声認識に寄せ、生成されたテキストを Codex OAuth Responses API に渡す方式が現実的。
