# Push and Background Sync

## Push Registration

Use `registerPush(keys:)` with Web Push credentials:

```swift
let keys = PushKeys(
    url: "https://push.service/...",
    p256dh: p256dhData,
    auth: authData
)

try await client.registerPush(keys: keys)
```

The library updates server settings and caches keys in `AuthData.pushKeys`.

## Background Sync

Use `connectBackground()` for short sync windows (typical push-triggered worker flow):

```swift
do {
    try await client.connectBackground()
} catch GMClientError.backgroundPollingExitedUncleanly {
    // retry policy or diagnostics
}
```

## Typical Worker Pattern

1. Load client from store.
2. Ensure logged in.
3. Run `connectBackground()`.
4. Process events emitted during session.
5. Save auth data if changed.
