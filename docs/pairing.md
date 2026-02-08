# Pairing

`swift-gmessages` supports two pairing modes:

- QR pairing (`startLogin`)
- Gaia/Google-account pairing (`startGaiaPairing` + `finishGaiaPairing`)

## QR Pairing

### Flow

1. Create a client with an event handler.
2. Call `startLogin()`.
3. Show returned QR URL.
4. Wait for `GMEvent.pairSuccessful`.
5. Save auth state via `saveAuthData(to:)`.

### Example

```swift
actor PairEvents: GMEventHandler {
    var onPaired: (() -> Void)?

    func handleEvent(_ event: GMEvent) async {
        switch event {
        case .qrCode(let url):
            print("QR URL: \(url)")
        case .pairSuccessful:
            onPaired?()
        default:
            break
        }
    }
}

let events = PairEvents()
let client = await GMClient(eventHandler: events)
let qrURL = try await client.startLogin()
print(qrURL)
```

## Gaia Pairing

Gaia pairing requires signed-in Google cookies.

### Minimum Steps

1. Inject cookies into `authData`.
2. Call `startGaiaPairing()` and show emoji.
3. User confirms emoji on phone.
4. Call `finishGaiaPairing(session:)`.

### Example

```swift
let client = await GMClient()
await client.authData.setCookies([
    "SAPISID": "...",
    "__Secure-1PSID": "...",
    "__Secure-1PAPISID": "..."
])

let (emoji, session) = try await client.startGaiaPairing()
print("Confirm on phone: \(emoji)")

let phoneID = try await client.finishGaiaPairing(session: session)
print("Paired phone: \(phoneID)")
```

## Multiple Primary Devices

If multiple primary-looking devices are returned, select by index:

```swift
await client.setGaiaDeviceSwitcher(1)
```

Or pass override per call:

```swift
let (_, session) = try await client.startGaiaPairing(deviceSelectionIndex: 1)
```

## Pairing API Surface

- `startLogin() -> String`
- `refreshPhoneRelay() -> String`
- `registerPhoneRelay() -> Authentication_RegisterPhoneRelayResponse`
- `startGaiaPairing(deviceSelectionIndex:) -> (emoji: String, session: PairingSession)`
- `finishGaiaPairing(session:) -> String`
- `cancelGaiaPairing(session:)`
- `doGaiaPairing(emojiCallback:)`
- `unpair()` / `unpairBugle()` / `unpairGaia()`

## Pairing Errors

Main error enum: `PairingError`

Common cases:
- `noCookies`
- `noDevicesFound`
- `incorrectEmoji`
- `pairingCancelled`
- `pairingTimeout`
- `pairingInitTimeout`
