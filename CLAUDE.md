# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What This Is

swift-gmessages is a Swift library (`LibGM`) implementing the Google Messages for Web protocol. It provides async/await APIs for pairing, messaging, media, contacts, and real-time events via long-polling. It is a Swift port of the Go `libgm` library with explicit parity goals.

## Build & Test Commands

```bash
# Build all targets
swift build

# Build only the library (no CLI)
swift build --target LibGM

# Run all tests
swift test

# Run a specific test target
swift test --filter GMCryptoTests
swift test --filter LibGMTests

# Run the CLI tool
swift run gmcli status
swift run gmcli pair
swift run gmcli list
swift run gmcli send <conversationID> "message"
```

## Architecture

### Module Dependency Graph

```
gmcli → LibGM → GMProto (protobuf types)
                → GMCrypto (AES-CTR, AES-GCM, ECDSA/JWK, HKDF)
```

- **GMProto** – Generated `.pb.swift` files from `Protos/*.proto`. Do not hand-edit; regenerate with `protoc` + `swift-protobuf` plugin.
- **GMCrypto** – Standalone crypto primitives: `AESCTRHelper` (request encryption), `AESGCMHelper` (media encryption), `JWK` (ECDSA P-256 key management), `HKDFHelper` (Gaia pairing key derivation).
- **LibGM** – Core client library. The public API surface is `GMClient` (actor).
- **gmcli** – CLI test tool using `swift-argument-parser`. Stores auth at `~/.gmcli/auth_data.json`.

### LibGM Internal Layers

- **`GMClient`** (actor, `Sources/LibGM/GMClient.swift`) – Main API. Orchestrates all other components. All public methods are here.
- **`SessionHandler`** (actor, `Transport/SessionHandler.swift`) – RPC request/response correlation. Builds `OutgoingRPCMessage`, waits for matching responses by request ID, batches ack messages.
- **`LongPollConnection`** (actor, `Transport/LongPollConnection.swift`) – Streaming PBLite long-poll. Parses `[[...]]` JSON-array stream, routes incoming RPCs (pair/data/gaia events), runs the "ditto pinger" health-check loop.
- **`GMHTTPClient`** (actor, `Transport/HTTPClient.swift`) – Low-level HTTP layer. Handles protobuf vs PBLite encoding, cookie/SAPISIDHASH auth, proxy support.
- **`PBLite`** (enum, `Transport/PBLite.swift`) – Custom `SwiftProtobuf.Visitor`/`Decoder` for Google's JSON-array protobuf encoding. The `PBLiteBinaryFields` table maps fields that need base64 binary encoding (must stay in sync with proto annotations).
- **`AuthData`** (actor, `Models/AuthData.swift`) – In-memory auth/session state. Serializable via `AuthData.Serialized`.
- **`AuthDataStore`** (struct, `Storage/AuthDataStore.swift`) – JSON file persistence for `AuthData`.
- **`MediaHandler`** (actor, `Media/MediaHandler.swift`) – Two-phase resumable upload + encrypted download.
- **`PairingSession`** (struct, `Pairing/PairingSession.swift`) – UKEY2 handshake for Gaia pairing.
- **`GMConstants`** (enum, `Models/Constants.swift`) – All endpoint URLs, header values, config version.

### Key Patterns

- **All major components are Swift actors** – `GMClient`, `AuthData`, `GMHTTPClient`, `SessionHandler`, `LongPollConnection`, `MediaHandler`. Call with `await`.
- **Two encoding formats**: Standard protobuf (pairing RPCs) and PBLite/JSON-array (messaging RPCs, long-poll stream).
- **Two hostname variants**: `googleapis.com` (pairing/upload) and `clients6.google.com` (messaging/ack/receive). Which one is used depends on `AuthData.shouldUseGoogleHost`.
- **Request/response correlation**: `SessionHandler` registers a `CheckedContinuation` keyed by request ID. `LongPollConnection` receives the response via the streaming long-poll and calls `SessionHandler.receiveResponse()`.
- **Go libgm parity**: Many behaviors (timing, post-connect delays, pinger logic, deduplication ring buffer) are ported from Go libgm. Comments with "Match Go libgm" or "Go libgm parity" indicate intentional behavior alignment.

### Proto Files

Proto definitions live in `Protos/`. The generated Swift code is in `Sources/GMProto/`. To regenerate:

```bash
protoc --swift_out=Sources/GMProto --proto_path=Protos Protos/*.proto Protos/vendor/*.proto
```

The `pblite.proto` vendor file defines custom options (`pblite_binary`) that control binary-field encoding in `PBLite.swift`. When adding fields with `(pblite.pblite_binary) = true`, update the `PBLiteBinaryFields.fieldsByMessageName` table in `PBLite.swift`.

### Event System

`GMClient` pushes events via `GMEventHandler` protocol. Key events: `.pairSuccessful`, `.message(_, isOld:)`, `.conversation(_)`, `.typing(_)`, `.listenTemporaryError(_)`, `.listenFatalError(_)`, `.phoneNotResponding`, `.phoneRespondingAgain`, `.gaiaLoggedOut`.

`isOld: true` on messages means backlog data from initial sync, not new live messages.

### Config Version

`GMConstants.makeConfigVersion()` contains hardcoded protocol version numbers observed from Messages for Web. These may need periodic updates to stay compatible.
