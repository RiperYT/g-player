# Localization

English is the source language: the keys in the code are the English text. Ukrainian lives in `uk.lproj`.

- `uk.lproj/Localizable.strings`: `"English key" = "translation";`. A key with `%@` or `%lld` keeps the same placeholders, in
  any order (`%2$@`).
- `uk.lproj/Localizable.stringsdict`: keys with a count whose words change with it (1 game, 2 games). They need the four
  Ukrainian forms: one, few, many, other. `en.lproj/Localizable.stringsdict` lists these keys and has the English forms.
- `uk.lproj/InfoPlist.strings`: names of the document types and the copyright line.
- `en.lproj` stays: without it a Mac set to another language would be matched to Ukrainian.

`scripts/build-app.sh` copies the folders into `G-Player.app/Contents/Resources/`. `scripts/Info.plist` lists the languages
(`CFBundleLocalizations`).

## In the code

- A literal given to SwiftUI (`Text("…")`, `Button("…")`, `.help("…")`) is a key already.
- Text built in code is `String(localized: "…")`, in `GPlayerCore` too. `Text(someString)` shows the string as it is.
- Sentences are whole, with placeholders. Where a fragment is inserted into a sentence (“Waiting for …”), the key has a
  `comment:` that says where.
- Not translated: game titles and other user data, product names (G-Player, Steam, Wine, DXVK…), file names, settings and
  arguments given to Wine, and the text of a “Share What Worked” report (a public issue, in English).

## Checking

`scripts/l10n.sh` (or `make l10n`) builds with `-emit-localized-strings`, the way Xcode finds keys, and lists:

- keys the code has that `uk.lproj` doesn't (missing),
- keys `uk.lproj` has that the code no longer has (stale),
- translations whose placeholders differ from the key's, and plural entries without all forms (mismatched).

It exits with 1 on missing or mismatched keys, and on an English plural rule left for a key the code no longer has.
Stale translations are only listed.

`scripts/l10n.sh --missing-json <file>` writes the missing keys with the source lines (`files`), the translator comment and,
for plural keys, the English forms.

To see a screen in Ukrainian without the real library: `G-Player.app/Contents/MacOS/GPlayer --render-onboarding <folder>
-AppleLanguages '(uk)'`.
