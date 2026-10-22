# Game fix database

`Sources/GPlayerCore/Resources/GameFixes.json` holds known fixes for single games (`GameFix` in
`Sources/GPlayerCore/Compat/CompatModels.swift`, read by `GameFixDatabase`). It is built from two inputs:

- [umu-protonfixes](https://github.com/Open-Wine-Components/umu-protonfixes) (BSD-2-Clause), the Steam fixes in `gamefixes-steam/<appid>.py`.
- `gplayer-fixes.json` in this folder: G-Player's own entries, checked on a Mac. These win over imported ones.

## Regenerate

```bash
git clone https://github.com/Open-Wine-Components/umu-protonfixes /path/to/umu-protonfixes
python3 tools/compat-db/import_umu.py /path/to/umu-protonfixes
```

Python 3, standard library only. The script reads the fixes with `ast` and never imports or runs them.
It takes the upstream commit from the checkout (`git rev-parse HEAD`) and writes the same bytes for the same
inputs (fixes sorted by id, keys sorted, 2-space indent). It prints how many files it imported and skipped and
why. Commit the new `GameFixes.json`; if upstream's `LICENSE` changed, update
`Sources/GPlayerCore/Resources/licenses/umu-protonfixes-LICENSE.txt` and `NOTICE` too (the script warns).

## What an imported fix keeps

Only `main()` (or `main_with_id()`) made of plain calls with literal arguments:

| umu call | GameFix field |
| --- | --- |
| `util.protontricks('verb ...')` | `components` (one entry per verb, in order) |
| `util.winedll_override('dll', OverrideOrder.X)` | `dllOverrides` (`n`, `b`, `n,b`, `b,n`, or empty for disabled) |
| `util.set_environment('K', 'V')` | `environment` |
| `util.append_argument('-x')` | `arguments` |
| `util.replace_command('a', 'b')` | `replacements` |
| `util.regedit_add(key, name, 'REG_SZ' or 'REG_DWORD', value)` | `registry` |

Each fix is `steam-<appid>`, has `verifiedOnMac: false` and `source: "umu-protonfixes@<short commit>"`.

## What is dropped, and why

Dropped, the rest of the fix stays:

- `util.disable_esync/fsync/ntsync/nvapi`, `util.set_cpu_topology*`: Linux kernel and driver switches.
- Environment variables `PROTON_*`, `WINEFSYNC`, `WINEESYNC`, `WINENTSYNC`, `__GL_*`, `__NV_*`, `RADV_*`, `RADEONSI_*`,
  `MESA_*`, `AMD_DEBUG`, `VKD3D*` (G-Player has no vkd3d), `VK_X11_*`, `PULSE_*`, `ENABLE_GAMESCOPE_WSI`,
  `SteamDeck`, `SteamOS` (and `del_environment` of the last two): Proton, Linux graphics and audio drivers, Steam Deck.
  `DXVK_*` and `WINE_*` stay.
- `util.set_xml_options`, `util.set_ini_options`, `util.create_dosbox_conf`, `util.create_dos_device`,
  `util.import_saves_folder`, `util.set_game_drive`: edit files or devices a fix can't describe.
- `util.install_eac_runtime`, `util.install_battleye_runtime`: Proton's anti-cheat runtimes.
- Winetricks verbs `gui` and `sound=...` (an ALSA audio driver).
- `regedit_add` without a value, or with a type other than `REG_SZ`/`REG_DWORD` (for example `REG_BINARY`).
- `early()`: in the current data it only sets `PROTON_*` variables.

Skipped, the whole file (its fix needs real code): anything in `main()` other than those calls, such as `if`, `for`,
`try`, assignments or string building, other function calls, or arguments that aren't literals. A file that is empty
after filtering is skipped too. `default.py` (applies to every game) is not a game and is not read.

## Things to know when applying a fix

- `replacements[].from` is a regular expression in umu (`re.sub`, case-insensitive, on every command-line entry
  including the program path); `to` is the replacement text.
- `arguments` are kept as upstream wrote them. Upstream appends each string as one command-line entry, even when it
  holds spaces (`-skipdrivercheck -noHDR`).
- `components` are winetricks verbs as umu writes them: `vcrun2019`, `d3dcompiler_47`, but also `win7`,
  `hidewineexports=enable`. G-Player decides which of them it can install.
- Imported fixes come from Linux and Proton. They are hints, not promises, until `verifiedOnMac` is true.

## gplayer-fixes.json

`{"fixes": [ ... ]}`. Each entry uses the `GameFix` keys; only `id` and `source` are required, the rest default to
empty (`verifiedOnMac` to `false`). The script rejects unknown keys and bad `macStatus` or DLL override values.
A curated entry replaces an imported fix with the same `id` or with any of the same `steamAppIDs`, so one game
never gets both. Use `gplayer-<name>` ids.

## Licensing

umu-protonfixes is BSD 2-Clause (Copyright (c) 2018, Chris Simons). The license requires keeping the copyright
notice and license text with redistributions. G-Player ships the text in
`Sources/GPlayerCore/Resources/licenses/umu-protonfixes-LICENSE.txt` (copied into the app's `Resources/licenses`)
and mentions the data in `NOTICE`. The importer stops if upstream's `LICENSE` is not BSD 2-Clause.
