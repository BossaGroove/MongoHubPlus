# CLAUDE.md

Guidance for AI-assisted development in this repository.

## What this is

**MongoHub Plus** — a native macOS MongoDB GUI (Swift 6 + AppKit), a
from-scratch revival of the classic MongoHub. See [README.md](README.md) for
features, install, and build instructions.

## Hard rules

- **BSON documents preserve key order end-to-end.** Use `BSON.Document`
  (MongoKitten); never round-trip through `Swift.Dictionary`.
- **Never silently change a value's BSON type.** The document editor's
  round-trip verification and the type-fidelity output rules are load-bearing.
- **JSON dialect is official MongoDB Extended JSON v2 only**, plus
  mongosh-style input conveniences (`ObjectId(…)`, unquoted keys). The
  ExtendedJSON package's corpus tests (the official mongodb/specifications
  BSON corpus) are the golden suite — never weaken them to make a change pass.
- **Atlas must work**: `mongodb+srv://`, TLS, SCRAM; connection strings
  follow the current MongoDB spec.
- **The Xcode project is generated.** Edit `project.yml`, never the pbxproj;
  run `xcodegen generate` after changing it (both are committed).

## Build & test

```bash
swift test --package-path Packages/ExtendedJSON
swift test --package-path Packages/MongoService
xcodegen generate   # brew install xcodegen
xcodebuild -project MongoHubPlus.xcodeproj -scheme MongoHubPlus build
```

MongoService integration tests are env-gated: set
`MONGOHUBPLUS_TEST_URI=mongodb://localhost:27017` with a local server
running (e.g. `docker run -d --rm -p 27017:27017 mongo:7`), or they skip.

## Conventions

- macOS 14+, universal (arm64 + x86_64), App Sandbox on; Swift 6 strict
  concurrency, `@MainActor` UI, programmatic AppKit (SwiftUI only for
  Settings).
- swift-format with the committed config; match surrounding style.
- Tests use Swift Testing (`import Testing`). JSON-dialect changes require
  ExtendedJSON tests in the same change.
- Commit style: short imperative subject; group by feature.
- Code comments cite items like "feature-spec 3.17" or
  "legacy-architecture §5" — those are the maintainers' private working
  docs (see below); treat the numbers as stable identifiers.

## Private working docs

If an `internal/` directory exists in this checkout (a separate private
repository, gitignored here), read `internal/CLAUDE.md` before starting
work — it carries the full project context.
