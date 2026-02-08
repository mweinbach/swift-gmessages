# Events

`GMClient` emits runtime state via `GMEventHandler`.

## Implementing a Handler

```swift
actor Events: GMEventHandler {
    func handleEvent(_ event: GMEvent) async {
        switch event {
        case .message(let msg, let isOld):
            print("msg=\(msg.messageID) old=\(isOld)")
        case .listenTemporaryError(let err):
            print("temporary=\(err)")
        default:
            break
        }
    }
}
```

You can also use closure form:

```swift
await client.setEventHandler { event in
    print(event)
}
```

## Event Categories

Authentication:
- `qrCode(url:)`
- `gaiaPairingEmoji(emoji:)`
- `pairSuccessful(phoneID:data:)`
- `authTokenRefreshed`
- `gaiaLoggedOut`

Connection:
- `listenFatalError(Error)`
- `listenTemporaryError(Error)`
- `listenRecovered`
- `pingFailed(error:count:)`
- `browserActive(sessionID:)`
- `phoneNotResponding`
- `phoneRespondingAgain`
- `noDataReceived`

Data:
- `message(Conversations_Message, isOld: Bool)`
- `conversation(Conversations_Conversation)`
- `typing(Events_TypingData)`
- `userAlert(Events_UserAlertEvent)`
- `settings(Settings_Settings)`
- `accountChange(Events_AccountChangeOrSomethingEvent, isFake: Bool)`

Error wrappers:
- `requestError(ErrorInfo)`
- `httpError(HTTPErrorInfo)`

## `isOld` Semantics

`message(..., isOld: true)` means backlog data received during initial sync, not newly arrived live traffic.
