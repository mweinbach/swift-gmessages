# Repository Guidelines

## Project Structure & Module Organization
This repository is a Swift Package (`Package.swift`) organized by module:
- `Sources/LibGM`: core Google Messages client (`GMClient`) and transport/pairing/storage models.
- `Sources/GMCrypto`: crypto primitives and key utilities.
- `Sources/GMProto`: generated SwiftProtobuf types (`*.pb.swift`).
- `Sources/gmcli`: CLI executable for pairing and local workflow validation.
- `Protos/`: source `.proto` definitions used to produce `Sources/GMProto`.
- `Tests/GMCryptoTests` and `Tests/LibGMTests`: XCTest suites.
- `docs/`: usage and API reference docs.

Prefer changes in source `.proto` files over editing generated `*.pb.swift` directly.

## Build, Test, and Development Commands
Use SwiftPM from the repo root:
- `swift build` - compile all library and executable targets.
- `swift test` - run all XCTest targets.
- `swift test --filter LibGMTests` - run only LibGM tests.
- `swift test --filter GMCryptoTests` - run only crypto tests.
- `swift run gmcli --help` - inspect CLI commands.
- `swift run gmcli status` - quick runtime check for local auth/session state.

## Coding Style & Naming Conventions
- Use Swift 5.9+ conventions and Swift API Design Guidelines.
- Indentation: 4 spaces; avoid tabs.
- Types/protocols: `UpperCamelCase`; methods/properties/variables: `lowerCamelCase`.
- Keep concurrency explicit: prefer `async/await`, actors, and `Sendable`-safe patterns.
- Keep event handlers lightweight; push heavy work to separate tasks when needed.
- Do not hand-edit generated protobuf files in `Sources/GMProto`.

## Testing Guidelines
- Framework: XCTest.
- Name tests as `test<BehaviorOrScenario>()` (for example, `testConnectBackgroundRequiresLogin`).
- Add/extend tests in the module-specific suite for every behavior change.
- Prefer deterministic unit tests; avoid network-dependent tests unless explicitly scoped.

## Commit & Pull Request Guidelines
- Follow the repository’s current commit style: short, imperative subject lines (for example, `Create README.md`).
- Keep commits focused by concern (crypto, transport, CLI, docs).
- PRs should include:
  - clear summary of behavior changes,
  - linked issue/context,
  - test evidence (`swift test` output or filtered equivalent),
  - screenshots only when changing macOS pairing UI behavior.

## Security & Configuration Tips
- Never commit cookies, auth tokens, or persisted auth state (for example `auth_data.json`).
- Treat local pairing/session artifacts as secrets and keep them out of version control.
