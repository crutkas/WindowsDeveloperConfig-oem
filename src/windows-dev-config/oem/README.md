# Windows Dev Config: offline kit for OEM images

This kit sets up a new Windows PC the same way as the standard Windows Dev Config setup:

```powershell
irm https://aka.ms/devconfig/standard/setup.ps1 | iex
```

The difference is that everything is downloaded ahead of time. The PC needs **no network
access** during Windows setup or at first sign-in, and **the user never sees a setup window**.
The work happens while Windows shows its own setup screens: the machine part before OOBE, and the
per-user part behind Windows' first sign-in screen. When the desktop appears, the developer
tools, settings, Windows Terminal, PowerShell 7, the GitHub Copilot CLI, and WSL with Ubuntu are
already in place.

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

## Machine-wide and per-user work

The kit splits that work in two. Everything that can be done for the whole PC is done once,
before OOBE. Only what Windows stores in each user's own profile is done per user, hidden, at
that user's first sign-in.

### Machine-wide: `machine-setup.ps1`

Runs once per PC, before OOBE: as SYSTEM from `SetupComplete.cmd` (Options A and C) or as an
administrator in audit mode (Option B). It never restarts Windows.

| Area | What it does |
|---|---|
| Kit and setup files | Restricts `C:\setup` and the kit to administrators and SYSTEM. Installs the signed Windows Dev Config scripts to `C:\ProgramData\CalmOS`, where the online setup keeps them, and copies the files each user needs to `C:\ProgramData\CalmOS-Offline`. |
| Apps for all users | Installs from the kit with each installer's silent switches: Git, GitHub CLI, Azure CLI, GitHub Copilot CLI, VS Code, .NET 10 SDK, Python 3.14, VC++ Redistributable, uv, Node.js LTS, NVM for Windows, Coreutils, and PowerToys. |
| MSIX apps | Windows Terminal, Intelligent Terminal, PowerShell 7, App Installer (WinGet), Oh My Posh, and winapp CLI. Option B provisions them for all users. Options A and C stage them in `C:\ProgramData\CalmOS-Offline` for each user's first sign-in, because Windows drops MSIX provisioning made during OOBE. |
| System settings | Win32 long paths. |
| Fonts | Cascadia Code NF and Cascadia Mono NF, for all users. |
| WSL | Turns on Virtual Machine Platform and Windows Subsystem for Linux, and installs the WSL MSI. |
| Default user profile | Writes the per-user settings that every new account starts with: the File Explorer settings (file extensions, hidden files, full path in the title bar, open to This PC, no frequent folders or files, no sync tips, Details pane), the taskbar and Start settings (End Task, no recommendations, no account notifications), dark mode, the Oh My Posh line in the PowerShell 7 profile, the WSL first-run flag, and PowerToys' always-on-top notification turned off. |
| First sign-in | Registers `user-setup.ps1` with Active Setup. |
| Retry | If a step is flagged, registers the `WindowsDevConfig-OfflineMachineRetry` scheduled task, which runs the machine part again as SYSTEM, hidden, at the next startup, up to three times. The task removes itself once every step passes. |

### Per user: `user-setup.ps1`

Runs once per account at its first sign-in, through Active Setup: as that user, never elevated,
with no window and no network. Explorer waits for it before it shows the desktop, so it is done
when the desktop appears.

| Area | What it does |
|---|---|
| MSIX apps | Installs them for this user from the staged copy (Options A and C) or registers the provisioned ones (Option B), and makes sure their commands (`wt`, `pwsh`, `winget`, `oh-my-posh`, `winapp`) work. |
| PowerToys | Registers its identity package with its app folder, so PowerToys Settings, Image Resizer, Advanced Paste, and the Command Palette extension start. |
| Coreutils | Adds Coreutils' command hook (`ls` and the other Coreutils commands) to the PowerShell 7 profile, using Coreutils' own script. |
| Windows Terminal | Sets PowerShell 7 as the default profile and Cascadia Mono NF as the font, and adds the GitHub Copilot profile. |
| GitHub Copilot CLI | Adds the win-dev-skills marketplace (from GitHub when the PC is online, otherwise the local copy) and installs the WinUI plugin. |
| Ubuntu | Registers Ubuntu in WSL from the local image. Ubuntu asks for a Linux user name the first time it opens. |
| Settings check | Checks every Default user profile setting above and puts back any that Windows reset during the first sign-in (Windows resets dark mode, for example). |

These items are per user because Windows keeps them in each user's profile: MSIX app
registrations, Terminal settings, the PowerShell profile, Copilot's configuration, and WSL
distributions. Windows creates that profile only at the user's first sign-in.

## How it works

```mermaid
flowchart TD
    A["Internet-connected PC<br/>download.ps1"] -->|"kit folder (about 3 GB)"| B["Windows image<br/>C:\setup\devsetup"]
    B --> C{"Machine part:<br/>machine-setup.ps1"}
    C -->|"Option A: SetupComplete.cmd<br/>(SYSTEM, before OOBE)"| D["Machine-wide installs and settings"]
    C -->|"Option B: audit mode<br/>(administrator, before sysprep)"| D
    C -->|"Option C: USB install media<br/>(SetupComplete.cmd from sources\$OEM$)"| D
    D --> D2["Default user profile:<br/>Explorer, Start, dark mode, prompt settings"]
    D2 --> E["Active Setup entry:<br/>run user-setup.ps1 once per user"]
    F["User finishes OOBE and signs in"] --> G["Explorer runs the Active Setup StubPath as that user<br/>(Windows keeps its 'This might take a few minutes' screen up)"]
    E -.-> G
    G --> H["user-setup.ps1, hidden, about 1-2 minutes<br/>apps, Terminal, Copilot, Ubuntu; checks every setting"]
    H --> I["Desktop appears, fully set up"]
```

| File | Runs | Account | Network |
|---|---|---|---|
| `download.ps1` | Once, on a technician PC | Any user | Required |
| `machine-setup.ps1` | Once per device or image | SYSTEM or an administrator | Not used |
| `SetupComplete.cmd` | Windows runs it at the end of setup | SYSTEM | Not used |
| `build-media.ps1` | Optional (Option C), on the technician PC | Any user (an administrator for `-UsbDrive`) | Not used |
| `user-setup.ps1` | Once per user, at first sign-in, hidden | That user, never elevated | Not used |

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

### What download.ps1 downloads

When it finishes, `download.ps1` prints a table of every item with its version, source, and size.
Run `.\download.ps1 -List` to show that table again for an existing kit. The kit is about 3 GB.

| Item | Source | Version |
|---|---|---|
| Windows Dev Config scripts (Microsoft-signed) | github.com/microsoft/WindowsDeveloperConfig | The commit that `aka.ms/devconfig/standard/setup.ps1` pins |
| App Installer (WinGet), with its dependencies and license | github.com/microsoft/winget-cli releases | Pinned by the standard setup; SHA-256 checked |
| 18 standard packages, each with its WinGet manifest and any MSIX dependencies | WinGet, with `winget download` | Latest in WinGet when `download.ps1` runs; the machine-wide installer when the package has one |
| Cascadia Code fonts | github.com/microsoft/cascadia-code releases | Pinned by the standard setup; SHA-256 checked |
| Windows Subsystem for Linux (MSI) | github.com/microsoft/WSL releases | Latest release; must be Microsoft-signed |
| Ubuntu (`.wsl` image) | releases.ubuntu.com, from WSL's own distribution list | WSL's current default Ubuntu; SHA-256 checked |
| win-dev-skills marketplace and its WinUI plugin | github.com/microsoft/win-dev-skills and microsoft/winappCli | The marketplace's main branch and the plugin commit it pins |
| GitHub Copilot Terminal icon | github.githubassets.com | |

The 18 packages, by WinGet ID: Microsoft.WindowsTerminal, Microsoft.IntelligentTerminal,
Microsoft.PowerShell, Git.Git, GitHub.cli, Microsoft.AzureCLI, GitHub.Copilot,
Microsoft.VisualStudioCode, Microsoft.DotNet.SDK.10, Python.Python.3.14,
Microsoft.VCRedist.2015+.x64 (`.arm64` on Arm64), astral-sh.uv, OpenJS.NodeJS.LTS,
CoreyButler.NVMforWindows, Microsoft.Coreutils, JanDeDobbeleer.OhMyPosh, Microsoft.WinAppCli,
and Microsoft.PowerToys. The list comes from the signed scripts, so it follows the standard
setup.

## Step 2: Add the kit to the image

Choose one option for the machine part.

> **Important:** Windows does not run `SetupComplete.cmd` when the device uses an OEM product key,
> except on Enterprise editions
> ([Add a Custom Script to Windows Setup](https://learn.microsoft.com/windows-hardware/manufacture/desktop/add-a-custom-script-to-windows-setup)).
> For devices that ship with an OEM key, use **Option B**. Options A and C both depend on `SetupComplete.cmd`.

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

### Option C: installation media (USB drive)

This is Option A delivered on bootable media: the same `SetupComplete.cmd` flow, so the same
OEM product key limit applies. The Windows image itself is not changed. `build-media.ps1` makes
the media in one of three ways. Run it from the folder that contains this README, after Step 1:

| Goal | Command | Needs |
|---|---|---|
| A bootable ISO (for Hyper-V, Rufus, or a lab image server) | `.\build-media.ps1 -IsoPath D:\iso\Win11_x64.iso -OutputPath D:\iso\Win11_x64_devsetup.iso` | Any user |
| A new FAT32 USB drive from an ISO | `.\build-media.ps1 -IsoPath D:\iso\Win11_x64.iso -UsbDrive E:` | Elevated PowerShell, 16 GB or larger USB drive |
| Add the kit to a USB drive that already installs Windows (for example, from the Media Creation Tool) | `.\build-media.ps1 -AddToUsb E:` | Any user, about 3.5 GB free on the drive |

- `-UsbDrive` **erases the drive** after you type `ERASE` to confirm (`-Force` skips the prompt),
  formats it FAT32 (up to
  32 GB), and copies the ISO. FAT32 cannot hold files larger than 4 GB, so it splits
  `sources\install.wim` into `install.swm` files with DISM; Windows Setup reads them as is. FAT32
  drives boot on every UEFI PC without extra boot helpers.
- `-AddToUsb` keeps everything on the drive. It merges the WSL step into an existing
  `autounattend.xml` (saving the original as `autounattend.xml.bak`) and asks for `-Force` before
  it replaces an existing `sources\$OEM$` folder.

`build-media.ps1` adds:

| Path on the media | What Windows Setup does with it |
|---|---|
| `sources\$OEM$\$1\setup\devsetup\` | Copies the kit to `C:\setup\devsetup` |
| `sources\$OEM$\$$\Setup\Scripts\SetupComplete.cmd` | Copies it to `C:\Windows\Setup\Scripts\`, so the machine part runs as SYSTEM after setup |
| `autounattend.xml` | Turns on the WSL features during setup, so Ubuntu works at the first sign-in without a restart |

- Windows Setup and OOBE stay interactive. To automate them, pass your own answer file with
  `-AnswerFile`; `build-media.ps1` adds its WSL step to it.
- The ISO is about 10 GB and boots on UEFI PCs (Windows 11 requires UEFI). To write it to a USB
  drive with another tool, [Rufus](https://rufus.ie) with its defaults works.
- Booting the ISO in a Hyper-V Gen 2 VM tests the same files the USB drive uses; see
  [Testing the kit in Hyper-V](#testing-the-kit-in-hyper-v).

Keep `C:\setup\devsetup` in the image until `machine-setup.ps1` has run. After that,
`machine-setup.ps1` has copied everything each user needs to `C:\ProgramData\CalmOS-Offline`, so
`C:\setup\devsetup` can be deleted to save about 3 GB.

> **Run the machine part before any user account exists.** Windows runs Active Setup entries only
> during a profile's *first* sign-in, so accounts that already signed in before
> `machine-setup.ps1` ran do not get the per-user part automatically. In both options above the
> customer's account is created later in OOBE, so this happens on its own (also in Option C). For an account that
> already exists, run the per-user command in [Troubleshooting](#troubleshooting) once.

## Step 3: What happens on the device

[Machine-wide and per-user work](#machine-wide-and-per-user-work) lists everything each part
does. In order:

1. **Before OOBE:** `SetupComplete.cmd` runs the machine part as SYSTEM while Windows shows
   "Just a moment" (Options A and C). In Option B it already ran in audit mode.
2. **OOBE:** the customer goes through OOBE as normal and creates their account from the
   prepared Default user profile.
3. **First sign-in:** the per-user part runs hidden while Windows keeps its own "This might take
   a few minutes" screen up, so the user sees nothing from the kit. It took about 70 seconds in
   testing when the MSIX apps were provisioned for all users, and about 2 minutes when they
   installed per user. If a step cannot finish yet (for example, because WSL needs a restart), the
   script runs again, hidden, at the next sign-in, up to three times.
4. **Every later user** on the PC gets the same per-user setup, hidden, at their first sign-in.

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
| User part | `%LOCALAPPDATA%\CalmOS\offline-user-setup-log.txt` (same phases and check marks as the online setup) |

## Troubleshooting

- **Run the machine part again:** run the audit-mode command from an elevated PowerShell. Steps
  that are done report `already OK`. If the machine part flagged a step, it already runs again at
  each startup (up to three times) through the `WindowsDevConfig-OfflineMachineRetry` task;
  `C:\ProgramData\CalmOS-Offline\machine-setup-log.txt` shows each run.
- **Run the user part again** (signed in as that user, not elevated). Run from a console, it shows
  the same output it writes to its log:

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
- PowerToys is installed machine-wide. Because the PowerToys installer registers its identity package
  without its app folder when it runs as SYSTEM, the per-user part registers that package again for
  each user, so PowerToys Settings, Advanced Paste, and the Command Palette extension work.
- Coreutils' `ls`-style command hook is added to each user's PowerShell 7 profile with Coreutils'
  own script at first sign-in. Recording that profile for the Coreutils uninstaller needs an
  administrator, so uninstalling Coreutils leaves the hook in those profiles.
- WinGet does not list the GitHub Copilot CLI or Python as WinGet installs, so `winget upgrade`
  does not update them. Both work: Copilot CLI updates itself, and Python's main uninstall entry
  belongs to the SYSTEM account that installed it.
- Versions are the ones current when `download.ps1` ran. The apps update themselves, or with
  `winget upgrade --all`, once the PC is online.
- When the PC is offline at first sign-in, the win-dev-skills marketplace points at the copy in
  `C:\ProgramData\CalmOS-Offline\copilot`. To switch it to GitHub later, run
  `copilot plugin marketplace remove win-dev-skills` and then
  `copilot plugin marketplace add microsoft/win-dev-skills`.
- There are no windows, UAC prompts, or restarts, and the Terminal font applies right away instead
  of at the next sign-in. The first sign-in takes 1-2 minutes longer behind Windows' own screen.

## Testing the kit in Hyper-V

`src/tests/oem/hyperv-e2e.ps1` in the Windows Developer Config repository runs the whole flow in a
virtual machine with no network adapter. It needs membership in the Hyper-V Administrators group,
not elevation:

```powershell
.\src\tests\oem\hyperv-e2e.ps1 -IsoPath D:\iso\Win11_x64.iso -KitPath C:\setup\devsetup

# Option C: build the installation media with build-media.ps1 and boot only that ISO
.\src\tests\oem\hyperv-e2e.ps1 -IsoPath D:\iso\Win11_x64.iso -KitPath C:\setup\devsetup -UseMedia
```

It installs Windows unattended from the ISO, applies the Option A image changes during setup,
completes OOBE with a local account, signs in once, and then saves screenshots, logs, and a
`verify.json` report. The report reads PATH from a new sign-in, as a new terminal sees it, and the
run fails if any entry still contains an unexpanded variable such as `%NVM_HOME%`.
`src\tests\oem\unit.ps1` runs in seconds and fails if the standard setup
gains a step the kit does not cover.

The kit has been run this way on Windows 11 Pro (x64) with no network: Windows Setup,
`SetupComplete.cmd`, OOBE, and the first sign-in of both administrator and standard accounts, with
the Microsoft Defender definitions that ship in the image.
