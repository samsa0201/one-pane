# tmux pocket

Android app for driving tmux over SSH on a phone: one pane at a time, full screen, while always
showing where that pane sits in its window and which window/session you are in.

It speaks tmux **control mode** (`tmux -C`), so it gets real structure from tmux (sessions,
windows, the layout tree with every pane's geometry, per-pane output) instead of screen-scraping a
desktop-sized terminal.

## Install
- Build: `flutter build apk --release` → `build/app/outputs/flutter-apk/app-release.apk`
  (signed with the debug key; fine for sideloading).
- Server needs tmux ≥ 3.2 (tested with 3.6). If `tmux` is not on the non-interactive SSH PATH
  (e.g. Homebrew), put the full path in the host's *tmux command* field.

## Use
Host list → **+** → host, port, user, password and/or private key (PEM / OpenSSH), tmux command
(default `tmux`), session (default `main`, created if missing). Secrets are kept in Android
Keystore-backed secure storage. Host key: trusted on first use, a changed key is refused.

### Phone mode (default) vs desk mode
- **Phone mode**: the phone tells tmux its own size (`refresh-client -C`) and zooms the pane you
  look at, so programs reflow to the phone (readable font, no horizontal scrolling). When you go back
  to the desktop and type there, tmux resizes back to it (`window-size latest`). Leaving the screen
  unzooms what the app zoomed.
- **Desk mode** (toggle in the session sheet): never resizes anything; shows the pane at its real
  size, font fitted to width, pinch to enlarge and pan.

### Gestures
| Where | Gesture | Does |
|---|---|---|
| terminal | one-finger drag ↑ ↓ | scroll, as tmux sees the pane: shell / logs / inline TUIs → tmux history view (scrollbar, "↑ N lines", fling; back at the bottom or LIVE → live); full-screen apps → mouse wheel if the app enabled the mouse, else arrow keys |
| terminal | two-finger swipe ← → ↑ ↓ | move to the neighbouring pane in that direction (bump if none) |
| terminal | pinch | font size (phone mode); pinch in at the minimum → window overview |
| terminal | two-finger double tap | toggle tmux zoom |
| window bar (bottom) | swipe left / right | next / previous window |
| window bar | tap | sessions & windows sheet (switch, new, follow, phone mode) |
| minimap | tap a pane | jump to it |
| minimap | long-press | split ↔ / ↕, zoom, new window, kill pane |
| minimap | drag (any direction) | scrub: the layout opens large with each pane's command, the finger moves a pointer over it (×3); release on a pane → jump there |
| joystick (floating, bottom right) | push toward a side, let go / tap | move to that neighbour (chevrons show which exist) / overview (after 0.3 s); double tap + slide: ← → window, ↑ ↓ session; hold + drag: move the stick (remembered); toggle in the sessions sheet |
| overview | tap a pane / pinch in or **Sessions** button | enter that pane / session map of all windows |

Swipes follow the "move the content" convention: fingers moving left bring in the pane on the right.
Android reserves the screen edges for the back gesture, so nothing here uses edge swipes.

Neighbour hints on the terminal edges fade to faint 2 s after the pane changes; touching the terminal
brings them back.

Extra keys row: Esc Tab Ctrl Alt (sticky) ^C arrows Prefix (C-b) Paste | ~ / -. Paste sends the
clipboard (newlines as Enter), as a bracketed paste when the program asked for it.

## Develop
- `env -u TMUX flutter test` (unit + widget + a live test against a real tmux on `-L pocket-test`).
- On the emulator: `./tool_seed.sh` prints a debug-only `--dart-define=POCKET_SEED=...` that adds a
  test host (`10.0.2.2:2222`, a user-level sshd with its own key, `tmux -L pocket`) on first run.
- Architecture and protocol notes: `docs/architecture.md`.
