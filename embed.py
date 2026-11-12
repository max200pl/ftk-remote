#!/usr/bin/env python3
"""Copy ftk-remote.sh (mac) / ftk-remote.ps1 (windows) into the host setup scripts (they are sent alone, so it is embedded).
Run after editing ftk-remote.sh:  python3 embed.py   (tests fail if the copies drift)."""
import re, pathlib, sys
here = pathlib.Path(__file__).resolve().parent
targets = {
    "host-setup-mac.command": (r"(<<'FTK_REMOTE_EOF'\n)(.*?)(\nFTK_REMOTE_EOF\n)", "ftk-remote.sh"),
    "host-setup-windows.ps1": (r"(\$remote = @'\n)(.*?)(\n'@\n)", "ftk-remote.ps1"),
}
for name, (pat, src) in targets.items():
    remote = (here / src).read_text().rstrip("\n")
    if name.endswith(".ps1") and any(l.startswith("'@") for l in remote.splitlines()):
        sys.exit("ftk-remote.ps1 must not contain a line starting with '@")
    p = here / name
    s = p.read_text()
    new, n = re.subn(pat, lambda m: m.group(1) + remote + m.group(3), s, count=1, flags=re.S)
    if n != 1:
        sys.exit(f"marker not found in {name}")
    p.write_text(new)
    print(f"embedded {src} into {name}")
