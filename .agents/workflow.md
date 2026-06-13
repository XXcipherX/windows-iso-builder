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
- `low_latency_profile`: apply and verify the Windows Low Latency Profile feature flag `58989092` User (8) override during Tiny11 optimization; default `true`.

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
5. If `tiny11=true`, copy `autounattend.xml` into `scripts/`, run `scripts/tiny11maker-headless.ps1`, optionally enforce Low Latency Profile with a User (8) override in the offline SYSTEM hive, replace the original ISO with the `_Tiny11.iso` output, and recalculate SHA256.
6. Generate verification instructions.
7. Upload the ISO and checksum artifacts.
8. Write a GitHub step summary with build details, checksum, artifact link, and UUP dump source link.

## Important behavior

- The UUP stage writes `ISO_NAME` and `ISO_PATH` into `GITHUB_ENV`.
- UUP search skips standalone `.NET Framework` update entries before checking language, edition, and ring.
- Tiny11 assumes the UUP-generated ISO has a single image index, so the workflow calls it with `INDEX=1`.
- The Tiny11 output is staged through a temporary path before replacing the final ISO path.
- The workflow expects output artifacts under `c:/output`.

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
