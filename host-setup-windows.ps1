# FTK Remote - HOST setup for Windows (run on the colleague's PC).
# Lets a teammate connect over SSH (via Tailscale) and watch / talk to
# the Claude Code agents, which run natively on Windows in headless mode (no WSL, no tmux).
# Safe to run again at any time.
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

# ---------- always run as 64-bit PowerShell ----------
# A 32-bit parent (e.g. an x86 pwsh) starts 32-bit powershell: ProgramFiles points to "Program Files (x86)",
# and DISM/Add-WindowsCapability does not work under WOW64. Relaunch through Sysnative.
if ([Environment]::Is64BitOperatingSystem -and -not [Environment]::Is64BitProcess) {
    $ps64 = Join-Path $env:windir 'Sysnative\WindowsPowerShell\v1.0\powershell.exe'
    Start-Process $ps64 -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`""
    exit
}
$PF = if ($env:ProgramW6432) { $env:ProgramW6432 } else { $env:ProgramFiles }   # real "Program Files"

# ---------- run as Administrator ----------
$me = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
$Auto = ($env:FTK_AUTO -eq '1')   # non-interactive: no dialogs, defaults everywhere (for an agent running the setup)
if (-not $me.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    if ($Auto) { Write-Host 'ERROR: FTK_AUTO=1 needs an elevated (Administrator) PowerShell.'; exit 1 }
    Start-Process (Join-Path $env:windir 'System32\WindowsPowerShell\v1.0\powershell.exe') -Verb RunAs -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`""
    exit
}

# full log of every run, readable by an agent helping the user
$LogDir = Join-Path $env:ProgramData 'ftk'
New-Item -ItemType Directory -Force -Path $LogDir | Out-Null
try { Start-Transcript -Path (Join-Path $LogDir 'setup.log') -Append | Out-Null } catch { }
$global:FtkStep = 'start'
# live progress for the teammate: ntfy topic from the config line or from a file "ntfy-topic" next to this script
if (-not $NtfyTopic -and (Test-Path (Join-Path $PSScriptRoot 'ntfy-topic'))) { $NtfyTopic = (Get-Content (Join-Path $PSScriptRoot 'ntfy-topic') -Raw).Trim() }
if ($NtfyTopic -notmatch '^[A-Za-z0-9_-]{8,64}$') { $NtfyTopic = '' }
function Progress([string]$title, [string]$body) {
    if (-not $NtfyTopic) { return }
    try { Invoke-RestMethod -Method Post -Uri "https://ntfy.sh/$NtfyTopic" -Headers @{ Title = "FTK setup ($env:COMPUTERNAME): $title"; Tags = 'gear' } -Body ([Text.Encoding]::UTF8.GetBytes($body)) -TimeoutSec 8 | Out-Null } catch { }
}
function Mark([string]$name) { $global:FtkStep = $name; Write-Host "=== $name ($(Get-Date -Format HH:mm:ss))"; Progress $name 'started' }
function RebootPending {
    if (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending') { return $true }
    if (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired') { return $true }
    if (Test-Path (Join-Path $env:windir 'WinSxS\pending.xml')) { return $true }       # servicing transaction not applied yet
    try { if ((New-Object -ComObject Microsoft.Update.SystemInfo).RebootRequired) { return $true } } catch { }
    return $false
}

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName Microsoft.VisualBasic
$Title = 'FTK Remote - Host setup (Windows)'
$Owner = New-Object Windows.Forms.Form -Property @{ TopMost = $true }

function Step([string]$m) {
    Write-Host "[dialog] $m"
    if (-not $Auto) { Progress 'waiting for the user' $m }
    if ($Auto) { Write-Host "== $($m.Split([char]10)[0])"; return }
    $r = [Windows.Forms.MessageBox]::Show($Owner, $m, $Title, 'OKCancel', 'Information')
    if ($r -ne 'OK') { Write-Host 'Cancelled.'; exit 1 }
}
function Info([string]$m) { Write-Host "[dialog] $m"; if ($Auto) { Write-Host "-- $m"; return }; [void][Windows.Forms.MessageBox]::Show($Owner, $m, $Title, 'OK', 'Information') }
function YesNo([string]$m) { Write-Host "[dialog yes/no] $m"; if (-not $Auto) { Progress 'waiting for the user (yes/no)' $m }; if ($Auto) { Write-Host "?? $($m.Split([char]10)[0]) -> Yes (auto)"; return $true }; return ([Windows.Forms.MessageBox]::Show($Owner, $m, $Title, 'YesNo', 'Question') -eq 'Yes') }
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

try {
# ---------- Step 0: welcome ----------
Step @"
This will set up your PC so your teammate can connect to your Claude Code agent.

Steps:
1. Tailscale (private network, no port forwarding)
2. OpenSSH Server (only reachable through Tailscale)
3. Add your teammate's SSH key  -> your teammate can connect from here on
4. Git for Windows
5. Claude Code (skipped if it is already installed)
6. Repository
7. Check that the agent answers
8. Send the connection line back to your teammate

Have the SSH key your teammate sent you ready. Click OK to start.
"@

# ---------- preflight: unfinished Windows updates break the OpenSSH install ----------
Mark 'Preflight'
if (RebootPending) {
    $go = YesNo @"
Windows has unfinished updates waiting for a restart.

While they are pending, OpenSSH Server often cannot be installed
(the script would then keep asking for a restart).

Recommended: click NO, then Start -> Power -> 'Update and restart',
and run this script again after Windows has finished updating.

Continue anyway? (YES = continue now, NO = stop and update first)
"@
    if (-not $go) { Write-Host 'Stopped: finish Windows updates first (Start -> Power -> Update and restart).'; exit 0 }
}

# ---------- Step 1: Tailscale ----------
Mark 'Step 1/8 Tailscale'
$ts = Join-Path $PF 'Tailscale\tailscale.exe'
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
        # no sshd after the install = Windows did not apply it (pending update / servicing), even when no flag says so
        if ($true) {
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
    }
}
Set-Service sshd -StartupType Automatic -ErrorAction Stop
# keys only: no password logins on this SSH server
$sshdCfg = Join-Path $env:ProgramData 'ssh\sshd_config'
if (Test-Path $sshdCfg) {
    $c = [IO.File]::ReadAllText($sshdCfg)
    $c2 = [regex]::Replace($c, '(?m)^\s*#?\s*PasswordAuthentication\s+\S+', 'PasswordAuthentication no')
    if ($c2 -notmatch '(?m)^PasswordAuthentication no') { $c2 = "PasswordAuthentication no`r`n" + $c2 }
    if ($c2 -ne $c) { [IO.File]::WriteAllText($sshdCfg, $c2, (New-Object Text.UTF8Encoding($false))); Write-Host 'sshd: password logins switched off (keys only)' }
}
Restart-Service sshd -ErrorAction SilentlyContinue
Start-Service sshd -ErrorAction Stop
# allow port 22 only from Tailscale addresses
$rule = Get-NetFirewallRule -Name 'OpenSSH-Server-In-TCP' -ErrorAction SilentlyContinue
if ($rule) {
    Set-NetFirewallRule -Name 'OpenSSH-Server-In-TCP' -Enabled True -RemoteAddress '100.64.0.0/10'
} else {
    New-NetFirewallRule -Name 'OpenSSH-Server-In-TCP' -DisplayName 'OpenSSH Server (Tailscale only)' -Direction Inbound -Protocol TCP -LocalPort 22 -Action Allow -RemoteAddress '100.64.0.0/10' | Out-Null
}

# ---------- Step 3: teammate's SSH key ----------
Mark 'Step 3/8 SSH key'
$clip = ''
try { $clip = "$(Get-Clipboard | Select-Object -First 1)".Trim() } catch { }
# teammate.pub shipped next to this script wins over the clipboard
$pubFile = Join-Path $PSScriptRoot 'teammate.pub'
if (Test-Path $pubFile) { $clip = "$(Get-Content $pubFile | Select-Object -First 1)".Trim() }
$key = ''
if ($clip -match '^(ssh-ed25519|ssh-rsa|ecdsa-\S+) ') { $key = $clip }
while ($true) {
    if ($Auto -and -not $key) { Write-Host 'ERROR (auto): no teammate.pub next to the script and no key in the clipboard'; exit 1 }
    $key = Ask "Step 3/8 - Teammate's SSH key`n`nPaste the public key your teammate sent you.`nIt starts with 'ssh-ed25519 ...'" $key
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

# ---------- install the remote helper ----------
$Helper = Join-Path $env:ProgramData 'ftk\ftk-remote.ps1'
$remote = @'
# ftk-remote.ps1 - Windows-native host helper (no WSL, no tmux).
# Agents run HEADLESS: every `say` starts one turn `claude -p --output-format stream-json --resume <id>`
# in a detached process that survives the SSH session; wait/peek/log read its JSON stream.
# The client calls:  powershell -NoProfile -ExecutionPolicy Bypass -File C:\ProgramData\ftk\ftk-remote.ps1 [-s lane] <cmd> [arg...]
# Arguments are plain words or base64 (no quoting problems). Windows PowerShell 5.1 compatible, ASCII only.
$ErrorActionPreference = 'Continue'
$FtkVersion = '2026.11.12.5'   # bump on every release; hosts update themselves from GitHub
$FtkRaw = if ($env:FTK_UPDATE_URL) { $env:FTK_UPDATE_URL } else { 'https://raw.githubusercontent.com/max200pl/ftk-remote/main/ftk-remote.ps1' }
try { [Console]::OutputEncoding = New-Object Text.UTF8Encoding($false) } catch { }
$U8 = New-Object Text.UTF8Encoding($false)
$IsWin = ($env:OS -eq 'Windows_NT')
$FTK = if ($env:FTK_HOME) { $env:FTK_HOME } else { Join-Path $HOME '.ftk' }
$DenyPrefix = 'migrate/operator-records'    # private branch: never fetched / checked out here

# ---- lane selection: no -s = main agent "ftk", -s a1 = "ftk-a1"
$a = @($args)
$S = 'ftk'
if ($a.Count -ge 2 -and $a[0] -eq '-s') {
    if ($a[1] -notmatch '^[a-z0-9][a-z0-9-]{0,30}$') { Write-Output 'bad lane name (a-z 0-9 -)'; exit 2 }
    if ($a[1] -ne 'main') { $S = "ftk-$($a[1])" }
    $a = @($a | Select-Object -Skip 2)
}
function A([int]$i) { if ($a.Count -gt $i) { return [string]$a[$i] } else { return '' } }
$cmd = A 0

$MainProjectFile = Join-Path $FTK 'project'
$ProjectFile = if ($S -eq 'ftk') { $MainProjectFile } else { Join-Path $FTK "project-$S" }
$BaseBranchFile = Join-Path $FTK 'base-branch'
$TopicFile = Join-Path $FTK 'ntfy-topic'
$Xfer = Join-Path $FTK 'xfer'
$Workspace = Join-Path $FTK 'workspace'
$LaneDir = Join-Path (Join-Path $FTK 'lanes') $S
$Ntfy = if ($env:FTK_NTFY_URL) { $env:FTK_NTFY_URL } else { 'https://ntfy.sh' }

function Write-Utf8([string]$path, [string]$text) {
    $d = Split-Path $path -Parent; if ($d -and -not (Test-Path $d)) { New-Item -ItemType Directory -Force -Path $d | Out-Null }
    [IO.File]::WriteAllText($path, $text, $U8)
}
function Read-Lines([string]$path) {   # read while another process is writing (the turn writer shares ReadWrite)
    if (-not (Test-Path -LiteralPath $path)) { return @() }
    try {
        $fs = New-Object IO.FileStream($path, 'Open', 'Read', 'ReadWrite')
        $sr = New-Object IO.StreamReader($fs, $U8)
        $txt = $sr.ReadToEnd(); $sr.Close()
        return @($txt -split "`r?`n" | Where-Object { $_ -ne '' })
    } catch { return @() }
}
function Verify-Release([string]$file, [string]$sig, [string]$signers) {   # ssh-keygen -Y verify, message on stdin
    if (-not (Test-Path $sig)) { return $false }
    $kg = if ($IsWin) { Join-Path $env:windir 'System32\OpenSSH\ssh-keygen.exe' } else { 'ssh-keygen' }
    $psi = New-Object Diagnostics.ProcessStartInfo
    $psi.FileName = $kg
    $psi.Arguments = '-Y verify -f "' + $signers + '" -I ftk-release -n ftk-update -s "' + $sig + '"'
    $psi.UseShellExecute = $false; $psi.RedirectStandardInput = $true; $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true; $psi.CreateNoWindow = $true
    try {
        $p = [Diagnostics.Process]::Start($psi)
        $b = [IO.File]::ReadAllBytes($file); $p.StandardInput.BaseStream.Write($b, 0, $b.Length); $p.StandardInput.Close()
        [void]$p.StandardOutput.ReadToEnd(); [void]$p.StandardError.ReadToEnd(); $p.WaitForExit()
        return ($p.ExitCode -eq 0)
    } catch { return $false }
}
function Say([string]$t) { [Console]::Out.WriteLine($t) }   # inside functions: print without polluting the return value
function Read-Text([string]$path) { if (Test-Path -LiteralPath $path) { return ([IO.File]::ReadAllText($path)).Trim() } else { return '' } }
function B64Dec([string]$s) { if (-not $s -or $s -eq '-') { return '' }; return $U8.GetString([Convert]::FromBase64String($s)) }
function Now { return [DateTimeOffset]::UtcNow.ToUnixTimeSeconds() }
function Expand-Home([string]$p) {
    if ($p -eq '~') { return $HOME }
    if ($p.StartsWith('~/') -or $p.StartsWith('~\')) { return (Join-Path $HOME $p.Substring(2)) }
    return $p
}
function Project-Dir { $d = Read-Text $ProjectFile; if ($d -and (Test-Path -LiteralPath $d -PathType Container)) { return $d }; return '' }
function Lane-Name([string]$s) { if ($s -eq 'ftk') { return 'main' } else { return $s.Substring(4) } }
function Proc-Alive([string]$pidText) { if (-not $pidText) { return $false }; return [bool](Get-Process -Id ([int]$pidText) -ErrorAction SilentlyContinue) }

# ---- state: "<word> <unix time>" in ~/.ftk/state-<session>; busy | stop | error | stopped
function Set-State([string]$s, [string]$word) { Write-Utf8 (Join-Path $FTK "state-$s") "$word $(Now)`n" }
function Get-StateWord([string]$s) {
    $w = (Read-Text (Join-Path $FTK "state-$s")) -split ' ' | Select-Object -First 1
    if ($w -eq 'busy') {   # runner died without writing a final state?
        $ld = Join-Path (Join-Path $FTK 'lanes') $s
        if (-not (Proc-Alive (Read-Text (Join-Path $ld 'runner.pid')))) { Set-State $s 'error'; return 'error' }
    }
    return $w
}

function Notify([string]$title, [string]$body) {
    $t = Read-Text $TopicFile; if (-not $t) { return }
    try { Invoke-RestMethod -Method Post -Uri "$Ntfy/$t" -Headers @{ Title = $title; Tags = 'robot' } -Body $U8.GetBytes($body) -TimeoutSec 10 | Out-Null } catch { }
}

function Claude-Path {
    if ($env:FTK_CLAUDE) { return $env:FTK_CLAUDE }
    $p = Read-Text (Join-Path $FTK 'claude-path'); if ($p -and (Test-Path -LiteralPath $p)) { return $p }
    foreach ($c in @((Join-Path $HOME '.local\bin\claude.exe'), (Join-Path $HOME '.local/bin/claude'))) { if (Test-Path -LiteralPath $c) { return $c } }
    $g = Get-Command claude -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($g) { return $g.Source }
    return ''
}
function Bash-Path {
    if ($env:FTK_BASH) { return $env:FTK_BASH }
    if (-not $IsWin) { return '/bin/bash' }
    $pf = if ($env:ProgramW6432) { $env:ProgramW6432 } else { $env:ProgramFiles }
    foreach ($c in @((Join-Path $pf 'Git\bin\bash.exe'), (Join-Path ${env:ProgramFiles(x86)} 'Git\bin\bash.exe'))) { if ($c -and (Test-Path -LiteralPath $c)) { return $c } }
    return ''
}
function Quote-Arg([string]$s) { if ($s -match '[\s"]') { return '"' + ($s -replace '"', '\"') + '"' } else { return $s } }

# start a process that is NOT tied to this SSH session (Windows sshd kills the session's job on disconnect)
function Start-Detached([string]$file, [string[]]$argv) {
    if ($IsWin) {
        $cl = (Quote-Arg $file) + ' ' + (($argv | ForEach-Object { Quote-Arg $_ }) -join ' ')
        $r = Invoke-CimMethod -ClassName Win32_Process -MethodName Create -Arguments @{ CommandLine = $cl; CurrentDirectory = $FTK }
        return [int]$r.ProcessId
    }
    $p = Start-Process -FilePath $file -ArgumentList $argv -PassThru
    return $p.Id
}

# ---- render a claude stream-json file as plain text lines
function Short([string]$s, [int]$k) { $s = ($s -replace '\s+', ' ').Trim(); if ($s.Length -gt $k) { return $s.Substring(0, $k) + ' ...' } else { return $s } }
function Render-Stream([string]$path) {
    $out = New-Object Collections.Generic.List[string]
    if (-not (Test-Path -LiteralPath $path)) { return $out }
    foreach ($line in (Read-Lines $path)) {
        if (-not $line.Trim()) { continue }
        try { $e = $line | ConvertFrom-Json } catch { continue }
        switch ([string]$e.type) {
            'user' {
                $c = $e.message.content
                if ($c -is [string]) { $out.Add("user: $(Short $c 600)"); break }
                foreach ($it in @($c)) {
                    if ($it.type -eq 'tool_result') {
                        $r = $it.content
                        if ($r -isnot [string]) { $r = (@($r) | ForEach-Object { $_.text }) -join ' ' }
                        $tag = if ($it.is_error) { 'tool_result (error)' } else { 'tool_result' }
                        $out.Add("${tag}: $(Short ([string]$r) 300)")
                    } elseif ($it.type -eq 'text') { $out.Add("user: $(Short $it.text 600)") }
                }
            }
            'assistant' {
                foreach ($it in @($e.message.content)) {
                    if ($it.type -eq 'text' -and $it.text.Trim()) { $out.Add("assistant: $(Short $it.text 600)") }
                    elseif ($it.type -eq 'tool_use') {
                        $inp = $it.input; $what = $inp.command; if (-not $what) { $what = $inp.file_path }; if (-not $what) { $what = ($inp | ConvertTo-Json -Compress -Depth 4) }
                        $out.Add("tool_use $($it.name): $(Short ([string]$what) 300)")
                    }
                }
            }
            'result' {
                $out.Add("result ($($e.subtype)$(if ($e.is_error) { ', error' })): $(Short ([string]$e.result) 600)")
                foreach ($d in @($e.permission_denials)) { if ($d) { $out.Add("permission denied: $($d.tool_name) - allow it in .claude/settings.local.json") } }
            }
        }
    }
    return $out
}

# ---- snapshot of all agents for the progress window / monitor-text
function All-Lanes {
    $r = @()
    if ((Test-Path $MainProjectFile) -or (Test-Path (Join-Path (Join-Path $FTK 'lanes') 'ftk'))) { $r += 'ftk' }
    $r += @(Get-ChildItem -Path $FTK -Filter 'project-ftk-*' -File -ErrorAction SilentlyContinue | ForEach-Object { $_.Name.Substring(8) })
    return $r
}
function Lane-Info([string]$s) {
    $ld = Join-Path (Join-Path $FTK 'lanes') $s
    $raw = Read-Text (Join-Path $FTK "state-$s")
    $word = Get-StateWord $s; if (-not $word) { $word = 'idle' }
    $since = 0; $parts = $raw -split ' '; if ($parts.Count -ge 2 -and $parts[1] -match '^\d+$') { $since = (Now) - [int64]$parts[1] }
    $pf = if ($s -eq 'ftk') { $MainProjectFile } else { Join-Path $FTK "project-$s" }
    $steps = 0; $now = ''
    $out = Join-Path $ld 'out.jsonl'
    if (Test-Path -LiteralPath $out) {
        foreach ($line in (Read-Lines $out)) {
            if ($line -match '"type":\s*"tool_use"') { $steps += ([regex]::Matches($line, '"type":\s*"tool_use"')).Count }
        }
        $r = @(Render-Stream $out | Where-Object { $_ -match '^(tool_use|assistant|result)' })
        if ($r.Count) { $now = $r[-1] }
    }
    $label = switch ($word) { 'busy' { 'working' } 'stop' { 'finished turn' } 'stopped' { 'stopped' } 'error' { 'error' } default { $word } }
    return [pscustomobject]@{ Name = (Lane-Name $s); State = $word; Label = $label; Seconds = $since; Steps = $steps; Now = $now; Folder = $(if (Read-Text $pf) { Split-Path (Read-Text $pf) -Leaf } else { '' }); Lane = $s }
}
function Fmt-Time([int64]$sec) { if ($sec -lt 60) { return "${sec}s" }; if ($sec -lt 3600) { return ('{0}m {1:00}s' -f [math]::Floor($sec / 60), ($sec % 60)) }; return ('{0}h {1:00}m' -f [math]::Floor($sec / 3600), [math]::Floor(($sec % 3600) / 60)) }
function Nice-Now([string]$t) {
    if ($t -match '^tool_use (\S+): (.*)$') {
        $tool = $Matches[1]; $what = $Matches[2]
        switch -Regex ($tool) {
            '^(Bash|PowerShell)$' { return "Running: $what" }
            '^Read$' { return "Reading: $what" }
            '^(Write|Edit|MultiEdit)$' { return "Editing: $what" }
            '^(Grep|Glob)$' { return "Searching: $what" }
            default { return "${tool}: $what" }
        }
    }
    if ($t -match '^assistant: (.*)$') { return "Says: $($Matches[1])" }
    if ($t -match '^result') { return 'Turn finished' }
    return $t
}

function Check-Branch([string]$b) {
    & git check-ref-format --branch $b 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) { Say "ERROR: bad branch name: $b"; return $false }
    if ($b.StartsWith($DenyPrefix)) { Say "ERROR: branch '$b' is not allowed on this machine"; return $false }
    return $true
}
function Has-Origin([string]$d) { & git -C $d remote get-url origin 2>&1 | Out-Null; return ($LASTEXITCODE -eq 0) }
function On-Origin([string]$d, [string]$b) {
    if (-not (Has-Origin $d)) { return $false }
    & git -C $d ls-remote --exit-code --heads origin "refs/heads/$b" 2>&1 | Out-Null; return ($LASTEXITCODE -eq 0)
}
function Has-Ref([string]$d, [string]$r) { & git -C $d show-ref --verify -q $r 2>&1 | Out-Null; return ($LASTEXITCODE -eq 0) }
function Fetch-Exact([string]$d, [string]$b) {   # exact refspec for this one branch (tracking works), then fetch only it
    $rs = "+refs/heads/${b}:refs/remotes/origin/$b"
    $have = @(& git -C $d config --get-all remote.origin.fetch)
    if ($have -notcontains $rs) { & git -C $d config --add remote.origin.fetch $rs }
    & git -C $d fetch -q origin $rs; return ($LASTEXITCODE -eq 0)
}
function Checkout-Branch([string]$d, [string]$b) {
    if (-not (Check-Branch $b)) { return $false }
    if (@(& git -C $d status --porcelain).Count -gt 0) { Say "ERROR: uncommitted changes in $d - not switching branch"; return $false }
    if (Has-Origin $d) { & git -C $d fetch -q origin; if ($LASTEXITCODE -ne 0) { return $false } }
    if (On-Origin $d $b) { if (-not (Fetch-Exact $d $b)) { return $false } }
    if (Has-Ref $d "refs/heads/$b") {
        & git -C $d checkout -q $b; if ($LASTEXITCODE -ne 0) { return $false }
        & git -C $d merge --ff-only -q "origin/$b" 2>&1 | Out-Null
    } elseif (Has-Ref $d "refs/remotes/origin/$b") {
        & git -C $d checkout -q -b $b --track "origin/$b"; if ($LASTEXITCODE -ne 0) { return $false }
    } else {
        & git -C $d checkout -q -b $b; if ($LASTEXITCODE -ne 0) { return $false }
        Say "branch '$b' does not exist on origin - created locally from $(& git -C $d rev-parse --short HEAD)"
    }
    Say "branch: $(& git -C $d rev-parse --abbrev-ref HEAD)"
    return $true
}
function Fix-Owner([string]$path) {   # an elevated run creates Administrators-owned files; git then refuses them for the user
    if (-not $IsWin -or -not (Test-Path -LiteralPath $path)) { return }
    $me = [Security.Principal.WindowsIdentity]::GetCurrent().Name
    & icacls.exe $path /setowner $me /T /C /Q 2>&1 | Out-Null
}
function Xfer-Path([string]$b64) {
    $r = B64Dec $b64
    if (-not $r -or $r -notmatch '^[A-Za-z0-9._/-]+$' -or $r.StartsWith('/') -or $r.Contains('..')) { return '' }
    return (Join-Path $Xfer ($r -replace '/', [IO.Path]::DirectorySeparatorChar))
}
function Stop-Turn {
    $killed = $false
    foreach ($f in @('claude.pid', 'runner.pid')) {
        $p = Read-Text (Join-Path $LaneDir $f)
        if (Proc-Alive $p) {
            if ($IsWin) { & taskkill.exe /PID $p /T /F 2>&1 | Out-Null } else { Stop-Process -Id ([int]$p) -Force -ErrorAction SilentlyContinue }
            $killed = $true
        }
    }
    return $killed
}

switch ($cmd) {
'say' {
    if ((Get-StateWord $S) -eq 'busy') { Write-Output 'busy: the agent is still working - use wait, or key C-c to stop it'; exit 3 }
    $text = B64Dec (A 1); if (-not $text) { Write-Output 'usage: say <b64 text>'; exit 2 }
    if (-not (Claude-Path)) { Write-Output 'ERROR: claude not found on this machine'; exit 1 }
    Write-Utf8 (Join-Path $LaneDir 'msg.txt') $text
    Remove-Item -LiteralPath (Join-Path $LaneDir 'out.jsonl') -ErrorAction SilentlyContinue
    Set-State $S 'busy'
    $me = (Get-Process -Id $PID).Path
    $rp = Start-Detached $me @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $PSCommandPath, '-s', (Lane-Name $S), '_turn')
    Write-Utf8 (Join-Path $LaneDir 'runner.pid') "$rp"
    Write-Output 'sent'
}
'_turn' {   # internal: one headless turn, run detached
    $msg = Join-Path $LaneDir 'msg.txt'; $outF = Join-Path $LaneDir 'out.jsonl'
    $proj = Project-Dir; if (-not $proj) { New-Item -ItemType Directory -Force -Path $Workspace | Out-Null; $proj = $Workspace }
    $claude = Claude-Path
    $cargs = @('-p', '--output-format', 'stream-json', '--verbose')
    $sid = Read-Text (Join-Path $LaneDir 'session-id'); if ($sid) { $cargs += @('--resume', $sid) }
    $psi = New-Object Diagnostics.ProcessStartInfo
    if ($claude -match '\.(cmd|bat)$') { $psi.FileName = 'cmd.exe'; $psi.Arguments = '/d /c ' + (Quote-Arg $claude) + ' ' + ($cargs -join ' ') }
    else { $psi.FileName = $claude; $psi.Arguments = ($cargs | ForEach-Object { Quote-Arg $_ }) -join ' ' }
    $psi.WorkingDirectory = $proj; $psi.UseShellExecute = $false; $psi.CreateNoWindow = $true
    $psi.RedirectStandardInput = $true; $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true
    $psi.StandardOutputEncoding = $U8; $psi.StandardErrorEncoding = $U8
    $code = 1
    try {
        $p = [Diagnostics.Process]::Start($psi)
        Write-Utf8 (Join-Path $LaneDir 'claude.pid') "$($p.Id)"
        $bytes = $U8.GetBytes([IO.File]::ReadAllText($msg, $U8))
        $p.StandardInput.BaseStream.Write($bytes, 0, $bytes.Length); $p.StandardInput.Close()
        $errTask = $p.StandardError.ReadToEndAsync()
        $wfs = New-Object IO.FileStream($outF, 'Create', 'Write', 'ReadWrite')   # readers (peek, monitor) may read while we write
        $w = New-Object IO.StreamWriter($wfs, $U8)
        while ($null -ne ($line = $p.StandardOutput.ReadLine())) { $w.WriteLine($line); $w.Flush() }
        $w.Close(); $p.WaitForExit(); $code = $p.ExitCode
        $err = $errTask.Result; if ($err) { Write-Utf8 (Join-Path $LaneDir 'stderr.txt') $err }
    } catch { Write-Utf8 (Join-Path $LaneDir 'stderr.txt') "$($_.Exception.Message)" }
    $final = 'error'
    if (Test-Path -LiteralPath $outF) {
        [IO.File]::AppendAllText((Join-Path $LaneDir 'history.jsonl'), (((Read-Lines $outF) -join "`n") + "`n"), $U8)
        foreach ($line in (Read-Lines $outF)) {
            try { $e = $line | ConvertFrom-Json } catch { continue }
            if ($e.session_id) { Write-Utf8 (Join-Path $LaneDir 'session-id') ([string]$e.session_id) }
            if ($e.type -eq 'result' -and -not $e.is_error -and $code -eq 0) { $final = 'stop' }
        }
    }
    if ((Get-StateWord $S) -ne 'stopped') { Set-State $S $final }
    Remove-Item -LiteralPath (Join-Path $LaneDir 'claude.pid') -ErrorAction SilentlyContinue
    $h = [Environment]::MachineName
    if ($final -eq 'stop') { Notify "FTK $S finished a turn ($h)" "Check: ftk -s $(Lane-Name $S) peek" }
    else { Notify "FTK $S stopped with an error ($h)" "Check: ftk -s $(Lane-Name $S) peek" }
}
'wait' {
    $to = A 1; if (-not $to) { $to = '600' }
    if ($to -notmatch '^\d+$' -or [int64]$to -gt 86400) { Write-Output 'bad timeout'; exit 2 }
    $end = (Now) + [int64]$to
    while ($true) {
        $st = Get-StateWord $S
        if ($st -and $st -ne 'busy' -and $st -ne 'started') { Write-Output $st; exit 0 }
        if ((Now) -ge $end) { Write-Output "timeout ($(if ($st) { $st } else { 'unknown' }))"; exit 124 }
        Start-Sleep -Seconds 1
    }
}
'peek' {   # the current / last turn as text
    $n = A 1; if ($n -notmatch '^\d+$') { $n = '200' }
    $st = Get-StateWord $S
    if ($st -eq 'busy') { Write-Output '(the agent is working on this turn...)' }
    $lines = @(Render-Stream (Join-Path $LaneDir 'out.jsonl'))
    if ($lines.Count -eq 0) { Write-Output '(no output yet)' } else { $lines | Select-Object -Last ([int]$n) }
    $errF = Join-Path $LaneDir 'stderr.txt'
    if ($st -eq 'error' -and (Test-Path $errF)) { Write-Output "stderr: $(Short (Read-Text $errF) 600)" }
}
'log' {   # all turns of this agent
    $n = A 1; if ($n -notmatch '^\d+$') { $n = '30' }
    $hf = Join-Path $LaneDir 'history.jsonl'
    if (-not (Test-Path $hf)) { Write-Output 'no transcript yet'; break }
    Write-Output "# $hf"
    if ((A 2) -eq 'raw') { Read-Lines $hf | Select-Object -Last ([int]$n) }
    else { @(Render-Stream $hf) | Select-Object -Last ([int]$n) }
}
'key' {
    $k = A 1
    if ($k -notmatch '^[A-Za-z0-9-]+$') { Write-Output 'bad key name'; exit 2 }
    if ($k -eq 'C-c' -or $k -eq 'Escape') {
        if (Stop-Turn) { Set-State $S 'stopped'; Write-Output 'stopped the current turn' } else { Write-Output 'nothing is running' }
        break
    }
    Write-Output "key '$k' is not used on a Windows host: the agent runs headless and cannot be asked for permission."
    Write-Output 'Allow the tools it needs in the project''s .claude/settings.local.json, then say again. Stop a turn with: key C-c'
    exit 2
}
'status' {
    $st = Get-StateWord $S
    Write-Output "session: $S (headless, Windows)"
    Write-Output "state: $(if ($st) { $st } else { 'idle' })$(if (Proc-Alive (Read-Text (Join-Path $LaneDir 'claude.pid'))) { ' (claude running)' })"
    Write-Output "conversation: $(if (Read-Text (Join-Path $LaneDir 'session-id')) { Read-Text (Join-Path $LaneDir 'session-id') } else { '(new)' })"
    Write-Output "claude: $(if (Claude-Path) { Claude-Path } else { 'NOT FOUND' })"
    Write-Output "project: $(if (Read-Text $ProjectFile) { Read-Text $ProjectFile } else { '(not set)' })"
}
'lanes' {
    $files = @()
    if (Test-Path $MainProjectFile) { $files += Get-Item $MainProjectFile }
    $files += @(Get-ChildItem -Path $FTK -Filter 'project-ftk-*' -File -ErrorAction SilentlyContinue)
    foreach ($f in $files) {
        $s = if ($f.Name -eq 'project') { 'ftk' } else { $f.Name.Substring(8) }
        $w = Get-StateWord $s; if (-not $w) { $w = 'idle' }
        '{0,-14} {1,-8} {2}' -f $s, $w, (Read-Text $f.FullName)
    }
}
'run' {    # run <b64 command>: bash (Git Bash) in the project dir, no stdin; prints output + [exit N]
    $d = Project-Dir; if (-not $d) { New-Item -ItemType Directory -Force -Path $Xfer | Out-Null; $d = $Xfer }
    $c = B64Dec (A 1); if (-not $c) { Write-Output 'usage: run <b64 command>'; exit 2 }
    $bash = Bash-Path; if (-not $bash) { Write-Output 'ERROR: Git Bash not found (install Git for Windows)'; exit 1 }
    $script = Join-Path $FTK "run-$S.sh"
    $dq = ($d -replace '\\', '/') -replace "'", "'\''"
    Write-Utf8 $script ("exec 2>&1`ncd '$dq' || exit 97`n" + ($c -replace "`r`n", "`n") + "`n")
    $psi = New-Object Diagnostics.ProcessStartInfo
    $psi.FileName = $bash; $psi.Arguments = (Quote-Arg ($script -replace '\\', '/'))
    $psi.UseShellExecute = $false; $psi.RedirectStandardInput = $true; $psi.RedirectStandardOutput = $true
    $psi.StandardOutputEncoding = $U8; $psi.CreateNoWindow = $true; $psi.WorkingDirectory = $d
    $p = [Diagnostics.Process]::Start($psi); $p.StandardInput.Close()
    while ($null -ne ($line = $p.StandardOutput.ReadLine())) { Write-Output $line }
    $p.WaitForExit(); $rc = $p.ExitCode
    Remove-Item -LiteralPath $script -ErrorAction SilentlyContinue
    Write-Output "[exit $rc]"; exit $rc
}
'setup-log' {   # the host setup's transcript (works before Git / Claude are installed)
    $n = A 1; if ($n -notmatch '^\d+$') { $n = '60' }
    $f = Join-Path $env:ProgramData 'ftk\setup.log'
    if (-not $env:ProgramData -or -not (Test-Path -LiteralPath $f)) { Write-Output 'no setup log on this machine'; break }
    Get-Content -LiteralPath $f -Tail ([int]$n)
}
{ $_ -eq 'monitor' -or $_ -eq 'monitor-text' } {   # one text snapshot of all agents (what the progress window shows)
    $l = @(All-Lanes | ForEach-Object { Lane-Info $_ })
    $busy = @($l | Where-Object { $_.State -eq 'busy' }).Count
    Write-Output ("{0} agent(s), {1} working" -f $l.Count, $busy)
    foreach ($x in $l) { Write-Output ('{0,-8} {1,-13} {2,8}  steps {3,-3} {4}' -f $x.Name, $x.Label, (Fmt-Time $x.Seconds), $x.Steps, (Short (Nice-Now $x.Now) 90)) }
}
'show-monitor' {   # open the progress window on the logged-in user's desktop (from SSH: via an interactive task)
    if (-not $IsWin) { Write-Output 'show-monitor works on a Windows host only'; exit 2 }
    $ps = Join-Path $env:windir 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $act = New-ScheduledTaskAction -Execute $ps -Argument ('-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "' + $PSCommandPath + '" autostart')
    $who = [Security.Principal.WindowsIdentity]::GetCurrent().Name
    $pr = New-ScheduledTaskPrincipal -UserId $who -LogonType Interactive
    Register-ScheduledTask -TaskName 'FTK Agents window' -Action $act -Principal $pr -Force | Out-Null
    Start-ScheduledTask -TaskName 'FTK Agents window'
    Write-Output 'progress window opened on the host desktop (if the user is logged in)'
}
'monitor-window' {   # read-only progress window on this computer's desktop
    Add-Type -AssemblyName System.Windows.Forms; Add-Type -AssemblyName System.Drawing
    $appT = 'System.Windows.Forms.Application' -as [type]; $appT::EnableVisualStyles()
    $f = New-Object Windows.Forms.Form
    $f.Text = 'FTK - Claude agents on this computer'; $f.Size = New-Object Drawing.Size(860, 520); $f.StartPosition = 'CenterScreen'
    $fst = 'System.Drawing.FontStyle' -as [type]; $bold = [Enum]::Parse($fst, 'Bold'); $regular = [Enum]::Parse($fst, 'Regular')
    $f.Font = New-Object Drawing.Font('Segoe UI', [single]9.5, $regular)
    $head = New-Object Windows.Forms.Label; $head.Dock = 'Top'; $head.Height = 34; $head.Font = New-Object Drawing.Font('Segoe UI', [single]12, $bold); $head.Padding = New-Object Windows.Forms.Padding(8, 6, 0, 0)
    $bar = New-Object Windows.Forms.ProgressBar; $bar.Dock = 'Top'; $bar.Height = 14; $bar.Style = 'Marquee'; $bar.MarqueeAnimationSpeed = 30
    $lv = New-Object Windows.Forms.ListView; $lv.Dock = 'Top'; $lv.Height = 170; $lv.View = 'Details'; $lv.FullRowSelect = $true; $lv.HideSelection = $false
    foreach ($c in @(@('Agent', 90), @('Status', 110), @('Time', 80), @('Steps', 60), @('Now doing', 480))) { [void]$lv.Columns.Add($c[0], $c[1]) }
    $box = New-Object Windows.Forms.TextBox; $box.Dock = 'Fill'; $box.Multiline = $true; $box.ReadOnly = $true; $box.ScrollBars = 'Vertical'; $box.Font = New-Object Drawing.Font('Consolas', [single]9, $regular)
    $foot = New-Object Windows.Forms.Label; $foot.Dock = 'Bottom'; $foot.Height = 24; $foot.Padding = New-Object Windows.Forms.Padding(8, 4, 0, 0)
    $foot.Text = 'Read-only view. Your teammate drives the agents remotely. You can close this window any time - the agents keep working.'
    $f.Controls.Add($box); $f.Controls.Add($lv); $f.Controls.Add($bar); $f.Controls.Add($head); $f.Controls.Add($foot)
    $script:sel = ''
    $lv.Add_SelectedIndexChanged({ if ($lv.SelectedItems.Count) { $script:sel = $lv.SelectedItems[0].Tag } })
    $refresh = {
        $l = @(All-Lanes | ForEach-Object { Lane-Info $_ })
        $busy = @($l | Where-Object { $_.State -eq 'busy' })
        $head.Text = if ($busy.Count) { "$($busy.Count) of $($l.Count) agent(s) working..." } elseif ($l.Count) { "All $($l.Count) agent(s) idle - waiting for the next task" } else { 'No agents yet' }
        $bar.Style = if ($busy.Count) { 'Marquee' } else { 'Continuous' }; if (-not $busy.Count) { $bar.Value = $bar.Maximum }
        $lv.BeginUpdate(); $lv.Items.Clear()
        foreach ($x in $l) {
            $it = New-Object Windows.Forms.ListViewItem($x.Name); $it.Tag = $x.Lane
            [void]$it.SubItems.Add($x.Label); [void]$it.SubItems.Add((Fmt-Time $x.Seconds)); [void]$it.SubItems.Add([string]$x.Steps); [void]$it.SubItems.Add((Short (Nice-Now $x.Now) 120))
            if ($x.State -eq 'busy') { $it.ForeColor = 'DarkGreen' } elseif ($x.State -eq 'error') { $it.ForeColor = 'DarkRed' }
            [void]$lv.Items.Add($it); if ($x.Lane -eq $script:sel) { $it.Selected = $true }
        }
        $lv.EndUpdate()
        $show = $script:sel; if (-not $show -and $busy.Count) { $show = $busy[0].Lane }; if (-not $show -and $l.Count) { $show = $l[0].Lane }
        if ($show) {
            $lines = @(Render-Stream (Join-Path (Join-Path (Join-Path $FTK 'lanes') $show) 'out.jsonl') | Select-Object -Last 14 | ForEach-Object { Short (Nice-Now $_) 160 })
            $box.Text = "[$(Lane-Name $show)] current / last turn:`r`n" + ($lines -join "`r`n")
        }
    }
    $t = New-Object Windows.Forms.Timer; $t.Interval = 2000; $t.Add_Tick($refresh); $t.Start()
    & $refresh
    [void]$f.ShowDialog()
}
'version' { Write-Output $FtkVersion }
'update' {   # update [quiet]: install a newer helper from GitHub ONLY if it is signed by the teammate's key
    $quiet = ((A 1) -eq 'quiet')
    if (Test-Path (Join-Path $FTK 'no-update')) { if (-not $quiet) { Write-Output 'updates are switched off on this host (~/.ftk/no-update)' }; break }
    $signers = Join-Path $FTK 'allowed_signers'
    if (-not (Test-Path $signers)) { if (-not $quiet) { Write-Output 'update refused: no trusted release key on this host (~/.ftk/allowed_signers)' }; break }
    $tmp = Join-Path ([IO.Path]::GetTempPath()) ("ftk-remote-" + [guid]::NewGuid().ToString('N') + '.ps1')
    try {
        Invoke-WebRequest -UseBasicParsing -Uri $FtkRaw -OutFile $tmp -TimeoutSec 20
        Invoke-WebRequest -UseBasicParsing -Uri ($FtkRaw + '.sig') -OutFile ($tmp + '.sig') -TimeoutSec 20
    } catch { Remove-Item $tmp, ($tmp + '.sig') -ErrorAction SilentlyContinue; if (-not $quiet) { Write-Output "update check failed: $($_.Exception.Message)" }; break }
    $done = {
        param($msg) Remove-Item $tmp, ($tmp + '.sig') -ErrorAction SilentlyContinue; if ($msg) { Write-Output $msg }
    }
    if (-not (Verify-Release $tmp ($tmp + '.sig') $signers)) { & $done 'update REFUSED: the signature does not match the trusted release key'; break }
    $txt = [IO.File]::ReadAllText($tmp)
    $m = [regex]::Match($txt, "\`$FtkVersion = '([0-9.]+)'")
    $errs = $null; [void][System.Management.Automation.Language.Parser]::ParseFile($tmp, [ref]$null, [ref]$errs)
    if (-not $m.Success -or $errs) { & $done $(if ($quiet) { '' } else { 'update skipped: downloaded file is not a valid helper' }); break }
    $new = $m.Groups[1].Value
    if ([version]$new -le [version]$FtkVersion) { & $done $(if ($quiet) { '' } else { "up to date ($FtkVersion)" }); break }
    try {
        Copy-Item $PSCommandPath ($PSCommandPath + '.bak') -Force
        Copy-Item $tmp $PSCommandPath -Force
        & $done "updated $FtkVersion -> $new (signed; previous kept for: rollback)"
    } catch { & $done "update failed (no write access to $PSCommandPath): $($_.Exception.Message)" }
}
'rollback' {   # go back to the helper that was installed before the last update
    $bak = $PSCommandPath + '.bak'
    if (-not (Test-Path $bak)) { Write-Output 'nothing to roll back to'; exit 1 }
    Copy-Item $bak $PSCommandPath -Force; Write-Output 'rolled back to the previous helper'
}
'trust-signer' {   # trust-signer <b64 public key>: the key whose signature releases need
    $k = (B64Dec (A 1)).Trim()
    if ($k -notmatch '^(ssh-ed25519|ssh-rsa|ecdsa-sha2-\S+) [A-Za-z0-9+/=]+') { Write-Output 'bad public key'; exit 2 }
    $parts = $k -split ' '
    Write-Utf8 (Join-Path $FTK 'allowed_signers') ('ftk-release namespaces="ftk-update" ' + $parts[0] + ' ' + $parts[1] + "`n")
    Write-Output 'release signing key trusted'
}
'autostart' {   # what the desktop / startup shortcut runs: update quietly, then show the progress window
    $ps = Join-Path $env:windir 'System32\WindowsPowerShell\v1.0\powershell.exe'
    & $ps -NoProfile -ExecutionPolicy Bypass -File $PSCommandPath update quiet | Out-Null
    & $ps -NoProfile -ExecutionPolicy Bypass -File $PSCommandPath monitor-window
}
'install-shortcuts' {   # "FTK Agents" on the Desktop and in Startup (opens at every logon)
    if (-not $IsWin) { Write-Output 'Windows only'; exit 2 }
    $ps = Join-Path $env:windir 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $sh = New-Object -ComObject WScript.Shell
    foreach ($dir in @([Environment]::GetFolderPath('Desktop'), [Environment]::GetFolderPath('Startup'))) {
        # WScript.Shell cannot save to non-ANSI paths (e.g. a Cyrillic OneDrive desktop): save to temp, then move
        $tmpL = Join-Path ([IO.Path]::GetTempPath()) ('ftk-' + [guid]::NewGuid().ToString('N') + '.lnk')
        $lnk = $sh.CreateShortcut($tmpL)
        $lnk.TargetPath = $ps
        $lnk.Arguments = '-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "' + $PSCommandPath + '" autostart'
        $lnk.Description = 'Claude agents on this computer: progress (read-only); also checks for updates'
        $lnk.IconLocation = "$env:windir\System32\shell32.dll,22"
        $lnk.Save()
        Move-Item -LiteralPath $tmpL -Destination (Join-Path $dir 'FTK Agents.lnk') -Force
        Write-Output "shortcut: $(Join-Path $dir 'FTK Agents.lnk')"
    }
    # let the logged-in user update the helper (the folder was created by an elevated setup)
    $me = [Security.Principal.WindowsIdentity]::GetCurrent().Name
    & icacls.exe (Split-Path $PSCommandPath -Parent) /grant "${me}:(OI)(CI)M" /C /Q 2>&1 | Out-Null
}
'start' { New-Item -ItemType Directory -Force -Path $LaneDir | Out-Null; Write-Output "ready: $S (headless - the agent runs when you say something)" }
'restart' {
    if (Stop-Turn) { Write-Output 'stopped the running turn' }
    Remove-Item -LiteralPath (Join-Path $LaneDir 'session-id') -ErrorAction SilentlyContinue
    Set-State $S 'stop'
    Write-Output "new conversation for $S on the next say"
}
'setproject' {
    $p = Expand-Home (B64Dec (A 1))
    if (-not $p -or -not (Test-Path -LiteralPath $p -PathType Container)) { Write-Output "no such folder: $p"; exit 1 }
    $p = (Resolve-Path -LiteralPath $p).Path
    Write-Utf8 $ProjectFile $p
    if ($S -eq 'ftk') { $b = & git -C $p rev-parse --abbrev-ref HEAD 2>$null; if ($LASTEXITCODE -eq 0 -and $b) { Write-Utf8 $BaseBranchFile "$b`n" } }
    Write-Output "project: $p"
}
'put' {
    $f = Xfer-Path (A 1); if (-not $f) { Write-Output 'bad path (letters, digits . _ - /, relative, no ..)'; exit 2 }
    $data = [Convert]::FromBase64String((([Console]::In.ReadToEnd()) -replace '\s', ''))
    $dir = Split-Path $f -Parent; if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
    [IO.File]::WriteAllBytes($f, $data)
    $sha = (Get-FileHash -Algorithm SHA256 -LiteralPath $f).Hash.ToLower()
    Write-Output "saved $f $($data.Length) bytes sha256 $sha"
}
'get' {
    $f = Xfer-Path (A 1); if (-not $f) { [Console]::Error.WriteLine('bad path'); exit 2 }
    if (-not (Test-Path -LiteralPath $f -PathType Leaf)) { [Console]::Error.WriteLine("no such file: $f"); exit 1 }
    [Console]::Out.Write([Convert]::ToBase64String([IO.File]::ReadAllBytes($f))); [Console]::Out.WriteLine()
}
'xfer-prep' {   # xfer-prep <b64 rel>: create the folder for an scp upload into ~/.ftk/xfer
    $f = Xfer-Path (A 1); if (-not $f) { Write-Output 'bad path (letters, digits . _ - /, relative, no ..)'; exit 2 }
    $dir = Split-Path $f -Parent; if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
    Write-Output 'ok'
}
'xfer-hash' {   # xfer-hash <b64 rel>: size + sha256 of a file in ~/.ftk/xfer
    $f = Xfer-Path (A 1); if (-not $f) { Write-Output 'bad path'; exit 2 }
    if (-not (Test-Path -LiteralPath $f -PathType Leaf)) { Write-Output "no such file: $f"; exit 1 }
    Write-Output "saved $f $((Get-Item -LiteralPath $f).Length) bytes sha256 $((Get-FileHash -Algorithm SHA256 -LiteralPath $f).Hash.ToLower())"
}
'xfer' {
    New-Item -ItemType Directory -Force -Path $Xfer | Out-Null
    Write-Output "# $Xfer"
    $root = (Resolve-Path $Xfer).Path
    Get-ChildItem -Path $root -Recurse -File | ForEach-Object { $_.FullName.Substring($root.Length + 1) -replace '\\', '/' } | Sort-Object
}
'git' {
    $d = Project-Dir; if (-not $d) { Write-Output 'project not set'; exit 1 }
    Write-Output "# $d"; & git -C $d status -sb; Write-Output ''; & git -C $d log --oneline -10
}
'checkout' {
    $d = Project-Dir; if (-not $d) { Write-Output 'project not set'; exit 1 }
    if (-not (Checkout-Branch $d (B64Dec (A 1)))) { exit 1 }
}
'new-lane' {
    $name = A 1
    if ($name -notmatch '^[a-z0-9][a-z0-9-]{0,30}$' -or $name -eq 'main') { Write-Output 'bad lane name (a-z 0-9 -)'; exit 2 }
    $b = B64Dec (A 2); if (-not $b) { Write-Output 'usage: new-lane <name> <b64 branch>'; exit 2 }
    if (-not (Check-Branch $b)) { exit 1 }
    $base = Read-Text $MainProjectFile
    if (-not $base -or -not (Test-Path -LiteralPath (Join-Path $base '.git'))) { Write-Output 'main project not set'; exit 1 }
    $bb = Read-Text $BaseBranchFile; if (-not $bb) { $bb = (& git -C $base rev-parse --abbrev-ref HEAD) }
    $wt = Join-Path (Split-Path $base -Parent) ((Split-Path $base -Leaf) + "-$name")
    if (Test-Path -LiteralPath $wt) { Write-Output "worktree exists: $wt" }
    else {
        if (Has-Origin $base) { & git -C $base fetch -q origin; if ($LASTEXITCODE -ne 0) { exit 1 } }
        $start = if (Has-Ref $base "refs/remotes/origin/$bb") { "origin/$bb" } else { $bb }   # bundle clone: local base
        if (On-Origin $base $b) {
            if (-not (Fetch-Exact $base $b)) { exit 1 }
            & git -C $base worktree add -q --track -b $b $wt "origin/$b"
        } elseif (Has-Ref $base "refs/heads/$b") {
            & git -C $base worktree add -q $wt $b
        } else {   # new lane branch from the base branch, NOT tracking it (no accidental push to the base)
            & git -C $base worktree add -q --no-track -b $b $wt $start
        }
        if ($LASTEXITCODE -ne 0) { exit 1 }
        Fix-Owner $wt
        Write-Output "worktree: $wt (branch $b)"
    }
    Write-Utf8 (Join-Path $FTK "project-ftk-$name") $wt
    New-Item -ItemType Directory -Force -Path (Join-Path (Join-Path $FTK 'lanes') "ftk-$name") | Out-Null
    Write-Output "lane ftk-$name ready (headless - say something to start it)"
}
'clone' {   # clone <b64 url> <b64 branch|-> <b64 parent>: single-branch, sets the main project
    $url = B64Dec (A 1); $br = B64Dec (A 2); $parent = Expand-Home (B64Dec (A 3))
    if (-not $url -or -not $parent) { Write-Output 'usage: clone <url> <branch|-> <parent>'; exit 2 }
    if ($br -and -not (Check-Branch $br)) { exit 1 }
    $name = (Split-Path ($url.TrimEnd('/')) -Leaf) -replace '\.git$', ''
    $dir = Join-Path $parent $name
    New-Item -ItemType Directory -Force -Path $parent | Out-Null
    if (Test-Path -LiteralPath (Join-Path $dir '.git')) {
        Write-Output "repo exists: $dir - fetching"; & git -C $dir fetch origin; if ($LASTEXITCODE -ne 0) { exit 1 }
        if ($br -and -not (Checkout-Branch $dir $br)) { exit 1 }
    } else {
        $onRemote = $false
        if ($br) { & git ls-remote --exit-code --heads $url "refs/heads/$br" 2>&1 | Out-Null; $onRemote = ($LASTEXITCODE -eq 0) }
        if ($onRemote) { & git clone --single-branch -b $br $url $dir } else { & git clone --single-branch $url $dir }
        if ($LASTEXITCODE -ne 0) { exit 1 }
        if ($br -and -not $onRemote -and -not (Checkout-Branch $dir $br)) { exit 1 }
    }
    Fix-Owner $dir
    Write-Utf8 $MainProjectFile $dir; Write-Utf8 $BaseBranchFile "$(& git -C $dir rev-parse --abbrev-ref HEAD)`n"
    Write-Output "project: $dir"; & git -C $dir log --oneline -1
}
'unbundle' {   # unbundle <b64 bundle> <b64 branch> <b64 dest>: single-branch clone from a git bundle, no origin
    $bf = B64Dec (A 1); $br = B64Dec (A 2); $dest = Expand-Home (B64Dec (A 3))
    if (-not $bf -or -not (Test-Path -LiteralPath $bf) -or -not $br -or -not $dest) { Write-Output 'usage: unbundle <bundle> <branch> <dest>'; exit 2 }
    if (-not (Check-Branch $br)) { exit 1 }
    $heads = @(& git bundle list-heads $bf 2>$null | ForEach-Object { ($_ -split ' ')[1] })
    if ($heads.Count -ne 1 -or $heads[0] -ne "refs/heads/$br") { Write-Output "ERROR: bundle must contain exactly refs/heads/$br, has: $($heads -join ', ')"; exit 1 }
    if (Test-Path -LiteralPath (Join-Path $dest '.git')) { Write-Output "repo exists: $dest - kept as is" }
    else {
        New-Item -ItemType Directory -Force -Path (Split-Path $dest -Parent) | Out-Null
        & git clone -q --single-branch -b $br $bf $dest; if ($LASTEXITCODE -ne 0) { exit 1 }
        & git -C $dest remote remove origin
        Write-Output "unpacked: $dest ($(& git -C $dest log --oneline -1))"
    }
    Fix-Owner $dest
    Write-Utf8 $MainProjectFile $dest; Write-Utf8 $BaseBranchFile "$br`n"
    Write-Output "project: $dest"
}
'set-topic' {
    if ((A 1) -notmatch '^[A-Za-z0-9_-]{8,64}$') { Write-Output 'bad topic'; exit 2 }
    Write-Utf8 $TopicFile (A 1); Write-Output 'topic set'
}
'notify' { if ((A 1) -eq 'ready') { Notify "FTK host ready ($([Environment]::MachineName))" (B64Dec (A 2)) } }
{ $_ -eq 'attach' -or $_ -eq 'drive' } {
    Write-Output 'No live terminal on a Windows host (the agent runs headless). Use: peek, log, wait, say.'; exit 2
}
default {
    Write-Output 'usage: ftk-remote.ps1 [-s lane] say|wait|peek|log|setup-log|monitor|monitor-window|show-monitor|version|update|rollback|trust-signer|autostart|install-shortcuts|key|status|lanes|run|start|restart|setproject|put|get|xfer|git|checkout|new-lane|clone|unbundle|set-topic|notify'
}
}
'@
Write-NoBom $Helper $remote
$FtkHome = Join-Path $env:USERPROFILE '.ftk'
New-Item -ItemType Directory -Force -Path $FtkHome | Out-Null
$PsExe = Join-Path $env:windir 'System32\WindowsPowerShell\v1.0\powershell.exe'
function FtkR { & $PsExe -NoProfile -ExecutionPolicy Bypass -File $Helper @args }
FtkR trust-signer (B64 $key) | Out-Host   # helper updates must be signed with this same key

# ---------- the connection is ready: tell the teammate NOW, the rest can be watched over SSH ----------
$line = "FTK|$ip|$env:USERNAME|windows"
try { Set-Clipboard -Value $line } catch { }
if ($NtfyTopic) { FtkR set-topic $NtfyTopic | Out-Null }
FtkR notify ready (B64 $line) | Out-Null
Progress 'CONNECTION READY' "$line  - you can connect now; the setup continues (ftk setup-log)"
Write-Host "Connection line (teammate can connect now): $line"

# ---------- Step 4: Git for Windows (git + Git Bash for the agents' commands) ----------
Mark 'Step 4/8 Git'
$gitExe = Join-Path $PF 'Git\cmd\git.exe'
if (-not (Test-Path $gitExe) -and -not (Get-Command git.exe -ErrorAction SilentlyContinue)) {
    Write-Host 'Installing Git for Windows...'
    try { & winget.exe install --id Git.Git -e --accept-source-agreements --accept-package-agreements } catch { }
    for ($i = 0; $i -lt 120 -and -not (Test-Path $gitExe); $i++) { Start-Sleep -Seconds 1 }
    if (-not (Test-Path $gitExe)) { throw 'Git for Windows could not be installed (winget). Install it from https://git-scm.com and run the script again.' }
}
if (Test-Path $gitExe) { $env:Path = "$(Split-Path $gitExe);$env:Path" }

# ---------- Step 5: Claude Code (native Windows - no WSL) ----------
Mark 'Step 5/8 Claude Code'
function Find-Claude {
    $c = Join-Path $env:USERPROFILE '.local\bin\claude.exe'; if (Test-Path $c) { return $c }
    $g = Get-Command claude -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($g) {
        if ($g.Source -match '\.ps1$') { $cmd = $g.Source -replace '\.ps1$', '.cmd'; if (Test-Path $cmd) { return $cmd } }
        return $g.Source
    }
    return ''
}
$claude = Find-Claude
if (-not $claude) {
    Write-Host 'Installing Claude Code...'
    try { Invoke-RestMethod 'https://claude.ai/install.ps1' | Invoke-Expression } catch { Write-Host "Claude Code install: $($_.Exception.Message)" }
    $claude = Find-Claude
    if (-not $claude) { throw 'Claude Code could not be installed. Install it (irm https://claude.ai/install.ps1 | iex) and run the script again.' }
}
Write-Host "claude: $claude"

Write-NoBom (Join-Path $FtkHome 'claude-path') $claude

# ---------- Step 6: repository + branch ----------
Mark 'Step 6/8 Repository'
$projects = Join-Path $env:USERPROFILE 'Projects'
$bundle = Join-Path $PSScriptRoot 'repo.bundle'
$provided = $false
if (Test-Path $bundle) {
    $name = ($RepoUrl.TrimEnd('/') -split '/')[-1] -replace '\.git$', ''
    if (-not $name) { $name = 'repo' }
    $branchB = if ($RepoBranch) { $RepoBranch } else { 'v2' }
    Write-Host "Unpacking the repo shipped with this kit ($branchB) ..."
    FtkR unbundle (B64 $bundle) (B64 $branchB) (B64 (Join-Path $projects $name))
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
    $url = (AskOpt "Step 6/8 - Repository`n`nGit URL of the repo to clone (only this one branch is cloned).`nLeave EMPTY to use a folder that already exists." $RepoUrl) -replace '\s', ''
    if (-not $url) {
        $fb = New-Object Windows.Forms.FolderBrowserDialog
        $fb.Description = 'Step 6/8 - Choose the existing project folder the agent will work in'
        if ($fb.ShowDialog($Owner) -ne 'OK') { Write-Host 'Cancelled.'; exit 1 }
        FtkR setproject (B64 $fb.SelectedPath) | Out-Host
    } else {
        $branch = (AskOpt "Step 6/8 - Branch`n`nBranch to work on (it is created if it does not exist yet).`nLeave EMPTY for the default branch." $RepoBranch) -replace '\s', ''
        $b64Branch = '-'; if ($branch) { $b64Branch = B64 $branch }
        Write-Host "Cloning $url into $projects ... (a browser login window may appear)"
        FtkR clone (B64 $url) $b64Branch (B64 $projects)
        if ($LASTEXITCODE -ne 0) {
            Info "Could not clone / switch the branch - see the console output.`n`nTypical causes:`n- no access to the repo`n- uncommitted changes in an existing copy`n`nFix it and run this script again."
            exit 1
        }
    }
}

# the elevated setup created these as Administrators-owned: hand them to the user (git refuses foreign-owned repos)
$meUser = [Security.Principal.WindowsIdentity]::GetCurrent().Name
foreach ($pth in @($FtkHome, $projects, (Join-Path $env:USERPROFILE '.claude\agents'), (Join-Path $env:USERPROFILE '.claude\skills\migration-unit'))) {
    if (Test-Path $pth) { & icacls.exe $pth /setowner $meUser /T /C /Q 2>&1 | Out-Null }
}

# ---------- migration files shipped with the kit ----------
$mw = Join-Path $PSScriptRoot 'migration-worker.md'
if (Test-Path $mw) {
    $agents = Join-Path $env:USERPROFILE '.claude\agents'
    New-Item -ItemType Directory -Force -Path $agents | Out-Null
    Copy-Item $mw (Join-Path $agents 'migration-worker.md') -Force
    Write-Host 'installed ~/.claude/agents/migration-worker.md'
}
$sk = Join-Path $PSScriptRoot 'migration-unit.SKILL.md'
if (Test-Path $sk) {
    $skd = Join-Path $env:USERPROFILE '.claude\skills\migration-unit'
    New-Item -ItemType Directory -Force -Path $skd | Out-Null
    Copy-Item $sk (Join-Path $skd 'SKILL.md') -Force
    Write-Host 'installed ~/.claude/skills/migration-unit/SKILL.md'
}
$mx = Join-Path $PSScriptRoot 'setup-migration-env.sh'
if (Test-Path $mx) { Copy-Item $mx (Join-Path $FtkHome 'setup-migration-env.sh') -Force; Write-Host 'copied ~/.ftk/setup-migration-env.sh (not run)' }

# ---------- Step 7: the agent (headless) ----------
Mark 'Step 7/8 Agent'
FtkR start | Out-Null
if (YesNo "Keep the PC awake while plugged in?`n(Recommended - a sleeping PC drops the connection.)") {
    & powercfg.exe /change standby-timeout-ac 0
}
if (-not (Test-Path (Join-Path $env:USERPROFILE '.claude\.credentials.json'))) {
    Step @"
Step 7/8 - Log in to Claude once

A window with Claude will open.
1. Log in (your own Claude account).
2. Then type /exit or close the window.

Click OK to open it, and OK again here when you are logged in.
"@
    if (-not $Auto) { Start-Process $PsExe -ArgumentList '-NoExit', '-Command', "& '$claude'" -WorkingDirectory $env:USERPROFILE }
    Step "Step 7/8 - Logged in to Claude?`n`nClick OK when the login is done."
}
Write-Host 'Checking that the agent answers (one short headless turn)...'
FtkR say (B64 'Reply with exactly one word: READY') | Out-Host
FtkR wait 240 | Out-Host
$check = (FtkR peek 20 | Out-String)
FtkR restart | Out-Null   # the real work starts with a fresh conversation
if ($check -match 'READY') { Write-Host 'Agent check: OK' }
else { Info "Step 7/8 - The agent did not answer as expected:`n`n$($check.Trim())`n`nUsually: Claude is not logged in. Run 'claude' once, log in, then run this script again." }

# ---------- "FTK Agents" shortcut on the Desktop + in Startup (update check + progress window) ----------
FtkR install-shortcuts | Out-Host
if (-not $Auto) { Start-Process $PsExe -ArgumentList '-NoProfile', '-ExecutionPolicy', 'Bypass', '-WindowStyle', 'Hidden', '-File', $Helper, 'monitor-window' }

# ---------- Step 8: connection line ----------
Mark 'Step 8/8 Done'
try { Set-Clipboard -Value $line } catch { }
Progress 'DONE' "$line"
Info @"
Step 8/8 - Done!

Your teammate has been notified automatically.
If not, send them this line (already copied to the clipboard):

$line

Notes:
- Keep the PC on and Tailscale connected.
- The agent runs headless: it starts when your teammate sends it a message.
- "FTK Agents" (Desktop + Startup) shows what the agents are doing and keeps the helper up to date.
"@
Write-Host "Connection line: $line"
}
catch {
    $line = $_.InvocationInfo.ScriptLineNumber
    Progress "FAILED at $global:FtkStep" "line ${line}: $($_.Exception.Message)"
    Info "Setup failed at: $global:FtkStep (script line $line)`n`n$($_.Exception.Message)`n`nFull log: $LogDir\setup.log`nFix the problem (a restart often helps) and run the script again."
    exit 1
}
