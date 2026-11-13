<div align="center">

# larperCord

**A native Discord client for Linux and Windows, at about 130 MB of RAM, whose entire interface is a theme file.**

Zig · SDL3 · Dear ImGui · FreeType · zero Electron

**English** · [Português](README.pt-BR.md)

![larperCord themes](docs/themes.png)

Since the original project now supports Japanese and has fulfilled all its objectives, I am archiving this project.

Thank you.

noelel



*The same binary and the same data, only the `.kdl` file changes. There are 11 themes, each in light and dark. The last tile is `cupertino` in light.*

このクライアントはフォーク元のlarpercordの日本語対応、スラッシュコマンドと転送機能へのフル実装を実現したフォークです。

Noto Sansを使用しています。
</div>

> [!WARNING]g
> **Third-party clients break Discord's Terms of Service**, and your account can be banned.
> Use it at your own risk, ideally with a secondary account. This project has no affiliation
> with Discord Inc. With no token configured, the app runs in a **demo mode** with fake data.

### If Discord locks your account

Discord disables accounts or forces a password reset when it thinks an account is a spam bot or was compromised. It can happen on any client, but third-party clients tend to trigger it more often. It already happened to this project's developer, after a day of testing. **Use a secondary account.**

These are the usual triggers people report, so do them in the official client:

- joining or leaving servers, the most common one
- disconnecting and reconnecting often, which includes restarting the app over and over
- opening DMs with new people
- changing your friends list
- editing your profile while connected here

If it happens, reset your password from discord.com. If the account stays locked, [appeal here](https://support.discord.com/hc/en-us/requests/new?ticket_form_id=360000029731). Discord doesn't publish these rules, so this list comes from the experience of people who make third-party clients.

### If your antivirus complains

The Windows build isn't signed, so SmartScreen warns about it. A scanner may also call it a Discord token stealer, likely because a Discord client is full of the same words a stealer has, such as "token" and "Authorization". One sandbox scored version 0.5.0 that way from a pattern rule, while its behavior report showed no credential access and, in demo mode, no network at all.

The token only goes to Discord, and it stays in the system keyring or, without one, in a private file. The code is public, so you can read it or build it yourself. Only download larperCord from this repository.

## Why

The official client is a whole browser dressed up as an app. On the same PC:

| | RAM (PSS) | Idle CPU | Binary |
|---|---|---|---|
| Vesktop (Electron) | **1279 MB** | 12–47%¹ | 287 MB |
| Discord Phoenix (Rust) | ~290 MB² | 0.1%² | not released |
| **larperCord**, real account | **~130 MB**³ | **0–0.4%**⁴ | **~15 MB** |

<sub>¹ Average since launch, measured with `ps`. Arch Linux, Hyprland, GTX 1050 Ti, 1280×800 window, `ReleaseFast` build.
² Not measured by us and not a side-by-side test: an early Windows 11 build, from a Task Manager screenshot [posted by Discord's CTO](https://x.com/svishnevskiy/status/2118081920194203799). The app isn't out yet.
³ 125–140 MB in one account's normal use on the same PC, about 70 MB right after opening. Yours depends on your servers, members and images; Settings → Performance shows where it goes. About 35 MB of the total is the NVIDIA driver, libraries and fonts. The published Linux file carries SDL3, libcurl and OpenSSL inside: side by side in demo, it used about 2 MB more than a build using the system's copies.
⁴ Measured with `tools/membench.sh`, with demo data, a real window and GIF autoplay off. An animated GIF on screen costs about 2.5% CPU.</sub>

## What's in it

- **Themes that rearrange everything.** A layout tree (`row`/`column`/`flex`/`gap`), 11 components
  with variants, colors overridden per layout piece (`c-text="#fff"`), styles, and color tokens with expressions (`mix(wal:0, black, 0.4)`).
  [Theme guide →](themes/README.md)
- **Reloads on save.** Edit the `.kdl` and the window changes right away (inotify, no polling).
  Errors show up as `file:line:column`.
- **Follows your wallpaper.** Themes with `palette "wal"` use pywal's colors and follow the change.
- **Real blur.** The `vidro` theme has a transparent background and your compositor (Hyprland, KDE…)
  applies the blur, at no cost to the app.
- **Connects to the real Discord**: WebSocket gateway with heartbeat, **session RESUME**,
  **zlib-stream** and reconnects; IDENTIFY and headers in the web client's format (the same
  approach as the web client). REST for history, sending, editing, deleting, reactions and "typing",
  one request at a time and respecting the rate limit.
- **Real voice calls**: voice gateway v8, UDP/RTP, Opus at 48 kHz stereo, **DAVE (E2EE)** through
  libdave/MLS, mic and output through SDL3, mute/deafen, a "speaking" ring and a **mixer with a
  volume per person**. The voice thread only starts when you join a call.
- **Discord interactions**: right-click menus on messages, users, channels and servers;
  a hover action bar; **replies** (with the little curve and a click that jumps to the
  original); **edit** (`↑` in the empty box edits your last one); **delete**; **reactions**;
  mouse **text selection** across several messages + `Ctrl+C`; a **profile card** with
  "Message @someone"; **direct messages**; mentions of you highlighted.
- **Channel tabs**, a command palette with fuzzy search (`Ctrl+K` / `Ctrl+Shift+P`: channels, DMs,
  servers, themes, status, mark as read and the toggles), keyboard shortcuts and optional
  vim-style navigation (`j`/`k`, `gg`/`G`, `J`/`K` switches channel, `/` searches).
- **Panels your size**: drag the edge of the channel list, the member list or the panes of a split view; a double-click goes back to the theme's width. Your choice is saved and follows you between themes, and the conversation always keeps enough room.
- **Lua plugins**: `.lua` files in `~/.config/larpercord/plugins/` that add panels, right-click
  entries, notes under messages, commands and reminders, on a thread of their own with an instruction
  and a memory limit, so they can't hold up the interface. Scam guard, CVE radar, GitHub cards, what did I miss, translate,
  reminders, highlights, clean links, and links and files come with the app. [Guide and API →](docs/plugins.md)
- **Voice settings.** In Settings → Voice you pick the microphone and output (remembered by name, back to the default if they disappear, switchable mid-call), adjust volumes, see the mic level live and use "Test microphone" to hear yourself. Voice activity has an adjustable threshold on the meter or an automatic mode that learns your background noise. "Push to talk" takes a key or mouse button and works while the window is focused (SDL has no portable global shortcut). There's a high-pass against rumble, a noise gate and beeps for joining, leaving, muting and unmuting, all of which can be turned off. The voice panel shows ping, quality by color and when you're transmitting, and warns you if the mic doesn't open or if the server muted or deafened you. Other people's mute and deafen show in the call list.
- **Runs on Linux and Windows.** Windows 10/11 builds come from the same code; tokens stay in Credential Manager.
- **Stays in the tray.** Closing keeps it connected in the system tray, with Open and Quit in the tray menu; "Close to tray" in Settings → Advanced turns it off. Without a tray, closing quits. Opening it a second time brings up the running window. On Linux the tray needs a StatusNotifier panel and libappindicator or ayatana.
- **Updates itself.** Checks when opening or from Settings → Updates. One button downloads, installs and restarts. Updates are signed, and a version without the right signature isn't installed. There's a restart button and a What's new page with the changes in each version.
- **Video volume.** The in-app player has a volume slider, remembered between runs.
- **Microphone noise suppression.** Settings → Voice → Noise suppression (Off / RNNoise), on by default and switchable mid-call. It uses [RNNoise](https://github.com/xiph/rnnoise) 0.2 (BSD), built into the executable and running on your computer, with no internet. It reduces steady noise such as fans, hiss and air conditioning; typing and bangs may get through, other voices stay and yours may get a bit muffled. It delays your mic by 20 ms and costs about 2% to 3.5% of a core on a 2011 Core i5 while the mic is open, and less on newer processors; off, muted or with the push-to-talk key released, it costs nothing.
- **Bot messages in full.** Bots and webhooks carry a BOT tag (with a check mark when verified). Discord's newer component messages (Components V2) show text, thumbnails, separators, galleries, files and link buttons. Forwarded messages and polls appear as cards. Buttons that talk to the bot aren't supported yet, so they aren't shown.
- **Discord markdown.** Headings, `-#` small text, quotes, lists and `[text](url)` links, which show the real address on hover. Code blocks have line numbers, and text in embeds can be selected and copied.
- **Manage what's yours.** Edit a server (name, description, icon, banner) or a group DM (name, icon), and delete threads when you have permission. Server banners appear at the top of the channel list and on invite cards; click one to see it in full.
- **Code diagnostics (optional).** See errors while typing a code block, from a language server you choose. Off by default, nothing bundled or downloaded. [Guide →](docs/lsp.md)
- **Threads and forums.** Active threads nested under the parent channel (collapsible, with unreads), opening as a normal conversation, with tabs, split view, drafts, cache and search; a card with the message count and last activity on the message that started it; create, join, leave and see archived threads from the menu. Forums and media channels show the list of posts instead of a conversation, with local search, sorting by activity, pages on demand and "New Post" with title, tags and text. Permissions come from the parent channel, and the member list shows who's in the thread.
- **Emoji and autocomplete.** Custom emoji show as images (animated too), large when the message is only emoji, and in reactions. PNG, APNG and GIF stickers show as images. The picker has the full Unicode list, search in Portuguese and English, recents and your servers' emoji, and warns when an emoji needs Nitro. In the text box, `@`, `#`, `:ab` and `/` open a list (arrows, Tab/Enter, Esc or click); names with spaces become real mentions when sent. In data saver mode, custom emoji become `:name:`, with nothing downloaded. To regenerate the table: `tools/gen_emoji.py`.
- **Read state synced with Discord**: unreads and mentions correct on open, `MESSAGE_ACK` from another device clears them here, confirmations like the official client's (at most one per channel every 3 s; none on its own with the window unfocused), "mark as read" per channel and per server, "mark as unread" from a message.
- **NEW MESSAGES line** with a button that jumps to the first one and "mark as read"; the channel opens at the first unread (you can turn it off in Settings → Chat).
- **Pinned messages**: a pin in the header, pin and unpin from the menu; jumping to any old message loads around it, with "Jump to present".
- **Discord links open in the app** (`ptb.` and `canary.` too); invites become a card with the server and members and open in the browser (the app doesn't join servers).
- Clicking `@someone` opens the profile, `#channel` opens the channel; the timestamp shows the full date on hover.
- **Inbox** (`Ctrl+I`): unread DMs and mentions from every server, by channel, with
  previews, jump to the message and "mark all as read"; a tab with Discord's recent mentions.
- **Saved messages with notes** (`Ctrl+Shift+S`, right-click → Save message): only on your
  computer, in `~/.config/larpercord/saved-<account>.json`; nothing goes to Discord.
- **Local cache and offline search.** The last 200 messages seen in each channel stay in
  `~/.cache/larpercord/messages` (folders 700, files 600, 50 MB cap): the conversation appears
  right away on open and the real history arrives on top, without jumping the scroll. `Ctrl+F` searches
  memory and the cache on every keystroke, without internet, with `from:name`, `in:channel`, `has:link`,
  `has:image` and `has:file`; clicking a result jumps to the message. You can turn it off and
  erase it in Settings → Privacy.
- **Multiple accounts.** Your own name's menu lists the saved accounts (name and picture) and switches
  right away; "Add account" goes back to sign-in without forgetting the others. The sign-in screen
  lists them too, and a token Discord refuses is forgotten instead of being tried again.
- **Discord-style settings** (`Ctrl+,`): 14 pages, theme switching with thumbnails,
  accent color and corners, **custom colors per theme and mode in hex**, font scale,
  compact mode, reduced motion, 12/24 h clock, spoilers…, saved in
  `~/.config/larpercord/settings.kdl`.
- **Discord markdown**: **bold**, *italic*, ~~strikethrough~~, `code`, ||spoiler||, `<@id>`/`<#id>`
  mentions, links and color emoji; code blocks highlighted by their label (zig, c/cpp,
  js/ts, py, rust, go, sh, json, lua…) with a "Copy" button; a preview above the box while you type.
- **Videos playing in the conversation** (attachments and direct .mp4/.webm links) with the **system's
  FFmpeg, if present** (loaded only on the first play, no build dependency): play/pause,
  progress bar, sound; up to 480p and about 30 fps. Without FFmpeg, the video opens in the browser. It also
  animates old Tenor GIFs that only exist as MP4.
- **Proxy** (http, https, socks5, socks5h; Tor at `socks5h://127.0.0.1:9050`) for media from
  outside Discord or for everything (Settings → Privacy → Network).
- Grouped messages, day separators, "pending" sends confirmed by the server,
  a typing indicator, smooth scrolling with a virtualized list.

<div align="center">

![Right-click menu, profile, text selection and action bar](docs/interactions.png)

![Settings](docs/settings.png)

</div>

## Built-in themes

All of them have **light and dark modes** and **their own options** in Settings → Appearance.

| Theme | Idea | Exclusive |
|---|---|---|
| `classico` | the layout everyone knows, in pywal's colors | server banner |
| `vidro` | translucent cards with the compositor's blur | light reflection on the cards |
| `terminal` | tmux + IRC; in light, dot-matrix printer paper | CRT effect, ASCII logo, green phosphor |
| `subsolo` | underground hacking terminal, acid green and scanlines | horizontal rack, ultraviolet, ASCII logo |
| `orbital` | a flight console among the stars, with numbered systems | star field and orbits in the background, command composer, server strip in the footer |
| `editorial` | a printed magazine on grainy paper, masthead between rules and an index on the right | inverted layout, serif conversation, colophon |
| `bolhas` | a messenger with chat bubbles | "Delivered ✓✓" and a typing bubble |
| `zen` | one central column, larger letters | navigation hides itself |
| `papel` | a notebook with an index in the margin and serif titles | ruled sheet with a red margin |
| `escritorio` | a work tool, dark sidebar | top bar with search and help |
| `cupertino` | a Mac-style desktop: wallpaper and a floating window | working traffic lights, translucent sidebar, Dock with magnifier, bubbles |

## Install

**Download:** [Linux](https://github.com/RshaCuDeVidro/larperCord/releases/latest/download/larpercord-linux-x86_64) · [Windows](https://github.com/RshaCuDeVidro/larperCord/releases/latest/download/larpercord-windows-x86_64.zip) · [all versions](https://github.com/RshaCuDeVidro/larperCord/releases). On Linux, `chmod +x` the file and run it. On Windows, unzip it and open `larpercord.exe`; it isn't code-signed yet, so Windows may warn you the first time.

The Linux build runs on distros from about 2022 onward (glibc 2.34 or newer). SDL3, libcurl and OpenSSL come inside it. FreeType, fontconfig, libwebp, Opus and zlib come from the system, and a desktop distro usually has them already. Before each release it's opened in Ubuntu 22.04 and 24.04, Debian 12 and 13, Fedora, openSUSE and Arch containers, in demo mode with no GPU.

GitHub Actions builds that file from this repository's code. With the GitHub CLI you can check it: `gh attestation verify larpercord-linux-x86_64 --repo RshaCuDeVidro/larperCord`.

Or use a script:

**Linux** (x86_64, into `~/.local`, no sudo):

```bash
curl -fsSL https://raw.githubusercontent.com/RshaCuDeVidro/larperCord/main/install.sh | sh
```

**Windows 10/11** (for your user, no administrator), in PowerShell:

```powershell
irm https://raw.githubusercontent.com/RshaCuDeVidro/larperCord/main/install.ps1 | iex
```

Both download the latest [release](https://github.com/RshaCuDeVidro/larperCord/releases) and check it against `SHA256SUMS`. On Linux the script lists any system library that's missing. On a distro older than 2022, [build from source](#building). After that, the app updates itself: Settings → Updates.

## Connecting your account

The token is **never** in the code, in a log or in an error message, and it's wiped from memory on
exit. The app looks in this order:

1. **System keyring** (recommended):
   ```bash
   secret-tool store --label='larperCord' service larpercord   # paste the token when asked
   ```
2. The `LARPER_TOKEN` variable
3. The file `~/.config/larpercord/token`, which must be `chmod 600`

With "Remember" at sign-in, each account gets its own keyring entry
(`service larpercord-account account <ID>`; without a keyring, `~/.config/larpercord/tokens/<ID>` with
`chmod 600`) and appears in the user menu for switching. The list (only ID, name and avatar) is in
`~/.config/larpercord/accounts`. The entry above still applies to the account that was already there.

`--demo` forces demo mode even with a token. Still missing: screen sharing and camera, and joining
servers by invite. Channels without access only show a notice, and notifications go through
`notify-send`. Voice uses the system's audio backend through SDL3 and only starts its thread when
you join a call.

## How it stays light

No magic, just many small decisions:

1. **It sleeps when nothing happens.** The loop waits in `SDL_WaitEvent`. Network, inotify and the clock
   wake the app with events. No animation, no redraw. A frame that comes out the same as the last one
   never reaches the GPU, and a mouse just moving asks for fewer frames.
2. **No browser.** Everything is drawn with Dear ImGui's `ImDrawList` on top of SDL_Renderer.
3. **Fonts are mapped, not copied.** Each font file is one `mmap` shared by
   every weight and family. Only the pages read stay in RAM. (Loading 4 weights of Inter + emoji
   the naive way cost about 90 MB.)
4. **Only the video driver it needs.** On NVIDIA-only machines, glvnd also loaded
   Mesa + LLVM (about 23 MB) for nothing. The app detects that and avoids it.
5. **Markdown is parsed once**, when the message arrives. The UI only lays out the
   spans, with a **height cache per width**.
6. **A virtualized list**: binary search for the first visible item, then draw only the screen.
7. **Memory has ceilings**: 1,500 messages per channel and 3,000 in total, with old ones freed. After a
   minute in the tray or minimized, images leave memory too, except small ones that were on screen.
8. **fontconfig gets freed** after fonts are resolved (`FcFini` + `malloc_trim`).
9. **No blinking cursor**: a cursor blinking on its own would keep the CPU awake.
10. **A lean binary**: a release build without debug symbols. The Linux file is about 15 MB with SDL3, libcurl and OpenSSL inside, and about 7 MB built against the system's copies.

## Building

To build for Windows from Linux: `tools/windows_deps.sh && zig build -Dtarget=x86_64-windows-gnu`.

You need **Zig 0.17**, **SDL3**, **FreeType**, **fontconfig** and **libcurl** (with WebSocket, 7.86+). Recommended fonts: Inter,
JetBrains Mono and Noto Color Emoji (fontconfig picks substitutes if one is missing).
Optional: **FFmpeg 7, 8 or 9** (libavformat 61–63) to play video inside the app; any other version
is ignored and the video opens in the browser.

```bash
# Arch
sudo pacman -S zig sdl3 freetype2 fontconfig curl inter-font ttf-jetbrains-mono noto-fonts-emoji

zig build -Doptimize=ReleaseFast
./zig-out/bin/larpercord --theme vidro
```

| Command | |
|---|---|
| `zig build test` | tests (KDL, colors, layout, markdown, Store, built-in themes, settings) |
| `tools/snapshots.sh` | generates the screenshots in `docs/` without opening a window |
| `tools/membench.sh 60` | measures RAM and CPU for each theme and fails over 60 MB |
| `tools/qa_quadros.py BIN [--slow]` | checks frame skipping and hidden-window memory with a real window in Xvfb |

```
larpercord [--theme NAME] [--demo] [--settings] [--list-themes] [--no-live] [--shot FILE.png] [--stats]
```

Shortcuts: `Ctrl+K` palette · `Ctrl+,` settings · `Ctrl+I` inbox · `Ctrl+Shift+S` saved · `F2` next theme · `Ctrl+Tab` tabs ·
`Alt+1…9` · `Ctrl+W` closes a tab · `Ctrl+Click` opens a channel in a new tab · `↑` edits your last
message · `Esc` cancels a reply or edit · `Ctrl+C` copies the selection · right-click on everything.

## Architecture

```
src/
  core/       plain data, no window: types (snowflakes), Store, markdown, events
  net/        real (Discord) and demo gateways, each on its own thread, plus the queues
  theme/      KDL parser, colors, theme loader, layout engine, manager + inotify
  ui/         components, rich text, palette, settings, animations
  platform/   window, renderer, "wake the loop"; the only place that knows SDL
themes/       the built-in themes (also compiled into the binary)
third_party/  Dear ImGui 1.93 + dear_bindings (C), with a small patch for bitmap emoji
```

The flow is **UI → `Action` → app → `Command` → gateway → `Event` → Store → UI**.
The UI never changes data directly: it only reads the Store and asks for actions. That's why
swapping the fake gateway for the real one doesn't touch the UI.

## Roadmap

- [x] Real gateway (WebSocket, heartbeat, reconnects) and REST respecting the rate limit
- [x] Session RESUME and zlib-stream
- [x] Presences, members and server/channel events (GUILD_CREATE, CHANNEL_*)
- [x] Images: avatars, attachments and custom emoji with a fixed-size cache
- [x] Per-channel permissions (a padlock on what you can't read), threads and forums
- [x] Windows 10/11
- [x] System tray, signed self-updates and install scripts
- [ ] Native notifications through D-Bus on Linux
- [x] Voice (DAVE/MLS + Opus)
- [ ] A software backend (`wl_shm`, no GPU) to get to about 15–20 MB
- [ ] Theme components written in Lua (sandboxed)

**Next**

- [ ] Open from the saved servers, channels and messages, then sync when Discord answers
- [ ] Memory settings: messages kept in channels you left, the image limit and GIF limits
- [ ] A texture atlas for avatars and emoji
- [ ] Server and role settings
- [ ] A better theme editor
- [ ] More versatile and more powerful plugins
- [ ] Windows as a single `.exe`

## License

Not decided yet. Third-party code keeps its own license, in each folder of `third_party/`: Dear ImGui and dear_bindings are MIT, RNNoise is BSD. The file
`third_party/imgui/misc/freetype/imgui_freetype.cpp` has changes marked with `[larperCord]`.
