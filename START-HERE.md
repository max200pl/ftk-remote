# FTK Remote — host setup

> **RU:** Отдай эту папку своему Claude Code и скажи: «Прочитай START-HERE.md и сделай настройку». Тебе останется нажимать OK в окнах, один раз залогиниться в Claude и выбрать папку для репозитория.

## What this does
A teammate wants to use this computer for Claude Code agents working on a project migration, and to watch and steer those agents remotely. The setup script installs and configures:
- **Tailscale:** a private network, so nothing is opened to the internet.
- **SSH:** login only with the teammate's key (`teammate.pub` in this folder).
- **tmux + Claude Code:** the agent runs in a session called `ftk` inside the cloned repo. The repo is cloned **single-branch** (`v2` only). The teammate can add more agents ("lanes"), each in its own git worktree.
- **Notifications:** ntfy pushes to the teammate, sent when setup is done, when the agent finishes a turn, and when it needs input.

## Instructions for Claude (the agent reading this)
1. Find out the OS. Do **not** edit the scripts.
2. **macOS.** The script must run in a real Terminal window: it shows dialogs, and Homebrew/git may ask for passwords. Do not run it inside your own shell tool, because it would block. From this folder, run:
   ```bash
   xattr -dr com.apple.quarantine . 2>/dev/null; chmod +x host-setup-mac.command
   open -a Terminal "$(pwd)/host-setup-mac.command"
   ```
   **Windows.** Run this in PowerShell from this folder (keep the `.cmd` and `.ps1` together). It asks for Administrator rights:
   ```powershell
   Get-ChildItem . | Unblock-File; Start-Process "$PWD\host-setup-windows.cmd"
   ```
3. Tell the human what to expect:
   - **Click OK through the dialogs.** The teammate's SSH key is pre-filled, so just confirm it.
   - **Repository:** choose **"Teammate sends it"** (Windows: **Yes**). The teammate copies the code over SSH, so no git login is needed here.
     - Only if the teammate asked you to clone it yourself, choose "Clone from URL" and log in to git when asked (Windows opens a browser; on a Mac use a Personal Access Token as the password).
   - **The agent window:** log in to Claude if asked, answer **"Yes, I trust this folder"**, then close that window. The agent keeps running.
   - **Windows only:** if WSL gets installed, the script asks for a restart. After it, open "Ubuntu" from the Start menu once and create a Linux user, then run step 2 again.
   - The setup also installs `~/.claude/agents/migration-worker.md` and copies `setup-migration-env.sh` to `~/.ftk/`, where the teammate runs it later. On Windows both go inside Ubuntu.
4. Verify:
   - macOS: `~/.ftk/ftk-remote status`
   - Windows: `wsl -e /usr/local/bin/ftk-remote status`

   Expected: `session: running`.
5. Done. The teammate is notified automatically. If the human wants, they can also send the `FTK|...` line from the clipboard.

## Migration
What the migration does on this computer, and what the agents may and may not do: see **MIGRATION.md**.

## Permissions (your decision)
The agents run with normal Claude Code permissions, and nothing is auto-approved. To let them run tests and git without asking each time, add an allowlist to the project's `.claude/settings.local.json`. Do this in the main clone; each lane worktree needs its own copy:
```json
{
  "permissions": {
    "allow": [
      "Bash(git status:*)", "Bash(git diff:*)", "Bash(git log:*)",
      "Bash(git add:*)", "Bash(git commit:*)",
      "Bash(python -m pytest:*)", "Bash(python3 -m pytest:*)"
    ]
  }
}
```
Leave out anything you don't want to allow (for example `git push`, so that pushes still ask).

## Keep in mind
- Keep the computer on, logged in (a locked screen is fine) and connected to Tailscale.
- The agent starts again automatically when you log in.

## How to revoke access later
| | macOS | Windows |
|---|---|---|
| SSH key | delete the `ftk-...` line in `~/.ssh/authorized_keys` | delete it in `C:\ProgramData\ssh\administrators_authorized_keys` and `%USERPROFILE%\.ssh\authorized_keys` |
| SSH server | System Settings → Sharing → Remote Login off | `Stop-Service sshd; Set-Service sshd -StartupType Disabled` |
| Autostart | `launchctl bootout gui/$(id -u)/com.ftk.agent; rm ~/Library/LaunchAgents/com.ftk.agent.plist` | Task Scheduler → delete "FTK Agent Keepalive" |
| Agent hooks | remove the `ftk-remote notify` entries from `~/.claude/settings.json` | same file inside Ubuntu |
| Tailscale | admin console → machine → Share → revoke | same |
