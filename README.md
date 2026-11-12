# FTK Remote

Lets you (the **client**) watch and talk to a Claude Code agent running on a teammate's machine (the **host**). The connection runs over SSH through Tailscale. The host script also clones the repo and switches to the working branch.

| You are | macOS | Windows |
|---|---|---|
| **Host** (runs the agent) | `host-setup-mac.command` | `host-setup-windows.cmd` (+ `.ps1` next to it) |
| **Client** (controls it) | `client-setup-mac.command` | `client-setup-windows.cmd` (+ `.ps1` next to it) |

Every script walks you through dialog windows with English steps. It is safe to run again.

## 0. Before sending (optional)
Open the host script and fill in the repo and branch at the top. The host then only clicks OK:
- Mac: `REPO_URL=""` and `REPO_BRANCH=""`
- Windows: `$RepoUrl = ''` and `$RepoBranch = ''`

## Order (handshake)
1. **Client** runs the client script.
   - It creates an SSH key and copies the public key to the clipboard.
   - Send the key to the host (Slack/Teams). Leave the dialog open.
2. **Host** runs the host script.
   - Pastes the key when asked.
   - Logs in to Claude the first time the agent window opens.
   - At the end, the script copies a line like `FTK|100.x.y.z|user|mac`. Send it back to the client.
3. **Client** clicks OK and pastes that line. The script tests the connection.

Normally the two of you use **different** Tailscale accounts (each person uses their own; nobody logs in with the other's). The host shares the machine:
- Open https://login.tailscale.com/admin/machines.
- Click the machine, then **...** > **Share**.
- Send the invite to the client, who accepts it.

## Running the scripts
- **Mac:** files sent through Slack/Teams lose the executable bit and get quarantined. Run them with bash:
  `bash ~/Downloads/host-setup-mac.command`
- **Windows:** keep the `.cmd` and `.ps1` in the same folder and double-click the `.cmd`.
  - It runs PowerShell with `-ExecutionPolicy Bypass`. If Windows still blocks it, right-click the `.ps1` > Properties > **Unblock**.
  - The host script asks for Administrator rights.
  - If WSL gets installed, the host script asks for a reboot. Run it again after the reboot.

## What the host gets
- Tailscale and an SSH server. On Windows, port 22 is open only to Tailscale addresses (100.64.0.0/10).
- The teammate's key in `authorized_keys`.
  - On Windows it also goes into `C:\ProgramData\ssh\administrators_authorized_keys`, with the ACL sshd requires.
- The agent (`claude`) in a tmux session named `ftk`, started in the cloned repo. Where it lives:
  - **Mac:** in the folder you choose.
  - **Windows:** inside Ubuntu (WSL) under `~/Projects`, reachable in Explorer under `\\wsl.localhost\Ubuntu\home\<user>\Projects`.
- Git login:
  - **Windows:** git in WSL uses the Windows Git Credential Manager, so Azure DevOps/GitHub login happens in the browser.
  - **Mac:** use a Personal Access Token as the password, or an SSH URL.
- Sleep:
  - **Mac:** `caffeinate` keeps it awake while the session exists.
  - **Windows:** you can disable sleep on AC power.
- Autostart at login:
  - **Mac:** a LaunchAgent `com.ftk.agent` starts the session at login, inside the GUI session, so Claude can read its Keychain login.
  - **Windows:** a logon task called `FTK Agent Keepalive` starts the session and keeps WSL (and tmux) alive.
- The host must be logged in to the computer (a locked screen is fine). If Claude ever asks to log in again, the host does it once with `~/.ftk/ftk-remote drive`.
- A helper:
  - **Mac:** `~/.ftk/ftk-remote`
  - **Windows:** `/usr/local/bin/ftk-remote` inside WSL

## Client commands (`ftk`)
```
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
```
All of these run without prompts, so your own Claude agent can drive the host:
```
ftk -s a1 say "do package X"  ->  ftk -s a1 wait 1800  ->  ftk -s a1 log 20  ->  ftk -s a1 run "python3 -m pytest -q"
```

### Lanes (parallel agents)
- `ftk new-lane a1 migrate/s2-a1` creates the git worktree `<repo>-a1` and starts the agent session `ftk-a1` in it. One lane = one worktree = one agent.
- Where the lane branch starts:
  - If the branch already exists on origin, exactly that ref is fetched and tracked.
  - Otherwise the branch starts from the base branch (`v2`) without tracking it, so a plain `git push` cannot hit `v2`.
- Removing a lane:
  - `ftk -s a1 shell` is not needed. Run `ftk run "git worktree remove ../<repo>-a1"` after the work is pushed.
  - Then kill the session with `ftk -s a1 key C-c`, or let the host close the window.

### Migration
- `MIGRATION.md` explains to the host what runs on the machine.
- The host setup installs `migration-worker.md` into `~/.claude/agents/` and copies `setup-migration-env.sh` to `~/.ftk/` without running it. The orchestrator runs it after delivering the repo.
- `package.sh` ships the three files from `migration/`, or from `FTK_MIGRATION_DIR`, verbatim.

### Repo delivered as a git bundle (no repo access on the host)
- The host setup asks where the code comes from. The default is **"Teammate sends it"**: nothing is cloned, there is no git login, and the agent waits in `~/.ftk/workspace`.
- Then, from the client:
```
git bundle create v2.bundle v2
ftk put v2.bundle v2.bundle
ftk run "git clone --single-branch -b v2 ~/.ftk/xfer/v2.bundle ~/Projects/project && git -C ~/Projects/project remote remove origin"
ftk setproject ~/Projects/project && ftk restart
ftk new-lane a1 migrate/s2-a1        # cut from local v2 when there is no origin
# work back: ftk -s a1 run "git bundle create ~/.ftk/xfer/a1.bundle v2..migrate/s2-a1" ; ftk get a1.bundle a1.bundle
```
- `ftk run` without a project runs in `~/.ftk/xfer`.
- On a Windows host, `~` is the Ubuntu (WSL) home.

### Branch safety
- The clone is single-branch (`git clone --single-branch -b v2`). `checkout` and `new-lane` fetch only the exact branch they need, and never `--all`.
- Branches starting with `migrate/operator-records` are refused everywhere.

### `wait` and state
- The Stop/Notification hooks write `~/.ftk/state-<session>` (`stop`/`waiting` + timestamp).
- `say`/`key` set the state to `busy`. `wait` returns as soon as the state is `stop` or `waiting`, and exits with 124 on timeout.
- Hooks fire only for ftk sessions; the host's own Claude sessions are ignored.

### Permissions
Nothing is auto-approved. The host can add an allowlist to the project's `.claude/settings.local.json` (see START-HERE.md).

## Troubleshooting
- **`status` says `session: NOT running` (Windows host).**
  - WSL stopped and took tmux with it. Run `ftk start`, or check that the `FTK Agent Keepalive` task is running in Task Scheduler.
  - The task runs elevated ("highest privileges"), like admin SSH sessions. Both must run at the same level, or they see different tmux servers.
- **`Permission denied (publickey)`.**
  - The host pasted the wrong key, or the key went into the wrong file.
  - Run the host script again and paste the content of the client's `~/.ssh/ftk_ed25519.pub`.
- **Timeout.** Tailscale is not connected on one side, the Share invite was not accepted, or the host is asleep.
- **`checkout` refuses.** The agent has uncommitted changes. Let it commit first, or use `ftk say` to ask it to.

## Development
- `ftk-remote.sh` is the single source of the host helper.
- After editing it, run `python3 embed.py` to copy it into both host scripts. The tests fail if the copies drift.
- Run the tests with `bash tests/run.sh` (needs `tmux`).
  - Everything runs in a temp HOME with a private tmux socket and stubbed `osascript`/`ssh`/`wsl`/`pbcopy`, so nothing real is touched.
  - The PowerShell tests download `pwsh` 7.4 to `tests/.cache` if it is missing.
