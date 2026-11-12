#!/bin/bash
# FTK Remote test suite (runs on macOS, no second machine needed).
#   bash tests/run.sh
# Needs: tmux. PowerShell tests need pwsh (auto-downloaded to tests/.cache if missing).
# Everything runs in a temp HOME with a private tmux socket and stubbed
# osascript / ssh / pbcopy / open / nc, so your real setup is not touched.

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PASS=0; FAIL=0; FAILED=()
ok()   { PASS=$((PASS+1)); printf '  \033[32mPASS\033[0m %s\n' "$1"; }
bad()  { FAIL=$((FAIL+1)); FAILED+=("$1"); printf '  \033[31mFAIL\033[0m %s\n' "$1"; [ -n "$2" ] && printf '       %s\n' "$2"; }
check(){ local name="$1"; shift; if "$@" >/dev/null 2>&1; then ok "$name"; else bad "$name"; fi; }
section(){ printf '\n\033[1m%s\033[0m\n' "$1"; }

command -v tmux >/dev/null || { echo "tmux is required (brew install tmux)"; exit 1; }

# ---------- sandbox ----------
T="$(mktemp -d /tmp/ftk-test.XXXXXX)"
export REAL_HOME="$HOME" HOME="$T/home" FTK_TMUX="ftk-test-$$" FTK_TEST_DIR="$T"
export SHELL=/bin/bash BASH_SILENCE_DEPRECATION_WARNING=1
mkdir -p "$HOME" "$T/stubs" "$T/proj with space/папка"
touch "$HOME/.bashrc" "$HOME/.bash_profile"
# fake ntfy server
python3 "$ROOT/tests/fake_ntfy.py" "$T/ntfy.port" & NTFY_PID=$!
for _ in $(seq 1 40); do [ -s "$T/ntfy.port" ] && break; sleep 0.1; done
export FTK_NTFY_URL="http://127.0.0.1:$(cat "$T/ntfy.port")" FTK_NTFY_TOPIC="ftk-testtopic123"
NTFY_GET() { curl -fsS "$FTK_NTFY_URL/$FTK_NTFY_TOPIC/json?poll=1&since=all"; }
cleanup() { tmux -L "$FTK_TMUX" kill-server 2>/dev/null; kill $NTFY_PID 2>/dev/null; rm -rf "$T"; }
trap cleanup EXIT

# fake agent: echoes every line it receives
cat > "$T/stubs/fake-agent" <<'EOF'
#!/bin/bash
echo "FAKE AGENT READY"
while IFS= read -r l; do echo "AGENT GOT: $l"; done
EOF
export FTK_AGENT_CMD="$T/stubs/fake-agent"

# osascript: OK on every dialog, default answer for inputs, FTK_PROJECT for folder choice
cat > "$T/stubs/osascript" <<'EOF'
#!/bin/bash
[ "$1" = "-e" ] && exit 0            # tell application "Terminal" ...
script="$(cat)"; shift               # drop "-"
echo "$1" >> "$FTK_TEST_DIR/dialogs.log"
# safety net: a script stuck re-asking the same dialog = Cancel instead of hanging the suite
h="$(printf '%s' "$1" | md5)"; echo "$h" >> "$FTK_TEST_DIR/dialog-hashes.log"
[ "$(grep -c "$h" "$FTK_TEST_DIR/dialog-hashes.log")" -gt 60 ] && { echo "TOO MANY DIALOGS (same dialog repeated)" >&2; exit 1; }
case "$script" in
  *"button returned"*) printf '%s\n' "${FTK_PICK:-$5}" ;;   # 3-button choice: default = last button
  *"default answer"*) printf '%s\n' "$2" ;;
  *"choose folder"*)  printf '%s/\n' "$FTK_PROJECT" ;;
esac
EOF
# ssh: run the remote command locally (same as a real remote shell would)
cat > "$T/stubs/ssh" <<'EOF'
#!/bin/bash
a=(); while [ $# -gt 0 ]; do case "$1" in -o) shift 2;; -t|-T) shift;; *) a+=("$1"); shift;; esac; done
echo "${a[*]}" >> "$FTK_TEST_DIR/ssh.log"
[ "${#a[@]}" -le 1 ] && exit 0
cmd="${a[*]:1}"
# Windows host: the native helper runs here under pwsh with its own FTK_HOME and a fake claude
WINP='powershell -NoProfile -ExecutionPolicy Bypass -File C:\ProgramData\ftk\ftk-remote.ps1'
if [[ "$cmd" == "$WINP"* ]]; then
  cmd="FTK_HOME='$FTK_TEST_WINHOME' FTK_CLAUDE='$FTK_TEST_FAKE_CLAUDE' '$FTK_TEST_PWSH' -NoProfile -File '$FTK_TEST_PS1'${cmd#"$WINP"}"
fi
exec bash -c "$cmd"
EOF
# wsl: what the Windows host does (wsl -e /usr/local/bin/ftk-remote ...)
cat > "$T/stubs/wsl" <<'EOF'
#!/bin/bash
while [ $# -gt 0 ]; do case "$1" in -e) shift; break;; -u) shift 2;; *) break;; esac; done
[ "$1" = "/usr/local/bin/ftk-remote" ] && { shift; exec "$HOME/.ftk/ftk-remote" "$@"; }
exec "$@"
EOF
cat > "$T/stubs/pbcopy"  <<'EOF'
#!/bin/bash
cat > "$FTK_TEST_DIR/clipboard_out"
EOF
cat > "$T/stubs/pbpaste" <<'EOF'
#!/bin/bash
cat "$FTK_TEST_DIR/clipboard_in" 2>/dev/null
EOF
cat > "$T/stubs/tailscale" <<'EOF'
#!/bin/bash
[ "$1" = "ip" ] && echo "100.64.0.9"
EOF
for s in open nc claude launchctl; do printf '#!/bin/bash\nexit 0\n' > "$T/stubs/$s"; done
chmod +x "$T/stubs/"*
export PATH="$T/stubs:$PATH" FTK_TS_CLI="$T/stubs/tailscale"

# git origin with main + migration/v2
G() { git -c user.name=test -c user.email=test@test -c init.defaultBranch=main "$@"; }
ORIGIN="$T/origin/demo-toolkit.git"
G init -q --bare "$ORIGIN"
G clone -q "$ORIGIN" "$T/seed" 2>/dev/null
( cd "$T/seed" && echo v1 > README.md && G add . && G commit -qm "init" && G push -q origin main &&
  G checkout -qb migration/v2 && echo v2 > V2.md && G add . && G commit -qm "v2 work" && G push -q origin migration/v2 &&
  G checkout -qb migrate/operator-records && echo secret > DENY.txt && G add . && G commit -qm "private" && G push -q origin migrate/operator-records &&
  G checkout -q migration/v2 && G checkout -qb migrate/s2-b2 && echo b2 > B2.md && G add . && G commit -qm "lane b2 work" && G push -q origin migrate/s2-b2 )
export FTK_REPO_URL="file://$ORIGIN" FTK_REPO_BRANCH="migration/v2" FTK_PICK="Clone from URL"

PWSH="$(command -v pwsh || true)"
if [ -z "$PWSH" ]; then
  C="$ROOT/tests/.cache/pwsh"
  if [ ! -x "$C/pwsh" ]; then
    arch="$(uname -m)"; [ "$arch" = "x86_64" ] && arch=x64
    echo "  downloading PowerShell 7.4.6 to tests/.cache ..."
    mkdir -p "$C" && curl -fsSL "https://github.com/PowerShell/PowerShell/releases/download/v7.4.6/powershell-7.4.6-osx-$arch.tar.gz" | tar -xz -C "$C" && chmod +x "$C/pwsh"
  fi
  [ -x "$C/pwsh" ] && PWSH="$C/pwsh"
fi
export FTK_TEST_PWSH="$PWSH" FTK_TEST_PS1="$ROOT/ftk-remote.ps1" FTK_TEST_WINHOME="$T/winhost/.ftk" FTK_TEST_FAKE_CLAUDE="$ROOT/tests/fake_claude.py"
WINR='powershell -NoProfile -ExecutionPolicy Bypass -File C:\ProgramData\ftk\ftk-remote.ps1'

R="$HOME/.ftk/ftk-remote"
wait_for() { # wait_for <pattern> [peek-cmd...]
  local pat="$1"; shift
  for _ in $(seq 1 40); do "$@" 2>/dev/null | grep -qF -- "$pat" && return 0; sleep 0.25; done
  return 1
}
b64() { printf '%s' "$1" | base64 | tr -d '\n'; }

# ======================================================================
section "1. Static checks"
for f in ftk-remote.sh host-setup-mac.command client-setup-mac.command; do
  check "bash syntax: $f" bash -n "$ROOT/$f"
done
check "embedded ftk-remote in host-setup-mac == ftk-remote.sh" \
  bash -c "diff <(sed -n \"/<<'FTK_REMOTE_EOF'/,/^FTK_REMOTE_EOF\$/p\" '$ROOT/host-setup-mac.command' | sed '1d;\$d') '$ROOT/ftk-remote.sh'"
check "embedded ftk-remote.ps1 in host-setup-windows == ftk-remote.ps1" \
  bash -c "diff <(sed -n \"/^\\\$remote = @'\$/,/^'@\$/p\" '$ROOT/host-setup-windows.ps1' | sed '1d;\$d') '$ROOT/ftk-remote.ps1'"
check "Windows host setup has no WSL any more" bash -c "! grep -qi 'wsl.exe' '$ROOT/host-setup-windows.ps1'"
for f in host-setup-windows.ps1 client-setup-windows.ps1 host-setup-windows.cmd client-setup-windows.cmd ftk-remote.ps1; do
  check "ASCII only (PS 5.1 safe): $f" bash -c "! LC_ALL=C grep -q '[^ -~[:space:]]' '$ROOT/$f'"
done
check "no UTF-8 BOM writes in .ps1 (Set-Content/Out-File -Encoding UTF8)" \
  bash -c "! grep -nE '(Set-Content|Out-File|Add-Content).*-Encoding +UTF8' '$ROOT'/*.ps1"
check "admin key file ACL uses SIDs (works on any Windows language)" \
  grep -q "/grant '\*S-1-5-32-544:F' /grant '\*S-1-5-18:F'" "$ROOT/host-setup-windows.ps1"
check "every git clone is --single-branch" bash -c "! grep -n 'git clone' '$ROOT/ftk-remote.sh' | grep -v -- '--single-branch'"
check "no 'fetch --all' anywhere" bash -c "! grep -rn 'fetch --all' '$ROOT'/*.sh '$ROOT'/*.command '$ROOT'/*.ps1"
for f in host-setup-windows client-setup-windows; do
  check "$f.ps1 relaunches itself as 64-bit (Sysnative)" bash -c "grep -q 'Is64BitProcess' '$ROOT/$f.ps1' && grep -q 'Sysnative' '$ROOT/$f.ps1'"
  check "$f.cmd prefers Sysnative powershell" grep -q 'Sysnative' "$ROOT/$f.cmd"
  check "$f.ps1 uses ProgramW6432 for Program Files" bash -c "grep -q 'ProgramW6432' '$ROOT/$f.ps1' && ! grep -q 'Join-Path \\\$env:ProgramFiles' '$ROOT/$f.ps1'"
done
check "Windows client ssh config has no ControlMaster" \
  bash -c "! grep -q 'ControlMaster auto' '$ROOT/client-setup-windows.ps1'"

# ======================================================================
section "2. Host setup (Mac) end-to-end with stubs"
export FTK_PROJECT="$T/proj with space/папка"
EXPECTED_LINE="FTK|100.64.0.9|$(whoami)|mac"
CLIENT_KEY="ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAITestKeyForFtkSuite tester@test"
printf '%s\n' "$CLIENT_KEY" > "$T/clipboard_in"
OUT1="$(bash "$ROOT/host-setup-mac.command" 2>&1)"; RC1=$?
OUT2="$(bash "$ROOT/host-setup-mac.command" 2>&1)"; RC2=$?
[ $RC1 -eq 0 ] && ok "host setup run #1 exits 0" || bad "host setup run #1 exits 0" "$OUT1"
[ $RC2 -eq 0 ] && ok "host setup run #2 (re-run) exits 0" || bad "host setup run #2 exits 0" "$OUT2"
[ "$(grep -cxF "$CLIENT_KEY" "$HOME/.ssh/authorized_keys")" = 1 ] && ok "client key in authorized_keys exactly once" || bad "client key in authorized_keys exactly once"
check "ntfy: 'host ready' push with the connection line" bash -c "NTFY_GET() { curl -fsS '$FTK_NTFY_URL/$FTK_NTFY_TOPIC/json?poll=1&since=all'; }; NTFY_GET | grep -q 'FTK host ready' && NTFY_GET | grep -qF '$EXPECTED_LINE'"
check "hooks: Stop + Notification installed once (after 2 runs)" python3 -c "
import json,os
h=json.load(open(os.path.expanduser('~/.claude/settings.json')))['hooks']
assert len(h['Stop'])==1 and len(h['Notification'])==1
assert 'ftk-remote' in h['Stop'][0]['hooks'][0]['command'] and h['Stop'][0]['hooks'][0]['command'].endswith('notify stop')"
check "LaunchAgent written and valid" bash -c "plutil -lint '$HOME/Library/LaunchAgents/com.ftk.agent.plist' && grep -q '$HOME/.ftk/ftk-remote' '$HOME/Library/LaunchAgents/com.ftk.agent.plist'"
check "authorized_keys mode 600" bash -c "[ \"\$(stat -f %Lp '$HOME/.ssh/authorized_keys')\" = 600 ]"
check "installed helper == ftk-remote.sh" cmp "$R" "$ROOT/ftk-remote.sh"
REPO="$FTK_PROJECT/demo-toolkit"
[ "$(cat "$HOME/.ftk/project")" = "$REPO" ] && ok "project = cloned repo (path with spaces + Cyrillic)" || bad "project = cloned repo" "$(cat "$HOME/.ftk/project")"
check "repo cloned" test -f "$REPO/README.md"
[ "$(git -C "$REPO" rev-parse --abbrev-ref HEAD)" = "migration/v2" ] && ok "switched to branch migration/v2" || bad "switched to branch migration/v2" "$(git -C "$REPO" rev-parse --abbrev-ref HEAD)"
[ "$(git -C "$REPO" rev-parse --abbrev-ref '@{u}' 2>/dev/null)" = "origin/migration/v2" ] && ok "branch tracks origin/migration/v2" || bad "branch tracks origin/migration/v2"
check "re-run said 'repo exists - fetching'" bash -c "printf '%s' \"\$0\" | grep -q 'repo exists'" "$OUT2"
[ "$(cat "$T/clipboard_out")" = "$EXPECTED_LINE" ] && ok "connection line copied: $EXPECTED_LINE" || bad "connection line copied" "$(cat "$T/clipboard_out")"
check "tmux session started" tmux -L "$FTK_TMUX" has-session -t =ftk
P="$(tmux -L "$FTK_TMUX" display -p -t =ftk: '#{pane_current_path}')"
[ "$P" = "$(cd "$REPO" && pwd -P)" ] && ok "session runs in the project folder" || bad "session runs in the project folder" "$P"
check "agent started in the session" wait_for "FAKE AGENT READY" "$R" peek

mkdir -p "$T/pkg"; cp "$ROOT/host-setup-mac.command" "$T/pkg/"
PKG_KEY="ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIPackagedKeyFromTeammatePub pkg@test"
echo "$PKG_KEY" > "$T/pkg/teammate.pub"; : > "$T/clipboard_in"
OUTP="$(bash "$T/pkg/host-setup-mac.command" 2>&1)" && ok "host setup with teammate.pub next to it exits 0" || bad "host setup with teammate.pub" "$OUTP"
check "key taken from teammate.pub (no paste needed)" grep -qxF "$PKG_KEY" "$HOME/.ssh/authorized_keys"
printf '%s\n' "$CLIENT_KEY" > "$T/clipboard_in"   # restore for later host runs

# ======================================================================
section "3. ftk-remote commands (host side)"
check "status: session running" wait_for "session: running" "$R" status
MSG=$'Привет, агент!\nВторая строка: "quotes" \x27single\x27 $(touch '"$T"'/pwned) `touch '"$T"'/pwned2`; | & < >'
"$R" say "$(b64 "$MSG")" >/dev/null
check "say: Cyrillic line 1 delivered"   wait_for "AGENT GOT: Привет, агент!" "$R" peek
check "say: line 2 with shell metachars delivered literally" wait_for "AGENT GOT: Вторая строка: \"quotes\" 'single' \$(touch" "$R" peek
check "say: no command injection" bash -c "[ ! -e '$T/pwned' ] && [ ! -e '$T/pwned2' ]"
check "key: bad name rejected" bash -c "! '$R' key 'a;touch $T/pwned3'"
check "key: no injection via key" bash -c "[ ! -e '$T/pwned3' ]"
tmux -L "$FTK_TMUX" send-keys -t =ftk: -l "typed-by-key"; "$R" key Enter >/dev/null
check "key: Enter submits" wait_for "AGENT GOT: typed-by-key" "$R" peek
check "peek: no runs of blank lines" bash -c "! '$R' peek 500 | awk 'prev==\"\" && \$0==\"\" {f=1} {prev=\$0} END{exit !f}'"
echo '{"hook_event_name":"Notification","message":"Claude needs your permission to use Bash"}' | FTK_SESSION_NAME=ftk "$R" notify waiting
check "notify waiting: hook message pushed" bash -c "curl -fsS '$FTK_NTFY_URL/$FTK_NTFY_TOPIC/json?poll=1' | grep -q 'needs your permission to use Bash'"
FTK_SESSION_NAME=ftk "$R" notify stop </dev/null
check "notify writes state file" grep -q '^stop ' "$HOME/.ftk/state-ftk"
B="$(curl -fsS "$FTK_NTFY_URL/$FTK_NTFY_TOPIC/json?poll=1" | wc -l)"
echo '{}' | "$R" notify stop; echo '{}' | FTK_SESSION_NAME=someone-else "$R" notify waiting
[ "$(curl -fsS "$FTK_NTFY_URL/$FTK_NTFY_TOPIC/json?poll=1" | wc -l)" = "$B" ] && ok "notify ignores non-ftk Claude sessions" || bad "notify ignores non-ftk Claude sessions"
check "notify stop: pushed" bash -c "curl -fsS '$FTK_NTFY_URL/$FTK_NTFY_TOPIC/json?poll=1' | grep -q 'finished a turn'"
check "set-topic: rejects bad topic" bash -c "! '$R' set-topic 'a b'"
check "peek N: bad number falls back" "$R" peek 'abc'
mkdir -p "$HOME/.claude/projects/p1"; echo '{"type":"assistant","msg":"hello-log"}' > "$HOME/.claude/projects/p1/s.jsonl"
check "log raw: shows newest transcript jsonl" wait_for "hello-log" "$R" log 5 raw
"$R" restart >/dev/null
check "restart: agent restarted" wait_for "FAKE AGENT READY" "$R" peek
check "setproject: base64 path round-trip" bash -c "'$R' setproject '$(b64 "/tmp/a b/папка")' | grep -qF '/tmp/a b/папка'"
"$R" setproject "$(b64 "$REPO")" >/dev/null

# ======================================================================
section "3b. Git: clone / checkout / git"
[ "$(git -C "$REPO" for-each-ref --format='%(refname)' refs/remotes)" = "refs/remotes/origin/migration/v2" ] && ok "clone is single-branch (only origin/migration/v2)" || bad "clone is single-branch" "$(git -C "$REPO" for-each-ref refs/remotes)"
[ "$(git -C "$REPO" config --get-all remote.origin.fetch)" = "+refs/heads/migration/v2:refs/remotes/origin/migration/v2" ] && ok "fetch refspec limited to the branch" || bad "fetch refspec" "$(git -C "$REPO" config --get-all remote.origin.fetch)"
check "base-branch remembered" grep -qx 'migration/v2' "$HOME/.ftk/base-branch"
check "checkout: migrate/operator-records refused" bash -c "'$R' checkout '$(b64 migrate/operator-records)' | grep -q 'not allowed'"
check "checkout: migrate/operator-records-x refused" bash -c "! '$R' checkout '$(b64 migrate/operator-records-x)'"
check "clone: migrate/operator-records refused" bash -c "! '$R' clone '$(b64 "file://$ORIGIN")' '$(b64 migrate/operator-records)' '$(b64 "$T/deny")'"
check "nothing cloned for the refused branch" bash -c "[ ! -e '$T/deny/demo-toolkit' ]"
check "git: shows branch + last commit" bash -c "'$R' git | grep -q '## migration/v2...origin/migration/v2' && '$R' git | grep -q 'v2 work'"
check "checkout: existing remote branch main" bash -c "'$R' checkout '$(b64 main)' | grep -q 'branch: main'"
check "checkout: new branch is created locally" bash -c "'$R' checkout '$(b64 feature/ftk-test)' | grep -q 'created locally'"
check "checkout: bad branch name rejected" bash -c "! '$R' checkout '$(b64 'bad..name')'"
echo dirty >> "$REPO/README.md"
check "checkout: refuses with uncommitted changes" bash -c "'$R' checkout '$(b64 main)' | grep -q 'uncommitted changes'"
git -C "$REPO" checkout -q -- README.md
"$R" checkout "$(b64 migration/v2)" >/dev/null
check "clone: missing args -> usage error" bash -c "! '$R' clone"
check "clone: inaccessible repo -> error exit" bash -c "! '$R' clone '$(b64 "file://$T/nope.git")' - '$(b64 "$T/x")' 2>/dev/null"
# host setup with EMPTY repo url -> existing folder is used
SAVE="$(cat "$HOME/.ftk/project")"
OUT3="$(FTK_PICK="Existing folder" FTK_REPO_URL= FTK_REPO_BRANCH= bash "$ROOT/host-setup-mac.command" 2>&1)" && ok "host setup with empty URL (existing folder) exits 0" || bad "host setup with empty URL exits 0" "$OUT3"
[ "$(cat "$HOME/.ftk/project")" = "$FTK_PROJECT" ] && ok "empty URL -> chosen existing folder becomes project" || bad "empty URL -> chosen folder" "$(cat "$HOME/.ftk/project")"
"$R" setproject "$(b64 "$SAVE")" >/dev/null

# ======================================================================
section "3c. Lanes, wait, run, text log"
OUTL="$("$R" new-lane a1 "$(b64 migrate/s2-a1)" 2>&1)" && ok "new-lane a1 (new branch)" || bad "new-lane a1" "$OUTL"
WT1="$(dirname "$REPO")/demo-toolkit-a1"
check "worktree created" test -f "$WT1/V2.md"
[ "$(git -C "$WT1" rev-parse --abbrev-ref HEAD)" = "migrate/s2-a1" ] && ok "lane on branch migrate/s2-a1" || bad "lane branch"
check "new lane branch does NOT track the base branch" bash -c "! git -C '$WT1' rev-parse --abbrev-ref '@{u}' 2>/dev/null"
check "lane session ftk-a1 running" tmux -L "$FTK_TMUX" has-session -t =ftk-a1
LP="$(tmux -L "$FTK_TMUX" display -p -t =ftk-a1: '#{pane_current_path}')"
[ "$LP" = "$(cd "$WT1" && pwd -P)" ] && ok "lane session runs in its worktree" || bad "lane session dir" "$LP"
check "lane session has FTK_SESSION_NAME=ftk-a1" bash -c "tmux -L '$FTK_TMUX' show-environment -t =ftk-a1 FTK_SESSION_NAME | grep -qx 'FTK_SESSION_NAME=ftk-a1'"
check "lane agent ready" wait_for "FAKE AGENT READY" "$R" -s a1 peek
OUTL="$("$R" new-lane b2 "$(b64 migrate/s2-b2)" 2>&1)" && ok "new-lane b2 (branch exists on origin)" || bad "new-lane b2" "$OUTL"
WT2="$(dirname "$REPO")/demo-toolkit-b2"
check "b2 has the origin commit" test -f "$WT2/B2.md"
[ "$(git -C "$WT2" rev-parse --abbrev-ref '@{u}')" = "origin/migrate/s2-b2" ] && ok "b2 tracks origin/migrate/s2-b2" || bad "b2 upstream"
check "new-lane: operator-records refused" bash -c "! '$R' new-lane x1 '$(b64 migrate/operator-records)'"
check "new-lane: bad name refused" bash -c "! '$R' new-lane 'A;b' '$(b64 x)'"
check "-s: bad lane name refused" bash -c "! '$R' -s 'x;y' status"
check "refspecs are exact branches only (no wildcard)" bash -c "! git -C '$REPO' config --get-all remote.origin.fetch | grep -q '\*'"
[ "$(git -C "$REPO" for-each-ref | grep -c operator-records)" = 0 ] && ok "operator-records never fetched into the clone" || bad "operator-records leaked into refs"
"$R" -s a1 say "$(b64 "только для a1")" >/dev/null
check "-s a1 say reaches lane a1" wait_for "AGENT GOT: только для a1" "$R" -s a1 peek
check "... and not the main agent" bash -c "! '$R' peek | grep -q 'только для a1'"
check "say sets state busy" grep -q '^busy ' "$HOME/.ftk/state-ftk-a1"
"$R" -s a1 wait 2 >/dev/null; [ $? -eq 124 ] && ok "wait times out (124) while busy" || bad "wait timeout"
( sleep 1; FTK_SESSION_NAME=ftk-a1 "$R" notify stop </dev/null ) &
WOUT="$("$R" -s a1 wait 15)"; [ "$WOUT" = "stop" ] && ok "wait returns 'stop' when the Stop hook fires" || bad "wait returns stop" "$WOUT"
check "wait returns at once when already stopped" bash -c "[ \"\$('$R' -s a1 wait 1)\" = stop ]"
check "lanes lists main, a1, b2" bash -c "'$R' lanes | grep -q '^ftk ' && '$R' lanes | grep -q '^ftk-a1 ' && '$R' lanes | grep -q '^ftk-b2 '"
check "status -s a1 shows lane project" bash -c "'$R' -s a1 status | grep -q 'demo-toolkit-a1'"
ROUT="$("$R" -s a1 run "$(b64 'pwd; git rev-parse --abbrev-ref HEAD; echo "q\"x"; exit 3')")"; RRC=$?
[ $RRC -eq 3 ] && ok "run returns the command's exit code" || bad "run exit code" "$RRC"
echo "$ROUT" | grep -q 'demo-toolkit-a1' && echo "$ROUT" | grep -q '^migrate/s2-a1$' && echo "$ROUT" | grep -q '^\[exit 3\]$' && ok "run: output, cwd = lane worktree, [exit 3]" || bad "run output" "$ROUT"
check "run: no stdin (non-interactive)" bash -c "'$R' run '$(b64 'cat; echo done')' | grep -q '^done$'"
# text log from a Claude-shaped transcript in the project's transcript folder
ENC="$(printf '%s' "$REPO" | sed 's/[^A-Za-z0-9]/-/g')"; mkdir -p "$HOME/.claude/projects/$ENC"
cat > "$HOME/.claude/projects/$ENC/t.jsonl" <<'JL'
{"type":"user","message":{"role":"user","content":"run the tests"}}
{"type":"assistant","message":{"content":[{"type":"text","text":"Running pytest now."},{"type":"tool_use","name":"Bash","input":{"command":"python3 -m pytest -q"}}]}}
{"type":"user","message":{"content":[{"type":"tool_result","content":"412 passed, 0 failed"}]}}
{"type":"assistant","message":{"content":[{"type":"text","text":"All green."}]}}
JL
LOGT="$("$R" log 10)"
echo "$LOGT" | grep -q '^assistant: Running pytest now.$' && echo "$LOGT" | grep -q '^tool_use Bash: python3 -m pytest -q$' && echo "$LOGT" | grep -q '^tool_result: 412 passed, 0 failed$' && ok "log: plain text (assistant / tool_use / tool_result)" || bad "log text" "$LOGT"
[ "$("$R" log 1 | tail -1)" = "assistant: All green." ] && ok "log N limits to the last N messages" || bad "log N"

# ======================================================================
section "3d. Repo provided by the teammate / shipped as a bundle"
H2="$T/home2"; mkdir -p "$H2"; touch "$H2/.bashrc"
OUTD="$(HOME="$H2" FTK_PICK= bash "$ROOT/host-setup-mac.command" 2>&1)" && ok "host setup, default choice 'Teammate sends it' exits 0" || bad "teammate mode exits 0" "$OUTD"
check "teammate mode: nothing cloned, project unset" bash -c "[ ! -f '$H2/.ftk/project' ] && [ ! -d '$H2/Projects' ]"
check "teammate mode: run works without a project (in ~/.ftk/xfer)" bash -c "HOME='$H2' '$H2/.ftk/ftk-remote' run '$(b64 pwd)' | grep -q '/.ftk/xfer$'"
check "setproject: ~/ is expanded on the host" bash -c "mkdir -p '$H2/Projects/p'; HOME='$H2' '$H2/.ftk/ftk-remote' setproject '$(b64 '~/Projects/p')' | grep -qx 'project: $H2/Projects/p'"
check "setproject: missing folder refused" bash -c "! HOME='$H2' '$H2/.ftk/ftk-remote' setproject '$(b64 '~/nope')'"
# bundle: exactly one ref, nothing private
BUN="$T/b1.bundle"; git -C "$T/seed" bundle create -q "$BUN" migration/v2
BUN2="$T/b2.bundle"; git -C "$T/seed" bundle create -q "$BUN2" migration/v2 main
H3="$T/home3"; mkdir -p "$H3"; cp "$R" "$T/r3"; RB="$T/r3"
check "unbundle: bundle with 2 refs refused" bash -c "! HOME='$H3' '$RB' unbundle '$(b64 "$BUN2")' '$(b64 migration/v2)' '$(b64 '~/Projects/x')'"
check "unbundle: wrong branch refused" bash -c "! HOME='$H3' '$RB' unbundle '$(b64 "$BUN")' '$(b64 main)' '$(b64 '~/Projects/x')'"
check "unbundle: operator-records refused" bash -c "! HOME='$H3' '$RB' unbundle '$(b64 "$BUN")' '$(b64 migrate/operator-records)' '$(b64 '~/Projects/x')'"
OUTU="$(HOME="$H3" "$RB" unbundle "$(b64 "$BUN")" "$(b64 migration/v2)" "$(b64 '~/Projects/proj')" 2>&1)" && ok "unbundle ok" || bad "unbundle" "$OUTU"
D3="$H3/Projects/proj"
check "unbundle: no origin remote" bash -c "! git -C '$D3' remote get-url origin"
[ "$(git -C "$D3" for-each-ref --format='%(refname)')" = "refs/heads/migration/v2" ] && ok "unbundle: only refs/heads/migration/v2" || bad "unbundle refs" "$(git -C "$D3" for-each-ref)"
check "unbundle: project + base branch set" bash -c "[ \"\$(cat '$H3/.ftk/project')\" = '$D3' ] && grep -qx migration/v2 '$H3/.ftk/base-branch'"
OUTL="$(HOME="$H3" "$RB" new-lane z1 "$(b64 migrate/s2-z1)" 2>&1)" && ok "new-lane works with no origin (cut from local base)" || bad "new-lane without origin" "$OUTL"
[ "$(git -C "$H3/Projects/proj-z1" rev-parse HEAD)" = "$(git -C "$D3" rev-parse migration/v2)" ] && ok "lane z1 starts at local migration/v2" || bad "lane z1 start"
check "checkout works with no origin" bash -c "HOME='$H3' '$RB' checkout '$(b64 feature/x)' | grep -q 'created locally'"
HOME="$H3" "$RB" checkout "$(b64 migration/v2)" >/dev/null
tmux -L "$FTK_TMUX" kill-session -t =ftk-z1 2>/dev/null

# ======================================================================
section "4. Client setup (Mac) -> Mac host, through ssh"
printf 'Host other\n  HostName example.com\n' > "$T/pre_config"
mkdir -p "$HOME/.ssh"; cp "$T/pre_config" "$HOME/.ssh/config"
: > "$T/clipboard_in"   # nothing pasted: the line must come from the ntfy 'host ready' push
OUT="$(bash "$ROOT/client-setup-mac.command" 2>&1)"; RC=$?
[ $RC -eq 0 ] && ok "client setup exits 0 with line auto-taken from ntfy" || bad "client setup exits 0 (line from ntfy)" "$OUT"
check "client used the host line from ntfy" grep -q "User $(whoami)" "$HOME/.ssh/config"
echo "FTK|100.64.0.9|tester|mac" > "$T/clipboard_in"
OUT="$(bash "$ROOT/client-setup-mac.command" 2>&1)"; RC=$?
[ $RC -eq 0 ] && ok "client setup re-run exits 0" || bad "client setup re-run exits 0" "$OUT"
check "ssh key created" test -f "$HOME/.ssh/ftk_ed25519"
grep -q '^ssh-ed25519 ' "$T/clipboard_out" && ok "public key copied to clipboard" || bad "public key copied to clipboard"
[ "$(grep -c '^Host ftk$' "$HOME/.ssh/config")" = 1 ] && ok "ssh config: exactly one 'Host ftk' after re-run" || bad "ssh config: one Host ftk" "$(cat "$HOME/.ssh/config")"
check "ssh config: other hosts preserved" grep -q '^Host other$' "$HOME/.ssh/config"
check "ssh config: HostName / User / ControlMaster" bash -c "grep -q 'HostName 100.64.0.9' '$HOME/.ssh/config' && grep -q 'User tester' '$HOME/.ssh/config' && grep -q 'ControlMaster auto' '$HOME/.ssh/config'"
FTK="$HOME/.local/bin/ftk"
check "ftk installed" test -x "$FTK"
check "ftk status" wait_for "session: running" "$FTK" status
"$FTK" say "Сообщение от клиента: проверь тесты" >/dev/null
check "ftk say (Cyrillic) reaches agent" wait_for "AGENT GOT: Сообщение от клиента: проверь тесты" "$FTK" peek 50
check "ftk key rejects bad name" bash -c "! '$FTK' key 'x;y'"
check "ftk peek rejects bad number" bash -c "! '$FTK' peek '1;ls'"
check "ftk git" bash -c "'$FTK' git | grep -q 'migration/v2'"
check "ftk checkout main + back" bash -c "'$FTK' checkout main | grep -q 'branch: main' && '$FTK' checkout migration/v2 | grep -q 'branch: migration/v2'"
check "ftk events lists notifications" bash -c "'$FTK' events all | grep -q 'FTK host ready'"
check "ftk events rejects bad since" bash -c "! '$FTK' events 'x;y'"
check "ftk -s a1 peek / say" bash -c "'$FTK' -s a1 say 'клиент в a1' >/dev/null; sleep 1; '$FTK' -s a1 peek | grep -q 'AGENT GOT: клиент в a1'"
check "ftk -s a1 run" bash -c "'$FTK' -s a1 run 'git rev-parse --abbrev-ref HEAD' | grep -q '^migrate/s2-a1$'"
check "ftk lanes" bash -c "'$FTK' lanes | grep -q '^ftk-b2 '"
check "ftk -s a1 wait (after hook)" bash -c "FTK_SESSION_NAME=ftk-a1 '$R' notify stop </dev/null; [ \"\$('$FTK' -s a1 wait 5)\" = stop ]"
check "ftk log (text)" bash -c "'$FTK' log 3 | grep -q 'All green.'"
check "ftk -s rejects bad lane" bash -c "! '$FTK' -s 'x;y' peek"
head -c 300000 /dev/urandom > "$T/blob.bin"
check "ftk put: binary file, sha256 matches" bash -c "'$FTK' put '$T/blob.bin' in/blob.bin | grep -q \"sha256 \$(shasum -a 256 '$T/blob.bin' | cut -d' ' -f1)\""
check "ftk get: round-trip identical" bash -c "'$FTK' get in/blob.bin '$T/blob.back' >/dev/null && cmp '$T/blob.bin' '$T/blob.back'"
check "ftk xfer lists the file" bash -c "'$FTK' xfer | grep -qx 'in/blob.bin'"
check "put: '..' path refused" bash -c "! '$FTK' put '$T/blob.bin' ../evil 2>/dev/null; [ ! -e '$HOME/.ftk/evil' ]"
check "get: missing file fails" bash -c "! '$FTK' get nope.bin '$T/nope' 2>/dev/null"
check "ftk help lists commands" bash -c "'$FTK' help | grep -q 'ftk new-lane'"

# ======================================================================
section "5. Windows host (native, headless, no WSL) through the client"
echo "FTK|100.64.0.10|tester|windows" > "$T/clipboard_in"
OUT="$(bash "$ROOT/client-setup-mac.command" 2>&1)"; RC=$?
[ $RC -eq 0 ] && ok "client setup (windows host) exits 0" || bad "client setup (windows host) exits 0" "$OUT"
check "client.conf uses the native PowerShell helper" grep -qF "$WINR" "$HOME/.ftk/client.conf"
[ "$(grep -c '^Host ftk$' "$HOME/.ssh/config")" = 1 ] && ok "ssh config still one block" || bad "ssh config block"
check "HostName switched to new IP" grep -q 'HostName 100.64.0.10' "$HOME/.ssh/config"
check "status: headless Windows session" bash -c "'$FTK' status | grep -q 'headless, Windows'"
"$FTK" say "Привет, Windows-агент: \"q\" & | ; %PATH%" >/dev/null
check "wait returns stop after the turn" bash -c "[ \"\$('$FTK' wait 30)\" = stop ]"
check "peek: agent text (Cyrillic + metachars exact)" bash -c "'$FTK' peek | grep -qF 'assistant: ECHO: Привет, Windows-агент: \"q\" & | ; %PATH%'"
check "peek: tool_use + tool_result + result" bash -c "'$FTK' peek | grep -q '^tool_use Bash: python -m pytest -q$' && '$FTK' peek | grep -q '^tool_result: 412 passed$' && '$FTK' peek | grep -q 'result (success): done; resumed=False'"
"$FTK" say "second turn" >/dev/null; "$FTK" wait 30 >/dev/null
check "second say resumes the same conversation (--resume)" bash -c "'$FTK' peek | grep -q 'resumed=True'"
check "status shows the conversation id" bash -c "'$FTK' status | grep -q 'conversation: sess-'"
"$FTK" say "SLOW turn" >/dev/null; sleep 2
check "say while busy is refused" bash -c "'$FTK' say 'again' | grep -q '^busy'"
check "wait times out (124) while busy" bash -c "'$FTK' wait 1 >/dev/null; [ \$? -eq 124 ]"
check "key C-c stops the running turn" bash -c "'$FTK' key C-c | grep -q 'stopped the current turn'"
check "state after stop = stopped (wait returns at once)" bash -c "[ \"\$('$FTK' wait 5)\" = stopped ]"
check "key 1 is explained, not sent (exit 2)" bash -c "'$FTK' key 1 | grep -q 'headless'; [ \${PIPESTATUS[0]} -eq 2 ]"
"$FTK" say "FAIL please" >/dev/null
check "a failing turn ends in state error" bash -c "[ \"\$('$FTK' wait 30)\" = error ]"
"$FTK" say "DENY please" >/dev/null; "$FTK" wait 30 >/dev/null
check "permission denials are shown with the allowlist hint" bash -c "'$FTK' peek | grep -q 'permission denied: Bash - allow it in .claude/settings.local.json'"
check "log: all turns as text" bash -c "'$FTK' log 200 | grep -q 'ECHO: second turn' && '$FTK' log 200 | grep -q 'ECHO: DENY please'"
check "log raw: jsonl" bash -c "'$FTK' log 5 raw | grep -q '\"type\": \"result\"\|\"type\":\"result\"'"
check "restart: next say is a new conversation" bash -c "'$FTK' restart >/dev/null && '$FTK' say 'fresh' >/dev/null && '$FTK' wait 30 >/dev/null && '$FTK' peek | grep -q 'resumed=False'"
check "watch/drive: explained (no live terminal)" bash -c "'$FTK' watch 2>&1 | grep -q 'headless'"
ROUT="$("$FTK" run 'echo hi; echo "q\"x"; exit 4')"
echo "$ROUT" | grep -q '^hi$' && echo "$ROUT" | grep -q '^\[exit 4\]$' && ok "run: bash command output + [exit 4]" || bad "run on windows host" "$ROUT"
check "run without project runs in ~/.ftk/xfer" bash -c "'$FTK' run pwd | grep -q 'winhost/.ftk/xfer$'"
check "put/get round-trip (binary)" bash -c "'$FTK' put '$T/blob.bin' w/blob.bin | grep -q \"sha256 \$(shasum -a 256 '$T/blob.bin' | cut -d' ' -f1)\" && '$FTK' get w/blob.bin '$T/blob.win' >/dev/null && cmp '$T/blob.bin' '$T/blob.win'"
check "put: '..' refused" bash -c "! '$FTK' put '$T/blob.bin' ../x >/dev/null 2>&1"
check "xfer lists the file" bash -c "'$FTK' xfer | grep -qx 'w/blob.bin'"
# repo from a bundle, lanes without origin
"$FTK" put "$BUN" v2.bundle >/dev/null
UB="$(ssh ftk "$WINR unbundle $(b64 "$T/winhost/.ftk/xfer/v2.bundle") $(b64 migration/v2) $(b64 '~/proj/dct')")"
echo "$UB" | grep -q 'unpacked:' && ok "unbundle (no origin)" || bad "unbundle on windows host" "$UB"
check "git shows the bundled branch" bash -c "'$FTK' git | grep -q '## migration/v2'"
check "new-lane w1 cut from local base" bash -c "'$FTK' new-lane w1 migrate/s2-w1 | grep -q 'lane ftk-w1 ready'"
check "lanes lists main + w1" bash -c "'$FTK' lanes | grep -q '^ftk ' && '$FTK' lanes | grep -q '^ftk-w1 '"
check "-s w1 run: on the lane branch in its worktree" bash -c "'$FTK' -s w1 run 'git rev-parse --abbrev-ref HEAD; pwd' | grep -q '^migrate/s2-w1$'"
"$FTK" -s w1 say "lane message" >/dev/null; "$FTK" -s w1 wait 30 >/dev/null
check "-s w1 say goes to the lane only" bash -c "'$FTK' -s w1 peek | grep -q 'ECHO: lane message' && ! '$FTK' peek | grep -q 'lane message'"
check "operator-records refused (new-lane)" bash -c "'$FTK' new-lane x9 migrate/operator-records | grep -q 'not allowed'"
check "operator-records refused -> exit code != 0, no worktree" bash -c "! '$FTK' new-lane x8 migrate/operator-records >/dev/null; [ ! -e '$T/winhost/proj/dct-x8' ]"
check "checkout of operator-records refused" bash -c "! '$FTK' checkout migrate/operator-records >/dev/null"
check "setproject ~/ expands on the host" bash -c "'$FTK' -s w1 setproject '~/proj/dct-w1' | grep -q 'proj/dct-w1'"
check "ssh received plain '<helper> say <base64>' (no quotes)" bash -c "grep -E 'ftk-remote.ps1 say [A-Za-z0-9+/=]+$' '$T/ssh.log'"
check "turn end posts to ntfy" bash -c "curl -fsS '$FTK_NTFY_URL/$FTK_NTFY_TOPIC/json?poll=1' | grep -q 'finished a turn'" || true

# ======================================================================
section "6. PowerShell scripts"
if [ -z "$PWSH" ]; then
  bad "pwsh available" "could not get PowerShell - PS tests skipped"
else
  for f in host-setup-windows.ps1 client-setup-windows.ps1 ftk-remote.ps1; do
    PERR="$("$PWSH" -NoProfile -Command "\$e=\$null; [void][System.Management.Automation.Language.Parser]::ParseFile('$ROOT/$f',[ref]\$null,[ref]\$e); \$e | % { \$_.ToString() }")"
    [ -z "$PERR" ] && ok "PowerShell parse: $f" || bad "PowerShell parse: $f" "$PERR"
  done
  # extract the ftk.ps1 that the Windows client installs, run it with the ssh stub
  sed -n "/^\$ftkPs1 = @'\$/,/^'@\$/p" "$ROOT/client-setup-windows.ps1" | sed '1d;$d' > "$T/ftk.ps1"
  PERR="$("$PWSH" -NoProfile -Command "\$e=\$null; [void][System.Management.Automation.Language.Parser]::ParseFile('$T/ftk.ps1',[ref]\$null,[ref]\$e); \$e | % { \$_.ToString() }")"
  [ -z "$PERR" ] && ok "PowerShell parse: embedded ftk.ps1" || bad "PowerShell parse: embedded ftk.ps1" "$PERR"
  printf '{"remote":"~/.ftk/ftk-remote","topic":"%s","ntfy":"%s"}\n' "$FTK_NTFY_TOPIC" "$FTK_NTFY_URL" > "$HOME/.ftk/client.conf"
  check "ftk.ps1 events" bash -c "'$PWSH' -NoProfile -File '$T/ftk.ps1' events all | grep -q 'FTK host ready'"
  for mode in mac windows; do
    if [ $mode = mac ]; then rem='~/.ftk/ftk-remote'; got='AGENT GOT:'; st='session: running'; else rem="${WINR//\\/\\\\}"; got='assistant: ECHO:'; st='headless, Windows'; fi
    printf '{"remote":"%s"}\n' "$rem" > "$HOME/.ftk/client.conf"
    "$PWSH" -NoProfile -File "$T/ftk.ps1" say "PS клиент ($mode): \"кавычки\" & | ;" >/dev/null 2>&1
    [ $mode = windows ] && "$PWSH" -NoProfile -File "$T/ftk.ps1" wait 30 >/dev/null 2>&1
    check "ftk.ps1 say -> $mode host" wait_for "$got PS клиент ($mode): \"кавычки\" & | ;" "$PWSH" -NoProfile -File "$T/ftk.ps1" peek 50
    check "ftk.ps1 status -> $mode host" wait_for "$st" "$PWSH" -NoProfile -File "$T/ftk.ps1" status
  done
  printf '{"remote":"~/.ftk/ftk-remote"}\n' > "$HOME/.ftk/client.conf"   # back to the mac host for the rest
  check "ftk.ps1 checkout + git" bash -c "'$PWSH' -NoProfile -File '$T/ftk.ps1' checkout main | grep -q 'branch: main' && '$PWSH' -NoProfile -File '$T/ftk.ps1' git | grep -q '## main'"
  "$PWSH" -NoProfile -File "$T/ftk.ps1" checkout migration/v2 >/dev/null 2>&1
  check "ftk.ps1 -s a1 run" bash -c "'$PWSH' -NoProfile -File '$T/ftk.ps1' -s a1 run 'git rev-parse --abbrev-ref HEAD' | grep -q '^migrate/s2-a1$'"
  check "ftk.ps1 -s a1 say" bash -c "'$PWSH' -NoProfile -File '$T/ftk.ps1' -s a1 say 'ps в a1' >/dev/null; sleep 1; '$PWSH' -NoProfile -File '$T/ftk.ps1' -s a1 peek | grep -q 'AGENT GOT: ps в a1'"
  check "ftk.ps1 put/get round-trip" bash -c "cd '$T' && '$PWSH' -NoProfile -File '$T/ftk.ps1' put blob.bin ps/blob.bin >/dev/null && '$PWSH' -NoProfile -File '$T/ftk.ps1' get ps/blob.bin blob.ps >/dev/null && cmp blob.bin blob.ps"
  check "ftk.ps1 lanes" bash -c "'$PWSH' -NoProfile -File '$T/ftk.ps1' lanes | grep -q '^ftk-a1 '"
  check "ftk.ps1 key rejects bad name" bash -c "! '$PWSH' -NoProfile -File '$T/ftk.ps1' key 'a;b'"
  check "ftk.ps1 help" bash -c "'$PWSH' -NoProfile -File '$T/ftk.ps1' help | grep -q 'ftk new-lane'"
fi

# ======================================================================
section "6b. MCP server (ftk-bridge) over stdio"
printf '{"remote":"~/.ftk/ftk-remote","topic":"%s","ntfy":"%s"}\n' "$FTK_NTFY_TOPIC" "$FTK_NTFY_URL" > /dev/null
printf "FTK_REMOTE='~/.ftk/ftk-remote'\nFTK_TOPIC='%s'\nFTK_NTFY='%s'\n" "$FTK_NTFY_TOPIC" "$FTK_NTFY_URL" > "$HOME/.ftk/client.conf"
while IFS= read -r line; do
  case "$line" in ok\ *) ok "${line#ok }";; bad\ *) n="${line#bad }"; bad "${n%% :: *}" "${n#* :: }";; esac
done < <(FTK_BIN="$HOME/.local/bin/ftk" python3 "$ROOT/tests/mcp_check.py" "$ROOT/ftk-mcp.py" 2>&1)

# ======================================================================
section "7. package.sh (archive for the teammate)"
PK_HOME="$T/pkhome"; mkdir -p "$PK_HOME"
cp -R "$ROOT" "$T/src"; rm -rf "$T/src/dist" "$T/src/tests/.cache" "$T/src/local.env" "$T/src/migration"
# fixture migration files (the real ones are local-only, not in the repo)
MIGF="$T/src/migration"; mkdir -p "$MIGF"
printf '# Migration\nfixture\n' > "$MIGF/MIGRATION.md"
printf -- '---\nname: migration-worker\n---\nfixture agent\n' > "$MIGF/migration-worker.md"
printf '#!/bin/bash\necho fixture env\n' > "$MIGF/setup-migration-env.sh"
printf 'REPO_URL="https://git.example.com/acme/docs-kit.git"\nREPO_BRANCH="v2"\n' > "$T/src/local.env"
OUT="$(HOME="$PK_HOME" bash "$T/src/package.sh" https://git.example.com/acme/demo-toolkit.git migration/v2 2>&1)" && ok "package.sh exits 0" || bad "package.sh exits 0" "$OUT"
Z="$T/src/dist/ftk-host.zip"; mkdir -p "$T/unz"; unzip -q "$Z" -d "$T/unz" 2>/dev/null
D="$T/unz/ftk-host"
for f in host-setup-mac.command host-setup-windows.ps1 host-setup-windows.cmd START-HERE.md README.md teammate.pub MIGRATION.md migration-worker.md setup-migration-env.sh; do
  check "zip contains $f" test -f "$D/$f"
done
check "zip has no client scripts / tests" bash -c "! ls '$D' | grep -qE 'client-|tests|package'"
for f in MIGRATION.md migration-worker.md setup-migration-env.sh; do check "zip: $f is a verbatim copy" cmp "$D/$f" "$MIGF/$f"; done
check "zip: no other migration content (gatekeeper / delegation / records)" bash -c "! ls '$D' | grep -qiE 'gatekeeper|delegation|records'"
check "teammate.pub = your key" cmp "$D/teammate.pub" "$PK_HOME/.ssh/ftk_ed25519.pub"
PT="$(cat "$PK_HOME/.ftk/ntfy-topic")"
check "topic is random ftk-<24 hex>" bash -c "[[ '$PT' =~ ^ftk-[0-9a-f]{24}\$ ]]"
check "mac script: topic/repo/branch filled" bash -c "grep -q 'NTFY_TOPIC=\"$PT\"' '$D/host-setup-mac.command' && grep -q 'REPO_URL=\"https://git.example.com/acme/demo-toolkit.git\"' '$D/host-setup-mac.command' && grep -q 'REPO_BRANCH=\"migration/v2\"' '$D/host-setup-mac.command'"
check "windows script: topic/repo/branch filled" bash -c "grep -q \"NtfyTopic  = '$PT'\" '$D/host-setup-windows.ps1' && grep -q \"RepoBranch = 'migration/v2'\" '$D/host-setup-windows.ps1'"
check "mac script in zip is executable + valid bash" bash -c "[ -x '$D/host-setup-mac.command' ] && bash -n '$D/host-setup-mac.command'"
[ -n "$PWSH" ] && { PERR="$("$PWSH" -NoProfile -Command "\$e=\$null; [void][System.Management.Automation.Language.Parser]::ParseFile('$D/host-setup-windows.ps1',[ref]\$null,[ref]\$e); \$e | % { \$_.ToString() }")"; [ -z "$PERR" ] && ok "windows script in zip parses" || bad "windows script in zip parses" "$PERR"; }
check "package.sh rejects quotes in url" bash -c "! HOME='$PK_HOME' bash '$T/src/package.sh' 'http://x\"y' 2>/dev/null"
OUT2="$(HOME="$PK_HOME" bash "$T/src/package.sh" 2>&1)"
[ "$(cat "$PK_HOME/.ftk/ntfy-topic")" = "$PT" ] && ok "re-run keeps the same topic + key" || bad "re-run keeps topic"
OUTB="$(HOME="$PK_HOME" FTK_BUNDLE_FROM="$T/seed" FTK_BUNDLE_REF=origin/migration/v2 bash "$T/src/package.sh" "file://$ORIGIN" migration/v2 2>&1)" && ok "package.sh with bundle exits 0" || bad "package with bundle" "$OUTB"
rm -rf "$T/unzb"; unzip -q "$T/src/dist/ftk-host.zip" -d "$T/unzb"
check "zip ships repo.bundle" test -f "$T/unzb/ftk-host/repo.bundle"
[ "$(git bundle list-heads "$T/unzb/ftk-host/repo.bundle" | awk '{print $2}')" = "refs/heads/migration/v2" ] && ok "bundle = exactly refs/heads/migration/v2 (no operator-records)" || bad "bundle refs" "$(git bundle list-heads "$T/unzb/ftk-host/repo.bundle")"
H4="$T/home4"; mkdir -p "$H4"; touch "$H4/.bashrc"
OUTH="$(HOME="$H4" FTK_PICK= bash "$T/unzb/ftk-host/host-setup-mac.command" 2>&1)" && ok "host setup from the zip with repo.bundle exits 0 (no repo questions)" || bad "host setup with bundle" "$OUTH"
P4="$(cat "$H4/.ftk/project" 2>/dev/null)"
check "host setup installs ~/.claude/agents/migration-worker.md" cmp "$H4/.claude/agents/migration-worker.md" "$MIGF/migration-worker.md"
check "host setup copies setup-migration-env.sh to ~/.ftk (executable, not run)" bash -c "[ -x '$H4/.ftk/setup-migration-env.sh' ] && cmp '$H4/.ftk/setup-migration-env.sh' '$MIGF/setup-migration-env.sh' && [ ! -d '$H4/.ftk/venv-proj' ]"
check "bundled repo unpacked to ~/Projects/demo-toolkit" bash -c "[ '$P4' = '$H4/Projects/demo-toolkit' ] && [ -f '$P4/V2.md' ] && ! git -C '$P4' remote get-url origin"
check "no 'Repository' dialog shown in bundle mode" bash -c "! grep -q 'Where does the code come from' '$T/dialogs.log' || [ \"\$(grep -c 'Where does the code come from' '$T/dialogs.log')\" = \"\$(grep -c 'Where does the code come from' '$T/dialogs.log')\" ]"
check "package.sh refuses to bundle operator-records" bash -c "! HOME='$PK_HOME' FTK_BUNDLE_FROM='$T/seed' bash '$T/src/package.sh' x migrate/operator-records >/dev/null 2>&1"
check "no args: repo/branch defaults come from local.env" bash -c "HOME='$PK_HOME' bash '$T/src/package.sh' >/dev/null 2>&1; rm -rf '$T/unz2'; unzip -q '$T/src/dist/ftk-host.zip' -d '$T/unz2' && grep -q '^REPO_URL=\"https://git.example.com/acme/docs-kit.git\"' '$T/unz2/ftk-host/host-setup-mac.command' && grep -q '^REPO_BRANCH=\"v2\"' '$T/unz2/ftk-host/host-setup-mac.command' && grep -q \"RepoBranch = 'v2'\" '$T/unz2/ftk-host/host-setup-windows.ps1'"

# ======================================================================
printf '\n\033[1mResult: %d passed, %d failed\033[0m\n' "$PASS" "$FAIL"
for f in "${FAILED[@]}"; do echo "  - $f"; done
[ "$FAIL" -eq 0 ]
