<#
.SYNOPSIS
  Captures this Windows install's "profile" (apps, settings, app state, unsaved
  work) into a folder that restore.py can replay on CachyOS.

.DESCRIPTION
  Bulk personal data (OneDrive, NAS shares, the games drive) is NOT copied unless
  asked. What is captured:
    - Inventory: installed apps, running apps, hardware, drives, Steam games, git repo risk
    - App state per catalog\apps.json (configs, sessions, resume data)
    - Notepad++ session incl. every unsaved tab, exported as plain files too
    - qBittorrent torrents + resume data + settings
    - WoW WTF/Interface/Fonts/Screenshots for every flavor (retail, forever, classic...)
    - Code projects (with .git, minus node_modules & friends)
  Writes REPORT.md: a go/no-go checklist for the wipe.

.EXAMPLE
  .\Export-Win2Cachy.ps1 -DryRun                  # see what would be copied, sizes, blockers
  .\Export-Win2Cachy.ps1                          # real run to Z:\Win2CachyOS
  .\Export-Win2Cachy.ps1 -Destination X:\backup -IncludeModels -IncludeDownloads
#>
[CmdletBinding()]
param(
    [string]$Destination = 'Z:\Win2CachyOS',
    [switch]$DryRun,
    [switch]$IncludeModels,        # ~/.ollama/models (large)
    [switch]$IncludeDownloads,     # %USERPROFILE%\Downloads (large)
    [switch]$IncludeClaudeHistory, # ~/.claude/projects transcripts
    [switch]$IncludeWifiKeys,      # Wi-Fi passwords in clear text
    [switch]$SkipProjects,
    [string[]]$ProjectRoots = @("$env:USERPROFILE\My Projects", "$env:USERPROFILE\Projects"),
    [switch]$NoWait                # don't pause to let you close apps
)

# Continue, not Stop: a backup tool should log a failed item and keep going.
# (Stop also turns any native stderr line from git/winget into a terminating error in PS 5.1.)
$ErrorActionPreference = 'Continue'

$Root     = $PSScriptRoot
$Catalog  = Get-Content -Raw -LiteralPath (Join-Path $Root 'catalog\apps.json') | ConvertFrom-Json
$Stamp    = Get-Date -Format 'yyyyMMdd-HHmm'
$Out      = Join-Path $Destination "$env:COMPUTERNAME-$Stamp"
$Docs     = [Environment]::GetFolderPath('MyDocuments')
$Results  = New-Object System.Collections.ArrayList   # one row per copy job
$Warnings = New-Object System.Collections.ArrayList
$Blockers = New-Object System.Collections.ArrayList

$RegenDirs = @('node_modules', '.venv', 'venv', '__pycache__', '.next', '.turbo', '.parcel-cache', '.pytest_cache', '.mypy_cache', 'target')

function Say([string]$msg, [string]$color = 'Gray') { Write-Host $msg -ForegroundColor $color }
function Warn([string]$msg)    { [void]$Warnings.Add($msg); Say "  ! $msg" 'Yellow' }
function Blocker([string]$msg) { [void]$Blockers.Add($msg); Say "  X $msg" 'Red' }

function Expand-WinPath([string]$p) {
    [Environment]::ExpandEnvironmentVariables($p.Replace('%PERSONAL%', $Docs))
}

function Save-Json($obj, [string]$rel) {
    $path = Join-Path $Out $rel
    New-Item -ItemType Directory -Force -Path (Split-Path $path) | Out-Null
    $obj | ConvertTo-Json -Depth 8 | Out-File -Encoding utf8 -LiteralPath $path
}

# Robocopy wrapper. Returns bytes copied (or that would be copied in -DryRun).
function Invoke-Copy {
    param(
        [Parameter(Mandatory)][string]$Src,
        [Parameter(Mandatory)][string]$Dst,
        [string[]]$ExcludeDirs = @(),
        [string]$Label = $Src
    )
    if (-not (Test-Path -LiteralPath $Src)) { return 0 }
    $isFile = Test-Path -LiteralPath $Src -PathType Leaf
    if ($isFile) { $rc = @((Split-Path $Src), $Dst, (Split-Path -Leaf $Src)) }
    else         { $rc = @($Src, $Dst, '/E') }
    $rc += '/COPY:DAT', '/DCOPY:T', '/R:1', '/W:1', '/XJ', '/MT:16', '/BYTES', '/NP', '/NFL', '/NDL', '/NJH'
    if ($ExcludeDirs.Count) { $rc += '/XD'; $rc += $ExcludeDirs }
    if ($DryRun) { $rc += '/L' }
    $log = & robocopy @rc
    $code = $LASTEXITCODE
    $bytes = [int64]0
    $line = $log | Where-Object { $_ -match '^\s*Bytes\s*:' } | Select-Object -First 1
    if ($line -match 'Bytes\s*:\s*(\d+)\s+(\d+)') { $bytes = [int64]$Matches[2] }
    $ok = $code -lt 8
    [void]$Results.Add([pscustomobject]@{ Label = $Label; Src = $Src; Dst = $Dst.Replace($Out, '<backup>'); Bytes = $bytes; Ok = $ok })
    if (-not $ok) { Warn "robocopy failed ($code): $Src" }
    return $bytes
}

function Test-Running([string]$name) { [bool](Get-Process -Name $name -ErrorAction SilentlyContinue) }

# Some apps only flush their state on exit. Ask the user to close them cleanly.
function Wait-Closed([string]$proc, [string]$display, [string]$why) {
    if (-not (Test-Running $proc)) { return }
    if ($DryRun -or $NoWait) { Warn "$display is running. $why Close it before the real run."; return }
    Say "`n$display is running. $why" 'Yellow'
    Say "Close it normally (File > Exit / tray > Quit), then press Enter. Type 'skip' to continue anyway." 'Yellow'
    while (Test-Running $proc) {
        $r = Read-Host
        if ($r -eq 'skip') { Warn "$display was still running during export, so its state may be stale."; return }
    }
}

function Format-Size([int64]$b) {
    if ($b -ge 1GB) { '{0:N1} GB' -f ($b / 1GB) } elseif ($b -ge 1MB) { '{0:N1} MB' -f ($b / 1MB) } elseif ($b -ge 1KB) { '{0:N0} KB' -f ($b / 1KB) } else { "$b B" }
}

# ---------------------------------------------------------------- preflight
if (-not (Test-Path -LiteralPath $Destination)) {
    try { New-Item -ItemType Directory -Force -Path $Destination | Out-Null }
    catch { throw "Destination '$Destination' is not reachable. Is the share mounted?" }
}
New-Item -ItemType Directory -Force -Path $Out | Out-Null
$mode = 'REAL RUN'
if ($DryRun) { $mode = 'DRY RUN (nothing is copied)' }
Say "Win2CachyOS export: $mode" 'Cyan'
Say "Output: $Out`n" 'Cyan'

Wait-Closed 'notepad++'          'Notepad++'         'It writes session.xml and the final unsaved-tab snapshots on exit.'
Wait-Closed 'qbittorrent'        'qBittorrent'       'It writes resume data on exit.'
Wait-Closed 'Wow'                'World of Warcraft' 'It saves WTF (addon settings, keybinds) on logout.'
Wait-Closed 'Plex Media Server'  'Plex Media Server' 'Its database must not be copied while open.'

# ---------------------------------------------------------------- inventory
Say '[1/7] Inventory' 'Cyan'
$uninstallKeys = 'HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*',
                 'HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*',
                 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*'
$installed = Get-ItemProperty $uninstallKeys -ErrorAction SilentlyContinue |
    Where-Object { $_.PSObject.Properties['DisplayName'] -and $_.DisplayName -and -not ($_.PSObject.Properties['SystemComponent'] -and $_.SystemComponent) } |
    ForEach-Object {
        $p = $_.PSObject.Properties
        [pscustomobject]@{
            Name      = $_.DisplayName
            Version   = $(if ($p['DisplayVersion']) { $_.DisplayVersion })
            Publisher = $(if ($p['Publisher']) { $_.Publisher })
            Location  = $(if ($p['InstallLocation']) { $_.InstallLocation })
        }
    } | Sort-Object Name -Unique
Save-Json $installed 'inventory\installed.json'

$running = Get-Process | Where-Object { $_.MainWindowTitle } |
    Select-Object ProcessName, MainWindowTitle, @{ n = 'Path'; e = { $_.Path } } | Sort-Object ProcessName -Unique
Save-Json $running 'inventory\running.json'

$secureBoot = $null; try { $secureBoot = Confirm-SecureBootUEFI } catch { }
$bitlocker = @(); try { $bitlocker = @(Get-BitLockerVolume -ErrorAction Stop 2>$null | Select-Object MountPoint, ProtectionStatus, VolumeStatus) } catch { }
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) { Warn 'Not running as Administrator, so BitLocker and Secure Boot status could not be read. Check V: in Settings > Privacy & security > Device encryption.' }
$hardware = [pscustomobject]@{
    CPU        = (Get-CimInstance Win32_Processor).Name.Trim()
    GPU        = @(Get-CimInstance Win32_VideoController | ForEach-Object Name)
    RAMGB      = [math]::Round((Get-CimInstance Win32_ComputerSystem).TotalPhysicalMemory / 1GB)
    Board      = (Get-CimInstance Win32_BaseBoard | ForEach-Object { "$($_.Manufacturer) $($_.Product)" })
    Disks      = @(Get-Disk | Select-Object Number, FriendlyName, @{ n = 'SizeGB'; e = { [math]::Round($_.Size / 1GB) } }, PartitionStyle)
    SecureBoot = $secureBoot
    BitLocker  = $bitlocker
}
Save-Json $hardware 'inventory\hardware.json'

$volumes = @(Get-Volume | Where-Object DriveLetter | Select-Object DriveLetter, FileSystemLabel, FileSystem, @{ n = 'SizeGB'; e = { [math]::Round($_.Size / 1GB) } })
$shares  = @(Get-SmbMapping -ErrorAction SilentlyContinue | Select-Object LocalPath, RemotePath)
Save-Json ([pscustomobject]@{ Volumes = $volumes; Shares = $shares }) 'inventory\drives.json'

# Windows path prefix -> Linux path. Edit pathmap.json before running restore.py if you mount things elsewhere.
$pathMap = [ordered]@{}
$pathMap[$env:USERPROFILE] = '~'
foreach ($s in $shares) {
    $leaf = ($s.RemotePath.TrimEnd('\') -split '\\')[-1]
    $pathMap[$s.LocalPath] = "/mnt/$($leaf.ToLower())"
}
foreach ($v in $volumes) {
    $l = "$($v.DriveLetter):"
    if ($l -eq 'C:' -or $pathMap.Contains($l)) { continue }
    $slug = ($v.FileSystemLabel -replace '[^A-Za-z0-9]+', '-').Trim('-').ToLower()
    if (-not $slug) { $slug = $v.DriveLetter.ToString().ToLower() }
    $pathMap[$l] = "/mnt/$slug"
}

try {
    $wg = Join-Path $Out 'inventory\winget.json'
    & winget export -o $wg --include-versions --disable-interactivity *> $null
    if (-not (Test-Path $wg)) { Warn 'winget export produced no file. Inventory is still in installed.json.' }
} catch { Warn "winget export failed: $_" }

if (Get-Command code -ErrorAction SilentlyContinue) {
    & code --list-extensions 2>$null | Out-File -Encoding utf8 (Join-Path $Out 'inventory\vscode-extensions.txt')
}

$wifiNames = @(netsh wlan show profiles 2>$null | Select-String 'All User Profile\s*:\s*(.+)$' | ForEach-Object { $_.Matches[0].Groups[1].Value.Trim() })
Save-Json $wifiNames 'inventory\wifi-networks.json'
if ($IncludeWifiKeys -and -not $DryRun) {
    $wdir = Join-Path $Out 'secrets\wifi'; New-Item -ItemType Directory -Force $wdir | Out-Null
    netsh wlan export profile folder="$wdir" key=clear | Out-Null
}

# ---------------------------------------------------------------- catalog apps
Say '[2/7] App settings (catalog)' 'Cyan'
$matched = @(); $mappedNames = @{}
foreach ($app in $Catalog.apps) {
    $hits = @($installed | Where-Object { $_.Name -match $app.match })
    if (-not $hits.Count) { continue }
    $hits | ForEach-Object { $mappedNames[$_.Name] = $true }
    $matched += [pscustomobject]@{ id = $app.id; name = $app.name; windows = @($hits | ForEach-Object { "$($_.Name) $($_.Version)".Trim() }) }
}
$unmapped = @($installed | Where-Object { -not $mappedNames.ContainsKey($_.Name) -and $_.Name -notmatch 'Redistributable|Runtime|SDK|Driver|Update|Microsoft Visual C|Edge(WebView| Update)|Compatibility|Add-in|vs_|Launcher$|Install Manager|Chipset|Realtek|Windows Software' })

$jobs = @()
foreach ($app in $Catalog.apps) { if (($matched | ForEach-Object id) -contains $app.id) { $jobs += $app } }
$jobs += $Catalog.always
foreach ($app in $jobs) {
    if (-not $app.PSObject.Properties['backup']) { continue }
    foreach ($b in $app.backup) {
        $dst = Join-Path $Out "apps\$($app.id)"
        if ($b.PSObject.Properties['reg']) {
            if (-not $DryRun) {
                New-Item -ItemType Directory -Force $dst | Out-Null
                & reg export $b.reg (Join-Path $dst $b.dest) /y *> $null
            }
            continue
        }
        $src = Expand-WinPath $b.src
        if (-not (Test-Path -LiteralPath $src)) { continue }
        $ex = @(); if ($b.PSObject.Properties['exclude']) { $ex = @($b.exclude) }
        if ($app.id -eq 'claude' -and $IncludeClaudeHistory) { $ex = @($ex | Where-Object { $_ -ne 'projects' }) }
        $size = Invoke-Copy -Src $src -Dst (Join-Path $dst $b.dest) -ExcludeDirs $ex -Label "$($app.name)"
        Say ("  {0,-28} {1,10}" -f $app.name, (Format-Size $size))
    }
}

# ---------------------------------------------------------------- Notepad++
Say '[3/7] Notepad++ session and unsaved tabs' 'Cyan'
$npp = [ordered]@{ tabs = @() }
$nppDir = Join-Path $env:APPDATA 'Notepad++'
$sessionPath = Join-Path $nppDir 'session.xml'
if (Test-Path $sessionPath) {
    $nppOut = Join-Path $Out 'apps\notepadpp'
    [void](Invoke-Copy -Src $nppDir -Dst (Join-Path $nppOut 'appdata') -Label 'Notepad++ appdata')
    [xml]$session = Get-Content -Raw -LiteralPath $sessionPath -Encoding UTF8
    $i = 0
    foreach ($f in $session.SelectNodes('/NotepadPlus/Session/*/File')) {
        $i++
        $fname  = $f.GetAttribute('filename')
        $backup = $f.GetAttribute('backupFilePath')
        $isUntitled = -not ($fname -match '^[A-Za-z]:\\|^\\\\')
        $hasBackup  = $backup -and (Test-Path -LiteralPath $backup)
        $tab = [ordered]@{ index = $i; view = $f.ParentNode.Name; title = $fname; untitled = $isUntitled; unsavedChanges = [bool]$hasBackup; lang = $f.GetAttribute('lang'); exportedAs = $null; originalCopiedTo = $null }
        if ($hasBackup) {
            $safe = ($fname -replace '^.*\\', '') -replace '[<>:"/\\|?*]', '_'
            $name = '{0:D3} - {1}' -f $i, $safe
            if ($isUntitled) { $name += '.txt' } else { $name += ' (UNSAVED EDITS)' + [IO.Path]::GetExtension($fname) }
            $tab.exportedAs = "unsaved-tabs/$name"
            if (-not $DryRun) {
                New-Item -ItemType Directory -Force (Join-Path $nppOut 'unsaved-tabs') | Out-Null
                Copy-Item -LiteralPath $backup -Destination (Join-Path $nppOut "unsaved-tabs\$name")
            }
        }
        # Real files open in tabs that live on C: would vanish with the wipe.
        if (-not $isUntitled -and $fname -match '^C:\\' -and (Test-Path -LiteralPath $fname)) {
            $rel = $fname.Substring(3)
            $tab.originalCopiedTo = "open-files/C/$($rel.Replace('\','/'))"
            if (-not $DryRun) {
                $target = Join-Path $nppOut "open-files\C\$rel"
                New-Item -ItemType Directory -Force (Split-Path $target) | Out-Null
                Copy-Item -LiteralPath $fname -Destination $target
            }
        }
        $npp.tabs += [pscustomobject]$tab
    }
    Save-Json $npp.tabs 'apps\notepadpp\tabs-index.json'
    $u = @($npp.tabs | Where-Object unsavedChanges).Count
    Say ("  {0} tabs, {1} with unsaved content exported as files" -f $npp.tabs.Count, $u)
} else { Say '  Notepad++ session not found, skipped.' }

# ---------------------------------------------------------------- qBittorrent
Say '[4/7] qBittorrent' 'Cyan'
$qbt = [ordered]@{ torrents = 0; savePaths = @() }
$qbtLocal = Join-Path $env:LOCALAPPDATA 'qBittorrent'
$qbtRoam  = Join-Path $env:APPDATA 'qBittorrent'
if (Test-Path $qbtLocal) {
    [void](Invoke-Copy -Src $qbtRoam  -Dst (Join-Path $Out 'apps\qbittorrent\roaming') -Label 'qBittorrent config')
    [void](Invoke-Copy -Src $qbtLocal -Dst (Join-Path $Out 'apps\qbittorrent\local') -ExcludeDirs @('logs', 'cache', 'GeoDB') -Label 'qBittorrent torrents+resume')
    $latin1 = [Text.Encoding]::GetEncoding(28591)
    $paths = @{}
    foreach ($fr in Get-ChildItem (Join-Path $qbtLocal 'BT_backup') -Filter *.fastresume -ErrorAction SilentlyContinue) {
        $qbt.torrents++
        $raw = $latin1.GetString([IO.File]::ReadAllBytes($fr.FullName))
        if ($raw -match '9:save_path(\d+):') {
            $start = $raw.IndexOf($Matches[0]) + $Matches[0].Length
            $val = [Text.Encoding]::UTF8.GetString($latin1.GetBytes($raw.Substring($start, [int]$Matches[1])))
            $paths[$val] = 1 + $(if ($paths.ContainsKey($val)) { $paths[$val] } else { 0 })
            if ($val -match '^([A-Za-z]:)' -and -not $pathMap.Contains($Matches[1].ToUpper())) { $pathMap[$Matches[1].ToUpper()] = "/mnt/$($Matches[1].Substring(0,1).ToLower())" }
        }
    }
    $qbt.savePaths = @($paths.GetEnumerator() | ForEach-Object { [pscustomobject]@{ path = $_.Key; torrents = $_.Value } })
    if (Test-Path "$qbtLocal\torrents.db") { Warn 'qBittorrent uses the SQLite resume store (torrents.db). restore.py only rewrites .fastresume files, so switch Advanced > Resume data storage to "Fastresume files" and restart qBittorrent before exporting.' }
    Say ("  {0} torrents; save paths: {1}" -f $qbt.torrents, (($qbt.savePaths | ForEach-Object path) -join ', '))
} else { Say '  qBittorrent not found, skipped.' }

# ---------------------------------------------------------------- WoW
Say '[5/7] World of Warcraft (all flavors)' 'Cyan'
$wow = [ordered]@{ install = $null; flavors = @() }
$wowDir = $null
$wowEntry = $installed | Where-Object Name -eq 'World of Warcraft' | Select-Object -First 1
if ($wowEntry) { $wowDir = $wowEntry.Location }
if (-not $wowDir) { $wowDir = "${env:ProgramFiles(x86)}\World of Warcraft" }
if (Test-Path $wowDir) {
    $wow.install = $wowDir
    $products = @{}
    $bi = Join-Path $wowDir '.build.info'
    if (Test-Path $bi) {
        $lines = Get-Content $bi; $hdr = $lines[0] -split '\|' | ForEach-Object { ($_ -split '!')[0] }
        foreach ($l in $lines | Select-Object -Skip 1) { $c = $l -split '\|'; $products[$c[[array]::IndexOf($hdr, 'Product')]] = $c[[array]::IndexOf($hdr, 'Version')] }
    }
    foreach ($fl in Get-ChildItem $wowDir -Directory | Where-Object Name -match '^_.+_$') {
        $total = 0
        foreach ($sub in 'WTF', 'Interface', 'Fonts', 'Screenshots') {
            $total += Invoke-Copy -Src (Join-Path $fl.FullName $sub) -Dst (Join-Path $Out "apps\wow\$($fl.Name)\$sub") -Label "WoW $($fl.Name) $sub"
        }
        $wow.flavors += [pscustomobject]@{ folder = $fl.Name; bytes = $total }
        Say ("  {0,-18} {1,10}" -f $fl.Name, (Format-Size $total))
    }
    $wow.products = $products
} else { Say '  WoW not found, skipped.' }

# ---------------------------------------------------------------- Steam games + Proton notes
Say '[6/7] Games' 'Cyan'
$steamGames = @()
$vdf = "${env:ProgramFiles(x86)}\Steam\steamapps\libraryfolders.vdf"
if (Test-Path $vdf) {
    $libs = Select-String -LiteralPath $vdf -Pattern '"path"\s+"(.+)"' | ForEach-Object { $_.Matches[0].Groups[1].Value.Replace('\\', '\') }
    foreach ($lib in $libs) {
        foreach ($acf in Get-ChildItem (Join-Path $lib 'steamapps') -Filter 'appmanifest_*.acf' -ErrorAction SilentlyContinue) {
            $t = Get-Content -Raw -LiteralPath $acf.FullName -Encoding UTF8
            $id = [regex]::Match($t, '"appid"\s+"(\d+)"').Groups[1].Value
            $nm = [regex]::Match($t, '"name"\s+"(.+?)"').Groups[1].Value
            $sz = [int64]([regex]::Match($t, '"SizeOnDisk"\s+"(\d+)"').Groups[1].Value)
            if ($nm -match 'Proton|Steamworks|Steam Linux Runtime|Redistributable') { continue }
            $status = 'protondb'; $note = ''
            if ($Catalog.games.blocked.PSObject.Properties[$id]) { $status = 'blocked'; $note = $Catalog.games.blocked.$id }
            $steamGames += [pscustomobject]@{ appid = $id; name = $nm; library = $lib; sizeGB = [math]::Round($sz / 1GB, 1); onSystemDrive = $lib.StartsWith('C:', 'OrdinalIgnoreCase'); status = $status; note = $note }
        }
    }
}
Save-Json $steamGames 'inventory\steam-games.json'
Say ("  {0} Steam games found" -f $steamGames.Count)

# ---------------------------------------------------------------- projects + git risk
Say '[7/7] Code projects' 'Cyan'
$gitRisk = @()
foreach ($pr in $ProjectRoots) {
    if (-not (Test-Path $pr)) { continue }
    foreach ($d in Get-ChildItem $pr -Directory) {
        if (-not (Test-Path (Join-Path $d.FullName '.git'))) { continue }
        $p = $d.FullName
        $dirty  = @(git -C $p status --porcelain 2>$null).Count
        $stash  = @(git -C $p stash list 2>$null).Count
        $remote = git -C $p remote get-url origin 2>$null
        $up     = git -C $p rev-parse --abbrev-ref '@{u}' 2>$null
        $ahead  = 0
        if ($up) { $ahead = [int](git -C $p rev-list --count '@{u}..HEAD' 2>$null) }
        # Branches that are ahead of their upstream, or exist only locally.
        $unpushedBranches = @(git -C $p for-each-ref --format='%(refname:short)|%(upstream)|%(upstream:track)' refs/heads 2>$null |
            Where-Object { $_ -match '\[ahead' -or $_ -match '^[^|]+\|\|' } | ForEach-Object { ($_ -split '\|')[0] })
        if ($dirty -or $stash -or $ahead -or -not $up -or $unpushedBranches.Count) {
            $gitRisk += [pscustomobject]@{ repo = $p.Replace($env:USERPROFILE, '~'); path = $p; dirty = $dirty; unpushed = $ahead; stash = $stash; upstream = [bool]$up; remote = $remote; branchesNotPushed = $unpushedBranches }
        }
    }
    if (-not $SkipProjects) {
        $size = Invoke-Copy -Src $pr -Dst (Join-Path $Out "projects\$(Split-Path -Leaf $pr)") -ExcludeDirs $RegenDirs -Label "Projects: $pr"
        Say ("  {0,-40} {1,10}" -f $pr.Replace($env:USERPROFILE, '~'), (Format-Size $size))
    }
}
Save-Json $gitRisk 'inventory\git-risk.json'
foreach ($g in $gitRisk | Where-Object { $_.unpushed -gt 0 }) { Blocker "$($g.repo) has $($g.unpushed) unpushed commit(s). It is in the backup, but push it too: git -C `"$($g.path)`" push" }

# ---------------------------------------------------------------- optional bulk
if ($IncludeModels -and (Test-Path "$env:USERPROFILE\.ollama\models")) {
    $s = Invoke-Copy -Src "$env:USERPROFILE\.ollama\models" -Dst (Join-Path $Out 'data\ollama-models') -Label 'Ollama models'
    Say ("  Ollama models {0}" -f (Format-Size $s))
}
if ($IncludeDownloads) {
    $s = Invoke-Copy -Src "$env:USERPROFILE\Downloads" -Dst (Join-Path $Out 'data\Downloads') -Label 'Downloads'
    Say ("  Downloads {0}" -f (Format-Size $s))
}

# ---------------------------------------------------------------- checks that need a human
$od = $env:OneDrive
if ($od -and ($Docs -like "$od*")) {
    Blocker "Documents, Desktop and Pictures are redirected into OneDrive ($od). Open the OneDrive tray icon and confirm it says 'up to date'. Anything set to 'Always keep on this device' is fine. Files with sync errors are NOT safe."
}
$dl = "$env:USERPROFILE\Downloads"
if ((Test-Path $dl) -and -not $IncludeDownloads) {
    $dlSize = (Get-ChildItem $dl -Recurse -File -Force -ErrorAction SilentlyContinue | Measure-Object Length -Sum).Sum
    if ($dlSize -gt 0) { Warn ("Downloads ({0}) is on C: and NOT backed up. Re-run with -IncludeDownloads, or move what you need." -f (Format-Size $dlSize)) }
}
$cGames = @($steamGames | Where-Object onSystemDrive)
if ($cGames.Count) { Warn ("{0} Steam game(s) are installed on C: and will need re-downloading: {1}" -f $cGames.Count, (($cGames | ForEach-Object name) -join ', ')) }
foreach ($b in $bitlocker | Where-Object { $_.ProtectionStatus -eq 'On' -and $_.MountPoint -ne 'C:' }) {
    Blocker "$($b.MountPoint) is BitLocker-encrypted. Linux can't read it easily. Save the recovery key or decrypt it first."
}
if ((Test-Path "$env:USERPROFILE\.ollama\models") -and -not $IncludeModels) { Warn 'Ollama models (~/.ollama/models) are not copied. Use -IncludeModels or re-pull them.' }

# ---------------------------------------------------------------- manifest
$manifest = [ordered]@{
    tool          = 'Win2CachyOS'
    schema        = 1
    created       = (Get-Date).ToString('o')
    dryRun        = [bool]$DryRun
    computer      = $env:COMPUTERNAME
    windowsUser   = $env:USERNAME
    windowsHome   = $env:USERPROFILE
    hardware      = $hardware
    pathMap       = $pathMap
    apps          = $matched
    unmapped      = @($unmapped | ForEach-Object Name)
    notepadpp     = $npp.tabs
    qbittorrent   = $qbt
    wow           = $wow
    steamGames    = $steamGames
    gitRisk       = $gitRisk
    copies        = $Results
    warnings      = $Warnings
    blockers      = $Blockers
}
Save-Json $manifest 'manifest.json'
Save-Json $pathMap 'pathmap.json'
Copy-Item -LiteralPath (Join-Path $Root 'catalog\apps.json') -Destination (Join-Path $Out 'catalog.json')
if (-not $DryRun) { Copy-Item -Recurse -Force -LiteralPath (Join-Path $Root 'linux') -Destination (Join-Path $Out 'linux') }

# ---------------------------------------------------------------- REPORT.md
$total = ($Results | Measure-Object Bytes -Sum).Sum
$md = New-Object System.Text.StringBuilder
function L([string]$s = '') { [void]$md.AppendLine($s) }
L "# Win2CachyOS pre-wipe report: $env:COMPUTERNAME"
L ''
L "Created $(Get-Date -Format 'yyyy-MM-dd HH:mm'). Mode: **$mode**. Backup size: **$(Format-Size $total)**."
L ''
L '## Do these before you wipe'
L ''
if ($Blockers.Count) { foreach ($b in $Blockers) { L "- [ ] $b" } } else { L '- No blockers found.' }
L '- [ ] Browser sync is on in Chrome and Brave (save the Brave sync chain code). Export Mullvad Browser bookmarks if you need them.'
L '- [ ] You have your password manager / 2FA. You will be signing back in to Battle.net, Steam, Discord, Proton, Tailscale, Signal, and others.'
L '- [ ] Update SSD firmware in Samsung Magician (Windows-only tool).'
L '- [ ] Copy this backup folder somewhere besides the NAS too (USB stick) if it holds your only copy of something.'
L "- [ ] Re-run without -DryRun after closing Notepad++, qBittorrent, WoW and Plex."
L '- [ ] For a clean NTFS games drive: Shut down with Shift+Shutdown (no Fast Startup/hibernate). Otherwise Linux mounts it read-only.'
L ''
if ($Warnings.Count) { L '## Warnings'; L ''; foreach ($w in $Warnings) { L "- $w" }; L '' }
L '## Hardware'
L ''
L "- CPU: $($hardware.CPU)  |  GPU: $($hardware.GPU -join ', ')  |  RAM: $($hardware.RAMGB) GB  |  Board: $($hardware.Board)"
if ($hardware.GPU -match 'NVIDIA') { L '- NVIDIA GPU: pick the NVIDIA driver option in the CachyOS installer (it detects the card).' }
else { L '- AMD/Intel GPU: drivers ship with the kernel and Mesa, nothing to install. Newest cards need a recent kernel + Mesa, which CachyOS ships.' }
L '- Secure Boot: turn it off for the installer. Once installed, you can re-enable it with sbctl (see the CachyOS wiki "Secure Boot setup").'
L ''
L '## Drives -> Linux mount points (edit pathmap.json if you prefer others)'
L ''
L '| Windows | Linux |'; L '|---|---|'
foreach ($k in $pathMap.Keys) { L "| ``$k`` | ``$($pathMap[$k])`` |" }
L ''
L '## Notepad++'
L ''
$un = @($npp.tabs | Where-Object unsavedChanges)
L "$($npp.tabs.Count) open tabs, of which **$($un.Count)** hold unsaved content. Each one is exported to ``apps/notepadpp/unsaved-tabs/`` as a plain file, and the full session is kept for Wine. ``tabs-index.json`` maps file -> tab."
L ''
L '## qBittorrent'
L ''
L "$($qbt.torrents) torrents. Save paths (rewritten via pathmap on restore):"
foreach ($sp in $qbt.savePaths) { L "- ``$($sp.path)`` ($($sp.torrents))" }
L ''
L '## World of Warcraft'
L ''
L "Install: ``$($wow.install)``. Flavors backed up (WTF, Interface, Fonts, Screenshots):"
foreach ($f in $wow.flavors) {
    if ($f.bytes -gt 0) { L "- ``$($f.folder)``: $(Format-Size $f.bytes)" }
    else { L "- ``$($f.folder)``: no WTF/Interface yet (never logged in on this flavor?), so nothing to restore" }
}
if ($wow.Contains('products')) { foreach ($k in $wow.products.Keys) { L "- Battle.net product ``$k`` version $($wow.products[$k])" } }
L ''
L 'On CachyOS: install Battle.net with Lutris, install WoW and **World of Warcraft Forever** from inside it, run each once, quit, then `restore.py --wow-dir <path to World of Warcraft>` copies your UI/addons/settings back.'
L ''
L '## App mapping'
L ''
L '| Windows | CachyOS | Notes |'; L '|---|---|---|'
foreach ($m in $matched) {
    $c = $Catalog.apps | Where-Object id -eq $m.id
    $how = @()
    if ($c.PSObject.Properties['paru'])    { $how += 'paru: ' + ($c.paru -join ' ') }
    if ($c.PSObject.Properties['flatpak']) { $how += 'flatpak: ' + ($c.flatpak -join ' ') }
    if (-not $how) { $how = @('manual') }
    $note = ''; if ($c.PSObject.Properties['note']) { $note = $c.note.Replace('|', '\|') }
    L "| $($m.name) | $($how -join '<br>') | $note |"
}
L ''
L '## Unmapped apps (no catalog entry yet, so add them to catalog/apps.json)'
L ''
$steamNames = @($steamGames | ForEach-Object name)
$nonGame = @($unmapped | Where-Object { $_.Location -notmatch 'steamapps' -and $steamNames -notcontains $_.Name })
foreach ($u in $nonGame) { L "- $($u.Name) $($u.Version)" }
L ''
L '## Steam games'
L ''
L '| Game | Library | Size | Linux |'; L '|---|---|---|---|'
foreach ($g in $steamGames | Sort-Object name) {
    $st = "[ProtonDB](https://www.protondb.com/app/$($g.appid))"
    if ($g.status -eq 'blocked') { $st = "**BLOCKED**: $($g.note)" }
    L "| $($g.name) | $($g.library) | $($g.sizeGB) GB | $st |"
}
L ''
L 'Games on an NTFS drive: Proton has trouble with NTFS (permissions, case-sensitivity, compatdata). The reliable path is to reformat the games drive as btrfs/ext4 after migrating and re-download. Restoring from Steam backups or LAN-transfer from another PC also works.'
L ''
L '## Git repos with local-only work (all copied in projects/, .git included)'
L ''
L '| Repo | Uncommitted files | Unpushed commits | Stashes | Has upstream | Local-only / ahead branches |'; L '|---|---|---|---|---|---|'
foreach ($g in $gitRisk) { L "| $($g.repo) | $($g.dirty) | $($g.unpushed) | $($g.stash) | $($g.upstream) | $(@($g.branchesNotPushed) -join ', ') |" }
L ''
L '## What was copied'
L ''
L '| Item | Size | OK |'; L '|---|---|---|'
foreach ($r in $Results) { L "| $($r.Label) | $(Format-Size $r.Bytes) | $($r.Ok) |" }
L ''
L '## Next: on CachyOS'
L ''
L '```bash'
L '# mount the NAS share that holds this backup, then:'
L "python3 linux/restore.py /mnt/<share>/Win2CachyOS/$(Split-Path -Leaf $Out)            # shows the plan"
L "python3 linux/restore.py /mnt/<share>/Win2CachyOS/$(Split-Path -Leaf $Out) --apply    # does it"
L '```'
$md.ToString() | Out-File -Encoding utf8 -LiteralPath (Join-Path $Out 'REPORT.md')

Say "`nDone. $mode, $(Format-Size $total). Blockers: $($Blockers.Count), warnings: $($Warnings.Count)" 'Green'
Say "Report: $(Join-Path $Out 'REPORT.md')" 'Green'
