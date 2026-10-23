# Google Play release

## Build

Upload key: `~/.config/one-pane/upload-keystore.jks` + `key.properties` (outside the repo; override the path with
`ONE_PANE_KEY_PROPERTIES`). Back up that folder. With Play App Signing, Google holds the app signing key; a lost
upload key can be reset from Play Console › App integrity.

```
flutter build appbundle --release --split-debug-info=<dir>
# -> build/app/outputs/bundle/release/app-release.aab
```

Bump `version:` in pubspec.yaml before every upload (the `+N` build number must grow).
Package id: `com.samsa.onepane` (fixed forever after the first upload).

## Store listing

- App name: One Pane
- Short description (≤80): tmux over SSH, made for a phone: one pane at a time, real keys, quick switching.
- Full description:

  One Pane connects to your server over SSH and attaches to tmux, showing one pane at a time at a size you can
  read on a phone.

  - Switch sessions, windows and panes from the bottom bar, or swipe with the joystick
  - A key row with Esc, Tab, Ctrl, arrows and your own snippets, on up to four pages
  - Split, zoom, rename and kill panes and windows without typing tmux commands
  - Scroll back through history, then jump back to live
  - Reconnects by itself when the network drops; your tmux session keeps running on the server
  - Eight terminal themes (Gruvbox, Catppuccin, Tokyo Night, Dracula, Nord, Solarized Light…) and Nerd Fonts
  - SSH keys made on the phone and kept in Android's secure storage; server keys checked on every connection
  - Home screen widget for your hosts

  No account, no ads, no tracking. One Pane talks only to the servers you add.

  Needs a server you can reach over SSH with tmux 3.x installed.

- Category: Tools. Tags: SSH, terminal.
- Graphics: icon 512×512 PNG, feature graphic 1024×500, 2–8 phone screenshots (1080×1920 or larger, 9:16).

## Play Console answers

- Privacy policy URL: https://claude.ai/artifact/FXVrZVCbW2JkqJvHYbpExh (must be shared publicly)
- App access: all functionality is available without special access (users connect to their own servers).
- Ads: no ads.
- Content rating (IARC): utility, no user-generated content shared, no violence → Everyone.
- Target audience: 18+.
- Data safety: no data collected, no data shared. Data stays on the device (host list, settings; keys in
  encrypted storage). Connections to the user's servers are encrypted (SSH). Fonts the user picks are downloaded
  from raw.githubusercontent.com.
- Government / financial / health features: none.

## New personal developer account

Accounts created after 2023-11-13 must run a closed test with at least 12 testers opted in for 14 days in a row
before applying for production access.
