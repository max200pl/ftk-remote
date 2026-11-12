# FTK Remote — host setup

> **RU:** Отдай эту папку своему Claude Code и скажи: «Прочитай START-HERE.md и сделай настройку». Тебе останется нажимать OK в окнах, один раз залогиниться в Claude и выбрать папку для репозитория.

## What this does
A teammate wants to use this computer for Claude Code agents working on a project migration, and to watch and steer those agents remotely. The setup script installs and configures:
- **Tailscale:** a private network, so nothing is opened to the internet.
- **SSH:** login only with the teammate's key (`teammate.pub` in this folder).
- **The agent:**
  - **Mac:** tmux + Claude Code; the agent runs in a session called `ftk`.
  - **Windows:** Claude Code natively in **headless** mode. No WSL, no Ubuntu; it works in a VM too.
  - The repo is single-branch (`v2` only). The teammate can add more agents ("lanes"), each in its own git worktree.
- **Order:** Tailscale, SSH and the teammate's key come **first**. From that moment the teammate can connect and watch the rest of the setup.
- **Notifications (optional, file `ntfy-topic` next to the scripts):** ntfy pushes to the teammate. They report the setup progress live (each step, waits, errors), when the connection is ready, when the setup is done, and when an agent finishes a turn.

## Windows: finish pending updates first
If Windows shows "Update and restart" in the Power menu, do that **before** the setup. While an update is pending, OpenSSH Server and WSL often cannot be installed, and the script keeps asking for a restart. A plain restart does not apply the update.

## Accounts: whose login goes where
- **Tailscale:** log in with **your own** account. The teammate is in a different tailnet, so share this machine with them:
  1. Open https://login.tailscale.com/admin/machines.
  2. Click this machine, then **...** > **Share** > **Copy share link**.
  3. Send the link to the teammate. They open it while logged in to *their* Tailscale account and click **Accept**. This machine then appears in their tailnet. Only this machine is shared, not your whole network.
- **Claude Code:** log in with **your own** subscription in the agent window. The agents run under your account.
- **Git:** no login. The repo comes inside the kit (`repo.bundle`) or from the teammate over SSH.
- **Nobody needs the teammate's password.** They reach this machine only with the SSH key in `teammate.pub`.

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
   - **Windows:** if the script asks for "Update and restart", do that, then run step 2 again.
   - The setup also installs `~/.claude/agents/migration-worker.md` (if the kit has it) and copies `setup-migration-env.sh` to `~/.ftk/`, where the teammate runs it later.
4. Verify:
   - macOS: `~/.ftk/ftk-remote status`. Expected: `session: running`.
   - Windows: `powershell -NoProfile -ExecutionPolicy Bypass -File C:\ProgramData\ftk\ftk-remote.ps1 status`. Expected: `claude:` with a path, and a `state:` line. The setup itself already checked that the agent answers.
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

## Windows in a virtual machine on a Mac (Parallels / VMware Fusion / UTM)
- **Run the Windows host setup inside the VM**, as on a normal PC. Tailscale inside the VM gives the VM its own address, so the VM's network mode (NAT or bridged) does not matter.
- **No WSL needed:** on Windows the agents run natively (headless Claude Code), so nested virtualization does not matter.
- **Keep the VM running:**
  - Do not suspend or pause it. Parallels: Configure > Options > Optimization, turn off "Pause Windows when possible". Battery: "Longer battery life" off.
  - Inside Windows, turn sleep off.
  - The Mac itself must not sleep either; see "On a MacBook" below (the lid).
- **Memory:** give the VM at least 8 GB if the Mac has 16 GB or more.

## On a MacBook (laptop)
- **The lid matters.** A closed lid puts the Mac to sleep, which stops the agents and drops the connection. The setup's `caffeinate` only prevents *idle* sleep, not lid sleep. Pick one:
  1. Keep the lid **open** and the charger connected. The screen may turn off; that is fine.
  2. Use clamshell mode: charger **and** an external display connected, then the lid can be closed.
  3. `sudo pmset -a disablesleep 1` keeps it awake even with the lid closed. Undo with `sudo pmset -a disablesleep 0`. Careful: a fanless MacBook Air in a bag gets hot, so turn it off before you pack the laptop.
- **macOS or a Windows VM:** both work. Running the host directly on macOS saves RAM; a Windows VM works too (no WSL needed).
- **Optional isolation:** to keep the agents away from your personal files, create a separate macOS user for this work (System Settings > Users & Groups), log in as that user once, and run the setup there. Keep that user logged in (fast user switching is fine).
- **Memory:** with 16 GB, 2–3 agents in parallel are fine; with 8 GB, use 1–2.

## Keep in mind
- Keep the computer on, logged in (a locked screen is fine) and connected to Tailscale.
- The agent starts again automatically when you log in.

## Automatic updates (please read)
The "FTK Agents" shortcut (Desktop and Startup on Windows, LaunchAgent on Mac) checks the kit repository on GitHub at every start. It installs a newer helper only if the version is higher and the file is valid. This means **whoever controls that GitHub repository can change the code that runs on this computer**.
- To switch updates off, create an empty file `~/.ftk/no-update` (Windows: `%USERPROFILE%\.ftk\no-update`). The teammate can still update on request with `ftk update-host` only after you delete that file.
- Removing the shortcut from Startup also stops the automatic update and the window at logon.

## How to revoke access later
| | macOS | Windows |
|---|---|---|
| SSH key | delete the `ftk-...` line in `~/.ssh/authorized_keys` | delete it in `C:\ProgramData\ssh\administrators_authorized_keys` and `%USERPROFILE%\.ssh\authorized_keys` |
| SSH server | System Settings → Sharing → Remote Login off | `Stop-Service sshd; Set-Service sshd -StartupType Disabled` |
| Autostart | `launchctl bootout gui/$(id -u)/com.ftk.agent; rm ~/Library/LaunchAgents/com.ftk.agent.plist` | nothing runs in the background (headless) |
| Agent hooks | remove the `ftk-remote notify` entries from `~/.claude/settings.json` | none |
| Helper | `rm -rf ~/.ftk` | delete `C:\ProgramData\ftk` and `%USERPROFILE%\.ftk` |
| Tailscale | admin console → machine → Share → revoke | same |
