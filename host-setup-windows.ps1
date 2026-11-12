# FTK Remote - HOST setup for Windows (run on the colleague's PC).
# Lets a teammate connect over SSH (via Tailscale) and watch / talk to
# the Claude Code agent, which runs inside WSL (Ubuntu) + tmux.
# Safe to run again at any time (it must be run twice if WSL gets installed).
# Start it with host-setup-windows.cmd (double-click).

# 'Continue' on purpose: in PS 5.1 'Stop' turns any stderr line of a native exe into a fatal error.
# Cmdlets that must succeed use -ErrorAction Stop explicitly.
$ErrorActionPreference = 'Continue'

# ===== Optional: fill these in before sending the script =====
$RepoUrl    = ''   # package.sh fills it (args or local.env)
$RepoBranch = 'v2'   # cloned single-branch; empty = default branch
$NtfyTopic  = ''   # ntfy.sh topic for "ready" / "agent needs you" pushes (package.sh fills it)
# ==============================================================
[Console]::OutputEncoding = [Text.Encoding]::UTF8

# ---------- run as Administrator ----------
$me = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
$Auto = ($env:FTK_AUTO -eq '1')   # non-interactive: no dialogs, defaults everywhere (for an agent running the setup)
if (-not $me.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    if ($Auto) { Write-Host 'ERROR: FTK_AUTO=1 needs an elevated (Administrator) PowerShell.'; exit 1 }
    Start-Process powershell.exe -Verb RunAs -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`""
    exit
}

# full log of every run, readable by an agent helping the user
$LogDir = Join-Path $env:ProgramData 'ftk'
New-Item -ItemType Directory -Force -Path $LogDir | Out-Null
try { Start-Transcript -Path (Join-Path $LogDir 'setup.log') -Append | Out-Null } catch { }
$global:FtkStep = 'start'
function Mark([string]$name) { $global:FtkStep = $name; Write-Host "=== $name ($(Get-Date -Format HH:mm:ss))" }
function RebootPending {
    return ((Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending') -or
            (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired'))
}

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName Microsoft.VisualBasic
$Title = 'FTK Remote - Host setup (Windows)'
$Owner = New-Object Windows.Forms.Form -Property @{ TopMost = $true }

function Step([string]$m) {
    if ($Auto) { Write-Host "== $($m.Split([char]10)[0])"; return }
    $r = [Windows.Forms.MessageBox]::Show($Owner, $m, $Title, 'OKCancel', 'Information')
    if ($r -ne 'OK') { Write-Host 'Cancelled.'; exit 1 }
}
function Info([string]$m) { if ($Auto) { Write-Host "-- $m"; return }; [void][Windows.Forms.MessageBox]::Show($Owner, $m, $Title, 'OK', 'Information') }
function YesNo([string]$m) { if ($Auto) { Write-Host "?? $($m.Split([char]10)[0]) -> Yes (auto)"; return $true }; return ([Windows.Forms.MessageBox]::Show($Owner, $m, $Title, 'YesNo', 'Question') -eq 'Yes') }
function Ask([string]$m, [string]$def) {
    if ($Auto) { if ([string]::IsNullOrWhiteSpace($def)) { Write-Host "ERROR (auto): no default for: $($m.Split([char]10)[0])"; exit 1 }; return $def.Trim() }
    $r = [Microsoft.VisualBasic.Interaction]::InputBox($m, $Title, $def)
    if ([string]::IsNullOrWhiteSpace($r)) { Write-Host 'Cancelled.'; exit 1 }
    return $r.Trim()
}
function AskOpt([string]$m, [string]$def) {  # empty answer allowed
    if ($Auto) { return "$def".Trim() }
    return ([Microsoft.VisualBasic.Interaction]::InputBox($m, $Title, $def)).Trim()
}
function Write-NoBom([string]$path, [string]$text) {
    [IO.File]::WriteAllText($path, $text, (New-Object Text.UTF8Encoding($false)))
}
function B64([string]$s) { return [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($s)) }
function Add-KeyLine([string]$path, [string]$key) {
    $dir = Split-Path $path
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $lines = @()
    if (Test-Path $path) { $lines = @(Get-Content $path | Where-Object { $_.Trim() -ne '' }) }
    if ($lines -notcontains $key) { $lines += $key }
    Write-NoBom $path (($lines -join "`n") + "`n")
}
function Wsl([string[]]$a) { & wsl.exe @a | Out-Host; return $LASTEXITCODE }

try {
# ---------- Step 0: welcome ----------
Step @"
This will set up your PC so your teammate can connect to your Claude Code agent.

Steps:
1. Tailscale (private network, no port forwarding)
2. OpenSSH Server (only reachable through Tailscale)
3. WSL + Ubuntu + tmux (keeps the agent running)
4. Claude Code (inside Ubuntu)
5. Add your teammate's SSH key
6. Clone the repo + switch to the branch
7. Start the agent session (auto-starts at logon)
8. Send the connection line back to your teammate

If WSL is not installed yet, the PC must restart once and you run this script again.
Have the SSH key your teammate sent you ready. Click OK to start.
"@

# ---------- preflight: unfinished Windows updates break OpenSSH / WSL installs ----------
Mark 'Preflight'
if (RebootPending) {
    $go = YesNo @"
Windows has unfinished updates waiting for a restart.

While they are pending, OpenSSH Server and WSL often cannot be installed
(the script would then keep asking for a restart).

Recommended: click NO, then Start -> Power -> 'Update and restart',
and run this script again after Windows has finished updating.

Continue anyway? (YES = continue now, NO = stop and update first)
"@
    if (-not $go) { Write-Host 'Stopped: finish Windows updates first (Start -> Power -> Update and restart).'; exit 0 }
}

# ---------- Step 1: Tailscale ----------
Mark 'Step 1/8 Tailscale'
$ts = Join-Path $env:ProgramFiles 'Tailscale\tailscale.exe'
if (-not (Test-Path $ts)) {
    Write-Host 'Installing Tailscale...'
    try { & winget.exe install --id Tailscale.Tailscale -e --accept-source-agreements --accept-package-agreements } catch { }
    # winget can return before the MSI has placed tailscale.exe - wait for it (up to 90 s)
    for ($i = 0; $i -lt 90 -and -not (Test-Path $ts); $i++) { Start-Sleep -Seconds 1 }
    if (-not (Test-Path $ts)) {
        Start-Process 'https://tailscale.com/download/windows'
        Step "Step 1/8 - Tailscale`n`nThe download page is open. Install Tailscale, then click OK."
    }
}
Step @"
Step 1/8 - Tailscale

Open Tailscale (tray icon) and log in. Wait until it shows Connected.

If your teammate uses a DIFFERENT Tailscale account:
open https://login.tailscale.com/admin/machines -> this PC -> ... -> Share -> send the invite link to your teammate.

Click OK to continue.
"@
$ip = ''
if (Test-Path $ts) { $ip = (& $ts ip -4 2>$null | Select-Object -First 1) }
if (-not $ip) { $ip = Ask "Step 1/8 - Could not read the Tailscale IP.`n`nRight-click the Tailscale tray icon and type this PC's IP (starts with 100.):" '100.' }
$ip = "$ip".Trim()

# ---------- Step 2: OpenSSH Server ----------
Mark 'Step 2/8 OpenSSH Server'
Write-Host 'Checking OpenSSH Server...'
if (-not (Get-Service sshd -ErrorAction SilentlyContinue)) {
    Write-Host 'Installing OpenSSH Server (can take several minutes)...'
    $cap = Get-WindowsCapability -Online | Where-Object { $_.Name -like 'OpenSSH.Server*' } | Select-Object -First 1
    $res = Add-WindowsCapability -Online -Name $cap.Name -ErrorAction Stop
    if (-not (Get-Service sshd -ErrorAction SilentlyContinue)) {
        if ($res.RestartNeeded -or (RebootPending)) {
            Info @"
Step 2/8 - Restart needed

OpenSSH Server is installed, but Windows needs a restart to finish it
(usually a pending Windows update must be applied first).

1. Start -> Power -> 'Update and restart' (if it only shows 'Restart', use that).
   A plain restart is NOT enough while an update is pending.
2. Run this script (host-setup-windows.cmd) again - it continues where it stopped.
"@
            exit 0
        }
        throw 'OpenSSH Server was installed but the sshd service does not exist. Restart the PC and run the script again.'
    }
}
Set-Service sshd -StartupType Automatic -ErrorAction Stop
Start-Service sshd -ErrorAction Stop
# allow port 22 only from Tailscale addresses
$rule = Get-NetFirewallRule -Name 'OpenSSH-Server-In-TCP' -ErrorAction SilentlyContinue
if ($rule) {
    Set-NetFirewallRule -Name 'OpenSSH-Server-In-TCP' -Enabled True -RemoteAddress '100.64.0.0/10'
} else {
    New-NetFirewallRule -Name 'OpenSSH-Server-In-TCP' -DisplayName 'OpenSSH Server (Tailscale only)' -Direction Inbound -Protocol TCP -LocalPort 22 -Action Allow -RemoteAddress '100.64.0.0/10' | Out-Null
}

# ---------- Step 3: WSL + Ubuntu + tmux ----------
Mark 'Step 3/8 WSL'
Write-Host 'Checking WSL...'
& wsl.exe --update 2>&1 | Out-Null
$wslOk = $false
try { & wsl.exe -e true 2>&1 | Out-Null; $wslOk = ($LASTEXITCODE -eq 0) } catch { $wslOk = $false }
if (-not $wslOk) {
    Step "Step 3/8 - WSL`n`nWSL + Ubuntu will now be installed. This takes a few minutes.`nClick OK to start."
    & wsl.exe --install -d Ubuntu
    Info @"
Step 3/8 - Restart needed

1. Restart the PC.
2. Open 'Ubuntu' from the Start menu once and create a Linux username + password.
3. Run this script (host-setup-windows.cmd) again.
"@
    exit 0
}
$linuxUser = ((& wsl.exe -e whoami) | Out-String).Trim()
if ($linuxUser -eq 'root') {
    Info "Step 3/8 - Ubuntu user missing`n`nOpen 'Ubuntu' from the Start menu once, create your Linux username + password, then run this script again."
    exit 0
}
Write-Host 'Installing tmux in Ubuntu...'
if ((Wsl @('-u', 'root', '-e', 'sh', '-c', 'command -v tmux >/dev/null && command -v curl >/dev/null && command -v git >/dev/null || (apt-get update && apt-get install -y tmux curl git)')) -ne 0) {
    throw 'tmux install in Ubuntu failed'
}

# ---------- Step 4: Claude Code (inside Ubuntu) ----------
Mark 'Step 4/8 Claude Code'
Write-Host 'Installing Claude Code in Ubuntu...'
if ((Wsl @('-e', 'bash', '-lc', '[ -x ~/.local/bin/claude ] || curl -fsSL https://claude.ai/install.sh | bash')) -ne 0) {
    throw 'Claude Code install in Ubuntu failed'
}

# ---------- Step 5: teammate's SSH key ----------
Mark 'Step 5/8 SSH key'
$clip = ''
try { $clip = "$(Get-Clipboard | Select-Object -First 1)".Trim() } catch { }
# teammate.pub shipped next to this script wins over the clipboard
$pubFile = Join-Path $PSScriptRoot 'teammate.pub'
if (Test-Path $pubFile) { $clip = "$(Get-Content $pubFile | Select-Object -First 1)".Trim() }
$key = ''
if ($clip -match '^(ssh-ed25519|ssh-rsa|ecdsa-\S+) ') { $key = $clip }
while ($true) {
    if ($Auto -and -not $key) { Write-Host 'ERROR (auto): no teammate.pub next to the script and no key in the clipboard'; exit 1 }
    $key = Ask "Step 5/8 - Teammate's SSH key`n`nPaste the public key your teammate sent you.`nIt starts with 'ssh-ed25519 ...'" $key
    if ($key -match '^(ssh-ed25519|ssh-rsa|ecdsa-\S+) \S+') { break }
    Info "That does not look like an SSH public key. It must start with ssh-ed25519."
}
# admins: sshd reads ONLY this file, and only with this exact ACL
$adminKeys = Join-Path $env:ProgramData 'ssh\administrators_authorized_keys'
Add-KeyLine $adminKeys $key
& icacls.exe $adminKeys /inheritance:r /grant '*S-1-5-32-544:F' /grant '*S-1-5-18:F' | Out-Null
# non-admin fallback
Add-KeyLine (Join-Path $env:USERPROFILE '.ssh\authorized_keys') $key
Restart-Service sshd -ErrorAction Stop

# ---------- install the remote helper (inside Ubuntu) ----------
$remote = @'
#!/bin/bash
# ftk-remote: helper that lives on the HOST (colleague's machine).
# The client calls it over ssh:  ftk-remote [-s <lane>] <command> [arg...]
# Arguments are always plain words or base64, so no quoting problems
# across PowerShell -> ssh -> cmd -> wsl -> bash.
export PATH="/opt/homebrew/bin:/usr/local/bin:$HOME/.local/bin:$PATH"

# ---- session (lane) selection: no -s = main session "ftk", -s a1 = "ftk-a1"
S="${FTK_SESSION:-ftk}"
if [ "$1" = "-s" ]; then
  [[ "$2" =~ ^[a-z0-9][a-z0-9-]{0,30}$ ]] || { echo "bad lane name (a-z 0-9 -)"; exit 2; }
  [ "$2" = "main" ] || S="ftk-$2"
  shift 2
fi
LANE="${S#ftk}"; LANE="${LANE#-}"           # "" for main
AGENT="${FTK_AGENT_CMD:-claude}"           # tests override this
X="=$S"          # exact session match (tmux -t does prefix matching)
P="=$S:"         # its active pane
T() { tmux ${FTK_TMUX:+-L "$FTK_TMUX"} "$@"; }  # tests use a private socket
FTK="$HOME/.ftk"
MAIN_PROJECT_FILE="$FTK/project"
if [ "$S" = "ftk" ]; then PROJECT_FILE="$MAIN_PROJECT_FILE"; else PROJECT_FILE="$FTK/project-$S"; fi
BASE_BRANCH_FILE="$FTK/base-branch"
TOPIC_FILE="$FTK/ntfy-topic"
NTFY="${FTK_NTFY_URL:-https://ntfy.sh}"
SELF="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"
DENY_PREFIX="migrate/operator-records"    # private branch: never fetched / checked out here
XFER="$FTK/xfer"                           # put/get exchange folder
WORKSPACE="$FTK/workspace"                 # where the agent waits while no project is set

notify_send() { # notify_send <title> <body>  (no-op without a topic; never fails)
  t="$(cat "$TOPIC_FILE" 2>/dev/null)"; [ -n "$t" ] || return 0
  curl -fsS -m 10 -H "Title: $1" -H "Tags: robot" -d "$2" "$NTFY/$t" >/dev/null 2>&1 || true
}
set_state() { mkdir -p "$FTK"; printf '%s %s\n' "$2" "$(date +%s)" > "$FTK/state-$1"; }

b64dec() { base64 --decode; }
arg() { [ "$1" = "-" ] && return 0; printf '%s' "$1" | b64dec; }   # base64 arg, "-" = empty

project_dir() { d="$(cat "$PROJECT_FILE" 2>/dev/null)"; [ -d "$d" ] && echo "$d"; }

check_branch() { # check_branch <name> -> valid and allowed?
  git check-ref-format --branch "$1" >/dev/null 2>&1 || { echo "ERROR: bad branch name: $1"; return 1; }
  case "$1" in "$DENY_PREFIX"*) echo "ERROR: branch '$1' is not allowed on this machine"; return 1;; esac
}
has_origin() { git -C "$1" remote get-url origin >/dev/null 2>&1; }
on_origin() { has_origin "$1" && git -C "$1" ls-remote --exit-code --heads origin "refs/heads/$2" >/dev/null 2>&1; }
sha256() { if command -v sha256sum >/dev/null; then sha256sum "$1" | cut -d' ' -f1; else shasum -a 256 "$1" | cut -d' ' -f1; fi; }
xfer_path() { # xfer_path <b64 rel path> -> absolute path inside $XFER (no "..", no leading /)
  r="$(arg "${1:--}")"
  [[ -n "$r" && "$r" =~ ^[A-Za-z0-9._/-]+$ && "$r" != /* && "$r" != *..* ]] || { echo "bad path (letters, digits . _ - /, relative, no ..)" >&2; return 1; }
  echo "$XFER/$r"
}
fetch_exact() { # add an exact refspec for this one branch (so tracking/pull work), then fetch only it
  rs="+refs/heads/$2:refs/remotes/origin/$2"
  git -C "$1" config --get-all remote.origin.fetch | grep -qxF "$rs" || git -C "$1" config --add remote.origin.fetch "$rs"
  git -C "$1" fetch -q origin "$rs"
}

checkout_branch() { # checkout_branch <dir> <branch>
  d="$1"; b="$2"
  check_branch "$b" || return 1
  if [ -n "$(git -C "$d" status --porcelain)" ]; then
    echo "ERROR: uncommitted changes in $d - not switching branch"; return 1
  fi
  if has_origin "$d"; then git -C "$d" fetch -q origin || return 1; fi   # single-branch clone: base branch only
  if on_origin "$d" "$b"; then fetch_exact "$d" "$b" || return 1; fi
  if git -C "$d" show-ref --verify -q "refs/heads/$b"; then
    git -C "$d" checkout -q "$b" || return 1
    git -C "$d" merge --ff-only -q "origin/$b" 2>/dev/null || true
  elif git -C "$d" show-ref --verify -q "refs/remotes/origin/$b"; then
    git -C "$d" checkout -q -b "$b" --track "origin/$b" || return 1
  else
    git -C "$d" checkout -q -b "$b" || return 1
    echo "branch '$b' does not exist on origin - created locally from $(git -C "$d" rev-parse --short HEAD)"
  fi
  echo "branch: $(git -C "$d" rev-parse --abbrev-ref HEAD)"
}

start_session() {
  dir="$(cat "$PROJECT_FILE" 2>/dev/null)"
  [ -d "$dir" ] || { mkdir -p "$WORKSPACE"; dir="$WORKSPACE"; }   # never the home folder
  if ! T has-session -t "$X" 2>/dev/null; then
    T new-session -d -s "$S" -x 220 -y 50 -c "$dir" -e "FTK_SESSION_NAME=$S"
    sleep 1
    T send-keys -t "$P" "$AGENT" Enter
    set_state "$S" "started"
    echo "session '$S' started in $dir"
  else
    echo "session '$S' already running"
  fi
  # macOS: keep the machine awake while any session exists
  if command -v caffeinate >/dev/null 2>&1 && ! T has-session -t "=awake-ftk" 2>/dev/null; then
    T new-session -d -s "awake-ftk" "caffeinate -dimsu"
  fi
}

transcript_text() { # transcript_text <project dir> <N>  -> last N messages as plain text
  python3 - "$1" "$2" <<'PY'
import glob, json, os, re, sys
proj, n = sys.argv[1], int(sys.argv[2])
base = os.path.expanduser("~/.claude/projects")
cand = glob.glob(os.path.join(base, re.sub(r"[^A-Za-z0-9]", "-", proj), "*.jsonl"))
if not cand:
    cand = glob.glob(os.path.join(base, "*", "*.jsonl"))
if not cand:
    print("no transcripts found"); sys.exit(0)
f = max(cand, key=os.path.getmtime)
def short(x, k=300):
    x = x if isinstance(x, str) else json.dumps(x, ensure_ascii=False)
    x = " ".join(x.split())
    return x if len(x) <= k else x[:k] + " ..."
out = []
for line in open(f, encoding="utf-8", errors="replace"):
    try: e = json.loads(line)
    except ValueError: continue
    if e.get("type") not in ("user", "assistant"): continue
    c = (e.get("message") or {}).get("content")
    if isinstance(c, str):
        out.append(f'{e["type"]}: {short(c, 600)}'); continue
    for it in c or []:
        t = it.get("type")
        if t == "text" and it.get("text", "").strip():
            out.append(f'{e["type"]}: {short(it["text"], 600)}')
        elif t == "tool_use":
            inp = it.get("input") or {}
            out.append(f'tool_use {it.get("name")}: {short(inp.get("command") or inp.get("file_path") or inp)}')
        elif t == "tool_result":
            r = it.get("content")
            if isinstance(r, list): r = " ".join(x.get("text", "") for x in r if isinstance(x, dict))
            out.append(f'tool_result{" (error)" if it.get("is_error") else ""}: {short(r or "")}')
print("# " + f)
print("\n".join(out[-n:]))
PY
}

case "$1" in
  peek)       # last N lines of the agent screen (default 200)
    n="${2:-200}"; [[ "$n" =~ ^[0-9]+$ ]] || n=200
    T capture-pane -p -J -t "$P" -S "-$n" | awk 'NF{if(b)print "";b=0;print;next}{b=1}' ;;   # collapse blank lines
  say)        # type a message (base64 UTF-8) into the agent and press Enter
    printf '%s' "$2" | b64dec | T load-buffer -b "msg$S" - &&
      T paste-buffer -p -d -b "msg$S" -t "$P" &&
      sleep 0.5 && T send-keys -t "$P" Enter && set_state "$S" busy && echo "sent" ;;
  key)        # press a key: Enter, Escape, Up, Down, Tab, 1, 2, y, n, C-c ...
    [[ "$2" =~ ^[A-Za-z0-9-]+$ ]] || { echo "bad key name"; exit 2; }
    T send-keys -t "$P" "$2" && set_state "$S" busy && echo "pressed $2" ;;
  wait)       # wait [timeout_s]: block until the agent finished its turn or needs input
    to="${2:-600}"; [[ "$to" =~ ^[0-9]+$ ]] && [ "$to" -le 86400 ] || { echo "bad timeout"; exit 2; }
    end=$(( $(date +%s) + to ))
    while :; do
      st="$(cut -d' ' -f1 "$FTK/state-$S" 2>/dev/null)"
      case "$st" in stop|waiting) echo "$st"; exit 0;; esac
      [ "$(date +%s)" -ge "$end" ] && { echo "timeout (${st:-unknown})"; exit 124; }
      sleep 1
    done ;;
  log)        # log [N] [raw]: last N messages as text (raw = jsonl lines)
    n="${2:-30}"; [[ "$n" =~ ^[0-9]+$ ]] || n=30
    if [ "$3" = "raw" ]; then
      f="$(ls -t "$HOME"/.claude/projects/*/*.jsonl 2>/dev/null | head -1)"
      [ -n "$f" ] && { echo "# $f"; tail -n "$n" "$f"; } || echo "no transcripts found"
    else
      transcript_text "$(project_dir || echo "$HOME")" "$n"
    fi ;;
  status)
    if T has-session -t "$X" 2>/dev/null; then echo "session: running ($S)"; else echo "session: NOT running ($S)"; fi
    if pgrep -x claude >/dev/null 2>&1; then echo "claude: running"; else echo "claude: not running"; fi
    echo "state: $(cat "$FTK/state-$S" 2>/dev/null || echo unknown)"
    echo "project: $(cat "$PROJECT_FILE" 2>/dev/null || echo '(not set)')" ;;
  lanes)      # all agent sessions with state and folder
    for f in "$FTK"/project "$FTK"/project-ftk-*; do
      [ -f "$f" ] || continue
      s="${f##*/project-}"; [ "$f" = "$MAIN_PROJECT_FILE" ] && s=ftk
      if T has-session -t "=$s" 2>/dev/null; then r=running; else r=stopped; fi
      printf '%-14s %-8s %-22s %s\n' "$s" "$r" "$(cat "$FTK/state-$s" 2>/dev/null | cut -d' ' -f1)" "$(cat "$f")"
    done ;;
  run)        # run <b64 command>: non-interactive, in the project dir (or ~/.ftk/xfer); prints output + [exit N]
    d="$(project_dir)" || { mkdir -p "$XFER"; d="$XFER"; }
    c="$(arg "${2:--}")"; [ -n "$c" ] || { echo "usage: run <b64 command>"; exit 2; }
    ( cd "$d" && bash -lc "$c" ) </dev/null 2>&1; rc=$?
    echo "[exit $rc]"; exit $rc ;;
  start)
    start_session
    [ "$2" = "keepalive" ] && exec sleep infinity ;;
  restart)
    T kill-session -t "$X" 2>/dev/null; start_session ;;
  setproject) # setproject <b64 path>  (~/ allowed); for the main session it also records the base branch
    p="$(arg "${2:--}")"; case "$p" in "~") p="$HOME";; "~/"*) p="$HOME/${p#\~/}";; esac
    [ -d "$p" ] || { echo "no such folder: $p"; exit 1; }
    p="$(cd "$p" && pwd)"
    mkdir -p "$FTK"; printf '%s' "$p" > "$PROJECT_FILE"
    if [ "$S" = ftk ] && git -C "$p" rev-parse --git-dir >/dev/null 2>&1; then
      git -C "$p" rev-parse --abbrev-ref HEAD > "$BASE_BRANCH_FILE"
    fi
    echo "project: $p" ;;
  put)        # put <b64 rel path>  <- base64 file content on stdin, saved under ~/.ftk/xfer
    f="$(xfer_path "$2")" || exit 2
    mkdir -p "$(dirname "$f")" && tr -d '\r\n ' | b64dec > "$f.part" && mv "$f.part" "$f" || { rm -f "$f.part"; echo "put failed"; exit 1; }
    echo "saved $f $(wc -c < "$f" | tr -d ' ') bytes sha256 $(sha256 "$f")" ;;
  get)        # get <b64 rel path>  -> base64 file content on stdout
    f="$(xfer_path "$2")" || exit 2
    [ -f "$f" ] || { echo "no such file: $f" >&2; exit 1; }
    base64 < "$f" ;;
  xfer)       # list ~/.ftk/xfer
    mkdir -p "$XFER"; echo "# $XFER"; (cd "$XFER" && find . -type f | sed 's|^\./||' | sort) ;;
  clone)      # clone <b64 url> <b64 branch|-> <b64 parent dir>  -> single-branch clone, sets the main project
    url="$(arg "$2")"; br="$(arg "$3")"; parent="$(arg "$4")"
    [ -n "$url" ] && [ -n "$parent" ] || { echo "usage: clone <url> <branch|-> <parent>"; exit 2; }
    if [ -n "$br" ]; then check_branch "$br" || exit 1; fi
    name="$(basename "${url%/}" .git)"; dir="$parent/$name"
    mkdir -p "$parent" || exit 1
    if [ -d "$dir/.git" ]; then
      echo "repo exists: $dir - fetching"; git -C "$dir" fetch origin || exit 1
      if [ -n "$br" ]; then checkout_branch "$dir" "$br" || exit 1; fi
    elif [ -n "$br" ] && git ls-remote --exit-code --heads "$url" "refs/heads/$br" >/dev/null 2>&1; then
      git clone --single-branch -b "$br" "$url" "$dir" || exit 1
    else
      git clone --single-branch "$url" "$dir" || exit 1
      if [ -n "$br" ]; then checkout_branch "$dir" "$br" || exit 1; fi
    fi
    mkdir -p "$FTK"; printf '%s' "$dir" > "$MAIN_PROJECT_FILE"
    git -C "$dir" rev-parse --abbrev-ref HEAD > "$BASE_BRANCH_FILE"
    echo "project: $dir"; git -C "$dir" log --oneline -1 ;;
  unbundle)   # unbundle <b64 bundle file> <b64 branch> <b64 dest dir>: single-branch clone from a git bundle, no origin
    bf="$(arg "${2:--}")"; br="$(arg "${3:--}")"; dest="$(arg "${4:--}")"
    case "$dest" in "~/"*) dest="$HOME/${dest#\~/}";; esac
    [ -f "$bf" ] && [ -n "$br" ] && [ -n "$dest" ] || { echo "usage: unbundle <bundle> <branch> <dest>"; exit 2; }
    check_branch "$br" || exit 1
    heads="$(git bundle list-heads "$bf" 2>/dev/null | awk '{print $2}')" || heads=""
    [ "$heads" = "refs/heads/$br" ] || { echo "ERROR: bundle must contain exactly refs/heads/$br, has: $heads"; exit 1; }
    if [ -d "$dest/.git" ]; then
      echo "repo exists: $dest - kept as is"
    else
      mkdir -p "$(dirname "$dest")" || exit 1
      git clone -q --single-branch -b "$br" "$bf" "$dest" || exit 1
      git -C "$dest" remote remove origin
      echo "unpacked: $dest ($(git -C "$dest" log --oneline -1))"
    fi
    mkdir -p "$FTK"; printf '%s' "$dest" > "$MAIN_PROJECT_FILE"; printf '%s\n' "$br" > "$BASE_BRANCH_FILE"
    echo "project: $dest" ;;
  new-lane)   # new-lane <name> <b64 branch>: own git worktree + own agent session "ftk-<name>"
    name="$2"; [[ "$name" =~ ^[a-z0-9][a-z0-9-]{0,30}$ ]] && [ "$name" != main ] || { echo "bad lane name (a-z 0-9 -)"; exit 2; }
    b="$(arg "${3:--}")"; [ -n "$b" ] || { echo "usage: new-lane <name> <b64 branch>"; exit 2; }
    check_branch "$b" || exit 1
    base="$(cat "$MAIN_PROJECT_FILE" 2>/dev/null)"; [ -d "$base/.git" ] || { echo "main project not set"; exit 1; }
    bb="$(cat "$BASE_BRANCH_FILE" 2>/dev/null)"; [ -n "$bb" ] || bb="$(git -C "$base" rev-parse --abbrev-ref HEAD)"
    wt="$(dirname "$base")/$(basename "$base")-$name"
    S="ftk-$name"; X="=$S"; P="=$S:"; PROJECT_FILE="$FTK/project-$S"
    if [ -d "$wt" ]; then
      echo "worktree exists: $wt"
    else
      if has_origin "$base"; then git -C "$base" fetch -q origin || exit 1; fi
      if git -C "$base" show-ref --verify -q "refs/remotes/origin/$bb"; then start="origin/$bb"; else start="$bb"; fi   # bundle clone: local base
      if on_origin "$base" "$b"; then
        fetch_exact "$base" "$b" || exit 1
        git -C "$base" worktree add -q --track -b "$b" "$wt" "origin/$b" || exit 1
      elif git -C "$base" show-ref --verify -q "refs/heads/$b"; then
        git -C "$base" worktree add -q "$wt" "$b" || exit 1
      else   # new lane branch from the base branch, NOT tracking it (no accidental push to $bb)
        git -C "$base" worktree add -q --no-track -b "$b" "$wt" "$start" || exit 1
      fi
      echo "worktree: $wt (branch $b)"
    fi
    mkdir -p "$FTK"; printf '%s' "$wt" > "$PROJECT_FILE"
    start_session ;;
  checkout)   # checkout <b64 branch> in the project folder
    d="$(project_dir)" || { echo "project not set"; exit 1; }
    checkout_branch "$d" "$(arg "${2:--}")" ;;
  git)        # branch, working tree and last commits of the project
    d="$(project_dir)" || { echo "project not set"; exit 1; }
    echo "# $d"; git -C "$d" status -sb; echo; git -C "$d" log --oneline -10 ;;
  set-topic)  # ntfy topic for notifications
    [[ "$2" =~ ^[A-Za-z0-9_-]{8,64}$ ]] || { echo "bad topic"; exit 2; }
    mkdir -p "$FTK"; printf '%s' "$2" > "$TOPIC_FILE"; echo "topic set" ;;
  notify)     # notify stop|waiting|ready [b64 text]  (Claude Code hooks call this; hook JSON on stdin)
    h="$(hostname -s 2>/dev/null || hostname)"
    if [ "$2" = "ready" ]; then notify_send "FTK host ready ($h)" "$(arg "${3:--}")"; exit 0; fi
    sn="${FTK_SESSION_NAME:-}"
    [[ "$sn" =~ ^ftk(-[a-z0-9-]+)?$ ]] || exit 0     # not an ftk agent (e.g. the colleague's own Claude)
    in=""; [ "$2" = "waiting" ] && [ ! -t 0 ] && in="$(head -c 65536)"   # hook JSON
    msg="$(printf '%s' "$in" | sed -n 's/.*"message" *: *"\([^"]*\)".*/\1/p' | head -1)"
    case "$2" in
      stop)    set_state "$sn" stop;    notify_send "FTK $sn finished a turn ($h)" "Check: ftk -s ${sn#ftk-} peek" ;;
      waiting) set_state "$sn" waiting; notify_send "FTK $sn needs you ($h)" "${msg:-Waiting for input.} Check: ftk peek" ;;
    esac
    exit 0 ;;
  install-hooks) # add Stop + Notification hooks to ~/.claude/settings.json (idempotent)
    python3 - "$SELF" <<'PY'
import json, os, shlex, sys
p = os.path.expanduser("~/.claude/settings.json")
os.makedirs(os.path.dirname(p), exist_ok=True)
try:
    s = json.load(open(p))
except FileNotFoundError:
    s = {}
hooks = s.setdefault("hooks", {})
for ev, arg in (("Stop", "stop"), ("Notification", "waiting")):
    lst = [g for g in hooks.get(ev, []) if not any("ftk-remote notify" in h.get("command", "") for h in g.get("hooks", []))]
    lst.append({"hooks": [{"type": "command", "command": shlex.quote(sys.argv[1]) + " notify " + arg}]})
    hooks[ev] = lst
json.dump(s, open(p, "w"), indent=2)
print("hooks installed in " + p)
PY
    ;;
  attach)     # read-only view
    exec tmux ${FTK_TMUX:+-L "$FTK_TMUX"} attach -r -t "$X" ;;
  drive)      # full control (you can type)
    exec tmux ${FTK_TMUX:+-L "$FTK_TMUX"} attach -t "$X" ;;
  *)
    echo "usage: ftk-remote [-s lane] peek|say|key|wait|log|status|lanes|run|start|restart|new-lane|clone|unbundle|checkout|git|setproject|put|get|xfer|set-topic|notify|install-hooks|attach|drive" ;;
esac
'@
$cmd = "echo $(B64 $remote) | base64 -d | tr -d '\r' > /usr/local/bin/ftk-remote && chmod 755 /usr/local/bin/ftk-remote"
if ((Wsl @('-u', 'root', '-e', 'sh', '-c', $cmd)) -ne 0) { throw 'Could not install ftk-remote in Ubuntu' }

# ---------- Step 6: repository + branch ----------
Mark 'Step 6/8 Repository'
$bundle = Join-Path $PSScriptRoot 'repo.bundle'
$provided = $false
if (Test-Path $bundle) {
    $name = ($RepoUrl.TrimEnd('/') -split '/')[-1] -replace '\.git$', ''
    if (-not $name) { $name = 'repo' }
    $branchB = if ($RepoBranch) { $RepoBranch } else { 'v2' }
    $bundleWsl = ((& wsl.exe -e wslpath -a ($bundle -replace '\\', '/')) | Out-String).Trim()
    $linuxHome = ((& wsl.exe -e sh -c 'echo $HOME') | Out-String).Trim()
    Write-Host "Unpacking the repo shipped with this kit ($branchB) ..."
    & wsl.exe -e /usr/local/bin/ftk-remote unbundle (B64 $bundleWsl) (B64 $branchB) (B64 "$linuxHome/Projects/$name")
    if ($LASTEXITCODE -ne 0) { Info 'Could not unpack repo.bundle - see the console output.'; exit 1 }
    $provided = $true
} else {
$provided = YesNo @"
Step 6/8 - Repository

Will your teammate send the repo to this PC? (recommended)

YES = your teammate copies the repo here over SSH. No git login needed here.
NO  = you clone it from a URL or pick a folder that is already here.
"@
}
if ($provided) {
    Write-Host 'Repo is ready (bundled) or will be provided by your teammate - skipping the clone.'
} else {
# git inside Ubuntu uses the Windows Git Credential Manager -> normal browser login for Azure DevOps / GitHub
$gcm = @("$env:ProgramFiles\Git\mingw64\bin\git-credential-manager.exe", "$env:ProgramFiles\Git\mingw64\libexec\git-core\git-credential-manager.exe") | Where-Object { Test-Path $_ } | Select-Object -First 1
if (-not $gcm) {
    Write-Host 'Installing Git for Windows (for its credential manager)...'
    try { & winget.exe install --id Git.Git -e --accept-source-agreements --accept-package-agreements } catch { }
    $gcm = @("$env:ProgramFiles\Git\mingw64\bin\git-credential-manager.exe", "$env:ProgramFiles\Git\mingw64\libexec\git-core\git-credential-manager.exe") | Where-Object { Test-Path $_ } | Select-Object -First 1
}
if ($gcm) {
    $gcmWsl = ((& wsl.exe -e wslpath -a ($gcm -replace '\\', '/')) | Out-String).Trim() -replace ' ', '\ '
    Wsl @('-e', 'git', 'config', '--global', 'credential.helper', $gcmWsl) | Out-Null
    Wsl @('-e', 'git', 'config', '--global', 'credential.https://dev.azure.com.useHttpPath', 'true') | Out-Null
}

$url = (AskOpt "Step 6/8 - Repository`n`nGit URL of the repo to clone.`nLeave EMPTY to use a folder that already exists." $RepoUrl) -replace '\s', ''
if (-not $url) {
    $fb = New-Object Windows.Forms.FolderBrowserDialog
    $fb.Description = 'Step 6/8 - Choose the existing project folder the agent will work in'
    if ($fb.ShowDialog($Owner) -ne 'OK') { Write-Host 'Cancelled.'; exit 1 }
    $wslDir = ((& wsl.exe -e wslpath -a ($fb.SelectedPath -replace '\\', '/')) | Out-String).Trim()
    if (-not $wslDir) { throw "Could not convert $($fb.SelectedPath) to a WSL path" }
    Wsl @('-e', '/usr/local/bin/ftk-remote', 'setproject', (B64 $wslDir)) | Out-Null
} else {
    $branch = (AskOpt "Step 6/8 - Branch`n`nBranch to work on (it is created if it does not exist yet).`nLeave EMPTY for the default branch." $RepoBranch) -replace '\s', ''
    # clone into the Linux file system (much faster than C:\ for the agent and tools)
    $linuxHome = ((& wsl.exe -e sh -c 'echo $HOME') | Out-String).Trim()
    $parent = "$linuxHome/Projects"
    $b64Branch = '-'
    if ($branch) { $b64Branch = B64 $branch }
    Write-Host "Cloning $url into $parent ... (a browser login window may appear)"
    # called directly (not piped) so git can ask for a login / host-key confirmation in this console
    & wsl.exe -e /usr/local/bin/ftk-remote clone (B64 $url) $b64Branch (B64 $parent)
    if ($LASTEXITCODE -ne 0) {
        Info "Could not clone / switch the branch - see the console output.`n`nTypical causes:`n- no access to the repo`n- uncommitted changes in an existing copy`n`nFix it and run this script again."
        exit 1
    }
    Info "Repo is ready in Ubuntu: $parent`n`nIn Windows Explorer it is under \\wsl.localhost\Ubuntu$($parent -replace '/', '\')"
}
}

# ---------- migration files shipped with the kit (into the Ubuntu home, where claude runs) ----------
function Copy-ToWsl([string]$src, [string]$dest, [string]$mode) {
    $b = [Convert]::ToBase64String([IO.File]::ReadAllBytes($src))
    $c = "mkdir -p `$(dirname $dest) && echo $b | base64 -d > $dest && chmod $mode $dest"   # no double quotes: PS 5.1 mangles them
    return (Wsl @('-e', 'sh', '-c', $c))
}
$mw = Join-Path $PSScriptRoot 'migration-worker.md'
if (Test-Path $mw) { if ((Copy-ToWsl $mw '$HOME/.claude/agents/migration-worker.md' '644') -eq 0) { Write-Host 'installed ~/.claude/agents/migration-worker.md' } }
$me = Join-Path $PSScriptRoot 'setup-migration-env.sh'
if (Test-Path $me) { if ((Copy-ToWsl $me '$HOME/.ftk/setup-migration-env.sh' '755') -eq 0) { Write-Host 'copied ~/.ftk/setup-migration-env.sh (not run)' } }

# ---------- Step 7: notifications, session, autostart ----------
Mark 'Step 7/8 Session'
if ($NtfyTopic) {
    Wsl @('-e', '/usr/local/bin/ftk-remote', 'set-topic', $NtfyTopic) | Out-Null
    Wsl @('-e', '/usr/local/bin/ftk-remote', 'install-hooks') | Out-Null
}

# WSL stops when no wsl.exe is running - this task keeps it (and tmux) alive.
# RunLevel Highest = same elevation as admin SSH sessions, so both see the same tmux.
$userId = "$env:USERDOMAIN\$env:USERNAME"
$action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument '-NoProfile -WindowStyle Hidden -Command "wsl.exe -e /usr/local/bin/ftk-remote start keepalive"'
$trigger = New-ScheduledTaskTrigger -AtLogOn -User $userId
$principal = New-ScheduledTaskPrincipal -UserId $userId -LogonType Interactive -RunLevel Highest
$settings = New-ScheduledTaskSettingsSet -ExecutionTimeLimit ([TimeSpan]::Zero) -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries
Register-ScheduledTask -TaskName 'FTK Agent Keepalive' -Action $action -Trigger $trigger -Principal $principal -Settings $settings -Force -ErrorAction Stop | Out-Null
Start-ScheduledTask -TaskName 'FTK Agent Keepalive'
Start-Sleep -Seconds 5

if (YesNo "Keep the PC awake while plugged in?`n(Recommended - a sleeping PC drops the connection.)") {
    & powercfg.exe /change standby-timeout-ac 0
}

Step @"
Step 7/8 - First start of the agent

A window will open with the agent session.
1. If Claude asks you to log in - log in.
2. If it asks to trust the folder - say Yes.
3. Then just close that window (the agent keeps running).

Click OK to open it.
"@
Wsl @('-e', '/usr/local/bin/ftk-remote', 'start') | Out-Null   # make sure the session exists before attaching
if (-not $Auto) { Start-Process wsl.exe -ArgumentList '-e', '/usr/local/bin/ftk-remote', 'drive' }
else { Write-Host 'Auto mode: log in to Claude once with:  wsl -e /usr/local/bin/ftk-remote drive' }

# ---------- Step 8: connection line ----------
Mark 'Step 8/8 Done'
$line = "FTK|$ip|$env:USERNAME|windows"
Set-Clipboard -Value $line
Wsl @('-e', '/usr/local/bin/ftk-remote', 'notify', 'ready', (B64 $line)) | Out-Null
Info @"
Step 8/8 - Done!

Your teammate has been notified automatically.
If not, send them this line (already copied to the clipboard):

$line

Notes:
- Keep the PC on and Tailscale connected.
- The agent starts automatically when you log in to Windows.
"@
Write-Host "Connection line: $line"
}
catch {
    $line = $_.InvocationInfo.ScriptLineNumber
    Info "Setup failed at: $global:FtkStep (script line $line)`n`n$($_.Exception.Message)`n`nFull log: $LogDir\setup.log`nFix the problem (a restart often helps) and run the script again."
    exit 1
}
