#!/bin/bash
# Build dist/ftk-host.zip - one archive (Mac + Windows) to send to the teammate.
#   ./package.sh [repo-url] [branch]
#   FTK_BUNDLE_FROM=<local repo> FTK_BUNDLE_REF=<ref, e.g. origin/v2> ./package.sh
#     -> also ships repo.bundle (exactly one ref: refs/heads/<branch>); the host unpacks it, no repo access needed
# Puts YOUR public key (teammate.pub) and a private ntfy topic into the host scripts,
# so the teammate only clicks OK and you get a push when the host is ready.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
# local.env (not committed) may set REPO_URL / REPO_BRANCH defaults and FTK_BUNDLE_FROM / FTK_BUNDLE_REF
[ -f "$ROOT/local.env" ] && . "$ROOT/local.env"
REPO_URL="${1:-${REPO_URL:-}}"; REPO_BRANCH="${2:-${REPO_BRANCH:-}}"   # empty = keep the defaults written in the host scripts
for v in "$REPO_URL" "$REPO_BRANCH"; do
  [[ "$v" =~ [\"\'\`\$\\[:space:]] ]] && { echo "repo url / branch must not contain quotes, \$, \\ or spaces"; exit 2; }
done

python3 "$ROOT/embed.py" >/dev/null

KEY="$HOME/.ssh/ftk_ed25519"
mkdir -p "$HOME/.ssh" && chmod 700 "$HOME/.ssh"
[ -f "$KEY" ] || ssh-keygen -t ed25519 -N "" -C "ftk-$(whoami)@$(hostname -s)" -f "$KEY" -q

mkdir -p "$HOME/.ftk"
TOPIC_FILE="$HOME/.ftk/ntfy-topic"
[ -s "$TOPIC_FILE" ] || printf 'ftk-%s' "$(openssl rand -hex 12)" > "$TOPIC_FILE"
TOPIC="$(cat "$TOPIC_FILE")"

OUT="$ROOT/dist/ftk-host"
rm -rf "$OUT" "$ROOT/dist/ftk-host.zip"; mkdir -p "$OUT"
cp "$ROOT"/{host-setup-mac.command,host-setup-windows.ps1,host-setup-windows.cmd,START-HERE.md,README.md} "$OUT/"
cp "$KEY.pub" "$OUT/teammate.pub"
MIG="${FTK_MIGRATION_DIR:-$ROOT/migration}"   # optional: MIGRATION.md, migration-worker.md, setup-migration-env.sh - shipped verbatim
if [ -d "$MIG" ]; then
  for f in MIGRATION.md migration-worker.md setup-migration-env.sh; do
    [ -f "$MIG/$f" ] || { echo "missing $MIG/$f"; exit 1; }
    cp "$MIG/$f" "$OUT/$f"
  done
  chmod +x "$OUT/setup-migration-env.sh"
fi

if [ -n "${FTK_BUNDLE_FROM:-}" ]; then
  BR="${REPO_BRANCH:-$(sed -n 's/^REPO_BRANCH="\([^"]*\)".*/\1/p' "$ROOT/host-setup-mac.command")}"; BR="${BR:-v2}"
  REF="${FTK_BUNDLE_REF:-$BR}"
  case "$BR" in migrate/operator-records*) echo "refusing to bundle $BR"; exit 2;; esac
  TMPB="$(mktemp -d)"; trap 'rm -rf "$TMPB"' EXIT
  git init -q --bare "$TMPB/b.git"
  # fetch exactly one ref, renamed to refs/heads/<branch>; nothing else can land in the bundle
  git -C "$TMPB/b.git" fetch -q --no-tags "$FTK_BUNDLE_FROM" "+$(git -C "$FTK_BUNDLE_FROM" rev-parse --symbolic-full-name "$REF"):refs/heads/$BR"
  git -C "$TMPB/b.git" bundle create -q "$OUT/repo.bundle" "refs/heads/$BR"
  HEADS="$(git bundle list-heads "$OUT/repo.bundle" | awk '{print $2}')"
  [ "$HEADS" = "refs/heads/$BR" ] || { echo "bundle has unexpected refs: $HEADS"; exit 1; }
  echo "Bundle  : repo.bundle = refs/heads/$BR @ $(git bundle list-heads "$OUT/repo.bundle" | cut -c1-12) from $REF ($(du -h "$OUT/repo.bundle" | cut -f1))"
fi

python3 - "$OUT" "$TOPIC" "$REPO_URL" "$REPO_BRANCH" <<'PY'
import re, sys, pathlib
out, topic, url, br = sys.argv[1:]
def fill(name, pairs):
    p = pathlib.Path(out) / name; s = p.read_text()
    for pat, val in pairs:
        if val is None: continue
        s, n = re.subn(pat, lambda m: m.group(1) + val + m.group(2), s, count=1, flags=re.M)
        assert n == 1, (name, pat)
    p.write_text(s)
fill("host-setup-mac.command", [(r'^(NTFY_TOPIC=")[^"]*(")', topic),
                                (r'^(REPO_URL=")[^"]*(")', url or None), (r'^(REPO_BRANCH=")[^"]*(")', br or None)])
fill("host-setup-windows.ps1", [(r"^(\$NtfyTopic  = ')[^']*(')", topic),
                                (r"^(\$RepoUrl    = ')[^']*(')", url or None), (r"^(\$RepoBranch = ')[^']*(')", br or None)])
PY
chmod +x "$OUT/host-setup-mac.command"
(cd "$ROOT/dist" && zip -qr ftk-host.zip ftk-host)

cat <<EOF
Archive : $ROOT/dist/ftk-host.zip
Repo    : $(grep -m1 '^REPO_URL=' "$OUT/host-setup-mac.command")  $(grep -m1 '^REPO_BRANCH=' "$OUT/host-setup-mac.command" | cut -d'#' -f1)
Pushes  : subscribe to topic '$TOPIC' in the ntfy app (iOS/Android/desktop)
          or open https://ntfy.sh/$TOPIC
Next    : send the zip to your teammate -> they give it to their Claude (START-HERE.md)
          -> when 'FTK host ready' arrives, run client-setup-mac.command
EOF
