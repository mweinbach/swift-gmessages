/// LibGM - Core Google Messages client library
///
/// This module provides the main client for interacting with Google Messages:
/// - Authentication (QR code and Gaia pairing)
/// - Connection management (long polling)
/// - Messaging operations (send, receive, reactions)
/// - Contact and conversation management
/// - Media upload/download

@_exported import GMCrypto
@_exported import GMProto
import SwiftProtobuf

// Re-export main types with non-conflicting names
public typealias GMMessage = Conversations_Message
public typealias GMConversation = Conversations_Conversation
public typealias GMContact = Conversations_Contact
public typealias GMDevice = Authentication_Device
