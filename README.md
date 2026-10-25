# Win2CachyOS

Move a Windows PC to CachyOS without losing your *setup*: apps, settings, sessions, unsaved work, game UI. It is not a bulk-file backup. It assumes your files already live somewhere that survives the wipe (cloud sync, a NAS, a second drive).

```
Windows                                   CachyOS
Export-Win2Cachy.ps1  ──►  Z:\Win2CachyOS\<PC>-<date>\  ──►  linux/restore.py
   inventory + app state      manifest.json, REPORT.md         packages, configs,
   + pre-wipe checklist       apps/, projects/, inventory/     path-rewritten app state
```

## 1. On Windows (before the wipe)

```powershell
.\Run-Export.cmd -DryRun        # sizes + blockers, copies nothing. Read REPORT.md
```

Fix what REPORT.md lists under **Do these before you wipe**. Then **close Notepad++, qBittorrent, WoW and Plex** (each writes its final state on exit) and run it for real, ideally from an Administrator prompt so BitLocker/Secure Boot can be checked:

```powershell
.\Run-Export.cmd                                  # -> Z:\Win2CachyOS
.\Run-Export.cmd -IncludeDownloads -IncludeModels # also Downloads and Ollama models (can be large)
```

| Flag | What it adds |
|---|---|
| `-Destination X:\path` | Write somewhere other than `Z:\Win2CachyOS` |
| `-IncludeDownloads` | `%USERPROFILE%\Downloads` |
| `-IncludeModels` | `~\.ollama\models` |
| `-IncludeClaudeHistory` | `~\.claude\projects` transcripts |
| `-IncludeWifiKeys` | Wi-Fi profiles with passwords (clear text) |
| `-SkipProjects` | Don't copy code projects |

What gets captured:

- **Notepad++**: the full session plus **every unsaved tab exported as a plain file** (`apps/notepadpp/unsaved-tabs/`). Real files open in tabs that live on C: are copied too.
- **qBittorrent**: all torrents, resume data, categories, RSS and settings. On restore, a save path like `Z:\Downloads` becomes `/mnt/nas/Downloads` inside the bencoded `.fastresume` files, so nothing re-downloads.
- **World of Warcraft**: `WTF`, `Interface` (addons), `Fonts`, `Screenshots` for every flavor (`_retail_`, `_forever_`, `_classic_*`).
- **Code projects**: `~\My Projects` and `~\Projects` with `.git`, minus `node_modules`/`.venv`/`target`. Repos with unpushed or uncommitted work are flagged.
- **App configs** listed in `catalog/apps.json`: SSH keys, git, VS Code (+ extension list), Steam userdata, Plex, XIVLauncher/FFXIV, VLC, calibre, Claude/Codex config, fonts…
- **Inventory**: installed apps, running apps, hardware, drives and shares, Steam games with Linux status, winget export.

> The backup contains SSH private keys and `.env` files from Notepad++ tabs. Keep it somewhere private, and delete it once you're settled.

## 2. Install CachyOS

- Turn Secure Boot off for the installer (you can re-enable it afterwards with `sbctl`).
- Install to the drive that was C:. Leave any other drives (games, data) alone unless you've decided to reformat them.
- Pick KDE Plasma if unsure. Btrfs + Limine/systemd-boot defaults are fine.

## 3. On CachyOS

```bash
sudo pacman -S --needed cifs-utils
# mount the share you exported to (example: SMB share 'backups' on host 'nas')
sudo mkdir -p /mnt/nas && sudo mount -t cifs //nas/backups /mnt/nas -o username=YOU,uid=$(id -u)
cd /mnt/nas/Win2CachyOS/<PC>-<date>

python3 linux/restore.py .            # plan only
python3 linux/restore.py . --apply    # do it
```

Steps can be run one at a time with `--only packages,mounts,configs,qbittorrent,notepadpp,wow,projects,models`. Handy because some need an app installed and launched once first:

```bash
# after installing Battle.net in Lutris and launching WoW + WoW Forever once:
python3 linux/restore.py . --apply --only wow --wow-dir ~/Games/battlenet/drive_c/Program\ Files\ \(x86\)/World\ of\ Warcraft
# real Notepad++ (in Wine) with every tab back:
python3 linux/restore.py . --apply --only notepadpp --npp-wine ~/.wine
```

`pathmap.json` in the backup controls how Windows paths map to Linux (e.g. `Z:` → `/mnt/<share name>`, built from your mapped drives). Edit it before restoring if you mount things elsewhere. Anything restore would overwrite is first renamed `*.w2c-bak-<timestamp>`.

## Gaming notes

- **WoW / WoW Forever / Overwatch**: Battle.net through Lutris. Both WoW products install from the same Battle.net into the same `World of Warcraft` folder, like on Windows.
- **Steam**: enable Steam Play for all titles. CachyOS ships `proton-cachyos`. REPORT.md has a ProtonDB link per game.
- **Known blocked by anti-cheat**: Destiny 2, GTA Online. Check [areweanticheatyet.com](https://areweanticheatyet.com) for the rest.
- **NTFS games drive**: Proton is unreliable on NTFS. Reformatting the drive to btrfs/ext4 and re-downloading is the clean path. Before that, shut Windows down fully (Shift+Shutdown) so the drive isn't left dirty.

## Extending the catalog

`catalog/apps.json` is the "Ninite list". An entry looks like:

```json
{ "id": "vlc", "name": "VLC", "match": "^VLC",
  "paru": ["vlc"], "flatpak": [],
  "backup":  [{ "src": "%APPDATA%\\vlc", "dest": "config", "exclude": ["art"] }],
  "restore": [{ "dest": "config", "to": "~/.config/vlc" }],
  "note": "shown in REPORT.md and as a manual step" }
```

Apps without an entry show up under **Unmapped** in REPORT.md.

## Roadmap (where this could go)

1. **Now**: one-shot Windows → CachyOS migration (this repo).
2. **Profiles as a product**: make the catalog community-maintained and the backup format OS-neutral, so the same profile restores onto Windows, Arch, Fedora or a new PC (`export` / `import` / `diff`).
3. **Profile hub**: a small hosted service (e.g. Cloudflare Worker + R2) holding client-side-encrypted profiles. "Install my profile" on any fresh machine = a Ninite that also brings your settings.
4. **Live sync**: a background agent that keeps chosen app state (Notepad++ session + unsaved tabs, qBittorrent, game UI) in sync between machines instead of snapshotting it once.
