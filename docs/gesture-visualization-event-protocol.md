# Gesture Visualization Event Protocol

## Goal

Define one small cross-client protocol for rendering touch/gesture overlays with a steady-state end-to-end target of `<= 30 ms` from:

1. client decides to perform a gesture
2. overlay consumer starts rendering it

This protocol is for live visualization only. It is not the source of truth for action history, replay, or recording export.

## Non-goals

- durable action logs
- replay scripts
- exact post-facto audit history
- transport over network
- coupling to a specific tool like `blitz-iphone`

## Design summary

Use two layers:

1. Live transport: local Unix domain datagram socket
2. Optional mirror: append-only JSONL for debugging and later ingestion

The socket is the protocol's primary path. JSONL is explicitly not on the critical path.

## Why this shape

The current single-file watcher approach is too lossy and too slow/variable for a 30 ms target:

- one mutable file means bursty events can overwrite each other
- file watching and re-open logic add jitter
- startup can replay stale state

A local datagram socket avoids those issues:

- one send per gesture event
- no file replacement races
- no polling
- no replay of stale state on app startup
- low steady-state latency on the same machine

## Latency budget

Target steady-state path:

- producer encode + send: `<= 2 ms`
- kernel delivery + consumer decode: `<= 3 ms`
- main-thread handoff and state update: `<= 8 ms`
- next frame to first visible render: `<= 16.7 ms` at 60 Hz

Total target: `<= 29.7 ms`

Notes:

- cold start is out of scope for the 30 ms target
- first gesture after socket connect or process launch may exceed target
- backend device execution latency is separate from overlay latency

## Transport

### Live socket

- Path: `~/.blitz/gesture-events.sock`
- Type: Unix domain datagram socket
- Delivery: best-effort, unordered enough for our purposes, one datagram per event
- Sender behavior: non-blocking fire-and-forget
- Receiver behavior: single listener, fan-in from any local client

Why datagram instead of stream:

- simpler write path
- no connection lifecycle on each event
- one gesture event maps to one packet
- easier to keep off the critical path

### Optional mirror

- Path: `~/.blitz/gesture-events.jsonl`
- Format: one JSON object per line, same schema as live event
- Purpose: diagnostics, offline debugging, optional bridge into recording/session artifacts
- Rule: mirror writes must never block the live send path

## Event model

Each gesture is a single visualization event emitted when the client is about to dispatch the underlying device action.

This protocol intentionally models renderable gestures, not generic device commands.

Supported kinds:

- `tap`
- `longpress`
- `swipe`
- `scroll`
- `back-swipe`
- `pinch`

For the first implementation, consumers may render only `tap` and `swipe` and ignore the rest.

## Required event schema

```json
{
  "v": 1,
  "id": "01JQ7M3V4VV2Q6H4G8Q1Q6S2JM",
  "tsMs": 1774853265123,
  "source": {
    "client": "blitz-iphone",
    "sessionId": "run-8f4f7d"
  },
  "target": {
    "platform": "ios",
    "deviceId": "A1B2C3D4-UDID"
  },
  "kind": "tap",
  "x": 196,
  "y": 802,
  "referenceWidth": 393,
  "referenceHeight": 852
}
```

Swipe example:

```json
{
  "v": 1,
  "id": "01JQ7M40A0V9KAHQJZ6S3N1F6M",
  "tsMs": 1774853265348,
  "source": {
    "client": "agent-device",
    "sessionId": "smoke-login"
  },
  "target": {
    "platform": "ios",
    "deviceId": "A1B2C3D4-UDID"
  },
  "kind": "swipe",
  "x": 187,
  "y": 734,
  "x2": 189,
  "y2": 242,
  "durationMs": 240,
  "referenceWidth": 393,
  "referenceHeight": 852
}
```

### Required fields

- `v`: protocol version
- `id`: unique event id, used for dedupe
- `tsMs`: wall-clock send timestamp in milliseconds
- `source.client`: producer name
- `target.platform`: platform, for example `ios`, `android`, `macos`
- `target.deviceId`: device/simulator identifier
- `kind`: gesture kind
- `referenceWidth`
- `referenceHeight`

### Required geometry by kind

- `tap`: `x`, `y`
- `longpress`: `x`, `y`, `durationMs`
- `swipe`: `x`, `y`, `x2`, `y2`, `durationMs`
- `scroll`: `x`, `y`, `x2`, `y2`, `durationMs`
- `back-swipe`: `x`, `y`, `x2`, `y2`, `durationMs`
- `pinch`: `x`, `y`, `scale`, `durationMs`

### Optional fields

- `actionCommand`: original command name like `device_action`, `press`, `swipe`
- `actionIndex`: source-local action index
- `recordingId`: session recording id
- `meta`: producer-specific metadata ignored by default consumers

## Semantics

### Coordinate space

Coordinates are always expressed in the source device reference frame, not in rendered pixels.

Consumers must map `(x, y)` and `(x2, y2)` from:

- `referenceWidth`
- `referenceHeight`

into the current on-screen preview bounds for the matching `target.deviceId`.

This makes the same event usable across:

- Blitz simulator preview
- live device preview
- future web viewers

### Emission timing

Producer rule:

- emit the gesture event immediately before dispatching the underlying device action

Not after completion.

That is the only way to reliably hit the `<= 30 ms` rendering target.

### Failure behavior

If the real device action later fails, no compensating event is required.

Rationale:

- overlay is best-effort user feedback
- adding cancel/error phases increases protocol size and consumer complexity
- the action layer should report execution failures separately

## Consumer rules

- ignore events with unsupported `v`
- ignore events for non-active `target.deviceId`
- dedupe by `id`
- never replay old events on startup
- auto-expire rendered events locally
- ignore unknown fields
- ignore unknown `kind` values

Recommended local expiry:

- `tap`: 700 ms
- `longpress`: `durationMs + 400 ms`
- `swipe`: `durationMs + 400 ms`
- `scroll`: `durationMs + 400 ms`
- `back-swipe`: `durationMs + 400 ms`
- `pinch`: `durationMs + 400 ms`

## Producer rules

- keep send path off the action critical section as much as possible
- pre-create socket handle during client startup
- reuse an encoder if possible
- generate monotonic-ish sortable ids such as ULID
- do not wait for receiver ack
- do not read from the socket on the action path
- if live send fails, optionally enqueue a debug log; do not fail the action

## Minimal Swift consumer shape

1. bind datagram socket once at app startup
2. decode events on a background queue
3. filter by active device id
4. push accepted events to `@MainActor`
5. render from an in-memory event queue keyed by `id`

Important:

- do not drive rendering from array count changes
- do not reprocess the full pending array on each update
- append only newly received events

## Minimal Node producer shape

1. open datagram socket once
2. on `tap`/`swipe` action creation, build event from already-known coordinates
3. `send()` event
4. immediately dispatch underlying device action

No filesystem writes are needed for the live path.

## Relationship to `agent-device`

`agent-device` already has a richer recording telemetry schema for offline artifacts. This protocol should stay intentionally smaller.

Mapping rule:

- live gesture event is the low-latency subset
- recording telemetry is the durable richer superset

That means `agent-device` can:

1. emit this live event immediately
2. continue recording full gesture telemetry for session artifacts

## Versioning

Versioning is additive-first.

Rules:

- bump `v` only for breaking schema changes
- adding optional fields does not require a version bump
- consumers must ignore unknown fields

## Recommendation

Adopt this as `Gesture Visualization Event Protocol v1`:

- primary transport: `~/.blitz/gesture-events.sock`
- optional debug mirror: `~/.blitz/gesture-events.jsonl`
- first supported kinds in `blitz-macos`: `tap`, `swipe`

This is the smallest protocol that is:

- fast enough for a 30 ms steady-state target
- robust under bursty local interaction traffic
- portable across `blitz-iphone`, `agent-device`, and future clients
