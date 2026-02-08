# Media

## High-level API

- `uploadMedia(data:fileName:mimeType:) -> Conversations_MediaContent`
- `downloadMedia(mediaID:decryptionKey:) -> Data`
- `sendMediaMessage(conversationID:mediaData:fileName:mimeType:text:)`
- `downloadAvatar(url:) -> Data`

## Send Media Flow

`sendMediaMessage` does:

1. upload media
2. build `Client_SendMessageRequest` with media payload
3. send message RPC

## Manual Upload + Send Example

```swift
let media = try await client.uploadMedia(
    data: imageData,
    fileName: "photo.jpg",
    mimeType: "image/jpeg"
)

var req = Client_SendMessageRequest()
req.conversationID = convID

var payload = Client_MessagePayload()
var info = Conversations_MessageInfo()
info.mediaContent = media
payload.messageInfo = [info]
req.messagePayload = payload

_ = try await client.sendMessage(req)
```

## Media Errors

Main enum: `MediaError`

Common failure classes:
- unsupported MIME type
- invalid server response
- encryption/decryption failures
- upload/download HTTP failures
