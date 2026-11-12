#!/usr/bin/env python3
"""Copy ftk-remote.sh into the two host setup scripts (they are sent alone, so it is embedded).
Run after editing ftk-remote.sh:  python3 embed.py   (tests fail if the copies drift)."""
import re, pathlib, sys
here = pathlib.Path(__file__).resolve().parent
remote = (here / "ftk-remote.sh").read_text().rstrip("\n")
targets = {
    "host-setup-mac.command": (r"(<<'FTK_REMOTE_EOF'\n)(.*?)(\nFTK_REMOTE_EOF\n)",),
    "host-setup-windows.ps1": (r"(\$remote = @'\n)(.*?)(\n'@\n)",),
}
for name, (pat,) in targets.items():
    p = here / name
    s = p.read_text()
    new, n = re.subn(pat, lambda m: m.group(1) + remote + m.group(3), s, count=1, flags=re.S)
    if n != 1:
        sys.exit(f"marker not found in {name}")
    p.write_text(new)
    print(f"embedded ftk-remote into {name}")
