# Local Runbook

This project is Windows-first. Full builds are heavy and usually need administrator privileges, network access, and a lot of free disk space.

## Build ISO only

```powershell
pwsh .\uup-dump-get-windows-iso.ps1 `
  win11-25h2 `
  c:\output `
  -architecture x64 `
  -edition pro `
  -lang en-us `
  -esd `
  -netfx3
```

Notes:

- `windowsTargetName` must match one of the target keys in `uup-dump-get-windows-iso.ps1`.
- The script downloads data from UUP dump and generated download scripts.
- It may install `aria2` through Chocolatey in the GitHub Actions path.
- `DISM_PROGRESS_STEP` can adjust normalized DISM progress buckets.
- `DISM_PROGRESS_RAW=1` disables the normalized `[DISM] Progress` output.

## Optimize an existing ISO with Tiny11

Pass an ISO path:

```powershell
pwsh .\scripts\tiny11maker-headless.ps1 `
  -ISOPath "C:\path\to\windows.iso" `
  -INDEX 1
```

Or pass a mounted drive letter:

```powershell
pwsh .\scripts\tiny11maker-headless.ps1 `
  -ISO E `
  -INDEX 1
```

With an explicit output path:

```powershell
pwsh .\scripts\tiny11maker-headless.ps1 `
  -ISOPath "C:\path\to\windows.iso" `
  -INDEX 1 `
  -OutputPath "C:\output\optimized.iso"
```

Add `-ESD` to export `install.esd` instead of `install.wim`.

## Lightweight validation

Use these before considering a full ISO build:

```powershell
pwsh -NoProfile -Command "[scriptblock]::Create((Get-Content -Raw .\uup-dump-get-windows-iso.ps1)) | Out-Null"
```

```powershell
pwsh -NoProfile -Command "[scriptblock]::Create((Get-Content -Raw .\scripts\tiny11maker-headless.ps1)) | Out-Null"
```

There is no dedicated automated test suite in this repository. A full validation is the GitHub Actions workflow, but it is expensive and should be run intentionally.

## Safety notes

- Do not run cleanup commands from `.github/workflows/build.yml` on a developer machine without explicit approval.
- Do not delete mounted images blindly. If a Tiny11 run fails, inspect the script log and mounted image state before cleanup.
- Do not commit generated images, temporary directories, logs, or checksum files.
- If `oscdimg.exe` is unavailable, `tiny11maker-headless.ps1` can download it into `scripts/`; it is treated as a generated artifact and should not be committed.
