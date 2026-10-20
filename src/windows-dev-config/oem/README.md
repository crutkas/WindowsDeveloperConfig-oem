# Windows Dev Config: offline kit for OEM images

This kit sets up a new Windows PC the same way as the standard Windows Dev Config setup:

```powershell
irm https://aka.ms/devconfig/standard/setup.ps1 | iex
```

The difference is that everything is downloaded ahead of time. The PC needs **no network
access** during Windows setup or at first sign-in. When the user first reaches the desktop, the
developer tools, settings, Windows Terminal, PowerShell 7, the GitHub Copilot CLI, and WSL with
Ubuntu are already in place.

## What the user gets

The kit reproduces the standard setup (`-Action Partial`):

| Area | Result |
|---|---|
| Tools | Windows Terminal, Intelligent Terminal, PowerShell 7, Git, GitHub CLI, Azure CLI, GitHub Copilot CLI, VS Code, .NET 10 SDK, Python 3.14, VC++ Redistributable, uv, Node.js LTS, NVM for Windows, Coreutils, Oh My Posh, winapp CLI, PowerToys |
| WinGet | App Installer updated to the version the standard setup pins |
| System | Long paths enabled; Cascadia Code and Cascadia Mono Nerd Fonts installed |
| File Explorer | File extensions and hidden files shown, full path in title bar, opens to This PC, no frequent files/folders, no sync tips, Details pane state |
| Taskbar and Start | End Task on right-click, no Start recommendations, no account notifications |
| Look | Dark mode; Terminal uses PowerShell 7 and Cascadia Mono NF; Oh My Posh prompt |
| Copilot | GitHub Copilot profile in Terminal; win-dev-skills marketplace and WinUI plugin |
| WSL | WSL installed and Ubuntu registered; Ubuntu asks for a Linux user name the first time it opens |

## How it works

```mermaid
flowchart TD
    A["Internet-connected PC<br/>download.ps1"] -->|"kit folder (about 3 GB)"| B["Windows image<br/>C:\setup\devsetup"]
    B --> C{"Machine part:<br/>machine-setup.ps1"}
    C -->|"Option A: SetupComplete.cmd<br/>(SYSTEM, first boot)"| D["Machine-wide installs and settings"]
    C -->|"Option B: audit mode<br/>(administrator, before sysprep)"| D
    D --> E["Active Setup entry:<br/>run user-setup.ps1 once per user"]
    F["User finishes OOBE and signs in"] --> G["Explorer runs the Active Setup StubPath as that user"]
    E -.-> G
    G --> H["user-setup.ps1 -Stage SignIn (hidden)<br/>Explorer, Start, and dark mode settings before the desktop loads"]
    H --> I["user-setup.ps1 -Stage Main (visible window)<br/>Terminal, PowerShell profile, Copilot, Ubuntu"]
```

| File | Runs | Account | Network |
|---|---|---|---|
| `download.ps1` | Once, on a technician PC | Any user | Required |
| `machine-setup.ps1` | Once per device or image | SYSTEM or an administrator | Not used |
| `SetupComplete.cmd` | Windows runs it at the end of setup | SYSTEM | Not used |
| `user-setup.ps1` | Once per user, at first sign-in | That user, never elevated | Not used |

Both setup scripts load the Microsoft-signed Windows Dev Config steps from the kit, so every
setting, check, and line of console output matches the online setup. Only downloads are replaced
with the files in the kit. Each step checks first, applies only what is missing, and checks again
afterwards, so running a script twice is safe.

## Requirements

**Technician PC (download):** Windows 10 or 11, internet access, WinGet 1.8 or later
(`winget --version`), and about 4 GB of free space.

**Target device:** Windows 11 x64 (pass `-Architecture arm64` to `download.ps1` for Arm64
devices). Virtualization must be enabled in the firmware so WSL 2 can run. Plan for about
3 GB for the kit and 8 GB for the installed tools.

## Step 1: Download the kit

On the internet-connected PC, from the folder that contains this README:

```powershell
powershell -NoProfile -ExecutionPolicy RemoteSigned -File .\download.ps1
```

- The kit is written to `C:\setup\devsetup`. Use `-Destination` to choose another folder.
- The script reads the current standard setup from `https://aka.ms/devconfig/standard/setup.ps1`,
  checks its Microsoft signature, and downloads the exact signed payload that it pins.
- The package list and pinned versions come from that payload, so the kit always matches what the
  online setup installs on the day you run it. Run it again to refresh the kit.
- Every installer is checked: WinGet verifies package hashes, the payload, WinGet, Cascadia, and
  Ubuntu are checked against pinned SHA-256 values, and the WSL MSI must be Microsoft-signed.
- If you downloaded these scripts with a browser, run `Unblock-File .\*.ps1` first.

The kit folder contains:

| Path | Contents |
|---|---|
| `devsetup.json` | The install plan: each package's file, SHA-256, silent switches, and how to detect it |
| `payload\` | The Microsoft-signed Windows Dev Config scripts |
| `packages\` | One folder per WinGet package (installer, manifest, and MSIX dependencies) |
| `winget\` | App Installer (WinGet) bundle, dependencies, and license |
| `fonts\` | Cascadia Code release |
| `wsl\` | WSL MSI and the Ubuntu image (`.wsl`) |
| `copilot\` | Terminal icon and an offline copy of the win-dev-skills marketplace with the WinUI plugin |
| `machine-setup.ps1`, `user-setup.ps1`, `_oem.ps1`, `SetupComplete.cmd`, `README.md` | The kit scripts and this guide |

## Step 2: Add the kit to the image

Choose one option for the machine part.

> **Important:** Windows does not run `SetupComplete.cmd` when the device uses an OEM product key,
> except on Enterprise editions
> ([Add a Custom Script to Windows Setup](https://learn.microsoft.com/windows-hardware/manufacture/desktop/add-a-custom-script-to-windows-setup)).
> For devices that ship with an OEM key, use **Option B**.

### Option A: offline servicing with SetupComplete.cmd

Use this for images without an OEM product key (for example Enterprise or volume-licensed
images). From an elevated command prompt, with the image index you ship:

```cmd
md C:\mount
Dism /Mount-Image /ImageFile:D:\images\install.wim /Index:5 /MountDir:C:\mount

robocopy C:\setup\devsetup C:\mount\setup\devsetup /E

md C:\mount\Windows\Setup\Scripts
copy C:\setup\devsetup\SetupComplete.cmd C:\mount\Windows\Setup\Scripts\SetupComplete.cmd

Dism /Image:C:\mount /Enable-Feature /FeatureName:VirtualMachinePlatform /All
Dism /Image:C:\mount /Enable-Feature /FeatureName:Microsoft-Windows-Subsystem-Linux /All

Dism /Unmount-Image /MountDir:C:\mount /Commit
```

- If the image already has a `SetupComplete.cmd`, add the lines from the kit's
  `SetupComplete.cmd` to it instead of replacing it.
- `SetupComplete.cmd` runs `machine-setup.ps1 -PerUserApps`. Windows removes MSIX app
  provisioning made during OOBE when it deletes its temporary setup account, so in this option the
  MSIX apps (Terminal, PowerShell 7, WinGet, Intelligent Terminal, Oh My Posh, winapp CLI) are staged
  and installed for each user at first sign-in from the local copy, the way the online setup
  installs them. Everything else is installed machine-wide.
- Turning the WSL features on in the image matters: `SetupComplete.cmd` cannot restart Windows,
  so features turned on there only start after the next restart. If you skip this, Ubuntu is
  added automatically at the user's next sign-in after a restart.
- `machine-setup.ps1` took about 9 minutes in a 4-core test VM; a second run takes about a
  minute. Use Option B to keep that time out of the customer's first boot.

### Option B: audit mode (recommended for factory images)

This installs the machine-wide tools on the reference PC before it is captured, so first boot is
not slower and the OEM product key does not matter.

1. Boot the reference PC into audit mode (press **Ctrl+Shift+F3** at the first OOBE screen, or use
   an answer file with `Microsoft-Windows-Deployment\Reseal\Mode = Audit`).
2. Copy the kit folder to `C:\setup\devsetup`.
3. From an elevated PowerShell:

   ```powershell
   powershell -NoProfile -ExecutionPolicy RemoteSigned -File C:\setup\devsetup\machine-setup.ps1
   ```

4. Restart (still in audit mode) so the WSL features finish turning on, then run the same command
   again. Every step should report `already OK`.
5. Generalize and capture as usual, for example `sysprep /generalize /oobe /shutdown`.

The audit-mode Administrator is skipped by `user-setup.ps1`; the per-user part runs for the
customer's account after OOBE. You do not need `SetupComplete.cmd` with this option.

Keep `C:\setup\devsetup` in the image until `machine-setup.ps1` has run. After that,
`machine-setup.ps1` has copied everything each user needs to `C:\ProgramData\CalmOS-Offline`, so
`C:\setup\devsetup` can be deleted to save about 3 GB.

> **Run the machine part before any user account exists.** Windows runs Active Setup entries only
> during a profile's *first* sign-in, so accounts that already signed in before
> `machine-setup.ps1` ran do not get the per-user part automatically. In both options above the
> customer's account is created later in OOBE, so this happens on its own. For an account that
> already exists, run the per-user command in [Troubleshooting](#troubleshooting) once.

## Step 3: What happens on the device

1. **Machine part** (SYSTEM via `SetupComplete.cmd`, or already done in audit mode):
   - Restricts `C:\setup` and the kit so only administrators and SYSTEM can change them (users can still read them), and refuses to run from a folder that other users could replace.
   - Installs the signed payload to `C:\ProgramData\CalmOS`, where the online setup also keeps it.
   - Provisions App Installer and the MSIX packages for every user (from `SetupComplete.cmd` it
     stages them for each user's first sign-in instead), runs the other installers machine-wide
     with silent switches, sets long paths, installs the fonts, turns on WSL, and installs the WSL
     MSI.
   - Copies the per-user files to `C:\ProgramData\CalmOS-Offline` and registers
     `user-setup.ps1` with Active Setup. It never restarts Windows.
2. **OOBE:** the customer goes through OOBE as normal.
3. **First sign-in:** Explorer runs the Active Setup entry once for that user:
   - A hidden step applies the File Explorer, taskbar, Start, and dark mode settings before the
     desktop appears, so no sign-out is needed for them.
   - A window titled **Windows Dev Config -- finishing setup** then makes sure Terminal,
     PowerShell 7, and the other apps are registered for this user (including their `pwsh`,
     `oh-my-posh`, and `winapp` commands), and configures Terminal, the PowerShell profile,
     Copilot, and Ubuntu. It shows the same phases and check marks as the online setup, takes about
     3 minutes, ends with a summary, and closes on a key press or after 15 minutes.
   - If a step cannot finish yet, for example because WSL needs a restart, the window says so and
     the script runs again at the next sign-in (up to three times).
4. **Every later user** on the PC gets the same per-user setup at their first sign-in.

If the PC is online at first sign-in, the Copilot marketplace is registered from GitHub exactly
like the online setup. Otherwise the kit's copy is used.

## Verify a device

| Check | Expected |
|---|---|
| `C:\ProgramData\CalmOS-Offline\machine-setup-result.json` | `"Completed": true` and an empty `Flagged` list |
| `%LOCALAPPDATA%\CalmOS\offline-user-setup-result.json` | `"Completed": true` and an empty `Flagged` list |
| `wsl --list` | `Ubuntu` |
| `git --version`, `gh --version`, `az version`, `code --version`, `dotnet --version`, `python --version`, `node --version`, `uv --version`, `copilot --version`, `pwsh --version`, `winget --version` | Each prints a version |
| Windows Terminal | Opens to PowerShell 7 in Cascadia Mono NF with the Oh My Posh prompt and a **GitHub Copilot** profile |

Logs:

| Log | Location |
|---|---|
| Machine part | `C:\ProgramData\CalmOS-Offline\machine-setup-log.txt` (MSI logs in `logs\`) |
| SetupComplete console output | `C:\Windows\Temp\devsetup-machine-setup.txt` |
| User part | `%LOCALAPPDATA%\CalmOS\offline-user-setup-log.txt` and `offline-signin-log.txt` |

## Troubleshooting

- **Run the machine part again:** run the audit-mode command from an elevated PowerShell. Steps
  that are done report `already OK`.
- **Run the user part again** (signed in as that user, not elevated):

  ```powershell
  powershell -NoProfile -ExecutionPolicy RemoteSigned -File C:\ProgramData\CalmOS-Offline\user-setup.ps1
  ```

- **Ubuntu is flagged:** restart the PC and sign in again. If it is still flagged, check that
  virtualization is enabled in the firmware.
- **"failed its SHA-256 check" or "failed Microsoft signature verification":** the kit was changed
  or copied incompletely. Download it again.
- **A package is flagged:** its installer log is in `C:\ProgramData\CalmOS-Offline\logs`, and its
  exit code is in `machine-setup-log.txt`.

## Differences from the online setup

- Tools are installed once for the whole PC instead of per user where the online setup would use
  per-user installers (VS Code, PowerToys, GitHub Copilot CLI, uv, and the MSIX apps).
- NVM for Windows is installed to `%ProgramFiles%\nvm`, so `nvm install` needs an administrator.
- Versions are the ones current when `download.ps1` ran. The apps update themselves, or with
  `winget upgrade --all`, once the PC is online.
- When the PC is offline at first sign-in, the win-dev-skills marketplace points at the copy in
  `C:\ProgramData\CalmOS-Offline\copilot`. To switch it to GitHub later, run
  `copilot plugin marketplace remove win-dev-skills` and then
  `copilot plugin marketplace add microsoft/win-dev-skills`.
- There are no UAC prompts and no restarts, and the Terminal font applies right away instead of at
  the next sign-in.

## Testing the kit in Hyper-V

`src/tests/oem/hyperv-e2e.ps1` in the Windows Developer Config repository runs the whole flow in a
virtual machine with no network adapter. It needs membership in the Hyper-V Administrators group,
not elevation:

```powershell
.\src\tests\oem\hyperv-e2e.ps1 -IsoPath D:\iso\Win11_x64.iso -KitPath C:\setup\devsetup
```

It installs Windows unattended from the ISO, applies the Option A image changes during setup,
completes OOBE with a local account, signs in once, and then saves screenshots, logs, and a
`verify.json` report. `src\tests\oem\unit.ps1` runs in seconds and fails if the standard setup
gains a step the kit does not cover.

The kit has been run this way on Windows 11 Pro (x64) with no network: Windows Setup,
`SetupComplete.cmd`, OOBE, and the first sign-in of both administrator and standard accounts, with
the Microsoft Defender definitions that ship in the image.
