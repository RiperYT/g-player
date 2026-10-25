# Localization

English is the source language: the keys in the code are the English text. Ukrainian lives in `uk.lproj`.

- `Localizable.strings`: `"English key" = "translation";`, the key with `%@`, `%lld` placeholders as `String(localized:)` makes it.
- `Localizable.stringsdict`: keys with a count (`%lld games`) need plural forms (one, few, many, other).
- `InfoPlist.strings`: names of the document types and the copyright line.
- `en.lproj` must stay: without it a Mac set to another language would be matched to Ukrainian.

`scripts/build-app.sh` copies the folders into `G-Player.app/Contents/Resources/`.
`scripts/l10n.sh` lists the keys the code has that `uk.lproj` doesn't (`--missing-json <file>` with context for translators), keys
that are no longer in the code, and translations whose placeholders don't match the key. `make l10n` runs it.
