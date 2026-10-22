# CLAUDE.md — G-Player

G-Player is a free, open-source macOS app (Apple Silicon, macOS 15+) that runs Windows games through Wine.
Native SwiftUI, Cupertino-minimal. Everything in this repository is English.

- Maintainers keep a private development wiki next to this repo at `../g-player-wiki`. If it exists, start
  there: `../g-player-wiki/CLAUDE.md`, then `../g-player-wiki/tasks/now.md` (current state and next steps).
- Architecture: `docs/ARCHITECTURE.md`. Why Steam needs the helper wrapper: `docs/HOW-STEAM-WORKS.md`.

## Rules
- `Sources/GPlayerCore` has no SwiftUI. Decisions (environment, DLL overrides, launch arguments, which .exe,
  .lnk/.vdf parsing) are pure functions with tests in `Tests/GPlayerCoreTests` (Swift Testing).
- Views hold no rules: view → `AppModel` → core.
- Every engine and component download is pinned by SHA-256 (`EngineCatalog`, `RuntimeCatalog`); store installers come
  straight from the store's own HTTPS address. No telemetry. Never add Apple Game Porting Toolkit files.
- UI text: short, plain verbs, says what happens. Native controls and SF Symbols; tokens in `Views/Components/Theme.swift`.
- Split big `@ViewBuilder` bodies into sub-views (Swift 6.3 crashed on a large one with `Task { await … }` in a tuple).

## Commands
```bash
make test     # unit tests, no Wine needed
make app      # build/G-Player.app
make run      # build and open
make release  # zip into releases/v<VERSION>/
make publish  # release + GitHub release
make wrapper  # rebuild the Chromium helper wrapper (brew install mingw-w64)
```

Commits: Conventional Commits (`feat(core): …`, `fix(app): …`, `docs: …`, `test: …`, `chore: …`).
