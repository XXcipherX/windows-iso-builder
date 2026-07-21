# Repository Map

## Top-level files

- `README.md` - human-facing project overview and usage examples.
- `.gitignore` - excludes large generated images, build directories, logs, checksums, and editor/OS noise.
- `LICENSE` - project license.
- `uup-dump-get-windows-iso.ps1` - UUP dump ISO builder. It queries the UUP dump API, selects a build, downloads the generated UUP package script, patches conversion options, runs the generated `uup_download_windows.cmd`, writes metadata/checksum files, and exports `ISO_NAME` and `ISO_PATH` for GitHub Actions.
- `CustomAppsList.txt` - app allowlist for UUP conversion when `CustomList=1` is set in the generated `ConvertConfig.ini`.
- `autounattend.xml` - unattended Windows setup configuration and embedded PowerShell cleanup scripts. It handles OOBE/privacy defaults and post-install removal of selected packages, capabilities, features, and scheduled update prompts.

## GitHub Actions

- `.github/workflows/build.yml` - manual workflow for building Windows ISOs. It maps workflow inputs to script parameters, frees runner disk space, builds the UUP ISO, optionally runs Tiny11, recalculates checksums, uploads artifacts, and can start an x64 ISO validation job.
- `.github/workflows/test-iso-url.yml` - manual workflow for downloading an existing x64 ISO from a direct HTTPS URL and running the same structural and optional QEMU boot checks without rebuilding it.

## Scripts

- `scripts/tiny11maker-headless.ps1` - CI-friendly Tiny11 optimization script. It accepts either a mounted ISO drive letter or an ISO path, processes a selected Windows image index, removes provisioned apps and selected system components, applies registry tweaks, optionally exports `install.esd`, builds a bootable ISO, and cleans up temporary files.
- `scripts/test-windows-iso.ps1` - Ubuntu CI-only x64 ISO validator. It checks boot files, verifies WIM/ESD metadata and integrity, and optionally boots Windows PE under UEFI QEMU using KVM when available and TCG otherwise, with a temporary startup-marker answer file.

## Generated artifacts

Common generated artifacts are intentionally ignored:

- `output*/`
- `Tiny11*/`
- `tiny11/`
- `scratchdir/`
- `test-input/`, `validation-results/`
- `*.iso`, `*.wim`, `*.esd`, `*.vhd`, `*.vhdx`, `*.swm`
- `*.log`, `*.tmp`
- `*.sha256`, `*.md5`

Agents should not add these files unless the user explicitly asks to manage generated outputs.
