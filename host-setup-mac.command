#!/bin/bash
# FTK Remote - HOST setup for macOS (run on the colleague's Mac).
# Lets a teammate connect over SSH (via Tailscale) and watch / talk to
# the Claude Code agent running here inside tmux.
# Safe to run again at any time.

# ===== Optional: fill these in before sending the script =====
REPO_URL=""      # package.sh fills it (args or local.env)
REPO_BRANCH="v2"   # cloned single-branch; empty = default branch
NTFY_TOPIC=""    # ntfy.sh topic for "ready" / "agent needs you" pushes (package.sh fills it)
# ==============================================================
NTFY_TOPIC="${FTK_NTFY_TOPIC:-$NTFY_TOPIC}"
REPO_URL="${FTK_REPO_URL-$REPO_URL}"; REPO_BRANCH="${FTK_REPO_BRANCH-$REPO_BRANCH}"   # tests override (also with empty)

TITLE="FTK Remote - Host setup (Mac)"
TS_CLI="${FTK_TS_CLI:-/Applications/Tailscale.app/Contents/MacOS/Tailscale}"

# ---------- dialogs ----------
step() { # step "message"  -> OK / Cancel (Cancel exits)
  osascript - "$1" "$TITLE" <<'OSA' >/dev/null || { echo "Cancelled."; exit 1; }
on run argv
  display dialog (item 1 of argv) with title (item 2 of argv) buttons {"Cancel", "OK"} default button "OK"
end run
OSA
}
info() { # info "message" -> single OK button
  osascript - "$1" "$TITLE" <<'OSA' >/dev/null
on run argv
  display dialog (item 1 of argv) with title (item 2 of argv) buttons {"OK"} default button "OK"
end run
OSA
}
ask() { # ask "message" "default" -> prints answer
  osascript - "$1" "$2" "$TITLE" <<'OSA' || { echo "Cancelled." >&2; exit 1; }
on run argv
  text returned of (display dialog (item 1 of argv) default answer (item 2 of argv) with title (item 3 of argv) buttons {"Cancel", "OK"} default button "OK")
end run
OSA
}
pick() { # pick "message" "button1" "button2" "default button" -> prints the chosen button
  osascript - "$1" "$TITLE" "$2" "$3" "$4" <<'OSA' || { echo "Cancelled." >&2; exit 1; }
on run argv
  button returned of (display dialog (item 1 of argv) with title (item 2 of argv) buttons {item 3 of argv, item 4 of argv, item 5 of argv} default button (item 5 of argv))
end run
OSA
}
choose_folder() { # choose_folder "prompt"
  osascript - "$1" <<'OSA'
on run argv
  POSIX path of (choose folder with prompt (item 1 of argv))
end run
OSA
}

# ---------- Step 0: welcome ----------
step "This will set up your Mac so your teammate can connect to your Claude Code agent.

Steps:
1. Tailscale (private network, no port forwarding)
2. Remote Login (SSH)
3. tmux (keeps the agent running)
4. Claude Code
5. Add your teammate's SSH key
6. Clone the repo + switch to the branch
7. Start the agent session
8. Send the connection line back to your teammate

Have the SSH key your teammate sent you ready. Click OK to start."

# ---------- Step 1: Tailscale ----------
if [ ! -d /Applications/Tailscale.app ]; then
  open "https://tailscale.com/download/mac"
  step "Step 1/8 - Tailscale

Tailscale is not installed. The download page is now open.
1. Download and install Tailscale.
2. Open it and log in.
3. Click OK here when the menu bar icon shows Connected."
fi
open -a Tailscale 2>/dev/null
step "Step 1/8 - Tailscale

Make sure Tailscale is running and logged in (menu bar icon -> Connected).

If your teammate uses a DIFFERENT Tailscale account:
open https://login.tailscale.com/admin/machines -> this Mac -> ... -> Share -> send the invite link to your teammate.

Click OK to continue."
TS_IP=""
if [ -x "$TS_CLI" ]; then TS_IP="$("$TS_CLI" ip -4 2>/dev/null | head -1)"; fi
[ -z "$TS_IP" ] && command -v tailscale >/dev/null && TS_IP="$(tailscale ip -4 2>/dev/null | head -1)"
if [ -z "$TS_IP" ]; then
  TS_IP="$(ask "Step 1/8 - Could not read the Tailscale IP automatically.

Click the Tailscale menu bar icon, find 'This device' and type its IP (starts with 100.):" "100.")" || exit 1
fi

# ---------- Step 2: Remote Login ----------
ssh_on() { nc -z -G 2 127.0.0.1 22 >/dev/null 2>&1; }
for _ in 1 2 3; do
  ssh_on && break
  open "x-apple.systempreferences:com.apple.Sharing-Settings.extension"
  step "Step 2/8 - Remote Login (SSH)

System Settings -> General -> Sharing is now open.
1. Turn ON 'Remote Login'.
2. Click (i) next to it -> 'Allow access for: Only these users' -> keep only YOUR user.
3. Click OK here."
done
ssh_on || { info "Remote Login is still off. Turn it on and run this script again."; exit 1; }

# ---------- Step 3: Homebrew + tmux ----------
[ -x /opt/homebrew/bin/brew ] && eval "$(/opt/homebrew/bin/brew shellenv)"
[ -x /usr/local/bin/brew ] && eval "$(/usr/local/bin/brew shellenv)"
if ! command -v tmux >/dev/null; then
  if ! command -v brew >/dev/null; then
    step "Step 3/8 - Homebrew

Homebrew (package manager) is needed to install tmux.
It will now install in this Terminal window - it may ask for your Mac password.
Click OK to continue."
    /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
    [ -x /opt/homebrew/bin/brew ] && eval "$(/opt/homebrew/bin/brew shellenv)"
    [ -x /usr/local/bin/brew ] && eval "$(/usr/local/bin/brew shellenv)"
  fi
  echo "Installing tmux..."
  brew install tmux || { info "tmux install failed - see the Terminal output."; exit 1; }
fi

# ---------- Step 4: Claude Code ----------
export PATH="$HOME/.local/bin:$PATH"
if ! command -v claude >/dev/null; then
  echo "Installing Claude Code..."
  curl -fsSL https://claude.ai/install.sh | bash
  export PATH="$HOME/.local/bin:$PATH"
  command -v claude >/dev/null || { info "Claude Code install failed - see the Terminal output."; exit 1; }
fi

# ---------- Step 5: teammate's SSH key ----------
KEY=""
CLIP="$(pbpaste 2>/dev/null | head -1)"
# teammate.pub shipped next to this script wins over the clipboard
PUBFILE="$(cd "$(dirname "$0")" && pwd)/teammate.pub"
[ -f "$PUBFILE" ] && CLIP="$(head -1 "$PUBFILE" | tr -d '\r')"
case "$CLIP" in ssh-ed25519\ *|ssh-rsa\ *) KEY="$CLIP";; esac
while :; do
  KEY="$(ask "Step 5/8 - Teammate's SSH key

Paste the public key your teammate sent you.
It starts with 'ssh-ed25519 ...'" "$KEY")" || exit 1
  case "$KEY" in ssh-ed25519\ *|ssh-rsa\ *|ecdsa-*) break;; esac
  info "That does not look like an SSH public key. It must start with ssh-ed25519."
done
mkdir -p "$HOME/.ssh" && chmod 700 "$HOME/.ssh"
touch "$HOME/.ssh/authorized_keys" && chmod 600 "$HOME/.ssh/authorized_keys"
grep -qxF "$KEY" "$HOME/.ssh/authorized_keys" || echo "$KEY" >> "$HOME/.ssh/authorized_keys"

# ---------- install the remote helper ----------
mkdir -p "$HOME/.ftk"
cat > "$HOME/.ftk/ftk-remote" <<'FTK_REMOTE_EOF'
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
FTK_REMOTE_EOF
chmod +x "$HOME/.ftk/ftk-remote"
# ---------- Step 6: repository + branch ----------
R="$HOME/.ftk/ftk-remote"
b64() { printf '%s' "$1" | base64 | tr -d '\n'; }
if ! git --version >/dev/null 2>&1; then
  xcode-select --install 2>/dev/null
  step "Step 6/8 - Git

Git is missing. A window to install the Command Line Tools is open - install them, then click OK."
fi
BUNDLE="$(cd "$(dirname "$0")" && pwd)/repo.bundle"
if [ -f "$BUNDLE" ]; then
  NAME="$(basename "${REPO_URL%/}" .git)"; [ -n "$NAME" ] || NAME=repo
  echo "Unpacking the repo shipped with this kit ($REPO_BRANCH) ..."
  "$R" unbundle "$(b64 "$BUNDLE")" "$(b64 "${REPO_BRANCH:-v2}")" "$(b64 "$HOME/Projects/$NAME")" ||
    { info "Could not unpack repo.bundle - see the Terminal output."; exit 1; }
  SRC="bundled"
else
SRC="$(pick "Step 6/8 - Repository

Where does the code come from?

- Teammate sends it (recommended): your teammate copies the repo to this Mac over SSH. No git login needed here.
- Clone from URL: clone it yourself (needs access to the repo).
- Existing folder: a copy that is already on this Mac." "Existing folder" "Clone from URL" "Teammate sends it")" || exit 1
if [ "$SRC" = "Teammate sends it" ]; then
  echo "Repo will be provided by your teammate - skipping the clone."
elif [ "$SRC" = "Existing folder" ]; then
  PROJECT="$(choose_folder "Step 6/8 - Choose the existing project folder the agent will work in")" || { echo "Cancelled."; exit 1; }
  "$R" setproject "$(b64 "${PROJECT%/}")"
else
  URL="$(ask "Step 6/8 - Repository URL

Git URL of the repo to clone (only this one branch is cloned)." "$REPO_URL")" || exit 1
  URL="$(printf '%s' "$URL" | tr -d '[:space:]')"
  [ -n "$URL" ] || { info "No URL given. Run the script again."; exit 1; }
  BRANCH="$(ask "Step 6/8 - Branch

Branch to work on (it is created if it does not exist yet).
Leave EMPTY for the default branch." "$REPO_BRANCH")" || exit 1
  BRANCH="$(printf '%s' "$BRANCH" | tr -d '[:space:]')"
  PARENT="$(choose_folder "Step 6/8 - Where to put the repo? (a sub-folder with the repo name is created inside)")" || { echo "Cancelled."; exit 1; }
  echo "Cloning $URL ..."
  if ! "$R" clone "$(b64 "$URL")" "$( [ -n "$BRANCH" ] && b64 "$BRANCH" || echo - )" "$(b64 "${PARENT%/}")"; then
    info "Could not clone / switch the branch - see the Terminal output.

Typical causes:
- no access to the repo (for Azure DevOps over HTTPS use a Personal Access Token as the password)
- uncommitted changes in an existing copy

Fix it and run this script again."
    exit 1
  fi
fi

fi   # bundle / no bundle

# ---------- migration files shipped with the kit ----------
KIT="$(cd "$(dirname "$0")" && pwd)"
if [ -f "$KIT/migration-worker.md" ]; then
  mkdir -p "$HOME/.claude/agents" && cp "$KIT/migration-worker.md" "$HOME/.claude/agents/migration-worker.md" &&
    echo "installed ~/.claude/agents/migration-worker.md"
fi
if [ -f "$KIT/setup-migration-env.sh" ]; then   # copied only; the orchestrator runs it after delivering the repo
  cp "$KIT/setup-migration-env.sh" "$HOME/.ftk/setup-migration-env.sh" && chmod +x "$HOME/.ftk/setup-migration-env.sh" &&
    echo "copied ~/.ftk/setup-migration-env.sh (not run)"
fi

# ---------- Step 7: notifications, agent session, autostart at login ----------
if [ -n "$NTFY_TOPIC" ]; then
  "$R" set-topic "$NTFY_TOPIC" && "$R" install-hooks || echo "WARNING: notifications not set up"
fi
"$HOME/.ftk/ftk-remote" start
# LaunchAgent: starts the session when you log in (inside your GUI session, so Claude
# can read its login from the Keychain - a session started over SSH might not).
LA="$HOME/Library/LaunchAgents/com.ftk.agent.plist"
mkdir -p "$HOME/Library/LaunchAgents"
cat > "$LA" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>com.ftk.agent</string>
  <key>ProgramArguments</key>
  <array><string>$HOME/.ftk/ftk-remote</string><string>start</string></array>
  <key>RunAtLoad</key><true/>
  <key>AbandonProcessGroup</key><true/>
  <key>StandardOutPath</key><string>$HOME/.ftk/launchagent.log</string>
  <key>StandardErrorPath</key><string>$HOME/.ftk/launchagent.log</string>
</dict>
</plist>
PLIST
launchctl bootout "gui/$(id -u)/com.ftk.agent" 2>/dev/null
launchctl bootstrap "gui/$(id -u)" "$LA" 2>/dev/null || true

step "Step 7/8 - First start of the agent

A Terminal window will open with the agent session.
1. If Claude asks you to log in - log in.
2. If it asks to trust the folder - say Yes.
3. Then you can just close that window (the agent keeps running).

Click OK to open it."
osascript -e 'tell application "Terminal" to do script "~/.ftk/ftk-remote drive"' -e 'tell application "Terminal" to activate' >/dev/null

# ---------- laptop: the lid puts the Mac to sleep ----------
if pmset -g batt 2>/dev/null | grep -q 'InternalBattery'; then
  info "This is a MacBook - important:

Closing the LID puts the Mac to sleep: the agents stop and your teammate loses the connection (keeping it awake while idle is already handled).

- Keep the lid open and the charger connected (the screen may turn off), or
- use an external display + charger (then the lid may be closed), or
- 'sudo pmset -a disablesleep 1' in Terminal (undo: 'sudo pmset -a disablesleep 0'; do not leave it on in a bag).

See START-HERE.md, section 'On a MacBook'."
fi

# ---------- Step 8: connection line ----------
LINE="FTK|$TS_IP|$(whoami)|mac"
printf '%s' "$LINE" | pbcopy
"$R" notify ready "$(b64 "$LINE")" </dev/null
info "Step 8/8 - Done!

Your teammate has been notified automatically.
If not, send them this line (already copied to the clipboard):

$LINE

Notes:
- Keep the Mac on and Tailscale connected.
- The agent starts automatically when you log in to the Mac.
- If Claude ever asks to log in again, do it once in that window (~/.ftk/ftk-remote drive).
- To see what the agent is doing yourself: ~/.ftk/ftk-remote drive"
echo "Connection line: $LINE"
