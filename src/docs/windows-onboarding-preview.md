# Windows onboarding: personal-fork source preview

This is a review-only preview in **crutkas/WindowsDeveloperConfig-oem**.
It is not a Microsoft-signed release or an official onboarding recommendation
from the linked projects. No new `aka.ms` routes exist. Published short links
and top-level signed `Workloads` copies still use upstream payloads and must
not be used to test these changes.

## Run from the fork

Review the draft PR and source before executing anything. On a disposable
Windows development VM, with Git, PowerShell and WinGet installed:

```powershell
git clone --branch crutkas-devconfig-fork-only-workloads --single-branch https://github.com/crutkas/WindowsDeveloperConfig-oem.git
Set-Location WindowsDeveloperConfig-oem
.\src\Workloads\install-source.ps1 -Workload python
```

Replace `python` with a workload ID in the table below. This dispatcher invokes
only local source. The reused Rust/.NET/Go/PHP engine is explicitly launched
with its existing `-AllowUnsigned` development option. No signatures are
created, simulated or relaxed in production code. If your execution policy
disallows unsigned source, use an approved development environment; the
dispatcher does not change policy.

Run as the intended developer account, not a separate administrator account:
Python/MSIX and editor installs are per-user. Tauri and Flutter require an
elevated PowerShell session for their toolchain setup. Other package installers
can also request elevation. WinGet Configuration/DSC resources must be available;
the existing configuration helper can remediate WinGet and its VC runtime
dependency. These scripts install software and download project-provider assets;
they are **not** dry runs. Do not execute provisioning on a shared desktop.

## Exact mapping

All paths below are relative to the repository root. Every row is available
through `.\src\Workloads\install-source.ps1 -Workload <ID>`.

| Documentation site | ID | Local implementation | Composition and boundaries |
| --- | --- | --- | --- |
| Node.js | `node` | `src\Workloads\node\install.ps1` | Node LTS MSI + bundled npm only. Keeps an existing LTS/runtime manager; stops for incompatible Node instead of replacing it. No TypeScript or nvm installation. |
| Python | `python` | `src\Workloads\python\install.ps1` | Python install manager. Inventory existing runtimes; install the default stable only when none exists. No mandatory uv. |
| Rust | `rust` | `src\windows-dev-config\dev-config.ps1 -Workload rust -AllowUnsigned` | Reused Rust flow: PowerShell, rustup, stable MSVC, VS Community C++ and Windows SDK. |
| VS Code | `vscode` | `src\Workloads\vscode\install.ps1` | Editor only using normal user-context WinGet defaults. Add a language workload separately. No extensions or IDE bundles. |
| .NET | `dotnet` | `src\windows-dev-config\dev-config.ps1 -Workload dotnet -AllowUnsigned` | Reused .NET SDK 10 flow. Existing Developer Mode/PowerShell prerequisites remain; no full workstation phases. |
| Go | `go` | `src\windows-dev-config\dev-config.ps1 -Workload go -AllowUnsigned` | Reused Go + PowerShell flow. |
| PHP | `php` | `src\windows-dev-config\dev-config.ps1 -Workload php -AllowUnsigned` | Reused PHP 8.5 + VC runtime/PowerShell flow. |
| uv | `uv` | `src\Workloads\uv\install.ps1` | Optional standalone uv. Does not install a global Python runtime; project-level `uv sync` may acquire its own Python. |
| PyTorch | `pytorch` | `src\Workloads\pytorch\install.ps1` | Reused hardware-aware backend resolver/private Python 3.13 environment. Not migrated to Python's general-purpose manager. Its GPU/driver constraints still apply. |
| Tauri | `tauri` | `src\Workloads\tauri\install.ps1` | MSVC Build Tools 2022, Windows SDK, stable Rust MSVC and WebView2. No VS IDE. Add `-IncludeNode` only for a JS frontend. |
| Flutter Windows | `flutter` | `src\Workloads\flutter\install.ps1` | Git, stable Flutter source SDK, VS Community C++ desktop/MSVC/CMake/Windows SDK. Windows desktop only; no Android Studio, VS Code or mobile toolchains. |
| Electron | `electron` | `src\Workloads\electron\install.ps1` | Node LTS/npm and Git for the tutorial. Add `-IncludeEditor` for VS Code. Electron/Forge remain project-local. No native-addon C++ toolchain by default. |
| Eclipse Temurin | `temurin` | `src\Workloads\temurin\install.ps1` | Temurin JDK 25 LTS x64 MSI, separate from the existing Microsoft OpenJDK `java` workload. Existing JDKs stay installed. |
| React Native | `react-native` | `src\Workloads\react-native\install.ps1` | **Windows host targeting Android**, not React Native Windows or iOS. Node LTS >=22.11, Microsoft JDK17 and Android Studio; SDK/license/device completion below. |

Use the individual scripts for optional parameters, for example:

```powershell
.\src\Workloads\tauri\install.ps1 -IncludeNode
.\src\Workloads\electron\install.ps1 -IncludeEditor
.\src\Workloads\flutter\install.ps1 -SdkRoot C:\develop\flutter
.\src\Workloads\react-native\install.ps1 -AndroidSdk C:\Android\Sdk -JavaHome 'C:\Program Files\Microsoft\jdk-17.0.21.21-hotspot'
```

Do not install every row: pick the toolchain you need. These focused flows do
not invoke the full workstation setup, WSL, terminal personalization, or
unrelated OS settings. The existing Rust workload includes a VS IDE; Tauri
instead reuses the existing AI C++ **Build Tools** helper. The existing .NET
workload enables Developer Mode; this preview does not rewrite reused workflows.

## Python coexistence and projects

The [Python Windows guide](https://docs.python.org/3/using/windows.html)
recommends Python install manager and per-project virtual environments.
The manager's unambiguous `pymanager` command avoids the old launcher's `py`
name collision. We never uninstall an old launcher/runtime, rewrite Python
PATH entries, migrate packages, remove virtual environments or force a
runtime upgrade. `pymanager list` includes existing external installations.
If the selected interpreter lacks pip/venv, setup fails with the underlying
error rather than silently replacing it.

```powershell
pymanager list
pymanager exec -m venv .venv
.\.venv\Scripts\Activate.ps1
python -m pip --version
```

Review App execution aliases and PATH manually if `python`/`py` resolves an
older install or a Store shortcut. For a particular runtime, explicitly use
the manager's `install <tag>` and `exec -V:<tag>` options. The full workstation
catalog now installs the manager as well and preserves it and existing Python
installations during cleanup; its explicitly bundled uv remains independent.
The standalone Python flow does not bundle uv or an editor.

## Required manual boundaries

**React Native Android:** the first run installs the prerequisite applications,
then fails clearly until Android Studio's setup wizard and SDK Manager have
installed Platform-Tools, **Android SDK Platform 35**, **Build-Tools 36.0.0**
and **Command-line Tools (latest)**. Review Google's SDK terms yourself; this
script never pipes `yes` to license acceptance. Run
`<SDK>\cmdline-tools\latest\bin\sdkmanager.bat --licenses`, then rerun the
workload. It sets user `ANDROID_HOME` and appends platform-tools to user PATH
only after these checks pass. `JAVA_HOME` selects JDK17 in the current session
only; configure your future project/terminal explicitly if another JDK is the
global default. Use a physical device or create an API35 x86_64 AVD yourself;
emulation/hypervisor setup is not installed. Use the project-local CLI from
the [official guide](https://reactnative.dev/docs/set-up-your-environment).
Expo/framework users who do not build native code locally may not need this
heavy workload at all. WinGet is used instead of the guide's Chocolatey
example to avoid adding a second system package manager.

**Flutter:** the official Windows guide requires **Visual Studio**, not VS
Code. Check your eligibility for Community's license before installing; an
organization requiring a different edition should configure its approved
Visual Studio manually instead of this Community preview. The SDK is cloned
from Flutter's official `stable` branch to a writable path without spaces
(default `%USERPROFILE%\develop\flutter`), then Flutter downloads its matching
Dart/engine assets from Google. This is the official source-distribution path,
not a rehosted ZIP or a claimed signed bundle. Existing SDKs are reused, not
upgraded or reset. `flutter doctor -v` and `flutter devices` still need a clean
Windows/Visual Studio result; unrelated Android/web warnings do not imply
those targets were configured. Follow [Windows setup](https://docs.flutter.dev/platform-integration/windows/setup)
and [manual SDK installation](https://docs.flutter.dev/install/manual).

**Tauri:** Node is [optional for a JS frontend](https://v2.tauri.app/start/prerequisites/).
Rust's MSVC toolchain is selected for the current session, not made the user's
global default. MSI packaging can additionally require the optional VBScript
feature; this workload does not enable it. Neither Tauri's CLI nor a project is
globally installed.

**Electron:** [upstream](https://www.electronjs.org/docs/latest/tutorial/tutorial-prerequisites)
recommends the Node LTS installer. Create an Electron/Forge project using that
tutorial after this prerequisite step. Native modules may require additional
tools appropriate to the particular module; they are not blanket-installed.

**Temurin:** [upstream's MSI support is x64-only](https://adoptium.net/installation/windows/).
The shim verifies Temurin 25 and sets session-only `JAVA_HOME`; no other JDK is
removed. MSI's own default PATH/JAR integration may change command resolution.
React Native intentionally uses JDK17 instead of this JDK25 workload.

## Compatibility, consent and validation

The new Node, editor, uv, Python and Tauri paths target x64/ARM64 Windows where
their packages and WinGet Configuration are supported. Flutter, Temurin MSI
and React Native Android Studio previews explicitly reject non-x64 hosts
before installation; they do not silently use emulation. This is a conservative
preview boundary, not a claim that every framework lacks ARM support. Existing
Rust/.NET/Go/PHP/PyTorch architecture and runtime support is unchanged.

WinGet resources carry `acceptAgreements: true`: **running a workload means
accepting the listed packages' terms**. Review those terms first. Visual Studio
Community/Build Tools, WebView2, VS Code and Android Studio have vendor-specific
terms; Python is PSF-licensed, Node MIT, Rust/uv MIT or Apache-2.0, Flutter
BSD-3-Clause and the JDKs GPL with Classpath Exception. Android SDK terms require
the separate explicit step above. Per-major JDK IDs are deliberate; manager,
LTS, Rustup, editor, Git and uv package IDs are publisher-maintained rolling
channels rather than invented minor-version IDs.

These configurations use DSC's supported raw `schemas/v3/bundled` document
schema. The older `schemas/2023/08` URL in existing repository examples is
rejected by the installed DSC validator; unrelated configurations are unchanged.

Non-provisioning checks:

```powershell
.\src\tests\onboarding\unit.ps1
```

These mock native commands and exercise Python coexistence/failure, Node LTS
checks, Android incompleteness, architecture rejection and local-engine
dispatch. Manifest probes for Electron/Flutter/React Native check prerequisite
readiness only; Tauri reuses the Rust MSVC build probe. They are **not** complete
framework app builds or GUI/device tests. Existing CI is manual-dispatch only.
No real provisioning was performed on the shared desktop. Disposable-VM
installation, rerun, framework app build and Android device/emulator acceptance
remain required before promoting this preview to production guidance.
