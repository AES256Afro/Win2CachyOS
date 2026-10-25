# Profile Hub: design

Status: proposal (design only, nothing built). Date: 2026-10-25.

Win2CachyOS today is a one-shot migration: `Export-Win2Cachy.ps1` writes a folder to the NAS, `linux/restore.py` replays it on CachyOS. This doc describes how it grows into a cross-platform **profile** tool: a Ninite that also brings your settings, sessions and unsaved work, in both directions between Windows and Linux, optionally through a hosted hub and optionally kept in sync live.

## TL;DR recommendation

1. **Make the profile format OS-neutral first.** Logical paths instead of `C:\Users\...`, per-OS install and state locations in the catalog, a content-addressed file store. Everything else builds on this.
2. **Ship one cross-platform CLI, `w2c`, in Python** with `export` / `import` / `diff`. Most of the hard parts (bencode, path mapping, Notepad++ session rewriting) already exist in `restore.py`. Package it as a single executable for bootstrapping fresh machines.
3. **Don't build a server for the first remote release.** Store client-encrypted profiles in a plain R2 bucket (S3 API) or on the NAS, using **restic** as the storage engine. That gives encryption, dedup, snapshots and `diff` for free and makes "install my profile on a fresh machine" work for one person with zero server code.
4. **Build the Cloudflare hub (Workers + R2 + D1, plus one Durable Object per profile) only when one of these becomes true:** live sync needs a reliable compare-and-swap and push notifications, more than one person uses it, or you want a web UI and shareable profile pages. Cloudflare is a good fit when that day comes (details in [section 4](#4-hosted-profile-hub)).
5. **Live sync is app-aware capture/apply on top of a dumb transport.** The hard part is not moving bytes (Syncthing already does that). It is knowing when an app's state is safe to read, safe to write, how to rewrite paths inside it, and how to merge two edits. Notepad++ gets tab-level merging; WoW gets file-level merging on game exit; qBittorrent syncs the torrent *set*, not resume data.
6. **Secrets never reach a server in plaintext, and by default never reach it at all.** All hub content is end-to-end encrypted. On top of that, anything classified `secret` (SSH keys, `.env` files, Wi-Fi keys, tokens, Notepad++ tabs that contain credentials) stays on local or NAS destinations unless the user opts it into a separate vault key.

Smallest useful first release: **`w2c` v0.1 = export / import / diff on Windows and Linux, to a folder (NAS or USB), encrypted with a passphrase, able to read today's schema-1 backups.** See [section 7](#7-phased-plan).

---

## 1. Where we are

| Piece | What it does | What ties it to Windows → CachyOS |
|---|---|---|
| `Export-Win2Cachy.ps1` | Inventory, catalog-driven config copy, Notepad++ / qBittorrent / WoW handlers, git risk, REPORT.md | PowerShell, robocopy, registry, `%APPDATA%` paths baked into `catalog/apps.json` |
| `linux/restore.py` | Plan/apply replay: packages, fstab lines, configs, path-rewritten qBittorrent and Notepad++ state, WoW, projects | Only reads; assumes source is Windows (`windowsHome`, drive letters, `paru`) |
| `catalog/apps.json` | ~70 apps: `match` (Windows uninstall regex), `paru` / `flatpak`, `backup` (Windows src → dest name), `restore` (dest name → Linux path), `handler`, `note`, `post`, `sensitive` | Detection is Windows-only; install targets are Arch-only; backup/restore are one-directional |
| `manifest.json` (schema 1) | Mix of inventory, results, warnings, per-handler state (`notepadpp` tabs, `qbittorrent.savePaths`, `wow.flavors`), `pathMap` | `pathMap` keyed by Windows prefixes; files stored at `apps/<id>/<dest>` with no hashes |

What's already right and worth keeping:

- **The catalog as data**, with the handful of genuinely hard apps as code (`handler`).
- **Plan by default, apply on request**, and `*.w2c-bak-<stamp>` set-aside before overwriting.
- **`pathmap.json` as a separate, user-editable file.** It becomes the per-device "roots" config below.
- **Path rewriting inside app state** (bencode `.fastresume`, qBittorrent ini/json, Notepad++ `session.xml`). This is the moat. Generic sync tools can't do it.

What has to change: the profile can't contain absolute paths, files need content hashes (for dedup, diff and sync), the catalog needs per-OS detect/install/state, and the backup is currently plaintext on the NAS, including `.ssh` and `.env` files from Notepad++ tabs.

---

## 2. OS-neutral profile format (schema 2)

### 2.1 Concepts

- **Profile**: a named, versioned description of "my setup": which apps, which state sets of each app, and the captured content of those state sets. A user can have several (desktop, laptop, "gaming only", a public "dev tools" list).
- **State set**: one named bundle of an app's state, e.g. `vlc/config`, `notepadpp/session`, `wow/_retail_/WTF`. It's the unit of capture, diff, sync policy and conflict handling.
- **Logical path**: a path relative to a **root token** rather than a drive. Resolved per device at import time.
- **Blob**: file content, stored once, addressed by hash.
- **Device**: a machine with its own root mapping, OS and (later) keypair.

### 2.2 Root tokens

| Token | Windows | Linux (native) | Linux (flatpak `<appid>`) |
|---|---|---|---|
| `{home}` | `%USERPROFILE%` | `~` | `~` |
| `{config}` | `%APPDATA%` | `~/.config` | `~/.var/app/<appid>/config` |
| `{data}` | `%LOCALAPPDATA%` | `~/.local/share` | `~/.var/app/<appid>/data` |
| `{documents}` | `[Environment]::GetFolderPath('MyDocuments')` | `xdg-user-dir DOCUMENTS` | same |
| `{fonts}` | `%LOCALAPPDATA%\Microsoft\Windows\Fonts` | `~/.local/share/fonts` | n/a |
| `{wine:<prefix>}` | n/a | `<prefix>/drive_c` | n/a |
| `{root:<name>}` | user-defined (`Z:\` for `root:nas`) | user-defined (`/mnt/nas`) | same |
| `{install:<app>}` | detected install dir (e.g. WoW from uninstall `InstallLocation`) | detected or asked (`find_wow()` today) | same |

`{root:*}` and `{install:*}` live in a **device file** (`~/.config/w2c/device.json` / `%APPDATA%\w2c\device.json`), never in the profile. That's today's `pathmap.json`, turned around: the profile says `{root:nas}/Downloads`, each device says where `nas` is mounted. Importing schema-1 backups seeds it from the old `pathMap`.

### 2.3 Profile layout

A profile is a manifest plus a blob store. On disk (folder/NAS/USB destination):

```
<profile>/
  profile.json            # manifest (encrypted as profile.json.age when --encrypt)
  blobs/ab/abcdef...      # content-addressed, one file per blob (or a restic repo instead, see 4.4)
  catalog.lock.json       # exact catalog entries this profile was made with
  REPORT.md               # human report, same idea as today
```

`profile.json`:

```json
{
  "format": "w2c-profile",
  "schema": 2,
  "id": "prf_01JB7T3...",
  "name": "Main desktop",
  "version": { "id": "v_01JB7T9...", "parents": ["v_01JB6Q..."], "created": "2026-10-25T14:31:00Z",
               "device": "dev_DESKTOP-AES", "os": "windows", "tool": "w2c 0.1.0" },
  "catalog": { "source": "github:AES256Afro/w2c-catalog", "release": "2026.10.3", "sha256": "..." },

  "apps": [
    { "id": "vlc", "install": true, "state": ["config"], "seenAs": { "windows": "VLC media player 3.0.21" } },
    { "id": "notepadpp", "install": true, "state": ["session"], "handler": "notepadpp" },
    { "id": "qbittorrent", "install": true, "state": ["config", "torrents"], "handler": "qbittorrent" },
    { "id": "battlenet", "install": true, "state": ["wow:_retail_", "wow:_forever_"], "handler": "wow" },
    { "id": "ssh", "install": false, "state": ["keys"], "class": "secret" }
  ],

  "state": {
    "vlc/config": {
      "class": "private",
      "policy": "snapshot",
      "files": [
        { "path": "{config}/vlc/vlcrc", "blob": "b3:9f2c...", "size": 18432, "mtime": "2026-10-20T09:12:00Z", "mode": "644" }
      ]
    },
    "notepadpp/session": {
      "class": "private",
      "policy": "live",
      "handler": "notepadpp",
      "tabs": [
        { "tabId": "tab_7Q2...", "title": "new 3", "untitled": true, "lang": "Markdown", "view": "mainView",
          "blob": "b3:41aa...", "sizeChars": 5120, "scan": { "secrets": 0 } },
        { "tabId": "tab_7Q3...", "title": "{root:nas}/notes/todo.md", "untitled": false, "unsavedEdits": true,
          "blob": "b3:77d1...", "base": "b3:0c9e..." }
      ],
      "files": [ { "path": "{config}/Notepad++/config.xml", "blob": "b3:..." } ]
    },
    "qbittorrent/torrents": {
      "class": "private",
      "policy": "mirror-on-exit",
      "handler": "qbittorrent",
      "torrents": [
        { "infohash": "a1b2...", "name": "debian-13.iso", "savePath": "{root:nas}/Downloads", "category": "linux",
          "tags": ["iso"], "torrentBlob": "b3:...", "resumeBlob": "b3:...", "state": "seeding" }
      ]
    },
    "ssh/keys": { "class": "secret", "policy": "snapshot", "files": [ { "path": "{home}/.ssh/id_ed25519", "blob": "b3:...", "mode": "600" } ] }
  },

  "inventory": { "blob": "b3:..." },
  "warnings": [],
  "blockers": []
}
```

Notes on the choices:

- **Handlers own their state shape.** Generic state sets are a file list. Notepad++ is a tab list, qBittorrent a torrent list. That's what lets diff and merge work per tab or per torrent instead of per byte.
- **Paths inside content are stored in logical form.** The qBittorrent handler rewrites `save_path` to `{root:nas}/Downloads` on export and to the device's real path on import, so a profile exported from Linux imports cleanly on Windows. Today's rewriting only goes Windows → Linux.
- **BLAKE3 (`b3:`) hashes** for blob IDs: fast, and keyed mode gives the HMAC-style IDs the hub needs (see [6.3](#63-encryption-of-content)). SHA-256 is fine if dependencies matter more.
- **`class`** is `public` (safe to publish: app list, package IDs), `private` (configs, sessions) or `secret` (credentials). It drives encryption and where things may be stored.
- **`policy`** is `snapshot` (only on explicit export), `mirror-on-exit` (sync when the app closes) or `live` (capture while running). Ignored outside sync.
- **Inventory** (hardware, installed list, Steam games, git risk) moves to its own blob. It's useful for REPORT.md and `diff`, noisy in the manifest.

### 2.4 Catalog schema 2

Today's entry:

```json
{ "id": "vlc", "name": "VLC", "match": "^VLC", "paru": ["vlc", "vlc-plugins-all"],
  "backup":  [{ "src": "%APPDATA%\\vlc", "dest": "config", "exclude": ["art", "ml.xspf"] }],
  "restore": [{ "dest": "config", "to": "~/.config/vlc" }] }
```

Schema 2:

```json
{
  "id": "vlc",
  "name": "VLC",
  "detect": {
    "windows": { "uninstall": "^VLC", "winget": "VideoLAN.VLC" },
    "linux":   { "pacman": "vlc", "flatpak": "org.videolan.VLC", "bin": "vlc" }
  },
  "install": {
    "winget": "VideoLAN.VLC",
    "pacman": ["vlc", "vlc-plugins-all"],
    "flatpak": "org.videolan.VLC",
    "apt": "vlc", "dnf": "vlc", "brew": "--cask vlc"
  },
  "state": [
    { "name": "config", "class": "private",
      "at": { "windows": "{config}/vlc", "linux": "{config}/vlc", "flatpak": "{config}/vlc" },
      "exclude": ["art", "ml.xspf"],
      "portable": true }
  ],
  "notes": { "linux": "...", "windows": "..." },
  "meta": { "maintainers": ["AES256Afro"], "verified": "2026-10-01" }
}
```

- `state[].at` replaces the `backup` + `restore` pair. Because both sides use the same name and logical path, the same entry works in both directions.
- `portable: false` marks state that is captured but not restored across OSes (Windows Terminal `LocalState`, PowerShell profiles: today's "Reference only" notes).
- `install` keys are package-manager names. `paru` becomes `pacman` + `aur` so AUR packages can be flagged as unreviewed (see [5.3](#53-trust-tiers)).
- `handler` stays: it names code in the client, never code in the catalog.
- `post` commands are kept but restricted (see [5.3](#53-trust-tiers)).
- `games` overrides move to a separate dataset with a `verified` date per entry, since anti-cheat status goes stale.

A converter maps every current entry mechanically: `match` → `detect.windows.uninstall`, `paru` → `install.pacman`/`aur` (looked up against the Arch repos), `backup[i].dest` joined with `restore[j].dest` → `state[name=dest]`, and `%APPDATA%`-style prefixes → tokens.

### 2.5 Verbs

One CLI, same verbs on both OSes. Plan by default, like `restore.py`.

```text
w2c export  [--to DIR | --to s3://... | --to hub:NAME] [--apps a,b] [--include-secrets] [--encrypt]
w2c import  PROFILE [--apply] [--only install,state,notepadpp,...] [--app a,b] [--target-os auto]
w2c diff    PROFILE [--against this|PROFILE2] [--json]
w2c install PROFILE [--apply]            # import --only install: the "Ninite" part
w2c catalog update | show <id> | suggest <installed-name>
w2c device  roots | set-root nas=/mnt/nas | enroll | revoke <id>
w2c sync    run | status | pause <stateset> | resolve <conflict-id>      # phase 3
```

- **`export`** detects installed apps through the catalog (`detect.<os>`), captures each enabled state set through the generic copier or a handler, writes blobs, then writes `profile.json`. On Windows it carries forward today's quiesce prompts (`Wait-Closed` for Notepad++, qBittorrent, WoW, Plex).
- **`import`** builds a plan with three sections: **install** (per-OS package plan: `winget import`-style list on Windows, `pacman`/`paru`/`flatpak` on Arch), **state** (files to write, each resolved through device roots, with set-aside of anything overwritten), **manual** (notes, sign-ins, fstab lines). `--apply` runs it.
- **`diff`** compares two profiles, or a profile against the live machine (`--against this` does an in-memory export). Output groups by app:

```text
$ w2c diff hub:main --against this
apps
  + obsidian            in profile, not installed here          (install: pacman obsidian)
  - komac               installed here, not in profile
state
  ~ vlc/config          2 files differ: vlcrc, vlc-qt-interface.ini
  ~ notepadpp/session   3 tabs only in profile, 1 tab edited on both sides (see: w2c diff --app notepadpp)
  = wow:_retail_        identical (412 files)
roots
  ! {root:nas}          not mapped on this device. Run: w2c device set-root nas=/mnt/nas
secrets
  ! ssh/keys            in profile but class=secret, needs --include-secrets and the vault passphrase
```

### 2.6 Client implementation choice

| Option | For | Against |
|---|---|---|
| **Python (recommended)** | `restore.py` already has bencode, PathMap, session rewriting; one language for both OSes; `watchdog` for file events; PyInstaller/Nuitka produce a single `w2c.exe` / `w2c` for bootstrap | Windows-specific bits (registry uninstall keys, DPAPI, process detection) need `winreg` / `pywin32` / `psutil`; startup slower than a native binary |
| Go | Single static binary, trivial cross-compile, good for a long-running agent | Rewrite everything, including what works today |
| Keep PowerShell + Python | Zero rewrite | Two implementations of every handler, and PowerShell on Linux is not something to ask of users |

Recommendation: Python for the CLI and agent. Revisit Go only if the sync agent's footprint becomes a real problem. The existing PowerShell exporter stays as-is for the current migration; schema-1 backups are readable by `w2c import` through a compatibility reader (`manifest.json` + `apps/<id>/<dest>` + `pathmap.json` → in-memory schema-2 profile).

---

## 3. Live sync of app state

### 3.1 Model

Sync is **per state set**, each one an independent versioned stream (like a tiny git branch):

- A **version** = a manifest of that state set (file list or handler-specific list), with `parents`.
- Each device remembers the **base**: the last version it synced for that stream.
- **Publish** = compare-and-swap the stream head: "set head to V2 if head is still V1". If it fails, fetch the new head, merge (three-way: base, local, remote), retry.
- **Apply** = write the remote version to disk, but only when the handler says the app is in a safe state.

Splitting by state set means a Notepad++ snapshot every few seconds never contends with a WoW logout.

Each handler implements five hooks:

| Hook | Purpose |
|---|---|
| `is_safe_to_read()` | Is state consistent right now? (app closed, or app's own snapshot complete) |
| `is_safe_to_write()` | Can we write without the app clobbering it? (almost always: app not running) |
| `capture()` → version | Read state into logical form (paths tokenized) |
| `apply(version)` | Write state, de-tokenizing paths for this device and OS |
| `merge(base, local, remote)` → version + conflicts | Domain-specific three-way merge |

Policies map onto these: `live` captures whenever `is_safe_to_read` and files changed; `mirror-on-exit` captures when the app's process exits; remote changes are queued until `is_safe_to_write`.

**Transport is pluggable.** Phase 3 can run over the same bucket used for profiles (if it supports conditional writes, see [4.4](#44-simpler-alternative-no-server)), over the hub's API, or over a folder that Syncthing replicates. The capture/apply/merge layer is the product; the transport is a commodity.

### 3.2 Notepad++ (session + unsaved tabs)

How Notepad++ stores this today (verify against the installed version before building; behavior has shifted between releases):

- `%APPDATA%\Notepad++\session.xml` lists open tabs per view (`mainView`, `subView`). Each `<File>` has `filename` (a real path, or `new 1` for untitled), `backupFilePath` when the tab has unsaved content, plus `lang`, caret and scroll position.
- `%APPDATA%\Notepad++\backup\` holds the unsaved content, one file per tab, named like `new 3@2026-10-25_143012`.
- With **Preferences > Backup > "Enable session snapshot and periodic backup"** on, Notepad++ rewrites backup files every N seconds (default 7) and updates the session snapshot. Without it, state only lands on clean exit (which is why the exporter prompts you to close it).
- Notepad++ reads `session.xml` only at startup and does not watch backup files. It *does* watch real files that are open and offers to reload them when they change on disk.

That last point decides the design: **remote changes to an untitled tab can't be pushed into a running Notepad++.**

**Capture (`live`, safe while running if snapshot mode is on):**

1. Watch `backup\` and `session.xml`. Debounce a few seconds after the last write so we don't read a half-written snapshot. Read the session, then read each referenced backup file, then re-read the session and retry if it changed in between.
2. Give each tab a stable `tabId`. Untitled names (`new 1`) collide across machines and get reused; the backup filename's timestamp suffix is stable for the life of a tab, so `tabId = hash(origin device, backup base name)` stored in a sidecar index (`%APPDATA%\w2c\npp-tabs.json`) that also maps tabId ↔ current backup file. Real-file tabs use the logical path as identity.
3. For real-file tabs with unsaved edits, store both the edited content and the on-disk content's hash as `base`, so import can tell "file changed underneath" from "only the tab changed".
4. Run the secret scanner on every tab (see [6.5](#65-secret-detection)). Tabs with findings are marked `class: secret` and excluded from remote sync unless the user allows that tab.

**Apply (only when Notepad++ is not running):**

1. Merge remote tabs into the local tab list (below).
2. Write backup files and a new `session.xml`, de-tokenizing paths for this device. On Linux with Notepad++ under Wine, that's today's `do_wine()` logic generalized: backup paths to `C:\users\<user>\AppData\Roaming\Notepad++\backup\...`, real files to `Z:\<linux path>`.
3. If Notepad++ is running when a remote change arrives, the agent shows a tray/desktop notification ("3 tabs changed on LAPTOP, close Notepad++ to receive them") and queues the change. Local edits keep being captured meanwhile; the merge on apply handles both.

**Merge (per tab, three-way against the base version):**

| Base → local / remote | Result |
|---|---|
| Changed on one side only | Take the changed side |
| Changed on both, same content | Take it |
| Changed on both, different | Keep local in place; add remote as a new tab titled `new 3 (LAPTOP 14:31)` right after it. Never a silent overwrite, never in-text conflict markers |
| Opened on one side | Add it |
| Closed on one side, unchanged on the other | Close it, keep content in local trash for 30 days |
| Closed on one side, edited on the other | Edit wins; tab stays open (deleting content you were typing is the worst outcome) |
| Real file changed on disk and tab edited | Keep the tab's edits; flag it in `w2c sync status` |

Tab order and active tab are last-writer-wins: cosmetic, and merging them produces worse results than picking one.

**Optional "notes mode" (later, opt-in):** for genuinely live editing across two running machines, the agent can materialize each synced untitled tab as a real file in `{documents}/Notepad++ Tabs/` and point the session at those files. Notepad++'s own file-change detection then reloads remote edits live. It changes how tabs behave (they're no longer "unsaved"), so it's a choice, not the default. A native Notepad++ plugin (C++, Scintilla API) could do true live sync, but that's a much larger project and only helps the Windows side.

**Linux without Wine:** the importer can target a plain folder of files (what `restore.py` does today with `~/Documents/Notepad++ Tabs`) and sync in notes mode. Kate, VS Code and others then work as the editor.

### 3.3 qBittorrent

Live-syncing resume data between two running clients is a trap: `.fastresume` holds per-piece state for *that machine's* copy of the files, and two clients seeding the same torrent from different disks produce resume data that fights.

So sync the **torrent set**, not the resume state:

- **Synced:** the `.torrent` metadata, magnet links, category, tags, logical save path, ratio/seeding limits, RSS feeds and rules, `categories.json`, and settings that are portable (connection limits, speed schedule). Tokenized paths throughout.
- **Not synced live:** `.fastresume`, piece state, statistics, `torrents.db`.
- **Policy per device:** "add new torrents paused", "add and start", or "ignore". A typical setup is one always-on box that downloads and other machines that only mirror the list.
- **Identity:** infohash. Merge is set union with tombstones. A torrent removed on device A is removed on B only if B hasn't changed its metadata since the base; otherwise it's flagged.
- **Handoff mode** (what the migration does today): a one-time transfer that *does* include resume data, rewritten for the target's save paths, so nothing re-downloads. Only runs with qBittorrent closed on both ends.
- **Mechanics:** prefer qBittorrent's WebUI API (`/api/v2/torrents/add`, `/torrents/info`) when the WebUI is enabled, because it works while the app is running. Fall back to file-level apply (today's `do_conf` / `do_data`) when it's closed. The exporter's warning about the SQLite resume store (`torrents.db`) still applies to file-level mode.

### 3.4 World of Warcraft (WTF, Interface)

- **When:** `mirror-on-exit`. WoW writes `WTF` (SavedVariables, `Config.wtf`, keybinds, macros) on logout/exit. Capture after the `Wow.exe` process exits (`Wow` process on Windows, the Wine process on Linux). Apply only when it's not running.
- **Granularity:** one stream per flavor (`_retail_`, `_forever_`, `_classic_era_`, ...), split into `WTF` and `Interface`, because they change at very different rates.
- **Interface (addons):** sync bytes, deduplicated by content hash, so a 600 MB addon folder only transfers changed files after the first push. Later, an addon manifest (from `.toc` files plus CurseForge/Wago IDs) could replace byte sync with "install these addons at these versions", but byte sync is simpler and correct.
- **WTF merge:** per file, three-way:
  - `SavedVariables/*.lua` (per account, realm or character): if both sides changed the same file, the newer `mtime` wins and the loser is kept as `<file>.conflict-<device>-<stamp>` and listed in `sync status`. Lua tables can't be merged safely in general.
  - `Config.wtf` / `config-cache.wtf`: line-based `SET key "value"` merge. Keys changed on one side apply; keys changed on both take the newer.
  - Files in `Account/*/` that WoW regenerates (`cache.md5`, `*.bak`) are excluded.
- **Cross-OS:** paths inside WTF are relative. The only per-device part is `{install:wow}`, found the way `find_wow()` does today or set with `w2c device set-root`.

### 3.5 Generic state sets

Everything else from the catalog (VS Code `User`, VLC, calibre, FFXIV config, `.gitconfig`) defaults to `snapshot`. If a user turns on sync for one, it's file-level three-way merge with conflict copies, captured on app exit when the catalog entry names a process, otherwise on a debounce. Path-bearing formats (ini, json, xml) can opt into the same Windows-path detection and tokenization that `rewrite_ini` and `rewrite_json_paths` do today.

### 3.6 Conflict handling rules (all handlers)

1. **Never lose content silently.** Every overwrite goes through a conflict copy, a tombstone with retention, or a set-aside file (as `restore.py` does with `*.w2c-bak-*`).
2. **Merge at the handler's natural unit:** tab, torrent, file, config key. Never byte-merge opaque data.
3. **Deletion is weaker than modification.** An edit on one side beats a delete on the other.
4. **Clock-free where it matters.** Versions are compared by parent chain, not wall clock. `mtime` is only a tie-breaker for "both changed" cases that can't merge.
5. **Visible.** `w2c sync status` and the tray/notification list unresolved conflicts; `w2c sync resolve <id> --keep local|remote|both`.
6. **History.** Every published version is retained for a window (e.g. 30 days or last 100 versions per stream), so "undo the last sync" is a restore, not a hope.

---

## 4. Hosted profile hub

### 4.1 What it must do

- Store a user's encrypted profiles and their version history; serve them back.
- Enroll devices and hand each one the wrapped keys it needs. The server can never unwrap them.
- Bootstrap a fresh machine: `irm https://hub.example/i | iex` (Windows) or `curl -fsSL https://hub.example/i | sh` (Linux) downloads `w2c`, signs in, picks a profile, and runs `w2c import --apply` (after showing the plan).
- For sync: atomic head updates per stream and push notification of new heads.
- Optionally: public profile pages that show only an app list (class `public`), like a shareable Ninite link.

### 4.2 Cloudflare Workers + R2 + D1: evaluation

| Component | Role | Fit |
|---|---|---|
| **Workers** | API, auth, presigned URL issuing, bootstrap scripts | Good. Requests are small; no crypto happens server-side, so CPU limits don't matter. Request bodies on Free/Pro are capped (100 MB at time of writing), so blobs go straight to R2 via presigned URLs, not through the Worker. |
| **R2** | Encrypted blobs and encrypted manifests | Very good. No egress fees (restoring a 2 GB profile costs nothing extra); S3-compatible, so restic/rclone/boto3 work and lock-in is low; presigned PUT/GET; multipart for big blobs; lifecycle rules for retention. |
| **D1** | Accounts, devices, wrapped keys, profiles, versions, stream heads, blob reference lists | Good. Small relational data, SQLite semantics, easy to export. Per-database size caps are far above what this needs. |
| **Durable Objects** (one per profile) | Serialize head updates per stream (the CAS), WebSocket push to connected agents | Good, and the reason not to fake sync with polling. Hibernatable WebSockets keep idle cost near zero. |
| **Pages / static assets** | Web UI, public profile pages, catalog mirror | Fine. |
| **Cloudflare Access** | Put the whole hub behind your identity for a personal deployment | Excellent for phase 4 if it stays personal: zero auth code. |

**Pros:** you already have the account; the free tier plausibly covers a personal deployment entirely (a profile with WoW addons is a few GB, under R2's free storage at time of writing; check current limits); zero egress; everything is S3/SQLite-shaped so moving off is a weekend, not a rewrite; global edge latency for "install my profile" anywhere.

**Cons and risks:**

- **It's a service.** Auth bugs, abuse and account recovery become your problem the moment anyone else uses it. Encrypted blobs can't be inspected, so a public hub is an anonymous encrypted file host; it needs quotas, rate limits, and a terms page.
- **Durable Objects add a concept** (actor model, placement, storage API) on top of Workers, D1 and R2.
- **Server-side GC is blind.** The server can't read manifests, so clients must report which blob IDs each version references (see `version_blobs` below). That leaks blob counts and sizes per version, not content.
- **Lock-in at the edges:** DO and the Workers runtime are Cloudflare-specific; R2 and D1 data are portable.

Verdict: **right platform for the hub, wrong first step.** Build it in phase 4.

### 4.3 Data model (D1)

```sql
CREATE TABLE users (
  id            TEXT PRIMARY KEY,          -- usr_...
  github_id     INTEGER UNIQUE,            -- or a passkey credential table
  created_at    TEXT NOT NULL,
  quota_bytes   INTEGER NOT NULL DEFAULT 10737418240
);

CREATE TABLE devices (
  id            TEXT PRIMARY KEY,          -- dev_...
  user_id       TEXT NOT NULL REFERENCES users(id),
  name          TEXT NOT NULL,
  os            TEXT NOT NULL,             -- windows | linux | macos
  pubkey        TEXT NOT NULL,             -- X25519 (encryption) + Ed25519 (signing), base64
  token_hash    TEXT NOT NULL,             -- hash of refresh token; never the token
  created_at    TEXT NOT NULL,
  last_seen_at  TEXT,
  revoked_at    TEXT
);

CREATE TABLE key_wraps (                   -- the account master key, wrapped several ways
  id            TEXT PRIMARY KEY,
  user_id       TEXT NOT NULL REFERENCES users(id),
  kind          TEXT NOT NULL,             -- passphrase | device | recovery | vault-passphrase
  device_id     TEXT REFERENCES devices(id),
  wrapped       BLOB NOT NULL,             -- opaque ciphertext (age format)
  kdf_params    TEXT,                      -- e.g. argon2id m/t/p + salt, for passphrase kinds
  created_at    TEXT NOT NULL
);

CREATE TABLE profiles (
  id            TEXT PRIMARY KEY,          -- prf_...
  user_id       TEXT NOT NULL REFERENCES users(id),
  name_enc      BLOB NOT NULL,             -- encrypted display name
  wrapped_key   BLOB NOT NULL,             -- profile key wrapped by the account master key
  visibility    TEXT NOT NULL DEFAULT 'private',   -- private | public-applist
  public_slug   TEXT UNIQUE,               -- only for public-applist
  public_doc    TEXT,                      -- signed plaintext app list, only for public-applist
  created_at    TEXT NOT NULL
);

CREATE TABLE streams (                     -- one per state set, plus one "profile" stream for the manifest
  id            TEXT PRIMARY KEY,
  profile_id    TEXT NOT NULL REFERENCES profiles(id),
  name_mac      TEXT NOT NULL,             -- keyed hash of "notepadpp/session"; server never sees the name
  head_version  TEXT,
  UNIQUE (profile_id, name_mac)
);

CREATE TABLE versions (
  id            TEXT PRIMARY KEY,          -- v_... (ULID)
  stream_id     TEXT NOT NULL REFERENCES streams(id),
  parent_id     TEXT,
  parent2_id    TEXT,                      -- merge versions
  device_id     TEXT NOT NULL REFERENCES devices(id),
  manifest_blob TEXT NOT NULL,             -- encrypted manifest in R2
  signature     BLOB NOT NULL,             -- device Ed25519 over (stream, parents, manifest_blob)
  total_bytes   INTEGER NOT NULL,
  created_at    TEXT NOT NULL
);

CREATE TABLE version_blobs (               -- for GC and quota; blob IDs are keyed hashes, not content hashes
  version_id    TEXT NOT NULL REFERENCES versions(id),
  blob_id       TEXT NOT NULL,
  PRIMARY KEY (version_id, blob_id)
);

CREATE TABLE blobs (
  user_id       TEXT NOT NULL REFERENCES users(id),
  blob_id       TEXT NOT NULL,
  size          INTEGER NOT NULL,
  created_at    TEXT NOT NULL,
  PRIMARY KEY (user_id, blob_id)
);
```

R2 keys: `u/<user_id>/b/<blob_id>` for blobs (manifests are blobs too). Retention and GC: a scheduled Worker drops versions past the retention window (never a stream head), then deletes blobs with no remaining `version_blobs` row after a grace period.

### 4.4 Simpler alternative: no server

For one person, the hub's job (store encrypted snapshots, list them, fetch them) is already done by **restic** against an S3 bucket:

```text
w2c export --to restic:s3:https://<account>.r2.cloudflarestorage.com/w2c-profiles
# internally: stage the profile, then
restic -r s3:... backup --tag profile=main --tag device=DESKTOP-AES <staging dir>
```

- **Encryption, dedup, snapshots, `restic diff`, pruning:** built in, reviewed, cross-platform single binaries.
- **"Install my profile" on a fresh machine:** a bootstrap script downloads `w2c` + `restic`, asks for the bucket credentials (a scoped R2 token, read-only for import) and the repository password, restores the latest `profile=main` snapshot into a temp dir, then `w2c import`. No server code.
- **Storage target:** R2 (zero egress), but the same works with the NAS (`restic -r /mnt/nas/w2c` or SFTP to the NAS) or any S3. A NAS-only setup never leaves the house.
- **Plainer still:** the built-in blob layout from [2.3](#23-profile-layout) with files encrypted by `age`, copied with `rclone` to any remote. Less efficient, fewer moving parts.

**What it can't do:** multi-user accounts, per-device keys and revocation (one shared repository password), web UI, public pages, and push notifications for sync. restic's locking is coarse, so concurrent writers from a sync agent need care. For sync over a bare bucket, compare-and-swap on the head object needs conditional writes (`If-Match` on PUT). R2 supports conditional operations, but verify the exact S3-API behavior before relying on it; if it's not sufficient, that's the point where the Worker + Durable Object earns its keep.

### 4.5 API sketch (hub)

All JSON over HTTPS. Auth: device access token (short-lived, from a refresh token bound to the device), sent as `Authorization: Bearer`. Every mutating request from a device also carries a signature over the body with the device's Ed25519 key, so a stolen bearer token alone can't publish versions.

```text
# accounts and devices
GET  /v1/auth/github/start                     -> redirect (or passkey: POST /v1/auth/passkey/*)
POST /v1/auth/github/callback                  -> { user_id, enrollment_token }
POST /v1/devices                               { name, os, pubkey, enrollment_token }  -> { device_id, refresh_token }
POST /v1/devices/pair/start                    -> { code: "483-221", expires }          # new device shows code
POST /v1/devices/pair/approve                  { code, wrapped_amk_for_new_device }     # existing device approves
GET  /v1/devices                               -> [{ id, name, os, last_seen, revoked }]
POST /v1/devices/{id}/revoke
POST /v1/token                                 { device_id, refresh_token, sig } -> { access_token, expires }

# keys (all opaque to the server)
GET  /v1/keys                                  -> { wraps: [{ kind, device_id?, wrapped, kdf_params? }] }
PUT  /v1/keys/{kind}                           { wrapped, kdf_params? }

# profiles
GET  /v1/profiles                              -> [{ id, name_enc, visibility, updated_at }]
POST /v1/profiles                              { name_enc, wrapped_key } -> { id }
GET  /v1/profiles/{id}                         -> { id, name_enc, wrapped_key, streams: [{ id, name_mac, head }] }
DELETE /v1/profiles/{id}

# blobs (content never passes through the Worker)
POST /v1/blobs/missing                         { ids: [...] } -> { missing: [...] }
POST /v1/blobs/upload                          { blobs: [{ id, size }] } -> { urls: { id: presigned_put } }
POST /v1/blobs/download                        { ids: [...] } -> { urls: { id: presigned_get } }

# versions and sync
GET  /v1/streams/{sid}/head                    -> { version_id, manifest_blob }
GET  /v1/streams/{sid}/versions?since=v_...    -> [{ id, parents, device_id, manifest_blob, created_at }]
POST /v1/streams/{sid}/versions                { parents, manifest_blob, blob_ids, total_bytes, sig }
                                               -> 201 { version_id }  |  409 { head }   # CAS on head
GET  /v1/profiles/{id}/events  (WebSocket)     -> { stream, head, device } pushes      # Durable Object

# public and bootstrap
POST /v1/profiles/{id}/publish                 { slug, applist_doc, sig }    # class=public data only
GET  /p/{slug}                                 -> HTML page + JSON app list
GET  /i, /install.ps1, /install.sh             -> bootstrap scripts (pinned w2c release + checksum)
GET  /v1/catalog/latest                        -> signed catalog bundle (mirrored from GitHub releases)
```

"Install my profile" on a fresh machine, end to end:

1. `irm https://hub.example/i | iex` downloads a pinned `w2c.exe` and verifies its checksum.
2. `w2c login` opens the browser for GitHub/passkey sign-in, registers the device, and shows a pairing code.
3. Approve on an existing device (or enter the account passphrase). The new device receives the wrapped master key and stores it in the OS keystore.
4. `w2c import hub:main` fetches and decrypts the manifest, shows the plan (packages, state, manual steps, unmapped roots), and applies on confirmation.

---

## 5. Community-maintained catalog

### 5.1 Repository and format

- A separate public repo (suggested `AES256Afro/w2c-catalog`), **one file per app** (`apps/vlc.json`) so pull requests don't conflict on a single 70-entry `apps.json`.
- `schema/app.schema.json` (JSON Schema for [catalog schema 2](#24-catalog-schema-2)), plus `games/*.json` for game compatibility overrides with `verified` dates.
- Seeded by converting today's `catalog/apps.json`, then filled out from winget's manifests, the Arch repos/AUR and Flathub (IDs only, never copied descriptions).

### 5.2 Process

- **CI on every PR:** schema validation; `detect` regexes compile; every package ID exists (winget-pkgs index, Arch package search and AUR RPC, Flathub API); `state.at` paths use only known tokens, no `..`, no absolute paths, nothing outside the user's home or a declared install dir; `exclude` sanity; no new `handler` names unless the client supports them.
- **CODEOWNERS** per area (games, dev tools, ...); two approvals for anything touching `post` or `class`.
- **Releases:** CI bundles all entries into `catalog.json`, signs it (minisign or Sigstore), publishes to GitHub Releases. Clients pin a release in each profile (`catalog.lock.json`) so an import months later uses the same mapping, and `w2c catalog update` moves forward explicitly.
- **Layering:** official catalog < optional extra catalogs the user adds < local overrides (`~/.config/w2c/catalog.local.json`), merged by `id`. Your own one-off entries never need a PR.
- **Feeding it:** apps that show up as "Unmapped" (today's REPORT.md section) get `w2c catalog suggest "<name>"`, which drafts an entry from what it can detect (install location, winget ID, likely config dirs) and opens a prefilled GitHub issue or PR on request. It never includes the user's real paths or file contents.

### 5.3 Trust tiers

A catalog entry tells the client what to install and which files to read and write, so it's a supply-chain surface.

| Field | Risk | Rule |
|---|---|---|
| `install` (repo packages, winget, flatpak) | Low: the package manager is the trust anchor | Allowed from any tier |
| `install.aur` | Medium: AUR packages are unreviewed build scripts | Allowed, flagged "AUR" in the plan; confirmation required |
| `state.at` / `exclude` | Medium: reads/writes files in your home | Token-only paths, CI-validated, shown in the plan |
| `class` | Medium: a malicious entry could downgrade `secret` to `private` | Client keeps its own built-in secret list (`.ssh`, `.gnupg`, `.env*`, credential stores) that catalog data can't override |
| `handler` | High: code | Names only; the code lives in the client release, reviewed like any other code |
| `post` commands | High: arbitrary shell | Only from the official tier, always shown, never auto-run; `import --apply` lists them as manual steps (as `restore.py` already does with Tailscale) |

---

## 6. Security model

### 6.1 Assets and threats

| Asset | Examples | Main threats |
|---|---|---|
| Secrets | SSH keys, `.env` files, Wi-Fi keys, API tokens, Notepad++ tabs with credentials | Server breach, stolen backup, accidental publishing, lost device |
| Private state | Configs, sessions, unsaved notes, torrent list, game settings | Server breach, hub operator curiosity, metadata leaks |
| Integrity of what gets installed | Catalog, bootstrap script, `w2c` binary | Malicious catalog PR, compromised release, MITM on bootstrap |
| Account | Device list, wrapped keys | Token theft, phishing, rogue device enrollment |

### 6.2 Keys

```text
passphrase ──Argon2id──► KEK_pass ─┐
device X25519 key (OS keystore) ───┼─ each wraps ─► AMK (account master key, 256-bit random)
recovery key (printed, 24 words) ──┘                  │
                                                      ├─ wraps ─► PK_<profile> (one per profile)
vault passphrase ──Argon2id──► VK (vault key) ────────┼─ wraps ─► secret blobs only
                                                      └─ derives ─► MAC key for stream/blob IDs
```

- **AMK** is generated on the first device and never leaves a device unwrapped. The server stores only wraps (`key_wraps`).
- **Device keys** live in the OS keystore: DPAPI / Windows Credential Manager on Windows, Secret Service (KWallet or GNOME Keyring) on Linux. A revoked device's wrap is deleted; to cut off a device that may have copied the AMK, rotate: generate a new AMK, re-wrap profile keys, re-wrap for remaining devices. Old blobs remain readable to the old key until re-encrypted, which is accepted and documented.
- **New devices** get the AMK either by the user typing the account passphrase or by approval from an existing device (pairing code; the existing device wraps the AMK to the new device's public key). Approval is the default; it means the passphrase is typed rarely.
- **Recovery:** a printed recovery key. There is no server-side recovery: lose the passphrase, the recovery key and every device, and the data is gone. That's the point, and onboarding says so plainly.
- **Primitives:** don't invent formats. Use `age` (X25519 and passphrase recipients) for key wraps and small files, XChaCha20-Poly1305 (libsodium / `cryptography`) for chunk encryption, Argon2id for passphrases, Ed25519 for signatures. In the no-server mode ([4.4](#44-simpler-alternative-no-server)), restic's own encryption replaces the chunk layer and its repository password plays the AMK's role.

### 6.3 Encryption of content

- Every blob is encrypted client-side with the profile key before upload; manifests too. The server stores ciphertext and opaque IDs only.
- **Blob IDs are keyed hashes** (`BLAKE3-keyed(MAC key, plaintext)`), not plain content hashes. Dedup still works within an account, but the server (or anyone with the bucket) can't confirm "this user has file X" by hashing a known file.
- Names are hidden too: profile names are encrypted, stream names are keyed MACs (`name_mac`).
- **What the server does see:** account and device IDs, number and sizes of blobs, version timestamps, which device published, public-applist profiles. This is documented in the UI.
- **Upload guard (defense in depth):** every encrypted blob starts with a fixed header (format magic + key ID + nonce). The Worker checks presigned uploads against the declared size, and a scheduled check samples new objects and rejects anything without the header or with low entropy. It can't prove encryption, but it catches the bug where a client uploads plaintext.

### 6.4 Secret handling

Rule: **no plaintext secret ever reaches a server.** End-to-end encryption already guarantees that for everything. Secrets get more on top:

1. **Classification.** `class: secret` comes from the client's built-in list (`.ssh`, `.gnupg`, `.env`, `.env.*`, `*.pem`, `*.key`, `id_*`, `.netrc`, `.git-credentials`, cloud CLI credential files, Wi-Fi exports, browser cookie and login stores) plus catalog entries marked `sensitive` (today's `ssh` entry), plus scanner hits ([6.5](#65-secret-detection)). The catalog can add to this list but not remove from it.
2. **Default destination policy.** `secret` state sets are exported to local and NAS destinations only (as today, but encrypted). `export --to hub:` and sync skip them, and the plan says so.
3. **Opt-in vault.** With `--include-secrets` for a hub target, secret blobs are encrypted with the **vault key**, derived from a separate vault passphrase that is typed on import and never cached on disk or in the keystore. A stolen, unlocked device then still can't pull SSH keys from the hub without that passphrase.
4. **Restore hygiene.** Permissions set on write (`600` for keys, `700` for `.ssh`, as `restore.py` does), the Windows ACL equivalent via `icacls`, and a report line listing every secret written.
5. **Fixing today's exposure.** Current exports on the NAS are plaintext, including `apps/ssh` and Notepad++ tabs that hold `.env` content. Phase 1 adds `--encrypt` to the export and a `w2c secure <backup-dir>` command that encrypts an existing schema-1 backup in place and deletes the plaintext. Deleting files on an SSD or an SMB share is not a secure wipe, so the report also tells the user to rotate any SSH keys and tokens that sat in a plaintext backup.

### 6.5 Secret detection

A scanner runs on every captured file and every Notepad++ tab before anything leaves the device:

- Patterns in the spirit of gitleaks: private key headers (`-----BEGIN ... PRIVATE KEY-----`), AWS/GCP/Azure/GitHub/Cloudflare/OpenAI/Anthropic token formats, `KEY=value` lines in `.env`-shaped text, JWTs, connection strings with passwords, high-entropy strings next to words like `secret`, `token`, `password`.
- A hit promotes the item to `secret` for remote targets. The user can mark a false positive per file or tab (`w2c sync allow <tabId>`), which is remembered locally only.
- Findings are reported by location and type, never by value.

### 6.6 Integrity and supply chain

- `w2c` releases are built in GitHub Actions, checksummed and signed (Sigstore/cosign or minisign); bootstrap scripts pin a version and verify the checksum before running anything.
- Catalog bundles are signed and pinned per profile ([5.2](#52-process)).
- Published versions are signed by the publishing device; clients verify signatures against the account's device list before applying a version, so a compromised server can't inject state.
- Hub: device tokens are short-lived and bound to a device key; refresh tokens are stored hashed; presigned URLs are scoped to one key with a short TTL; rate limits and per-user quotas; for a personal deployment, Cloudflare Access in front of everything.

---

## 7. Phased plan

### Phase 0: format spec (a few days)

- Write `schema/profile.schema.json` and `schema/app.schema.json` for schema 2.
- Converter: `catalog/apps.json` → per-app schema-2 files, checked by round-tripping every current entry.
- Compatibility reader: schema-1 backup folder → in-memory schema-2 profile.

### Phase 1: `w2c` v0.1, the smallest useful release

**Goal:** export / import / diff between your own machines, either direction, Windows and CachyOS, to a folder, encrypted. No network service.

Scope:

- `w2c export --to <dir> [--encrypt]` on Windows and Linux. Windows capture ports the current exporter's catalog copy, Notepad++, qBittorrent (handoff mode) and WoW logic. Linux capture covers the same apps at their Linux locations (native, flatpak, Notepad++ in a Wine prefix, WoW in a Lutris prefix).
- `w2c import <dir|old-backup> [--apply]`: packages (winget on Windows; pacman/paru/flatpak on Arch), state, manual steps. Reads schema-1 backups, so today's NAS export restores through it.
- `w2c diff` between profile and machine, and between two profiles.
- `device.json` roots, seeded from the old `pathmap.json`.
- Encryption with an `age` passphrase; `secret` class and the built-in secret list; scanner on Notepad++ tabs.
- Single-file builds for Windows and Linux attached to a GitHub release.

Out of scope: hub, sync agent, community PRs, distros other than Arch-based.

Done when: one profile exported from the Windows PC imports onto CachyOS with Notepad++ tabs, qBittorrent torrents and WoW UI intact, and a profile exported from CachyOS imports back onto a Windows VM with the same result. `diff` reports nothing on a fresh re-export.

### Phase 2: remote profiles without a server

- `--to restic:<repo>` (R2 bucket via S3 API, or the NAS), `w2c profiles list`, `import` from a remote snapshot.
- Bootstrap one-liners (`install.ps1` / `install.sh`) published from the GitHub repo (or a Pages site), which fetch `w2c` + `restic` and run `import` after showing the plan.
- Done when: a freshly installed machine gets to your setup with one command, a bucket token and a passphrase.

### Phase 3: sync agent v1

- `w2c sync run` as a tray app (Windows) / systemd user service (Linux).
- Notepad++ `live` capture, apply-on-close, tab-level merge; WoW `mirror-on-exit` with WTF merge; qBittorrent torrent-set sync over the WebUI API.
- Transport: the phase-2 bucket with conditional-write CAS if R2's S3 API supports what's needed; otherwise a Syncthing-replicated folder between your machines as a stopgap, or pull phase 4's Worker + Durable Object forward.
- Done when: a tab typed on the desktop shows up in Notepad++ on the laptop the next time it's opened there, and editing the same tab on both produces two tabs, not a lost edit.

### Phase 4: hosted hub

- Workers + R2 + D1 + one Durable Object per profile, per sections 4.3 and 4.5. Personal deployment behind Cloudflare Access first.
- Device enrollment with pairing codes, per-device keys, revocation; vault for opted-in secrets; WebSocket push for sync.
- Small web UI: profiles, devices, versions, restore points, conflicts.
- Migration path from phase 2: `w2c hub import restic:<repo>` re-uploads snapshots as hub versions.

### Phase 5: community

- Open `w2c-catalog` for PRs with the CI and trust tiers in section 5.
- Public app-list profiles (`/p/<slug>`), shareable like a Ninite link.
- More targets: Fedora (dnf), Ubuntu/Debian (apt), macOS (brew), and more handlers (browser profiles, OBS scenes, game launchers).
- Multi-user hub only after quotas, abuse handling and a terms page exist.

---

## 8. Open questions

1. **Notepad++ snapshot behavior by version.** Confirm how often `session.xml` is rewritten in snapshot mode on the installed version, and whether backup file names stay stable across restarts. The tab-identity scheme depends on it.
2. **R2 conditional writes over the S3 API.** If `If-Match` on PUT is reliable, phase 3 can run without a Worker. If not, phase 4's Durable Object comes earlier.
3. **qBittorrent on Linux in practice:** native Qt build vs flatpak changes the config paths; the catalog needs both.
4. **Who else uses it?** If the answer stays "just me", phases 4 and 5 may never be worth the operational cost, and restic + R2 + Cloudflare Access on a tiny Worker for bootstrap scripts is the end state.
5. **Addon manifests vs byte sync for WoW.** Byte sync is simpler; manifests are smaller and survive addon updates better. Decide after measuring real WTF/Interface churn.
6. **Wine prefix discovery.** Lutris, Bottles, Steam compatdata and plain `~/.wine` all put `drive_c` in different places. `{install:*}` detection needs a shared prefix finder, generalized from `find_wow()`.
