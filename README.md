# swift-gmessages

Swift library for Google Messages Web protocol access.

This package gives app developers a typed, async/await API for:
- Pairing (QR and Gaia/Google-account flows)
- Session persistence and reconnect
- Real-time events (messages, conversations, typing, alerts)
- Messaging operations (send, react, mark read, delete)
- Contacts and thumbnails
- Media upload/download
- Push registration
- Background sync (`connectBackground`)

## Platform + Swift Requirements

- Swift tools: `5.9+`
- Platforms:
  - macOS `13+`
  - iOS `16+`
  - tvOS `16+`
  - watchOS `9+`

## Install (SwiftPM)

```swift
dependencies: [
  .package(url: "https://github.com/<your-org>/swift-gmessages.git", from: "0.1.0")
],
targets: [
  .target(
    name: "YourApp",
    dependencies: ["LibGM"]
  )
]
```

Replace the package URL/version with your actual source.

## Core Concepts

### `GMClient` (actor)

`GMClient` is the main API surface. It handles auth state, long-poll lifecycle, request/response RPCs, and high-level operations.

Important properties:
- `isConnected`
- `isLoggedIn`
- `currentSessionID`
- `authData`

### `AuthData` + `AuthDataStore`

- `AuthData` is in-memory auth/session state.
- `AuthDataStore` persists auth to disk (`auth_data.json`) so sessions survive app restarts.

Common helpers:
- `GMClient.saveAuthData(to:)`
- `GMClient.loadFromStore(...)`
- `GMClient.loadOrCreate(...)`

### `GMEvent` + `GMEventHandler`

`GMClient` pushes runtime events through `GMEventHandler`, including:
- pairing state (`qrCode`, `pairSuccessful`, `gaiaPairingEmoji`)
- connection health (`listenTemporaryError`, `listenRecovered`, `phoneNotResponding`)
- data (`message`, `conversation`, `typing`, `settings`, `userAlert`)

## Quick Start (Existing Session)

```swift
import LibGM

actor AppEvents: GMEventHandler {
    func handleEvent(_ event: GMEvent) async {
        switch event {
        case .message(let message, _):
            print("New message: \(message.messageID)")
        case .listenTemporaryError(let error):
            print("Temporary error: \(error)")
        default:
            break
        }
    }
}

let store = AuthDataStore.defaultStore()
let handler = AppEvents()

guard let client = try await GMClient.loadFromStore(store, eventHandler: handler) else {
    // No saved session yet: run pairing first.
    fatalError("Not paired")
}

try await client.connect()
```

## Pairing

### QR Pairing

```swift
import LibGM

actor PairEvents: GMEventHandler {
    var onPaired: (() -> Void)?

    func handleEvent(_ event: GMEvent) async {
        switch event {
        case .qrCode(let url):
            print("Display this QR URL in UI: \(url)")
        case .pairSuccessful:
            onPaired?()
        default:
            break
        }
    }
}

let store = AuthDataStore.defaultStore()
let handler = PairEvents()
let client = await GMClient(eventHandler: handler)

let qrURL = try await client.startLogin()
print("QR URL: \(qrURL)")
// Wait for .pairSuccessful event in your UI/app state.

try await client.saveAuthData(to: store)
```

Notes:
- `startLogin()` starts long-polling for pairing events.
- By default (`autoReconnectAfterPairing: true`), client auto-reconnects shortly after successful pair.

### Gaia (Google Account) Pairing

You must set authenticated Google cookies first:

```swift
let client = await GMClient()
await client.authData.setCookies([
    "SAPISID": "...",
    "__Secure-1PSID": "...",
    "__Secure-1PAPISID": "..."
])

// Optional: choose alternate primary device when multiple are found.
await client.setGaiaDeviceSwitcher(0)

let (emoji, session) = try await client.startGaiaPairing()
print("Confirm emoji on phone: \(emoji)")

let phoneID = try await client.finishGaiaPairing(session: session)
print("Paired phone: \(phoneID)")
```

## Core Features (API Breakdown)

### 1) Connection + Session Lifecycle

Main calls:
- `connect()`
- `disconnect()`
- `reconnect()`
- `connectBackground()` (short-lived background long-poll session)
- `setProxy(_:)`
- `fetchConfig()`
- `setActiveSession()`

When to use `connectBackground()`:
- background workers / push-triggered sync
- keep behavior aligned with Go `ConnectBackground` semantics

### 2) Conversations + Timeline

Conversation APIs:
- `listConversations(...)`
- `listConversationsPage(...)`
- `getConversation(id:)`
- `getConversationType(conversationID:)`
- `updateConversation(_:)`
- `deleteConversation(...)`
- `updateConversationStatus(...)`
- `setConversationMuted(...)`

Message fetch APIs:
- `fetchMessages(conversationID:count:)`
- `fetchMessagesPage(...)`

### 3) Sending + Message Actions

Send/edit/action APIs:
- `sendMessage(conversationID:text:)`
- `sendMessage(_ rawRequest:)`
- `sendMediaMessage(...)`
- `sendReaction(...)`
- `deleteMessage(...)`
- `markRead(conversationID:messageID:)`
- `setTyping(...)`

Typing parity note:
- For Go-style behavior, use:
  - `setTyping(conversationID:)`
  - `setTyping(conversationID:simPayload:)`
- These always send `typing=true`.

### 4) Contacts + Thumbnails

- `listContacts()`
- `listTopContactsResponse(...)`
- `getParticipantThumbnail(...)`
- `getContactThumbnail(...)`

### 5) Compose / New Chat

- `getOrCreateConversation(_ request:)`
- `getOrCreateConversation(numbers:rcsGroupName:createRCSGroup:)`

### 6) Media

- `uploadMedia(data:fileName:mimeType:)`
- `downloadMedia(mediaID:decryptionKey:)`
- `downloadAvatar(url:)`
- `sendMediaMessage(...)`

### 7) Settings + Push

- `updateSettings(_:)`
- `registerPush(keys:)`

`PushKeys`:
- `url`
- `p256dh`
- `auth`

### 8) Pairing Management

- `startLogin()` / `refreshPhoneRelay()` / `registerPhoneRelay()`
- `startGaiaPairing(...)` / `finishGaiaPairing(...)` / `cancelGaiaPairing(...)`
- `unpair()` / `unpairBugle()` / `unpairGaia()`

## Event Handling Model

High-value runtime events:
- `pairSuccessful`
- `message(_, isOld:)`
- `conversation(_)`
- `typing(_)`
- `listenTemporaryError(_)`
- `listenRecovered`
- `phoneNotResponding` / `phoneRespondingAgain`
- `gaiaLoggedOut`

`message(..., isOld: true)` means backlog data, not newly-received live traffic.

## Persistence Pattern (Recommended)

1. Use `GMClient.loadOrCreate(...)` at app startup.
2. If loaded session exists, call `connect()`.
3. On successful pair or token refresh milestones, call `saveAuthData(to:)`.
4. On logout/unpair, call `AuthDataStore.delete()`.

## Error Types You’ll See

- `GMClientError`:
  - `.notLoggedIn`
  - `.backgroundPollingExitedUncleanly`
- `PairingError` (Gaia/QR pairing-specific)
- `GMHTTPError` (transport failures / non-2xx)
- `MediaError` (media pipeline errors)

## Minimal End-to-End Example

```swift
import LibGM

actor Events: GMEventHandler {
    func handleEvent(_ event: GMEvent) async {
        if case let .message(message, isOld) = event, !isOld {
            print("Live incoming message: \(message.messageID)")
        }
    }
}

let store = AuthDataStore.defaultStore()
let client = try await GMClient.loadOrCreate(from: store, eventHandler: Events())

if await client.isLoggedIn {
    try await client.connect()
} else {
    let qr = try await client.startLogin()
    print("Show QR to user: \(qr)")
    // Wait for pairSuccessful event in your app flow.
}

let convs = try await client.listConversations(count: 20)
if let first = convs.first {
    _ = try await client.sendMessage(conversationID: first.conversationID, text: "Hello from swift-gmessages")
}

try await client.saveAuthData(to: store)
```

## Concurrency + Integration Notes

- `GMClient` and most internals are actors. Call with `await`.
- Keep event handlers lightweight; dispatch heavy work to detached tasks if needed.
- Reconnect strategy:
  - treat `listenTemporaryError` as transient
  - treat `listenFatalError` as session-invalidating, then re-auth/re-pair as needed

