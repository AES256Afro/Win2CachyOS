#!/usr/bin/env python3
"""Replay a Win2CachyOS backup onto a fresh CachyOS install.

    python3 restore.py BACKUP_DIR                 # print the plan, change nothing
    python3 restore.py BACKUP_DIR --apply         # do it
    python3 restore.py BACKUP_DIR --apply --only qbittorrent,notepadpp

Steps: packages, mounts, configs, qbittorrent, notepadpp, wow, projects, models.
Every file this overwrites is first moved aside to <name>.w2c-bak-<timestamp>.
"""
import argparse
import glob
import json
import os
import re
import shutil
import subprocess
import sys
import time
import xml.etree.ElementTree as ET
from pathlib import Path

HOME = Path.home()
STAMP = time.strftime("%Y%m%d-%H%M%S")
STEPS = ["packages", "mounts", "configs", "qbittorrent", "notepadpp", "wow", "projects", "models"]

APPLY = False
manual = []  # things a human has to do, printed at the end


def say(msg, color="0"):
    print(f"\033[{color}m{msg}\033[0m")


def head(msg):
    say(f"\n== {msg} ==", "1;36")


def act(desc, fn=None, *a, **kw):
    """Print an action. Run it only with --apply."""
    say(("  + " if APPLY else "  - ") + desc, "32" if APPLY else "0")
    if APPLY and fn:
        try:
            fn(*a, **kw)
        except Exception as e:  # keep going; report at the end
            say(f"    FAILED: {e}", "31")
            manual.append(f"Failed: {desc}: {e}")


def run(cmd, check=True):
    subprocess.run(cmd, shell=isinstance(cmd, str), check=check)


def set_aside(target: Path):
    if target.exists() or target.is_symlink():
        target.rename(target.with_name(f"{target.name}.w2c-bak-{STAMP}"))


def copy_tree(src: Path, dst: Path):
    """Merge src into dst. Files that would be overwritten are moved aside first."""
    if src.is_file():
        dst.parent.mkdir(parents=True, exist_ok=True)
        set_aside(dst)
        shutil.copy2(src, dst)
        return
    for root, _dirs, files in os.walk(src):
        rel = Path(root).relative_to(src)
        (dst / rel).mkdir(parents=True, exist_ok=True)
        for f in files:
            t = dst / rel / f
            set_aside(t)
            shutil.copy2(Path(root) / f, t)


def has(cmd):
    return shutil.which(cmd) is not None


# ---------------------------------------------------------------- path mapping

class PathMap:
    """Windows path prefix -> Linux path, longest prefix wins, case-insensitive."""

    def __init__(self, mapping: dict):
        self.rules = sorted(
            ((k.rstrip("\\/").lower(), v) for k, v in mapping.items()),
            key=lambda kv: len(kv[0]), reverse=True)

    def to_linux(self, win: str):
        norm = win.replace("/", "\\")
        low = norm.lower()
        for prefix, target in self.rules:
            if low == prefix or low.startswith(prefix + "\\"):
                rest = norm[len(prefix):].lstrip("\\").replace("\\", "/")
                base = str(HOME) if target == "~" else os.path.expanduser(target)
                return f"{base}/{rest}" if rest else base
        return None

    @staticmethod
    def looks_windows(s: str):
        return bool(re.match(r"^[A-Za-z]:[\\/]", s)) or s.startswith("\\\\")


# ---------------------------------------------------------------- bencode (qBittorrent .fastresume)

def bdecode(data: bytes, i=0):
    c = data[i:i + 1]
    if c == b"i":
        j = data.index(b"e", i)
        return int(data[i + 1:j]), j + 1
    if c == b"l":
        i += 1
        out = []
        while data[i:i + 1] != b"e":
            v, i = bdecode(data, i)
            out.append(v)
        return out, i + 1
    if c == b"d":
        i += 1
        out = {}
        while data[i:i + 1] != b"e":
            k, i = bdecode(data, i)
            out[k], i = bdecode(data, i)
        return out, i + 1
    j = data.index(b":", i)
    n = int(data[i:j])
    return data[j + 1:j + 1 + n], j + 1 + n


def bencode(v) -> bytes:
    if isinstance(v, int):
        return b"i%de" % v
    if isinstance(v, bytes):
        return b"%d:%s" % (len(v), v)
    if isinstance(v, str):
        return bencode(v.encode())
    if isinstance(v, list):
        return b"l" + b"".join(bencode(x) for x in v) + b"e"
    if isinstance(v, dict):
        return b"d" + b"".join(bencode(k) + bencode(v[k]) for k in sorted(v)) + b"e"
    raise TypeError(type(v))


# ---------------------------------------------------------------- steps

def step_packages(b, man, cat):
    head("Packages")
    by_id = {a["id"]: a for a in cat["apps"]}
    paru, flat, post = ["cifs-utils", "rsync"], [], []
    for app in man["apps"]:
        c = by_id.get(app["id"], {})
        paru += c.get("paru", [])
        flat += c.get("flatpak", [])
        post += c.get("post", [])
    paru = list(dict.fromkeys(paru))
    flat = list(dict.fromkeys(flat))
    helper = next((h for h in ("paru", "yay") if has(h)), None)
    if helper:
        act(f"{helper} -S --needed {' '.join(paru)}", run, [helper, "-S", "--needed"] + paru)
    else:
        say("  ! No AUR helper found. Install paru first: sudo pacman -S paru", "33")
        manual.append("Install paru, then re-run --only packages")
    if flat:
        act(f"flatpak install flathub {' '.join(flat)}", run, ["flatpak", "install", "-y", "flathub"] + flat)
    ext = b / "inventory" / "vscode-extensions.txt"
    if ext.exists():
        names = [l.strip().lstrip("\ufeff") for l in ext.read_text(encoding="utf-8-sig").splitlines() if l.strip()]
        if names:
            def install_ext():
                for n in names:
                    run(["code", "--install-extension", n], check=False)
            act(f"code --install-extension x{len(names)}", install_ext)
    for p in post:
        manual.append(p)


def step_mounts(b, man, cat):
    head("Network shares and drives")
    drives = json.loads((b / "inventory" / "drives.json").read_text(encoding="utf-8-sig"))
    pm = man["pathMap"]
    seen = set()
    lines = []
    for s in drives.get("Shares") or []:
        unc, letter = s["RemotePath"], s["LocalPath"]
        if unc in seen:
            continue
        seen.add(unc)
        mnt = pm.get(letter, "/mnt/" + unc.rstrip("\\").split("\\")[-1].lower())
        host = unc.lstrip("\\").split("\\")[0]
        share = "/".join(unc.lstrip("\\").split("\\")[1:])
        cred = f"/etc/samba/credentials-{Path(mnt).name}"
        lines.append(f"//{host}/{share}  {mnt}  cifs  credentials={cred},uid={os.getuid()},gid={os.getgid()},"
                     f"iocharset=utf8,_netdev,nofail,x-systemd.automount  0 0")
        manual.append(f"sudo mkdir -p {mnt} && sudo install -m600 /dev/null {cred}, then put 'username=...' and 'password=...' in it")
        if not re.match(r"^\d+\.\d+\.\d+\.\d+$", host):
            manual.append(f"'{host}' is a Windows (NetBIOS) name. If it doesn't resolve, use its IP in /etc/fstab.")
    for v in drives.get("Volumes") or []:
        letter = f"{v['DriveLetter']}:"
        if letter == "C:" or v.get("FileSystem") != "NTFS":
            continue
        mnt = pm.get(letter, f"/mnt/{letter[0].lower()}")
        lines.append(f"UUID=<run: lsblk -f>  {mnt}  ntfs3  uid={os.getuid()},gid={os.getgid()},nofail  0 0   # {v.get('FileSystemLabel')}")
    say("  Add to /etc/fstab (not done automatically):")
    for l in lines:
        say("    " + l, "2")
    manual.append("Add the fstab lines above, then: sudo systemctl daemon-reload && sudo mount -a")


def step_configs(b, man, cat):
    head("App configs")
    ids = {a["id"] for a in man["apps"]}
    entries = [a for a in cat["apps"] if a["id"] in ids] + cat.get("always", [])
    for app in entries:
        for r in app.get("restore", []):
            src = b / "apps" / app["id"] / r["dest"]
            if not src.exists():
                continue
            dst = Path(os.path.expanduser(r["to"]))
            act(f"{app['name']}: {src.relative_to(b)} -> {dst}", copy_tree, src, dst)
            if r.get("mode") == "600":
                def lock(d=dst):
                    d.chmod(0o700)
                    for f in d.iterdir():
                        f.chmod(0o644 if f.suffix == ".pub" else 0o600)
                act(f"chmod ssh keys in {dst}", lock)
        if app.get("note") and app["id"] in ids:
            manual.append(f"{app['name']}: {app['note']}")
    if (b / "apps" / "fonts-user" / "fonts").exists():
        act("fc-cache -f", run, ["fc-cache", "-f"])


def rewrite_ini(text: str, pm: PathMap):
    out = []
    for line in text.splitlines():
        if "=" in line and not line.startswith(("[", ";", "#")):
            k, v = line.split("=", 1)
            if k == "FileLogger\\Path":  # points into Windows AppData; let qBittorrent use its Linux default
                continue
            raw = v.replace("\\\\", "\\")
            if PathMap.looks_windows(raw):
                mapped = pm.to_linux(raw)
                if mapped:
                    line = f"{k}={mapped}"
                else:
                    manual.append(f"qBittorrent setting {k} still points at {raw}, so fix it in the app")
        out.append(line)
    return "\n".join(out) + "\n"


def rewrite_json_paths(obj, pm: PathMap):
    if isinstance(obj, dict):
        return {k: rewrite_json_paths(v, pm) for k, v in obj.items()}
    if isinstance(obj, list):
        return [rewrite_json_paths(v, pm) for v in obj]
    if isinstance(obj, str) and PathMap.looks_windows(obj):
        return pm.to_linux(obj) or obj
    return obj


def step_qbittorrent(b, man, pm: PathMap):
    head("qBittorrent")
    src = b / "apps" / "qbittorrent"
    if not src.exists():
        say("  not in backup")
        return
    if has("pgrep") and subprocess.run(["pgrep", "-x", "qbittorrent"], capture_output=True).returncode == 0:
        say("  ! qBittorrent is running. Quit it first or it will overwrite the restore.", "33")
        if APPLY:
            sys.exit(1)
    conf_dir = HOME / ".config" / "qBittorrent"
    data_dir = HOME / ".local" / "share" / "qBittorrent"

    def do_conf():
        conf_dir.mkdir(parents=True, exist_ok=True)
        for f in (src / "roaming").rglob("*"):
            if f.is_dir():
                continue
            rel = f.relative_to(src / "roaming")
            name = rel.with_suffix(".conf") if rel.suffix == ".ini" else rel
            t = conf_dir / name
            t.parent.mkdir(parents=True, exist_ok=True)
            set_aside(t)
            if f.suffix == ".ini":
                t.write_text(rewrite_ini(f.read_text(encoding="utf-8-sig"), pm), encoding="utf-8")
            elif f.suffix == ".json":
                t.write_text(json.dumps(rewrite_json_paths(json.loads(f.read_text(encoding="utf-8-sig")), pm), indent=4))
            else:
                shutil.copy2(f, t)

    def do_data():
        copy_tree(src / "local", data_dir)
        fixed, unmapped = 0, set()
        for fr in (data_dir / "BT_backup").glob("*.fastresume"):
            d, _ = bdecode(fr.read_bytes())
            changed = False
            for k, v in list(d.items()):
                if isinstance(v, bytes):
                    s = v.decode("utf-8", "replace")
                    if PathMap.looks_windows(s):
                        m = pm.to_linux(s)
                        if m:
                            d[k] = m.encode()
                            changed = True
                        else:
                            unmapped.add(s)
            if changed:
                fr.write_bytes(bencode(d))
                fixed += 1
        for j in (data_dir / "rss").rglob("*.json") if (data_dir / "rss").exists() else []:
            j.write_text(json.dumps(rewrite_json_paths(json.loads(j.read_text(encoding="utf-8-sig")), pm), indent=4))
        say(f"    rewrote save paths in {fixed} torrents")
        for u in unmapped:
            manual.append(f"qBittorrent: no pathmap entry for {u}. Add it to pathmap.json and re-run --only qbittorrent")

    for sp in man["qbittorrent"].get("savePaths", []):
        say(f"  {sp['path']}  ->  {pm.to_linux(sp['path']) or 'UNMAPPED'}  ({sp['torrents']} torrents)")
    act(f"settings -> {conf_dir}/qBittorrent.conf (paths rewritten)", do_conf)
    act(f"torrents + resume data -> {data_dir}", do_data)
    manual.append("qBittorrent: make sure the save-path mounts exist BEFORE first launch, then Force Recheck if anything shows 'Missing files'")


def step_notepadpp(b, man, pm: PathMap, wine_prefix=None):
    head("Notepad++")
    src = b / "apps" / "notepadpp"
    if not src.exists():
        say("  not in backup")
        return
    dest = HOME / "Documents" / "Notepad++ Tabs"
    tabs = man.get("notepadpp") or []
    unsaved = [t for t in tabs if t.get("unsavedChanges")]
    say(f"  {len(tabs)} tabs, {len(unsaved)} unsaved")
    for sub in ("unsaved-tabs", "open-files"):
        if (src / sub).exists():
            act(f"{sub} -> {dest / sub}", copy_tree, src / sub, dest / sub)
    if (src / "tabs-index.json").exists():
        act(f"tabs-index.json -> {dest}", copy_tree, src / "tabs-index.json", dest / "tabs-index.json")

    if not wine_prefix:
        manual.append(f"Notepad++: unsaved tabs are plain files in {dest}/unsaved-tabs. For the real Notepad++ with every tab back, "
                      "install it in Wine and re-run with --only notepadpp --npp-wine ~/.wine")
        return

    prefix = Path(os.path.expanduser(wine_prefix))
    user = os.environ.get("USER", "user")
    target = prefix / "drive_c" / "users" / user / "AppData" / "Roaming" / "Notepad++"
    win_target = f"C:\\users\\{user}\\AppData\\Roaming\\Notepad++"
    old_root = man["windowsHome"] + "\\AppData\\Roaming\\Notepad++"

    def do_wine():
        copy_tree(src / "appdata", target)
        sess = target / "session.xml"
        tree = ET.parse(sess)
        for f in tree.getroot().iter("File"):
            bp = f.get("backupFilePath", "")
            if bp.lower().startswith(old_root.lower()):
                f.set("backupFilePath", win_target + bp[len(old_root):])
            fn = f.get("filename", "")
            if PathMap.looks_windows(fn):
                if fn.upper().startswith("C:\\"):
                    lin = str(dest / "open-files" / "C" / fn[3:].replace("\\", "/"))
                else:
                    lin = pm.to_linux(fn)
                if lin:
                    f.set("filename", "Z:" + lin.replace("/", "\\"))  # Wine maps Z: to /
        tree.write(sess, encoding="UTF-8", xml_declaration=True)

    act(f"Notepad++ session -> {target} (paths rewritten for Wine)", do_wine)


def find_wow():
    pats = [
        "~/Games/*/drive_c/Program Files (x86)/World of Warcraft",
        "~/Games/*/*/drive_c/Program Files (x86)/World of Warcraft",
        "~/.local/share/Steam/steamapps/compatdata/*/pfx/drive_c/Program Files (x86)/World of Warcraft",
        "~/.wine/drive_c/Program Files (x86)/World of Warcraft",
    ]
    for p in pats:
        hits = glob.glob(os.path.expanduser(p))
        if hits:
            return Path(hits[0])
    return None


def step_wow(b, man, wow_dir=None):
    head("World of Warcraft")
    src = b / "apps" / "wow"
    if not src.exists():
        say("  not in backup")
        return
    target = Path(os.path.expanduser(wow_dir)) if wow_dir else find_wow()
    if not target or not target.exists():
        say("  WoW install not found yet.")
        manual.append("WoW: install Battle.net via Lutris, install WoW + WoW Forever, launch each once, quit, then: "
                      "restore.py BACKUP --apply --only wow --wow-dir '<...>/World of Warcraft'")
        return
    say(f"  target: {target}")
    for flavor in sorted(p for p in src.iterdir() if p.is_dir()):
        if not (target / flavor.name).exists():
            say(f"  ! {flavor.name} isn't installed yet. Install it in Battle.net, then re-run --only wow", "33")
            continue
        for sub in flavor.iterdir():
            act(f"{flavor.name}/{sub.name}", copy_tree, sub, target / flavor.name / sub.name)


def step_projects(b, man, projects_to):
    head("Code projects")
    src = b / "projects"
    if not src.exists():
        say("  not in backup")
        return
    base = Path(os.path.expanduser(projects_to))
    for root in sorted(p for p in src.iterdir() if p.is_dir()):
        dst = base if root.name == "My Projects" else base / f"_from-{root.name.replace(' ', '-')}"

        def do(r=root, d=dst):
            d.mkdir(parents=True, exist_ok=True)
            if has("rsync"):
                run(["rsync", "-a", f"{r}/", f"{d}/"])
            else:
                shutil.copytree(r, d, dirs_exist_ok=True)
            # Files copied off NTFS/SMB come back +x; stop git reporting every file as modified.
            for g in d.glob("*/.git"):
                run(["git", "-C", str(g.parent), "config", "core.fileMode", "false"], check=False)

        act(f"{root.name} -> {dst}", do)
    risky = [g for g in man.get("gitRisk", []) if g.get("unpushed") or g.get("dirty")]
    if risky:
        manual.append(f"{len(risky)} repos had uncommitted/unpushed work on Windows. It's preserved in the copies. Review with: git status")


def step_models(b, man):
    head("Local AI models")
    m = b / "data" / "ollama-models"
    if not m.exists():
        say("  Ollama models not in backup (re-pull with 'ollama pull <model>')")
        return
    manual.append(f"Ollama: 'systemctl cat ollama' shows where the service keeps models (OLLAMA_MODELS / HOME). "
                  f"Stop the service, then: sudo rsync -a '{m}/' <that dir>/models/ && sudo chown -R ollama:ollama <that dir>")
    say("  see manual steps")


# ---------------------------------------------------------------- main

def main():
    global APPLY
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("backup", type=Path)
    ap.add_argument("--apply", action="store_true", help="actually make changes (default: show plan)")
    ap.add_argument("--only", help="comma list of steps: " + ",".join(STEPS))
    ap.add_argument("--wow-dir", help="Linux path to 'World of Warcraft' folder inside the Wine prefix")
    ap.add_argument("--npp-wine", metavar="PREFIX", help="also restore full Notepad++ session into this Wine prefix")
    ap.add_argument("--projects-to", default="~/Projects")
    a = ap.parse_args()
    APPLY = a.apply

    b = a.backup.expanduser().resolve()
    man = json.loads((b / "manifest.json").read_text(encoding="utf-8-sig"))
    if man.get("dryRun"):
        say("This backup came from a -DryRun export, so it has an inventory but no files. Run the export for real first.", "31")
        if APPLY:
            sys.exit(1)
    cat = json.loads((b / "catalog.json").read_text(encoding="utf-8-sig"))
    pm_file = b / "pathmap.json"
    pm = PathMap(json.loads(pm_file.read_text(encoding="utf-8-sig")) if pm_file.exists() else man["pathMap"])

    steps = a.only.split(",") if a.only else STEPS
    say(f"Win2CachyOS restore from {b}", "1")
    say("APPLYING CHANGES" if APPLY else "PLAN ONLY. Re-run with --apply to do it.", "1;33" if APPLY else "1")

    if "packages" in steps:    step_packages(b, man, cat)
    if "mounts" in steps:      step_mounts(b, man, cat)
    if "configs" in steps:     step_configs(b, man, cat)
    if "qbittorrent" in steps: step_qbittorrent(b, man, pm)
    if "notepadpp" in steps:   step_notepadpp(b, man, pm, a.npp_wine)
    if "wow" in steps:         step_wow(b, man, a.wow_dir)
    if "projects" in steps:    step_projects(b, man, a.projects_to)
    if "models" in steps:      step_models(b, man)

    head("Manual steps")
    for m in dict.fromkeys(manual):
        say(f"  [ ] {m}")


if __name__ == "__main__":
    main()
