# FTK Remote - checks to run on a real Windows box under Windows PowerShell 5.1.
# Installs nothing. Uses a python stub instead of ssh, so it sees exactly the argv ssh.exe would get.
#   powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\win-check.ps1
$ErrorActionPreference = 'Continue'
$here = $PSScriptRoot
$script:pass = 0; $script:fail = 0
function Ok([string]$n) { $script:pass++; Write-Host "PASS $n" }
function Bad([string]$n, [string]$d) { $script:fail++; Write-Host "FAIL $n :: $d" }
Write-Host "PowerShell $($PSVersionTable.PSVersion) ($($PSVersionTable.PSEdition)), 64-bit process: $([Environment]::Is64BitProcess)"

# 1. parse with this PowerShell
foreach ($f in 'host-setup-windows.ps1', 'client-setup-windows.ps1', 'ftk.ps1', 'ftk-remote.ps1') {
    $e = $null; [void][System.Management.Automation.Language.Parser]::ParseFile((Join-Path $here $f), [ref]$null, [ref]$e)
    if ($e) { Bad "parse $f" (($e | ForEach-Object { $_.ToString() }) -join ' | ') } else { Ok "parse $f" }
}
# 2. ASCII only (PS 5.1 reads BOM-less files as ANSI)
foreach ($f in 'host-setup-windows.ps1', 'client-setup-windows.ps1', 'ftk.ps1', 'ftk-remote.ps1') {
    $bytes = [IO.File]::ReadAllBytes((Join-Path $here $f))
    if (@($bytes | Where-Object { $_ -gt 127 }).Count -eq 0) { Ok "ascii $f" } else { Bad "ascii $f" 'non-ASCII bytes' }
}

# 3. ftk.ps1 with a python stub as ssh
$py = (Get-Command python -ErrorAction SilentlyContinue | Select-Object -First 1).Source
if (-not $py) { Bad 'python found' 'python not on PATH'; Write-Host "RESULT $($script:pass) passed, $($script:fail) failed"; exit 1 }
$work = Join-Path $here 'work'; New-Item -ItemType Directory -Force -Path $work | Out-Null
# the stub is a file literally named "ftk": `python ftk <remote command>` -> sys.argv[1:] = what ssh would receive after the host alias
$stub = @'
import sys, json, base64, hashlib
a = sys.argv[1:]
cmd = a[-1] if a else ""
if " put " in cmd:
    data = base64.b64decode("".join(sys.stdin.read().split()))
    print("PUT", len(data), hashlib.sha256(data).hexdigest())
elif " get " in cmd:
    sys.stdout.write(base64.b64encode(bytes(range(256)) * 4).decode() + "\n")
else:
    print("ARGV " + json.dumps(a))
'@
[IO.File]::WriteAllText((Join-Path $work 'ftk'), $stub, (New-Object Text.UTF8Encoding($false)))
$conf = Join-Path $work 'client.conf'
[IO.File]::WriteAllText($conf, '{"remote":"powershell -NoProfile -ExecutionPolicy Bypass -File C:\\ProgramData\\ftk\\ftk-remote.ps1","topic":"","ntfy":""}', (New-Object Text.UTF8Encoding($false)))
$env:FTK_CONF = $conf; $env:FTK_SSH = $py
$Remote = 'powershell -NoProfile -ExecutionPolicy Bypass -File C:\ProgramData\ftk\ftk-remote.ps1'
$Pfx = '^' + [regex]::Escape($Remote)
$ftk = Join-Path $here 'ftk.ps1'
Push-Location $work
function Run-Ftk { $o = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $ftk @args 2>&1 | Out-String; return @{ out = $o.Trim(); rc = $LASTEXITCODE } }
function Argv($r) { $l = ($r.out -split "`n" | Where-Object { $_ -like 'ARGV *' } | Select-Object -First 1); if (-not $l) { return $null }; return ($l.Substring(5) | ConvertFrom-Json) }

# Cyrillic + shell metacharacters, built from char codes so this file stays ASCII
$cyr = -join ([char[]](0x041F, 0x0440, 0x0438, 0x0432, 0x0435, 0x0442))
$msg = "$cyr ""quotes"" 'single' & | ; < > %PATH% `$HOME"
$r = Run-Ftk say $msg
$a = Argv $r
if ($a -and $a.Count -eq 1 -and $a[0] -match ($Pfx + ' say ([A-Za-z0-9+/=]+)$')) {
    $dec = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($Matches[1]))
    if ($dec -eq $msg) { Ok 'say: one plain arg, base64 decodes to the exact text' } else { Bad 'say decode' "got [$dec]" }
} else { Bad 'say argv' $r.out }

$r = Run-Ftk -s a1 run 'git status && echo "x"'
$a = Argv $r
if ($a -and $a[0] -match ($Pfx + ' -s a1 run ([A-Za-z0-9+/=]+)$') -and
    [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($Matches[1])) -eq 'git status && echo "x"') { Ok '-s a1 run' } else { Bad '-s a1 run' $r.out }

$r = Run-Ftk peek 50; $a = Argv $r
if ($a -and $a[0] -eq ($Remote + ' peek 50')) { Ok 'peek 50' } else { Bad 'peek 50' $r.out }
$r = Run-Ftk key 'a;b'; if ($r.rc -eq 2) { Ok 'key rejects bad name' } else { Bad 'key bad name' "rc=$($r.rc) $($r.out)" }
$r = Run-Ftk peek '1;x'; if ($r.rc -eq 2) { Ok 'peek rejects bad number' } else { Bad 'peek bad number' "rc=$($r.rc)" }
$r = Run-Ftk -s 'x;y' peek; if ($r.rc -eq 2) { Ok '-s rejects bad lane' } else { Bad '-s bad lane' "rc=$($r.rc)" }
$r = Run-Ftk new-lane a2 'migrate/s2-a2'; $a = Argv $r
if ($a -and $a[0] -match ($Pfx + ' new-lane a2 [A-Za-z0-9+/=]+$')) { Ok 'new-lane' } else { Bad 'new-lane' $r.out }

# put: binary through PS 5.1 stdin pipe -> stub decodes, sizes + sha256 must match
$blob = Join-Path $work 'blob.bin'; $rnd = New-Object byte[] 70000; (New-Object Random 7).NextBytes($rnd); [IO.File]::WriteAllBytes($blob, $rnd)
$sha = (Get-FileHash -Algorithm SHA256 $blob).Hash.ToLower()
$r = Run-Ftk put $blob 'x/blob.bin'
if ($r.out -match "PUT 70000 $sha") { Ok 'put: 70000 bytes, sha256 matches' } else { Bad 'put' $r.out }
$r = Run-Ftk get 'x/blob.bin' 'back.bin'
$exp = New-Object byte[] 1024; for ($i = 0; $i -lt 1024; $i++) { $exp[$i] = [byte]($i % 256) }
$got = [IO.File]::ReadAllBytes((Join-Path $work 'back.bin'))
if ([Convert]::ToBase64String($got) -eq [Convert]::ToBase64String($exp)) { Ok 'get: bytes identical' } else { Bad 'get' $r.out }
Pop-Location

# 4. BOM-free writer used by the setup scripts
$t = Join-Path $work 'nobom.txt'; [IO.File]::WriteAllText($t, "Host ftk`n", (New-Object Text.UTF8Encoding($false)))
$b = [IO.File]::ReadAllBytes($t); if ($b[0] -ne 0xEF) { Ok 'UTF8Encoding($false) writes no BOM' } else { Bad 'no BOM' 'BOM found' }

Write-Host "RESULT $($script:pass) passed, $($script:fail) failed"
exit $script:fail
