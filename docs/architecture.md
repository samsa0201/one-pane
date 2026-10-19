# tmux-pocket — architecture

Goal: phone app (Android first, Flutter) to drive tmux over SSH. Phone screens are portrait/small, so
we show ONE pane at a time, full screen, and make the user always aware where that pane sits in its
window (left/right/up/down neighbours) and which window/session they are in.

## Key decision: tmux control mode
SSH exec `<tmuxCmd> -C new-session -A -s <session>` (no PTY). tmux then speaks a line protocol:
- commands we write: one per line (`list-windows ...\n`), replies come back in order wrapped in
  `%begin <time> <num> <flags>` ... `%end|%error <time> <num> <flags>`. Only blocks with `flags & 1`
  answer OUR commands (FIFO). Blocks with flags 0 come from tmux itself (e.g. the attach) — ignore.
- async notifications: `%output %<pane> <escaped>`, `%layout-change @<win> <layout> <visible-layout> <flags>`,
  `%window-add @w`, `%window-close @w`, `%unlinked-window-close @w`, `%window-renamed @w <name>`,
  `%session-changed $s <name>`, `%sessions-changed`, `%session-window-changed $s @w`,
  `%window-pane-changed @w %p`, `%exit [reason]`. Unknown `%xxx` lines: ignore.
- `%output` escaping: bytes < 0x20 and `\` are written as `\ooo` (3 octal digits); everything else is raw
  UTF-8. Decode to bytes, then UTF-8-decode per pane with a streaming decoder (multi-byte chars can
  split across lines).
- Window layout string: `8b5f,160x48,0,0{80x48,0,0,0,79x48,81,0,1}` = checksum, then a cell
  `WxH,X,Y` followed by either `,<paneId>` (leaf) or `{...}` (children side by side, left→right) or
  `[...]` (children stacked, top→bottom), children comma-separated. Leaf pane id N means `%N`.
- Client size is the pane screen's decision (connectTmux only probes with `display -p`). Control
  clients without a size are ignored for window sizing.
  - Phone mode (default, pref `phoneMode` in shared_preferences): the pane screen computes cols×rows that
    fit its terminal area at the current font (cell size measured like xterm's TerminalPainter; area
    WITHOUT the keyboard) and sends `refresh-client -C <cols>x<rows>` (debounced 150ms; again on
    rotation / font change). The shown pane is kept zoomed (`zoom()` = `resize-pane -Z` unless tmux says
    the window is already zoomed; moving uses `select-pane -Z`). Windows we zoomed are unzoomed (best
    effort, `unzoom()`) when the screen closes or desk mode is switched on. Control clients have no
    status line, so a zoomed pane gets exactly cols×rows.
  - Desk mode: `refresh-client -f ignore-size` so the phone does NOT shrink the desktop layout; panes keep
    their real size and the phone scales the font to fit the width (pinch: zoom + horizontal scroll).
    Switching back sends `refresh-client -f !ignore-size`.
- While zoomed, `#{window_layout}` still describes the unzoomed geometry (minimap, neighbor()), and
  `#{window_visible_layout}` the real sizes (only the zoomed pane). Terminal size of a pane =
  `WindowInfo.sizeOf(id)`: its visible rect, else its layout rect.
- Input: `send-keys -t %N -H <hex bytes ...>` (raw bytes from the terminal widget).
- Seed a pane when shown: `capture-pane -p -e -J -t %N` (visible screen) and
  `display -p -t %N '#{cursor_x} #{cursor_y}'`.
- Fixture with real output: `test/fixtures/control_mode_sample.txt` (note: base-index may be 1).

## Modules and API contract (do not change signatures without updating this file)

### lib/tmux/layout.dart (pure Dart)
```dart
class PaneRect { final int id; final int x, y, w, h; const PaneRect(this.id, this.x, this.y, this.w, this.h); }
List<PaneRect> parseLayout(String layout);          // throws FormatException on garbage
enum Dir { left, right, up, down }
int? neighbor(List<PaneRect> panes, int fromId, Dir d);
// neighbor: candidates are panes on the far side of the border in direction d whose span overlaps
// fromId's span on the other axis; pick max overlap, tie → the one whose top/left is closest to
// fromId's top/left. null if none (edge of window).
```

### lib/tmux/control.dart (pure Dart, no Flutter imports)
```dart
List<int> decodeOutput(String escaped);   // octal-unescape to raw bytes (non-escaped chars → their UTF-8 bytes)

sealed class TmuxEvent {}
class OutputEvent extends TmuxEvent { final int paneId; final List<int> bytes; }
class LayoutEvent extends TmuxEvent { final int windowId; final String layout; }
class WindowsChangedEvent extends TmuxEvent {}          // add/close/rename/session-window-changed → refresh
class SessionChangedEvent extends TmuxEvent { final int sessionId; final String name; }
class SessionsChangedEvent extends TmuxEvent {}
class ActivePaneEvent extends TmuxEvent { final int windowId; final int paneId; }
class ExitEvent extends TmuxEvent { final String? reason; }

class SessionInfo { final int id; final String name; final int windows; final bool attached; }
class WindowInfo  { final int id; final int index; final String name; final bool active;
                    final List<PaneRect> panes; final int activePane; final bool zoomed;
                    final List<PaneRect> visiblePanes;   // #{window_visible_layout}, optional last ctor arg
                    PaneRect? sizeOf(int id); }          // visible rect, else layout rect

class TmuxClient {
  TmuxClient(Stream<List<int>> stdout, void Function(String data) write);  // client calls write('<cmd>\n')
  Stream<TmuxEvent> get events;                 // broadcast
  Future<void> get done;                        // tmux stdout ended (detach / exit / drop); later cmds fail
  Future<List<String>> cmd(String command);     // throws TmuxError(lines) on %error
  // helpers (all built on cmd):
  Future<List<SessionInfo>> listSessions();
  Future<List<WindowInfo>> listWindows();      // windows of the attached session, sorted by index
  Future<void> sendBytes(int paneId, List<int> bytes);   // send-keys -H, chunk ≤ 256 bytes/command
  Future<String> capturePane(int paneId);       // capture-pane -p -e -J, lines joined with \r\n
  Future<String> captureHistory(int paneId, {int lines = 2000}); // capture-pane -p -e -J -S -<lines> -E -1
                                                // (history above the screen; no history → first screen line)
  Future<Map<int, String>> paneCommands();      // list-panes -s: pane id → #{pane_current_command}
  Future<(int, int)> cursor(int paneId);        // (x, y)
  Future<void> selectPane(int paneId, {bool keepZoom = false}); // select-pane [-Z] -t %N
  Future<void> selectWindow(int windowId);      // select-window -t @N
  Future<void> switchSession(String name);      // switch-client -t <name>
  Future<void> newWindow();  Future<void> split(int paneId, {required bool horizontal});
  Future<void> killPane(int paneId); Future<void> toggleZoom(int paneId);
  Future<void> zoom(int paneId);                // zoom unless the window is zoomed (if -F, checked by tmux)
  Future<void> unzoom(int windowId);            // unzoom if zoomed
  Future<void> setClientSize(int cols, int rows); // refresh-client -C <cols>x<rows>
  Future<void> ignoreSize(bool on);             // refresh-client -f ignore-size | !ignore-size
  Future<void> newSession(String name);         // new-session -d -s name, then switchSession
  Future<void> close();                         // detach-client, completes pending cmds with error
}
class TmuxError implements Exception { final List<String> lines; }
```
Shell-quote every user string put in a command (single quotes, `'` → `'\''`). tmux parses commands
like a shell.

### lib/ssh/connection.dart
```dart
class HostConfig { String id, name, host; int port; String user; String? password; String? privateKeyPem;
                   String tmuxCmd /* default 'tmux' */; String session /* default 'main' */; toJson/fromJson }
Future<(SSHClient, TmuxClient)> connectTmux(HostConfig h);  // dartssh2 execute(), wires stdout/stdin
// PaneScreen({SSHClient? ssh, required TmuxClient client, required String session,
//             Future<(SSHClient?, TmuxClient)> Function()? reconnect}) — ssh null in widget tests;
//             HostsScreen passes reconnect: () => connectTmux(h). reconnect null: a drop closes the screen.
```
Secrets (password, key) live in flutter_secure_storage; the rest of HostConfig in shared_preferences.

### lib/ui/*
- `hosts_screen.dart`: list / add / edit / delete hosts, tap → connect.
- `pane_screen.dart`: the main screen (below).
- `overview.dart`: window overview + session/window tree.

## UX
Semantic zoom with pinch: pane (font size) → pinch below min font (phone) / fit-to-width (desk) → window overview (all panes of
the window drawn at their real relative positions, live text thumbnails, tap one to enter) → pinch
further → session map (all windows of all sessions as cards). Pinch out reverses.

Pane screen:
- Phone mode: terminal at font 13 (pinch 8–24), tmux sized to fit, shown pane zoomed. Desk mode: exactly
  the pane's cols×rows, font scaled to width. Keyboard hidden on open (tap terminal / keyboard button).
- Top bar: `session › window-index:name` + a mini-map of the window's panes (rectangles at relative
  positions, current one filled) + overview button (grid icon, same as pinch-in) + keyboard button.
  Tap the bar → session/window sheet.
- Neighbour edge hints: on each edge of the terminal area with a spatial neighbour, a translucent pill
  with its command (`‹ vim`, `git ›`, `˄ htop`, `˅ bash`), touch-transparent. Commands come from
  `paneCommands()`, reloaded with every window reload and every 3 s while the screen is visible.
  Full opacity for 2 s after the shown pane changes or any pointer down on the terminal, then fade to
  0.15 (the top hint covers the first terminal row; not 0, so they stay discoverable).
- Scrollback: one-finger drag scrolls the live view's own buffer (xterm TerminalView; only what arrived
  since attach). Dragging down further at its top (main screen only; on the alt screen TerminalView
  sends wheel/arrow keys to the app) opens a read-only overlay with `captureHistory()` (own xterm
  Terminal, pane width, starts at the bottom). "LIVE" chip, any key, or changing pane closes it.
- Auto-reconnect: when the connection drops (tmux stdout ends, ssh done, %exit not caused by our
  close(), or a failed probe on app resume) a "Reconnecting…" pill shows and `reconnect` is retried
  with backoff 1, 2, 4, 8, 15 s… for ~2 min; then the same window/pane are kept if they still exist,
  panes are reseeded and the phone-mode size / zoom re-sent. A killed session is not reconnected
  (that would recreate it via `new-session -A`): tmux 3.6 sends a bare `%exit` for both detach and kill,
  but a kill is preceded by `%sessions-changed`, so that pair (or a reason mentioning session/server
  exited) pops the screen with a message.
- Two-finger swipe left/right/up/down → move to the spatial neighbour (`neighbor()`), with a slide
  transition from that side. No neighbour → small rubber-band bump + haptic. Also selects the pane in
  tmux (`selectPane`) so the desktop follows.
- Swipe on the top bar left/right → previous/next window.
- Two-finger double tap → toggle tmux zoom on the pane.
- Long-press mini-map → pane actions: split ↔ / ↕, kill, zoom, new window.
- Mini-map scrub: a pan starting on the mini-map shows the window layout large and centred (same
  `scaleRects` / `MiniMapPainter`), each pane labelled with its command. A virtual pointer starts at
  the shown pane's centre and moves 3× the finger; the pane under it is highlighted, with a selection
  haptic on each change. Release → that pane (as a mini-map tap, `select-pane -Z` in phone mode);
  release on the start pane or cancel → nothing. The pan recognizer uses half the touch slop (pan slop
  is 2× touch slop) so it accepts at the same distance as the top bar's horizontal drag and wins,
  being deeper in the hit test.
- Overview app bar: "Sessions" button (view_module) = pinch in → session map.
- Bottom extra-keys row (horizontally scrollable): Esc Tab Ctrl Alt ^C ← ↓ ↑ → Prefix Paste | ~ / -
  (^C sends 0x03, Prefix sends C-b, Paste sends the clipboard with \n → \r through xterm's
  `Terminal.paste`, which wraps it in `\e[200~`…`\e[201~` when the pane enabled bracketed paste;
  embedded `\e[201~` is stripped).
- Android edge swipes are reserved by the system back gesture → no edge-swipe gestures.
- If the active pane in tmux changes from the desktop, the phone follows only when "follow" is on
  (toggle in the sheet; default on).

## Testing
- Pure Dart unit tests for layout + control parser (fixture above).
- Widget test: `test/widget_pane_screen_test.dart` drives PaneScreen against a fake tmux (scripted
  `%begin`/`%end` replies, recorded commands): client size, zoom, two-finger swipes, keyboard hidden.
- Integration test: `test/tmux_live_test.dart` spawns `tmux -L pocket-test -C new -A -s t` as a
  Process and drives TmuxClient against it (real tmux 3.6 on the dev host). Always use a separate
  `-L` socket in tests and on the dev host — never touch the user's default tmux server.
- On-device: emulator → host sshd on 10.0.2.2. HostConfig.tmuxCmd = `tmux -L pocket` for testing.
