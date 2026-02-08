# Persistence

`AuthDataStore` handles serialization of session/auth material.

## Store APIs

- `AuthDataStore.defaultStore()`
- `AuthDataStore.store(at:)`
- `save(_:)`
- `load() -> AuthData?`
- `delete()`
- `exists`
- `filePath`

By default, data is persisted at:
- `Application Support/GMMessages/auth_data.json`

## Recommended Usage

```swift
let store = AuthDataStore.defaultStore()

let client = try await GMClient.loadOrCreate(
    from: store,
    eventHandler: nil,
    autoReconnectAfterPairing: true
)

// ... after auth or important state changes
try await client.saveAuthData(to: store)
```

## Logout / Reset

```swift
try await client.unpair()
try store.delete()
```

## Security Notes

Persisted auth data includes credentials/tokens and request crypto keys. Store location and file protections should match your app’s security model.
