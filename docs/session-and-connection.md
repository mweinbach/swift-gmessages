# Session and Connection

## Connection Methods

- `connect()`
- `disconnect()`
- `reconnect()`
- `connectBackground()`
- `setProxy(_:)`
- `fetchConfig()`
- `setActiveSession()`

## `connect()` Behavior

`connect()`:

1. refreshes token if needed
2. starts long-poll stream
3. waits for first stream open
4. if logged in, runs post-connect actions (`ack`, `setActiveSession`, `isBugleDefault`)

## `connectBackground()`

Use for short-lived sync workers. It:

1. verifies login state
2. starts long-poll
3. waits for payload activity
4. stops long-poll
5. flushes pending acks

If no data payload arrives before exit criteria, it throws `GMClientError.backgroundPollingExitedUncleanly`.

## Connection State

- `await client.isConnected`
- `await client.isLoggedIn`
- `await client.currentSessionID`

## Recommended Lifecycle Pattern

1. App launch: load store + create client.
2. If logged in: call `connect()`.
3. On app background: optional `disconnect()`.
4. On reconnect triggers: `reconnect()`.
5. On push/background jobs: `connectBackground()`.
