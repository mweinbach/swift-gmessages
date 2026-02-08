# Errors and Troubleshooting

## Key Error Enums

- `GMClientError`
  - `notLoggedIn`
  - `backgroundPollingExitedUncleanly`
- `PairingError`
- `GMHTTPError`
- `MediaError`

## Common Failure Cases

## `notLoggedIn`

Cause:
- missing token and/or browser identity

Fix:
- pair first (`startLogin` or Gaia flow)
- load a valid persisted session

## Gaia pairing fails with `noCookies`

Cause:
- cookies were not set in `AuthData`

Fix:
- set Google cookies before `startGaiaPairing`

## Repeated `listenTemporaryError`

Cause:
- transient network/proxy/server issues

Fix:
- keep reconnect/backoff logic
- verify proxy config and connectivity

## `backgroundPollingExitedUncleanly`

Cause:
- background poll opened but no data payload arrived in expected window

Fix:
- retry once with jitter
- escalate to foreground `connect` for deeper diagnostics

## Diagnostics Checklist

- `await client.isLoggedIn`
- `await client.isConnected`
- inspect `GMEvent.listenTemporaryError`
- inspect HTTP status from `GMHTTPError.httpError`
- verify cookies for Gaia account sessions
