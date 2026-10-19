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
- After attach run `refresh-client -f ignore-size` so the phone does NOT shrink the desktop layout.
  Panes keep their real size; the phone renders the pane at exactly WxH cells and scales the font.
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
                    final List<PaneRect> panes; final int activePane; final bool zoomed; }

class TmuxClient {
  TmuxClient(Stream<List<int>> stdout, void Function(String data) write);  // client calls write('<cmd>\n')
  Stream<TmuxEvent> get events;                 // broadcast
  Future<List<String>> cmd(String command);     // throws TmuxError(lines) on %error
  // helpers (all built on cmd):
  Future<List<SessionInfo>> listSessions();
  Future<List<WindowInfo>> listWindows();      // windows of the attached session, sorted by index
  Future<void> sendBytes(int paneId, List<int> bytes);   // send-keys -H, chunk ≤ 256 bytes/command
  Future<String> capturePane(int paneId);       // capture-pane -p -e -J, lines joined with \r\n
  Future<(int, int)> cursor(int paneId);        // (x, y)
  Future<void> selectPane(int paneId);          // select-pane -t %N
  Future<void> selectWindow(int windowId);      // select-window -t @N
  Future<void> switchSession(String name);      // switch-client -t <name>
  Future<void> newWindow();  Future<void> split(int paneId, {required bool horizontal});
  Future<void> killPane(int paneId); Future<void> toggleZoom(int paneId);
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
```
Secrets (password, key) live in flutter_secure_storage; the rest of HostConfig in shared_preferences.

### lib/ui/*
- `hosts_screen.dart`: list / add / edit / delete hosts, tap → connect.
- `pane_screen.dart`: the main screen (below).
- `overview.dart`: window overview + session/window tree.

## UX
Semantic zoom with pinch: pane (font size) → pinch below fit-to-width → window overview (all panes of
the window drawn at their real relative positions, live text thumbnails, tap one to enter) → pinch
further → session map (all windows of all sessions as cards). Pinch out reverses.

Pane screen:
- Terminal fills the screen at exactly the pane's cols×rows; font scaled to width by default.
- Top bar: `session › window-index:name` + a mini-map of the window's panes (rectangles at relative
  positions, current one filled). Tap the bar → session/window sheet.
- Two-finger swipe left/right/up/down → move to the spatial neighbour (`neighbor()`), with a slide
  transition from that side. No neighbour → small rubber-band bump + haptic. Also selects the pane in
  tmux (`selectPane`) so the desktop follows.
- Swipe on the top bar left/right → previous/next window.
- Two-finger double tap → toggle tmux zoom on the pane.
- Long-press mini-map → pane actions: split ↔ / ↕, kill, zoom, new window.
- Bottom extra-keys row: Esc Tab Ctrl Alt ← ↓ ↑ → | ~ / - and a "prefix" key (sends C-b; configurable).
- Android edge swipes are reserved by the system back gesture → no edge-swipe gestures.
- If the active pane in tmux changes from the desktop, the phone follows only when "follow" is on
  (toggle in the sheet; default on).

## Testing
- Pure Dart unit tests for layout + control parser (fixture above).
- Integration test: `test/tmux_live_test.dart` spawns `tmux -L pocket-test -C new -A -s t` as a
  Process and drives TmuxClient against it (real tmux 3.6 on the dev host). Always use a separate
  `-L` socket in tests and on the dev host — never touch the user's default tmux server.
- On-device: emulator → host sshd on 10.0.2.2. HostConfig.tmuxCmd = `tmux -L pocket` for testing.
