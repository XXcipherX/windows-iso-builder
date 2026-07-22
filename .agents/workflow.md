# GitHub Actions Workflow

Workflow file: `.github/workflows/build.yml`

## Trigger

The workflow is manually triggered with `workflow_dispatch`.

Main inputs:

- `architecture`: `x64` or `arm64`; default `x64`.
- `versions`: Windows target; options are `Windows 11 25H2`, `Windows 11 Beta`, `Windows 11 26H1`, `Windows 11 Experimental`, and `Windows 11 Future Platforms`; default `Windows 11 25H2`.
- `edition`: `Pro` or `Home`; default `Pro`.
- `language`: one of the supported UI language labels; default `English (United States)`.
- `revision`: optional full build number matching the selected target, such as `26300.8553` for Experimental. Fixed branches also accept a numeric suffix; Future Platforms requires a full build number.
- `esd`: request ESD compression; default `false`.
- `netfx3`: include .NET Framework 3.5; default `false`.
- `tiny11`: run Tiny11 optimization; default `true`.
- `test_iso`: after artifact upload, run a quick x64 ISO validation and boot Windows PE in QEMU; skipped when `test_install=true`; default `false`.
- `test_install`: after artifact upload, validate the x64 ISO structure, install Windows in QEMU/KVM, and audit first boot; default `false`.

## Runner selection

The workflow chooses the runner from the architecture:

- `x64` -> `windows-2025-vs2026`
- `arm64` -> `windows-11-arm`

## Stages

1. Checkout the repository.
2. Map user-facing inputs to script values:
   - Language labels become UUP language codes such as `en-us` and `ru-ru`.
   - Version labels become `uup-dump-get-windows-iso.ps1` target names such as `win11-25h2`.
   - Public Insider names map to UUP rings: Beta uses `WIS`, Experimental uses `WIF`, and Future Platforms uses `CANARY`.
   - UUP ESD compression is enabled only when `esd=true` and `tiny11=false`, because Tiny11 recompresses later when requested.
3. Free disk space on the runner.
4. Build the Windows ISO through `uup-dump-get-windows-iso.ps1`.
5. If `tiny11=true`, copy `autounattend.xml` into `scripts/`, run `scripts/tiny11maker-headless.ps1`, replace the original ISO with the `_Tiny11.iso` output, and recalculate SHA256.
6. Generate verification instructions.
7. Upload the ISO and checksum artifacts.
8. Write a GitHub step summary with build details, checksum, artifact link, and UUP dump source link.
9. If `test_iso=true` and `test_install=false`, download the artifact in a separate Ubuntu job, verify its boot files and WIM/ESD integrity, then wait up to 20 minutes for a Windows PE startup marker from QEMU.
10. If `test_install=true` for x64, download the artifact in a separate Ubuntu job, free unused runner SDKs, validate the ISO structure and WIM/ESD integrity, install Windows to a sparse QEMU disk without a redundant Windows PE boot, run the guest audit after first logon, upload compact diagnostics, and delete the virtual disk.

## Existing ISO validation

Workflow file: `.github/workflows/test-iso-url.yml`

This separately triggered workflow accepts a direct HTTPS ISO URL, an optional SHA256, and `boot_test`, `install_test`, and `tiny11_audit` checkboxes. Structural validation always runs. The QEMU Windows PE boot check runs only when `boot_test=true` and `install_test=false`; a KVM installation and first-boot audit runs when `install_test=true`. The downloaded ISO is not uploaded again; only diagnostic files are retained as an artifact.

## Important behavior

- The UUP stage writes `ISO_NAME` and `ISO_PATH` into `GITHUB_ENV`.
- UUP search skips standalone `.NET Framework` update entries before checking language, edition, and ring.
- Tiny11 assumes the UUP-generated ISO has a single image index, so the workflow calls it with `INDEX=1`.
- The Tiny11 output is staged through a temporary path before replacing the final ISO path.
- The workflow expects output artifacts under `c:/output`.
- ISO testing supports x64 media only, uses KVM when the runner exposes `/dev/kvm`, and falls back to TCG software emulation otherwise.
- Full installation testing includes structural ISO and WIM/ESD validation. If both test checkboxes are selected, the standalone Windows PE boot test is skipped rather than duplicating the ISO download and boot coverage.
- The full-install QEMU answer file and guest diagnostics use a temporary raw FAT image rather than QEMU's experimental writable VVFAT directory backend. The guest mirrors its JSON result and signals completion over COM1, shuts down cleanly, and the host reads the FAT image only after QEMU exits. The tested ISO is not modified.
- The full installation test requires x64 KVM, image index 1, and at least 25 GiB free in the selected temporary work area. It derives a CI answer-file overlay from the ISO, automates only the ephemeral VM, and never uploads the virtual disk.
- Tiny11 guest assertions cover setup-script completion, selected registry policy values, disabled services and tasks, removed Appx/capability/feature state, and removed Edge/OneDrive paths.

## Change checklist

When modifying workflow inputs or supported targets:

- Update `workflow_dispatch` inputs.
- Update the `Map inputs` step.
- Update documentation in `README.md` and `.agents/`.
- Check `uup-dump-get-windows-iso.ps1` target names and validation sets.

When modifying artifact names or locations:

- Update the upload artifact path list.
- Update checksum and verification instruction generation.
- Update `.gitignore` if new generated file patterns are introduced.
