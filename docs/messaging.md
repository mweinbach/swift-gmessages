# Messaging and Conversations

## Conversation Listing and Lookup

- `listConversations(count:folder:)`
- `listConversationsPage(count:folder:cursor:)`
- `getConversation(id:)`
- `getConversationType(conversationID:)`

## Conversation Updates

- `updateConversation(_:)`
- `deleteConversation(conversationID:phone:)`
- `updateConversationStatus(conversationID:status:)`
- `setConversationMuted(conversationID:isMuted:)`

## Message Timeline

- `fetchMessages(conversationID:count:)`
- `fetchMessagesPage(conversationID:count:cursor:)`
- `fetchMessages(conversationID:count:cursor:) -> (messages, cursor)`

## Sending

Text:

```swift
_ = try await client.sendMessage(conversationID: convID, text: "hi")
```

Raw request:

```swift
var req = Client_SendMessageRequest()
req.conversationID = convID
_ = try await client.sendMessage(req)
```

## Reactions, Deletes, Read State

- `sendReaction(messageID:emoji:action:)`
- `sendReaction(_:)`
- `deleteMessage(messageID:)`
- `deleteMessage(_:)`
- `markRead(conversationID:messageID:)`

## Typing

- `setTyping(conversationID:isTyping:simPayload:)`
- `setTyping(conversationID:)`
- `setTyping(conversationID:simPayload:)`

Parity note:
- Go-equivalent behavior is `typing=true` (use the convenience/parity overloads).
- Swift also supports explicit stop typing (`isTyping=false`).

## Contacts and Thumbnails

- `listContacts()`
- `listContactsResponse()`
- `listTopContacts()`
- `listTopContactsResponse(count:)`
- `getParticipantThumbnail(participantIDs:)`
- `getParticipantThumbnail(participantIDs: String...)`
- `getContactThumbnail(contactIDs:)`
- `getContactThumbnail(contactIDs: String...)`

## New Conversation / Compose

- `getOrCreateConversation(_:)`
- `getOrCreateConversation(numbers:rcsGroupName:createRCSGroup:)`
