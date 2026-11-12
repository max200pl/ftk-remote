#!/bin/bash
# Release a new helper version: tests -> bump version -> embed -> SIGN -> commit (push is yours).
#   ./release.sh 2026.11.12.6
# Hosts install an update only if ftk-remote.{sh,ps1}.sig verifies with the key they trust
# (the teammate key from teammate.pub = ~/.ssh/ftk_ed25519.pub). Without the private key, no release.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"; cd "$ROOT"
NEW="${1:?usage: ./release.sh <version, e.g. 2026.11.12.6>}"
[[ "$NEW" =~ ^[0-9]+(\.[0-9]+){1,3}$ ]] || { echo "bad version: $NEW"; exit 2; }
KEY="${FTK_SIGNING_KEY:-$HOME/.ssh/ftk_ed25519}"
[ -f "$KEY" ] || { echo "signing key not found: $KEY"; exit 1; }
OLD="$(sed -n 's/^FTK_VERSION="\([0-9.]*\)".*/\1/p' ftk-remote.sh)"
[ "$(printf '%s\n%s\n' "$OLD" "$NEW" | sort -V | tail -1)" = "$NEW" ] && [ "$OLD" != "$NEW" ] || { echo "version must be higher than $OLD"; exit 2; }
sed -i '' "s/^FTK_VERSION=\"$OLD\"/FTK_VERSION=\"$NEW\"/" ftk-remote.sh
sed -i '' "s/^\$FtkVersion = '$OLD'/\$FtkVersion = '$NEW'/" ftk-remote.ps1
python3 embed.py >/dev/null
echo "running tests..."; bash tests/run.sh </dev/null > /tmp/ftk-release-tests.log 2>&1 || { tail -20 /tmp/ftk-release-tests.log; echo "TESTS FAILED - not released"; git checkout -- ftk-remote.sh ftk-remote.ps1 host-setup-mac.command host-setup-windows.ps1; exit 1; }
tail -1 /tmp/ftk-release-tests.log
for f in ftk-remote.sh ftk-remote.ps1; do
  rm -f "$f.sig"; ssh-keygen -Y sign -f "$KEY" -n ftk-update "$f" >/dev/null 2>&1
  ssh-keygen -Y verify -f <(printf 'ftk-release namespaces="ftk-update" %s\n' "$(cut -d' ' -f1,2 "$KEY.pub")") -I ftk-release -n ftk-update -s "$f.sig" < "$f" >/dev/null
done
git add ftk-remote.sh ftk-remote.ps1 ftk-remote.sh.sig ftk-remote.ps1.sig host-setup-mac.command host-setup-windows.ps1
git commit -q -m "release $NEW (signed helpers)

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
echo "released $NEW: commit $(git rev-parse --short HEAD). Push it: git push"
