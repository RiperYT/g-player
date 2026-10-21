# How Steam works in G-Player

In autumn 2026 two things broke Steam for free Wine setups on macOS:

1. **The client no longer starts on wine 7.7.** Apple's Game Porting Toolkit (and Whisky, and older CrossOver)
   are based on wine 7.7. The 2026 `steam.exe` crashes there with a page fault right after it updates itself.
   G-Player therefore runs Steam on **Wine Staging 11.18** (Gcenx's build).
2. **On newer Wine the window is black.** Steam's interface is Chromium (CEF). Chromium draws in a separate
   GPU process into a window that belongs to the browser process. Wine's Mac driver can only show
   cross-process Metal layers for top-level windows, and Steam's view is a child window, so it stays black.
   See [3Shain/dxmt#141](https://github.com/3Shain/dxmt/issues/141) for the full investigation.

## The fix

Chromium can draw inside its main process instead: `--disable-gpu --disable-gpu-compositing --in-process-gpu`.
Since 2026 Steam drops `-cef-*` options from its own command line, so the flags have to reach
`steamwebhelper.exe` directly. G-Player does what MaPC's open-source engine does:

- `steamwebhelper.exe` is moved to `steamwebhelper_real.exe`, and a tiny wrapper
  ([`tools/chromium-helper-wrapper/wrapper.c`](../tools/chromium-helper-wrapper/wrapper.c)) takes its place.
  The wrapper starts the real helper with the flags added.
- Steam starts with `-noverifyfiles`, so it doesn't put its own helper back.
- Steam updates restore the helper anyway, so the wrapper is applied again before every launch.
- On a fresh install the client isn't downloaded yet. G-Player starts Steam once, waits until the client is
  complete, stops it, and from then on starts it with the wrapper.

Other things Steam's space gets: `bcrypt` and `ncrypt` from Wine, the overlay DLLs disabled, and
Qt WebEngine flags for launchers that games start from Steam.

The same wrapper works for other Chromium-based launchers (Epic's `EpicWebHelper.exe`, GOG Galaxy) and for
Electron and NW.js games, which get the same flags on their command line.
