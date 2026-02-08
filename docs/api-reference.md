# API Reference

Public API from `LibGM`.

## `GMClientError`

```swift
enum GMClientError: Error {
    case notLoggedIn
    case backgroundPollingExitedUncleanly
}
```

## `GMClient`

### Init and State

```swift
init(authData:eventHandler:autoReconnectAfterPairing:)
var authData: AuthData { get }
var isConnected: Bool { get async }
var currentSessionID: String { get async }
var isLoggedIn: Bool { get async }
```

### Event Handler

```swift
func setEventHandler(_ handler: any GMEventHandler) async
func setEventHandler(_ handler: @escaping @Sendable (GMEvent) async -> Void) async
```

### Connection

```swift
func setProxy(_ url: URL?) async
func setProxy(_ proxy: String) async throws
func fetchConfig() async throws -> Config_Config
func connect() async throws
func disconnect() async
func reconnect() async throws
func connectBackground() async throws
func setActiveSession() async throws
func isBugleDefault() async throws -> Bool
```

### Pairing

```swift
func startLogin() async throws -> String
func registerPhoneRelay() async throws -> Authentication_RegisterPhoneRelayResponse
func refreshPhoneRelay() async throws -> String
func getWebEncryptionKey() async throws -> Authentication_WebEncryptionKeyResponse
func unpair() async throws
func unpairBugle() async throws
func unpairGaia() async throws

func setGaiaDeviceSwitcher(_ index: Int)
func getGaiaDeviceSwitcher() -> Int
func startGaiaPairing(deviceSelectionIndex: Int? = nil) async throws -> (emoji: String, session: PairingSession)
func finishGaiaPairing(session: PairingSession) async throws -> String
func doGaiaPairing(emojiCallback: @escaping (String) async -> Void) async throws
func cancelGaiaPairing(session: PairingSession) async throws
```

### Conversations

```swift
func listConversations(count: Int = 25, folder: Client_ListConversationsRequest.Folder = .inbox) async throws -> [Conversations_Conversation]
func listConversationsPage(count: Int = 25, folder: Client_ListConversationsRequest.Folder = .inbox, cursor: Client_Cursor? = nil) async throws -> Client_ListConversationsResponse
func getConversation(id conversationID: String) async throws -> Conversations_Conversation
func getConversationType(conversationID: String) async throws -> Client_GetConversationTypeResponse
func updateConversation(_ request: Client_UpdateConversationRequest) async throws -> Client_UpdateConversationResponse
func deleteConversation(conversationID: String, phone: String? = nil) async throws -> Bool
func updateConversationStatus(conversationID: String, status: Conversations_ConversationStatus) async throws
func setConversationMuted(conversationID: String, isMuted: Bool) async throws
```

### Messages

```swift
func fetchMessages(conversationID: String, count: Int = 25) async throws -> [Conversations_Message]
func fetchMessagesPage(conversationID: String, count: Int = 25, cursor: Client_Cursor? = nil) async throws -> Client_ListMessagesResponse
func fetchMessages(conversationID: String, count: Int = 25, cursor: Client_Cursor?) async throws -> (messages: [Conversations_Message], cursor: Client_Cursor?)

func sendMessage(conversationID: String, text: String) async throws -> Client_SendMessageResponse
func sendMessage(_ request: Client_SendMessageRequest) async throws -> Client_SendMessageResponse

func sendReaction(messageID: String, emoji: String, action: Client_SendReactionRequest.Action = .add) async throws
func sendReaction(_ request: Client_SendReactionRequest) async throws -> Client_SendReactionResponse

func deleteMessage(messageID: String) async throws -> Bool
func deleteMessage(_ request: Client_DeleteMessageRequest) async throws -> Client_DeleteMessageResponse

func markRead(conversationID: String, messageID: String) async throws

func setTyping(conversationID: String, isTyping: Bool, simPayload: Settings_SIMPayload? = nil) async throws
func setTyping(conversationID: String) async throws
func setTyping(conversationID: String, simPayload: Settings_SIMPayload?) async throws

func notifyDittoActivity() async throws -> Client_NotifyDittoActivityResponse
func getFullSizeImage(messageID: String, actionMessageID: String) async throws -> Client_GetFullSizeImageResponse
```

### Contacts

```swift
func listContacts() async throws -> [Conversations_Contact]
func listContactsResponse() async throws -> Client_ListContactsResponse
func listTopContacts() async throws -> [Conversations_Contact]
func listTopContactsResponse(count: Int32 = 8) async throws -> Client_ListTopContactsResponse
func getParticipantThumbnail(participantIDs: [String]) async throws -> Client_GetThumbnailResponse
func getParticipantThumbnail(participantIDs: String...) async throws -> Client_GetThumbnailResponse
func getContactThumbnail(contactIDs: [String]) async throws -> Client_GetThumbnailResponse
func getContactThumbnail(contactIDs: String...) async throws -> Client_GetThumbnailResponse
```

### Compose

```swift
func getOrCreateConversation(_ request: Client_GetOrCreateConversationRequest) async throws -> Client_GetOrCreateConversationResponse
func getOrCreateConversation(numbers: [String], rcsGroupName: String? = nil, createRCSGroup: Bool = false) async throws -> Client_GetOrCreateConversationResponse
```

### Media

```swift
func uploadMedia(data: Data, fileName: String, mimeType: String) async throws -> Conversations_MediaContent
func downloadMedia(mediaID: String, decryptionKey: Data) async throws -> Data
func downloadAvatar(url: String) async throws -> Data
func sendMediaMessage(conversationID: String, mediaData: Data, fileName: String, mimeType: String, text: String? = nil) async throws -> Client_SendMessageResponse
```

### Settings and Push

```swift
func updateSettings(_ request: Client_SettingsUpdateRequest) async throws
func registerPush(keys: PushKeys) async throws
```

### Persistence

```swift
func saveAuthData(to store: AuthDataStore) async throws
static func loadFromStore(_ store: AuthDataStore, eventHandler: (any GMEventHandler)? = nil, autoReconnectAfterPairing: Bool = true) async throws -> GMClient?
static func loadOrCreate(from store: AuthDataStore, eventHandler: (any GMEventHandler)? = nil, autoReconnectAfterPairing: Bool = true) async throws -> GMClient
```

## `GMEvent`

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
- `message(_:isOld:)`
- `conversation(_:)`
- `typing(_:)`
- `userAlert(_:)`
- `settings(_:)`
- `accountChange(_:isFake:)`

Wrapped errors:
- `requestError(ErrorInfo)`
- `httpError(HTTPErrorInfo)`

## `GMEventHandler`

```swift
protocol GMEventHandler: AnyObject, Sendable {
    func handleEvent(_ event: GMEvent) async
}
```

## `AuthDataStore`

```swift
struct AuthDataStore {
    init(directoryURL: URL)
    var directory: URL { get }
    static func defaultStore() -> AuthDataStore
    static func store(at path: String) -> AuthDataStore
    func save(_ authData: AuthData) async throws
    func load() throws -> AuthData?
    func delete() throws
    var exists: Bool { get }
    var filePath: String { get }
}
```

## `PushKeys`

```swift
struct PushKeys {
    var url: String
    var p256dh: Data
    var auth: Data
}
```
