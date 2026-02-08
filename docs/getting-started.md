# Getting Started

## Requirements

- Swift `5.9+`
- macOS `13+`, iOS `16+`, tvOS `16+`, watchOS `9+`

## Add Dependency

```swift
dependencies: [
  .package(url: "https://github.com/<your-org>/swift-gmessages.git", from: "0.1.0")
]
```

```swift
.target(
  name: "YourApp",
  dependencies: ["LibGM"]
)
```

## First Client

```swift
import LibGM

actor AppEvents: GMEventHandler {
    func handleEvent(_ event: GMEvent) async {
        if case let .listenTemporaryError(error) = event {
            print("Temporary listen error: \(error)")
        }
    }
}

let store = AuthDataStore.defaultStore()
let client = try await GMClient.loadOrCreate(from: store, eventHandler: AppEvents())
```

## Decide: Existing Session vs New Pairing

```swift
if await client.isLoggedIn {
    try await client.connect()
} else {
    let qr = try await client.startLogin()
    print("Show QR in UI: \(qr)")
    // Wait for .pairSuccessful event, then save auth data.
}
```

## Persist Session

```swift
try await client.saveAuthData(to: store)
```

## Core Rule

`GMClient` is an `actor`, so all stateful calls should be made with `await`.
