# FTK Remote - CLIENT setup for Windows (run on YOUR PC).
# Creates an SSH key, connects to the teammate's machine over Tailscale
# and installs the `ftk` command (peek / say / key / watch / ...).
# Safe to run again at any time. Start it with client-setup-windows.cmd.

# 'Continue' on purpose: in PS 5.1 'Stop' turns any stderr line of a native exe into a fatal error.
$ErrorActionPreference = 'Continue'
[Console]::OutputEncoding = [Text.Encoding]::UTF8

# ---------- always run as 64-bit PowerShell ----------
# A 32-bit parent (e.g. an x86 pwsh) starts 32-bit powershell: ProgramFiles points to "Program Files (x86)",
# and DISM/Add-WindowsCapability and wsl.exe do not work under WOW64. Relaunch through Sysnative.
if ([Environment]::Is64BitOperatingSystem -and -not [Environment]::Is64BitProcess) {
    $ps64 = Join-Path $env:windir 'Sysnative\WindowsPowerShell\v1.0\powershell.exe'
    Start-Process $ps64 -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`""
    exit
}
$PF = if ($env:ProgramW6432) { $env:ProgramW6432 } else { $env:ProgramFiles }   # real "Program Files"

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName Microsoft.VisualBasic
$Title = 'FTK Remote - Client setup (Windows)'
$Owner = New-Object Windows.Forms.Form -Property @{ TopMost = $true }

function Step([string]$m) {
    $r = [Windows.Forms.MessageBox]::Show($Owner, $m, $Title, 'OKCancel', 'Information')
    if ($r -ne 'OK') { Write-Host 'Cancelled.'; exit 1 }
}
function Info([string]$m) { [void][Windows.Forms.MessageBox]::Show($Owner, $m, $Title, 'OK', 'Information') }
function Ask([string]$m, [string]$def) {
    $r = [Microsoft.VisualBasic.Interaction]::InputBox($m, $Title, $def)
    if ([string]::IsNullOrWhiteSpace($r)) { Write-Host 'Cancelled.'; exit 1 }
    return $r.Trim()
}
function Write-NoBom([string]$path, [string]$text) {
    [IO.File]::WriteAllText($path, $text, (New-Object Text.UTF8Encoding($false)))
}

$sshDir  = Join-Path $HOME '.ssh'
$keyFile = Join-Path $sshDir 'ftk_ed25519'
$ftkDir  = Join-Path $HOME '.ftk'
$binDir  = Join-Path $ftkDir 'bin'
$ntfy    = 'https://ntfy.sh'
$topicFile = Join-Path $ftkDir 'ntfy-topic'
$topic = ''
if (Test-Path $topicFile) { $topic = (Get-Content $topicFile -Raw).Trim() }

# ---------- Step 0: welcome ----------
Step @"
This connects you to your teammate's Claude Code agent.

Steps:
1. Tailscale (private network)
2. Create your SSH key and send it to your teammate
3. Paste the connection line your teammate sends back
4. Install the 'ftk' command and test the connection

Order: YOU run this first -> teammate runs the host script -> you finish here.
Click OK to start.
"@

# ---------- Step 1: Tailscale ----------
$ts = Join-Path $PF 'Tailscale\tailscale.exe'
if (-not (Test-Path $ts)) {
    Write-Host 'Installing Tailscale...'
    try { & winget.exe install --id Tailscale.Tailscale -e --accept-source-agreements --accept-package-agreements } catch { }
    # winget can return before the MSI has placed tailscale.exe - wait for it (up to 90 s)
    for ($i = 0; $i -lt 90 -and -not (Test-Path $ts); $i++) { Start-Sleep -Seconds 1 }
    if (-not (Test-Path $ts)) {
        Start-Process 'https://tailscale.com/download/windows'
        Step "Step 1/4 - Tailscale`n`nThe download page is open. Install Tailscale, then click OK."
    }
}
Step @"
Step 1/4 - Tailscale

Open Tailscale (tray icon) and log in. Wait until it shows Connected.

If your teammate uses a DIFFERENT Tailscale account, they will send you a Share invite link - open it and accept.

Click OK to continue.
"@

# ---------- Step 2: SSH key ----------
if (-not (Get-Command ssh.exe -ErrorAction SilentlyContinue)) {
    Info "OpenSSH Client is missing.`n`nSettings -> System -> Optional features -> Add a feature -> 'OpenSSH Client'.`nThen run this script again."
    exit 1
}
if (-not (Test-Path $sshDir)) { New-Item -ItemType Directory -Path $sshDir | Out-Null }
if (-not (Test-Path $keyFile)) {
    # Start-Process passes the raw command line, so -N "" really is an empty passphrase
    Start-Process ssh-keygen.exe -ArgumentList "-t ed25519 -q -N `"`" -C ftk-$env:USERNAME -f `"$keyFile`"" -Wait -NoNewWindow
}
$pub = (Get-Content "$keyFile.pub" -Raw).Trim()
Set-Clipboard -Value $pub
Step @"
Step 2/4 - Your SSH key

Your public key is COPIED to the clipboard:

$pub

1. Send it to your teammate (Slack / Teams).
2. They run the HOST setup script and paste it when asked.
3. They send you back a line that starts with FTK|

Click OK when you have that line.
"@

# ---------- Step 3: connection line ----------
$line = ''
try { $clip = "$(Get-Clipboard | Select-Object -First 1)".Trim(); if ($clip -like 'FTK|*') { $line = $clip } } catch { }
if (-not $line -and $topic) {  # no line copied: take the newest one the host posted to ntfy
    try {
        $raw = (Invoke-WebRequest -UseBasicParsing -TimeoutSec 10 "$ntfy/$topic/json?poll=1&since=all").Content
        if ($raw -is [byte[]]) { $raw = [Text.Encoding]::UTF8.GetString($raw) }
        $msgs = @($raw -split "`n" | Where-Object { $_ } | ForEach-Object { $_ | ConvertFrom-Json } | Where-Object { $_.message -like 'FTK|*' })
        if ($msgs.Count) { $line = $msgs[-1].message }
    } catch { }
}
while ($true) {
    $line = (Ask "Step 3/4 - Connection line`n`nPaste the line your teammate sent you.`nExample: FTK|100.101.102.103|kolya|mac" $line) -replace '\s', ''
    $p = $line.Split('|')
    if ($p.Count -eq 4 -and $p[0] -eq 'FTK' -and $p[1] -and $p[2] -and ($p[3] -eq 'mac' -or $p[3] -eq 'windows')) { break }
    Info "That line is not valid. It must look like FTK|<ip>|<user>|mac or FTK|<ip>|<user>|windows"
}
$hostIp = $p[1]; $user = $p[2]; $os = $p[3]

# ---------- Step 4: ssh config + ftk command ----------
$cfg = Join-Path $sshDir 'config'
$old = ''
if (Test-Path $cfg) { $old = [IO.File]::ReadAllText($cfg) }
$old = [regex]::Replace($old, '(?s)# >>> ftk >>>.*?# <<< ftk <<<\r?\n?', '')
$keyPath = $keyFile -replace '\\', '/'
# no ControlMaster: Windows OpenSSH does not support it
$block = @"
# >>> ftk >>>
Host ftk
  HostName $hostIp
  User $user
  IdentityFile "$keyPath"
  IdentitiesOnly yes
  ServerAliveInterval 30
# <<< ftk <<<

"@
if ($old -and -not $old.EndsWith("`n")) { $old += "`n" }
Write-NoBom $cfg (($old + $block) -replace "`r`n", "`n")

if ($os -eq 'windows') { $remote = 'powershell -NoProfile -ExecutionPolicy Bypass -File C:\ProgramData\ftk\ftk-remote.ps1' } else { $remote = '~/.ftk/ftk-remote' }
if (-not (Test-Path $binDir)) { New-Item -ItemType Directory -Path $binDir -Force | Out-Null }
Write-NoBom (Join-Path $ftkDir 'client.conf') ((@{ remote = $remote; topic = $topic; ntfy = $ntfy } | ConvertTo-Json -Compress) + "`n")

$ftkPs1 = @'
# ftk - talk to the Claude Code agent(s) on the teammate's machine.
[Console]::OutputEncoding = [Text.Encoding]::UTF8
$confPath = if ($env:FTK_CONF) { $env:FTK_CONF } else { Join-Path (Join-Path $HOME '.ftk') 'client.conf' }
$conf = Get-Content $confPath -Raw | ConvertFrom-Json
$sshExe = if ($env:FTK_SSH) { $env:FTK_SSH } else { 'ssh' }
$scpExe = if ($env:FTK_SCP) { $env:FTK_SCP } else { 'scp' }
$TO = @('-o', 'ConnectTimeout=15', '-o', 'ServerAliveInterval=15', '-o', 'ServerAliveCountMax=4')   # a stalled transfer fails instead of hanging
$a = @($args | ForEach-Object { [string]$_ })
$sel = ''
if ($a.Count -ge 2 -and $a[0] -eq '-s') {
    if ($a[1] -notmatch '^[a-z0-9][a-z0-9-]{0,30}$') { Write-Host 'usage: ftk -s <lane> <command>'; exit 2 }
    $sel = "-s $($a[1])"; $a = @($a | Select-Object -Skip 2)
}
$R = "$($conf.remote) $sel".Trim()
function B64([string]$s) { return [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($s)) }
function Num([string]$n) { if ($n -and $n -notmatch '^\d+$') { Write-Host 'number expected'; exit 2 } }
$cmd = if ($a.Count -gt 0) { $a[0] } else { 'help' }
$rest = @($a | Select-Object -Skip 1)
$r1 = if ($rest.Count) { $rest[0] } else { '' }
switch -Regex ($cmd) {
    '^peek$' { Num $r1; & $sshExe ftk "$R peek $r1"; break }
    '^monitor$' { & $sshExe ftk "$($conf.remote) monitor"; break }
    '^show$' { & $sshExe ftk "$($conf.remote) show-monitor"; break }
    '^version$' { Write-Host "client kit $(if (Test-Path (Join-Path (Join-Path $HOME '.ftk') 'kit-version')) { (Get-Content (Join-Path (Join-Path $HOME '.ftk') 'kit-version') -Raw).Trim() } else { '?' })"; & $sshExe ftk "$($conf.remote) version"; break }
    '^update-host$' { & $sshExe ftk "$($conf.remote) update"; break }
    '^setup-log$' { Num $r1; & $sshExe ftk "$R setup-log $r1"; break }
    '^wait$' { Num $r1; & $sshExe ftk "$R wait $r1"; break }
    '^log$' {
        Num $r1; $n = if ($r1) { $r1 } else { '30' }
        $raw = if ($rest.Count -gt 1 -and $rest[1] -eq 'raw') { 'raw' } else { '' }
        & $sshExe ftk "$R log $n $raw"; break
    }
    '^(status|start|restart|git|lanes)$' { & $sshExe ftk "$R $cmd"; break }
    '^(say|run)$' {
        if (-not $rest.Count) { Write-Host "usage: ftk $cmd `"text`""; exit 2 }
        & $sshExe ftk "$R $cmd $(B64 ($rest -join ' '))"; break
    }
    '^key$' {
        if ($r1 -notmatch '^[A-Za-z0-9-]+$') { Write-Host 'usage: ftk key Enter|Escape|Up|Down|1|2|y|n|C-c'; exit 2 }
        & $sshExe ftk "$R key $r1"; break
    }
    '^checkout$' {
        if (-not $r1) { Write-Host 'usage: ftk checkout <branch>'; exit 2 }
        & $sshExe ftk "$R checkout $(B64 $r1)"; break
    }
    '^setproject$' {
        if (-not $r1) { Write-Host 'usage: ftk [-s LANE] setproject <host path, ~/ allowed>'; exit 2 }
        & $sshExe ftk "$R setproject $(B64 $r1)"; break
    }
    '^put$' {
        if ($rest.Count -lt 2 -or -not (Test-Path -LiteralPath $r1 -PathType Leaf) -or [string]$rest[1] -notmatch '^[A-Za-z0-9._/-]+$' -or ([string]$rest[1]).Contains('..') -or ([string]$rest[1]).StartsWith('/')) { Write-Host 'usage: ftk put <local file> <path under ~/.ftk/xfer>'; exit 2 }
        $full = (Resolve-Path -LiteralPath $r1).Path
        Write-Host "local $((Get-Item -LiteralPath $full).Length) bytes sha256 $((Get-FileHash -Algorithm SHA256 -LiteralPath $full).Hash.ToLower())"
        & $sshExe @TO ftk "$R xfer-prep $(B64 $rest[1])" | Out-Null; if ($LASTEXITCODE -ne 0) { Write-Host 'put failed (prepare)'; exit 1 }
        & $scpExe -q @TO $full "ftk:.ftk/xfer/$($rest[1])"; if ($LASTEXITCODE -ne 0) { Write-Host 'put failed (scp)'; exit 1 }
        & $sshExe @TO ftk "$R xfer-hash $(B64 $rest[1])"; break
    }
    '^get$' {
        if ($rest.Count -lt 2 -or $r1 -notmatch '^[A-Za-z0-9._/-]+$' -or $r1.Contains('..')) { Write-Host 'usage: ftk get <path under ~/.ftk/xfer> <local file>'; exit 2 }
        $dest = [IO.Path]::GetFullPath((Join-Path (Get-Location) $rest[1]))
        & $scpExe -q @TO "ftk:.ftk/xfer/$r1" $dest; if ($LASTEXITCODE -ne 0) { Write-Host 'get failed'; exit 1 }
        Write-Host "saved $dest $((Get-Item -LiteralPath $dest).Length) bytes sha256 $((Get-FileHash -Algorithm SHA256 -LiteralPath $dest).Hash.ToLower())"; exit 0
    }
    '^xfer$' { & $sshExe ftk "$R xfer"; break }
    '^new-lane$' {
        if ($r1 -notmatch '^[a-z0-9][a-z0-9-]{0,30}$' -or $rest.Count -lt 2) { Write-Host 'usage: ftk new-lane <name> <branch>'; exit 2 }
        & $sshExe ftk "$($conf.remote) new-lane $r1 $(B64 $rest[1])"; break
    }
    '^watch$' { Write-Host 'Read-only view. Detach: Ctrl+B then D'; & $sshExe -t ftk "$R attach"; break }
    '^drive$' { Write-Host 'FULL control. Detach: Ctrl+B then D'; & $sshExe -t ftk "$R drive"; break }
    '^shell$' { & $sshExe ftk; break }
    '^events$' {
        if (-not $conf.topic) { Write-Host 'no ntfy topic configured'; exit 1 }
        $since = if ($r1) { $r1 } else { '1h' }
        if ($since -notmatch '^([0-9]+[smhd]|all)$') { Write-Host 'usage: ftk events [30m|2h|1d|all]'; exit 2 }
        $raw = (Invoke-WebRequest -UseBasicParsing -TimeoutSec 15 "$($conf.ntfy)/$($conf.topic)/json?poll=1&since=$since").Content
        if ($raw -is [byte[]]) { $raw = [Text.Encoding]::UTF8.GetString($raw) }
        $raw -split "`n" | Where-Object { $_ } | ForEach-Object { $_ | ConvertFrom-Json } | Where-Object { $_.event -eq 'message' } | ForEach-Object {
            '{0} | {1} | {2}' -f ([DateTimeOffset]::FromUnixTimeSeconds($_.time).LocalDateTime.ToString('HH:mm:ss')), $_.title, $_.message
        }
        exit 0
    }
    default {
        Write-Host @"
ftk [-s LANE] COMMAND      (no -s = main agent; -s a1 = lane "a1")
  peek [N]          last N lines of the agent screen (default 200)
  say "text"        type a message to the agent and press Enter
  wait [SEC]        block until the agent finished its turn / needs input (default 600 s)
  key NAME          press a key: Enter, Escape, Up, Down, 1, 2, y, n, C-c
  run "cmd"         run a command in the project folder, print output + [exit N]
  status            session / claude / state / project
  log [N] [raw]     last N transcript messages as text (raw = jsonl)
  setup-log [N]     the host's setup log (Windows host)
  git               branch, changed files, last 10 commits
  checkout BR       switch the project to branch BR (refuses with uncommitted changes)
  start | restart   start / restart the agent session
  watch | drive     live view read-only / full control (Ctrl+B D to leave)
ftk new-lane NAME BRANCH   new git worktree + agent session for parallel work
ftk lanes                  all agent sessions with state and folder
ftk monitor                all agents: status, time, steps, what each is doing now
ftk show                   open the read-only progress window on the host's screen
ftk put FILE REL           upload FILE to ~/.ftk/xfer/REL on the host (prints sha256)
ftk get REL FILE           download ~/.ftk/xfer/REL to FILE
ftk xfer                   list ~/.ftk/xfer on the host
ftk [-s LANE] setproject PATH   point the agent at a folder on the host (~/ allowed)
ftk shell                  plain ssh to the host
ftk version                client kit + host helper versions
ftk update-host            update the host helper from GitHub now
ftk events [1h]            ntfy notifications: ready / turn finished / needs you
"@
        exit 0
    }
}
exit $LASTEXITCODE
'@
Write-NoBom (Join-Path $binDir 'ftk.ps1') $ftkPs1
Write-NoBom (Join-Path $binDir 'ftk.cmd') "@powershell.exe -NoProfile -ExecutionPolicy Bypass -File `"%~dp0ftk.ps1`" %*`r`n"

$userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
if (-not $userPath) { $userPath = '' }
if (($userPath.Split(';') | Where-Object { $_ -eq $binDir }).Count -eq 0) {
    [Environment]::SetEnvironmentVariable('Path', ($userPath.TrimEnd(';') + ';' + $binDir).TrimStart(';'), 'User')
}
$env:Path = "$env:Path;$binDir"

# ---------- MCP server for Claude Code (ftk-bridge) ----------
$kitMcp = Join-Path $PSScriptRoot 'ftk-mcp.py'
$m = [regex]::Match((Get-Content (Join-Path $PSScriptRoot 'ftk-remote.ps1') -Raw -ErrorAction SilentlyContinue), "\`$FtkVersion = '([0-9.]+)'")
if ($m.Success) { Write-NoBom (Join-Path $ftkDir 'kit-version') $m.Groups[1].Value }
if (Test-Path $kitMcp) {
    Copy-Item $kitMcp (Join-Path $ftkDir 'ftk-mcp.py') -Force
    $py = if (Get-Command py.exe -ErrorAction SilentlyContinue) { @('py.exe', '-3') } elseif (Get-Command python.exe -ErrorAction SilentlyContinue) { @('python.exe') } else { @() }
    if ((Get-Command claude -ErrorAction SilentlyContinue) -and $py.Count) {
        & claude mcp remove ftk-bridge -s user 2>&1 | Out-Null
        & claude mcp add ftk-bridge -s user -e "FTK_BIN=$(Join-Path $binDir 'ftk.cmd')" -- @py (Join-Path $ftkDir 'ftk-mcp.py') 2>&1 | Out-Null
        if ($LASTEXITCODE -eq 0) { Write-Host 'MCP server ftk-bridge registered for Claude Code (restart Claude Code sessions to load it)' } else { Write-Host 'WARNING: could not register the MCP server' }
    } else { Write-Host 'Claude Code CLI or Python not found - MCP server not registered' }
}

# ---------- test ----------
Write-Host "Testing connection to $hostIp ..."
$out = (& ssh.exe -o BatchMode=yes -o StrictHostKeyChecking=accept-new -o ConnectTimeout=15 ftk "$remote status" 2>&1 | Out-String).Trim()
if ($LASTEXITCODE -eq 0) {
    Info @"
Connected!

$out

Commands (open a NEW terminal window):
  ftk peek       - what is the agent doing
  ftk say "..."  - send it a message
  ftk key 1      - answer a prompt
  ftk watch      - live view
  ftk help       - everything else
"@
} else {
    Info @"
Connection failed:

$out

Check:
1. Tailscale is Connected on BOTH machines (and the Share invite is accepted).
2. Your teammate pasted YOUR key (starts with ssh-ed25519).
3. Remote Login / OpenSSH Server is on at their side.
Then run this script again.
"@
    exit 1
}
