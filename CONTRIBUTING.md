# Contributing

Thanks for helping. Most fixes for a game that doesn't run are small: a DLL override, an environment
variable, a different graphics backend, a file the game expects.

1. Open an issue first for anything bigger than a bug fix, so we can agree on the approach.
2. Keep pull requests small and focused. Add a test when the logic can be tested without Wine (most can, see
   `Tests/GPlayerCoreTests`).
3. Say which game you tested with, on which Mac and macOS version.
4. Run `make test` before you push.
5. No new network calls, analytics or downloads without a pinned SHA-256.
6. Never add files from Apple's Game Porting Toolkit.

Commit messages follow [Conventional Commits](https://www.conventionalcommits.org): `feat(core): …`,
`fix(app): …`, `docs: …`, `test: …`, `chore: …`.

By sending a pull request you agree that your contribution is licensed under the Apache License 2.0.
