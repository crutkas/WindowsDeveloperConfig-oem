@echo off
rem Windows Dev Config offline setup -- machine part.
rem Windows runs %WINDIR%\Setup\Scripts\SetupComplete.cmd as SYSTEM after setup, before the first sign-in.
rem If the image already has a SetupComplete.cmd, add the lines below to it instead of replacing it.
rem Windows skips SetupComplete.cmd when an OEM product key is used (except Enterprise); see README.md.

if exist "%SystemDrive%\setup\devsetup\machine-setup.ps1" (
    "%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -NonInteractive -ExecutionPolicy RemoteSigned -File "%SystemDrive%\setup\devsetup\machine-setup.ps1" -PerUserApps > "%SystemRoot%\Temp\devsetup-machine-setup.txt" 2>&1
)
