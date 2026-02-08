/// GMCrypto - Cryptographic primitives for Google Messages protocol
///
/// This module provides:
/// - AES-256-CTR encryption with HMAC-SHA256 authentication (for request/response encryption)
/// - AES-256-GCM chunked encryption (for media files)
/// - ECDSA P-256 key management via JWK (for token refresh and pairing)
/// - HKDF key derivation (for Gaia pairing)

@_exported import Crypto
