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
- Current target keys are `win11-25h2`, `win11-beta`, `win11-26h1`, `win11-experimental`, and `win11-future-platforms`.
- `-revision` accepts a full build number matching the selected target, such as `26300.8553` for Experimental. Fixed branches also accept a numeric suffix; Future Platforms requires a full build number.
- Deprecated aliases `win11-25h2-beta`, `win11-dev`, and `win11-canary` remain accepted for local compatibility.
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

The repository has an optional ISO validation and Windows PE boot smoke test in GitHub Actions. It is resource-intensive and should be run intentionally.

The optional ISO and QEMU smoke test is implemented by `scripts/test-windows-iso.ps1` for an ephemeral `ubuntu-24.04` GitHub runner. Do not invoke it during ordinary local validation: it mounts the ISO through `sudo`, requires `wimtools`, QEMU, and OVMF, and can consume substantial CPU time.

The full installation test is implemented by `scripts/test-windows-install.ps1` and `scripts/test-installed-windows.ps1`. It requires Linux KVM, at least 25 GiB of temporary free space, and a long-running QEMU VM. It is CI-only: do not invoke it on a developer machine during local validation.

## Safety notes

- Do not run cleanup commands from `.github/workflows/build.yml` on a developer machine without explicit approval.
- Do not delete mounted images blindly. If a Tiny11 run fails, inspect the script log and mounted image state before cleanup.
- Do not commit generated images, temporary directories, logs, or checksum files.
- Do not run the GitHub runner disk cleanup or full installation test on a developer machine.
- If `oscdimg.exe` is unavailable, `tiny11maker-headless.ps1` can download it into `scripts/`; it is treated as a generated artifact and should not be committed.
