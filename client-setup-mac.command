#!/bin/bash
# FTK Remote - CLIENT setup for macOS (run on YOUR Mac).
# Creates an SSH key, connects to the teammate's machine over Tailscale
# and installs the `ftk` command (peek / say / key / watch / ...).
# Safe to run again at any time.

TITLE="FTK Remote - Client setup (Mac)"
KEYFILE="$HOME/.ssh/ftk_ed25519"
NTFY="${FTK_NTFY_URL:-https://ntfy.sh}"
TOPIC="$(cat "$HOME/.ftk/ntfy-topic" 2>/dev/null)"   # written by package.sh
BIN="$HOME/.local/bin"

step() {
  osascript - "$1" "$TITLE" <<'OSA' >/dev/null || { echo "Cancelled."; exit 1; }
on run argv
  display dialog (item 1 of argv) with title (item 2 of argv) buttons {"Cancel", "OK"} default button "OK"
end run
OSA
}
info() {
  osascript - "$1" "$TITLE" <<'OSA' >/dev/null
on run argv
  display dialog (item 1 of argv) with title (item 2 of argv) buttons {"OK"} default button "OK"
end run
OSA
}
ask() {
  osascript - "$1" "$2" "$TITLE" <<'OSA' || { echo "Cancelled." >&2; exit 1; }
on run argv
  text returned of (display dialog (item 1 of argv) default answer (item 2 of argv) with title (item 3 of argv) buttons {"Cancel", "OK"} default button "OK")
end run
OSA
}

# ---------- Step 0: welcome ----------
step "This connects you to your teammate's Claude Code agent.

Steps:
1. Tailscale (private network)
2. Create your SSH key and send it to your teammate
3. Paste the connection line your teammate sends back
4. Install the 'ftk' command and test the connection

Order: YOU run this first -> teammate runs the host script -> you finish here.
Click OK to start."

# ---------- Step 1: Tailscale ----------
if [ ! -d /Applications/Tailscale.app ]; then
  open "https://tailscale.com/download/mac"
  step "Step 1/4 - Tailscale

Tailscale is not installed. The download page is now open.
1. Download and install Tailscale.
2. Open it and log in.
3. Click OK here when the menu bar icon shows Connected."
fi
open -a Tailscale 2>/dev/null
step "Step 1/4 - Tailscale

Make sure Tailscale is running and logged in.

If your teammate uses a DIFFERENT Tailscale account, they will send you a Share invite link - open it and accept.

Click OK to continue."

# ---------- Step 2: SSH key ----------
mkdir -p "$HOME/.ssh" && chmod 700 "$HOME/.ssh"
[ -f "$KEYFILE" ] || ssh-keygen -t ed25519 -N "" -C "ftk-$(whoami)@$(hostname -s)" -f "$KEYFILE" -q
pbcopy < "$KEYFILE.pub"
if [ -n "$TOPIC" ]; then
  step "Step 2/4 - Your SSH key

Your key is already inside the package made by package.sh (teammate.pub).
Wait until the host finishes - you get a push 'FTK host ready' (ntfy topic $TOPIC).

Click OK when it has arrived (or when your teammate sent you the FTK| line)."
else
step "Step 2/4 - Your SSH key

Your public key is COPIED to the clipboard:

$(cat "$KEYFILE.pub")

1. Send it to your teammate (Slack / Teams).
2. They run the HOST setup script and paste it when asked.
3. They send you back a line that starts with FTK|

Click OK when you have that line."
fi

# ---------- Step 3: connection line ----------
LINE=""
CLIP="$(pbpaste 2>/dev/null | head -1)"
case "$CLIP" in FTK\|*) LINE="$CLIP";; esac
if [ -z "$LINE" ] && [ -n "$TOPIC" ]; then  # no line copied: take the newest one the host posted to ntfy
  NL="$(curl -fsS -m 10 "$NTFY/$TOPIC/json?poll=1&since=all" 2>/dev/null | grep -o '"message": *"FTK|[^"]*"' | tail -1 | sed 's/^"message": *"//; s/"$//')"
  [ -n "$NL" ] && LINE="$NL"
fi
while :; do
  LINE="$(ask "Step 3/4 - Connection line

Paste the line your teammate sent you.
Example: FTK|100.101.102.103|kolya|mac" "$LINE")" || exit 1
  LINE="$(printf '%s' "$LINE" | tr -d '[:space:]')"
  IFS='|' read -r TAG HOST USER_R OS_R <<< "$LINE"
  if [ "$TAG" = "FTK" ] && [ -n "$HOST" ] && [ -n "$USER_R" ] && { [ "$OS_R" = "mac" ] || [ "$OS_R" = "windows" ]; }; then break; fi
  info "That line is not valid. It must look like FTK|<ip>|<user>|mac or FTK|<ip>|<user>|windows"
done

# ---------- Step 4: ssh config + ftk command ----------
CFG="$HOME/.ssh/config"; touch "$CFG"; chmod 600 "$CFG"
awk '/^# >>> ftk >>>/{skip=1} !skip{print} /^# <<< ftk <<</{skip=0}' "$CFG" > "$CFG.tmp" && mv "$CFG.tmp" "$CFG"
cat >> "$CFG" <<EOF
# >>> ftk >>>
Host ftk
  HostName $HOST
  User $USER_R
  IdentityFile $KEYFILE
  IdentitiesOnly yes
  ServerAliveInterval 30
  ControlMaster auto
  ControlPath ~/.ssh/cm-%C
  ControlPersist 10m
# <<< ftk <<<
EOF

mkdir -p "$HOME/.ftk" "$BIN"
if [ "$OS_R" = "windows" ]; then REMOTE="wsl -e /usr/local/bin/ftk-remote"; else REMOTE="~/.ftk/ftk-remote"; fi
printf "FTK_REMOTE='%s'\nFTK_TOPIC='%s'\nFTK_NTFY='%s'\n" "$REMOTE" "$TOPIC" "$NTFY" > "$HOME/.ftk/client.conf"

cat > "$BIN/ftk" <<'FTK_EOF'
#!/bin/bash
# ftk - talk to the Claude Code agent(s) on the teammate's machine.
source "$HOME/.ftk/client.conf"
SEL=""
if [ "${1:-}" = "-s" ]; then
  [[ "${2:-}" =~ ^[a-z0-9][a-z0-9-]{0,30}$ ]] || { echo "usage: ftk -s <lane> <command>"; exit 2; }
  SEL="-s $2"; shift 2
fi
RR="$FTK_REMOTE${SEL:+ $SEL}"
b64() { printf '%s' "$1" | base64 | tr -d '\n'; }
num() { [[ -z "${1:-}" || "$1" =~ ^[0-9]+$ ]] || { echo "number expected"; exit 2; }; }
cmd="${1:-help}"; shift 2>/dev/null
case "$cmd" in
  peek)          num "${1:-}"; ssh ftk "$RR peek ${1:-}" ;;
  log)           num "${1:-}"; [[ -z "${2:-}" || "$2" = raw ]] || { echo "usage: ftk log [N] [raw]"; exit 2; }
                 ssh ftk "$RR log ${1:-30} ${2:-}" ;;
  wait)          num "${1:-}"; ssh ftk "$RR wait ${1:-}" ;;
  status|start|restart|git|lanes) ssh ftk "$RR $cmd" ;;
  say)           [ $# -gt 0 ] || { echo 'usage: ftk say "message"'; exit 2; }
                 ssh ftk "$RR say $(b64 "$*")" ;;
  run)           [ $# -gt 0 ] || { echo 'usage: ftk run "command"'; exit 2; }
                 ssh ftk "$RR run $(b64 "$*")" ;;
  key)           [[ "${1:-}" =~ ^[A-Za-z0-9-]+$ ]] || { echo "usage: ftk key Enter|Escape|Up|Down|1|2|y|n|C-c"; exit 2; }
                 ssh ftk "$RR key $1" ;;
  checkout)      [ -n "${1:-}" ] || { echo "usage: ftk checkout <branch>"; exit 2; }
                 ssh ftk "$RR checkout $(b64 "$1")" ;;
  setproject)    [ -n "${1:-}" ] || { echo "usage: ftk [-s LANE] setproject <host path, ~/ allowed>"; exit 2; }
                 ssh ftk "$RR setproject $(b64 "$1")" ;;
  put)           [ -f "${1:-}" ] && [ -n "${2:-}" ] || { echo "usage: ftk put <local file> <path under ~/.ftk/xfer>"; exit 2; }
                 echo "local $(wc -c < "$1" | tr -d ' ') bytes sha256 $(shasum -a 256 "$1" | cut -d' ' -f1)"
                 base64 < "$1" | ssh ftk "$RR put $(b64 "$2")" ;;
  get)           [ -n "${1:-}" ] && [ -n "${2:-}" ] || { echo "usage: ftk get <path under ~/.ftk/xfer> <local file>"; exit 2; }
                 ssh ftk "$RR get $(b64 "$1")" > "$2.b64" && base64 --decode < "$2.b64" > "$2" && rm -f "$2.b64" &&
                   echo "saved $2 $(wc -c < "$2" | tr -d ' ') bytes sha256 $(shasum -a 256 "$2" | cut -d' ' -f1)" ||
                   { rm -f "$2.b64"; echo "get failed"; exit 1; } ;;
  xfer)          ssh ftk "$RR xfer" ;;
  new-lane)      [[ "${1:-}" =~ ^[a-z0-9][a-z0-9-]{0,30}$ ]] && [ -n "${2:-}" ] || { echo "usage: ftk new-lane <name> <branch>"; exit 2; }
                 ssh ftk "$FTK_REMOTE new-lane $1 $(b64 "$2")" ;;
  watch)         echo "Read-only view. Detach: Ctrl+B then D"; ssh -t ftk "$RR attach" ;;
  drive)         echo "FULL control. Detach: Ctrl+B then D"; ssh -t ftk "$RR drive" ;;
  shell)         ssh ftk ;;
  events)        [ -n "${FTK_TOPIC:-}" ] || { echo "no ntfy topic configured"; exit 1; }
                 since="${1:-1h}"; [[ "$since" =~ ^([0-9]+[smhd]|all)$ ]] || { echo "usage: ftk events [30m|2h|1d|all]"; exit 2; }
                 curl -fsS -m 15 "$FTK_NTFY/$FTK_TOPIC/json?poll=1&since=$since" | python3 -c '
import json, sys, time
for l in sys.stdin:
    try: e = json.loads(l)
    except ValueError: continue
    if e.get("event") == "message":
        print(time.strftime("%H:%M:%S", time.localtime(e["time"])), "|", e.get("title", ""), "|", e.get("message", ""))' ;;
  *) cat <<'H'
ftk [-s LANE] COMMAND      (no -s = main agent; -s a1 = lane "a1")
  peek [N]          last N lines of the agent screen (default 200)
  say "text"        type a message to the agent and press Enter
  wait [SEC]        block until the agent finished its turn / needs input (default 600 s)
  key NAME          press a key: Enter, Escape, Up, Down, 1, 2, y, n, C-c
  run "cmd"         run a command in the project folder, print output + [exit N]
  status            session / claude / state / project
  log [N] [raw]     last N transcript messages as text (raw = jsonl)
  git               branch, changed files, last 10 commits
  checkout BR       switch the project to branch BR (refuses with uncommitted changes)
  start | restart   start / restart the agent session
  watch | drive     live view read-only / full control (Ctrl+B D to leave)
ftk new-lane NAME BRANCH   new git worktree + agent session for parallel work
ftk lanes                  all agent sessions with state and folder
ftk put FILE REL           upload FILE to ~/.ftk/xfer/REL on the host (prints sha256)
ftk get REL FILE           download ~/.ftk/xfer/REL to FILE
ftk xfer                   list ~/.ftk/xfer on the host
ftk [-s LANE] setproject PATH   point the agent at a folder on the host (~/ allowed)
ftk shell                  plain ssh to the host
ftk events [1h]            ntfy notifications: ready / turn finished / needs you
H
  ;;
esac
FTK_EOF
chmod +x "$BIN/ftk"
case ":$PATH:" in *":$BIN:"*) ;; *)
  grep -q 'ftk: add ~/.local/bin' "$HOME/.zshrc" 2>/dev/null ||
    printf '\n# ftk: add ~/.local/bin to PATH\nexport PATH="$HOME/.local/bin:$PATH"\n' >> "$HOME/.zshrc" ;;
esac

# ---------- test ----------
echo "Testing connection to $HOST ..."
if OUT="$(ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new -o ConnectTimeout=15 ftk "$REMOTE status" 2>&1)"; then
  info "Connected!

$OUT

Commands (open a NEW terminal window):
  ftk peek      - what is the agent doing
  ftk say \"...\" - send it a message
  ftk key 1     - answer a prompt
  ftk watch     - live view
  ftk help      - everything else"
else
  info "Connection failed:

$OUT

Check:
1. Tailscale is Connected on BOTH machines (and the Share invite is accepted).
2. Your teammate pasted YOUR key (starts with ssh-ed25519).
3. Remote Login / OpenSSH Server is on at their side.
Then run this script again."
  exit 1
fi
