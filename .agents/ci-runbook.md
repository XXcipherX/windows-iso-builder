# GitHub Actions Runbook

This repository builds and validates Windows media exclusively through GitHub Actions. The supported entry points are the workflow-dispatch forms in the Actions tab.

## Build Windows

Workflow: `.github/workflows/build.yml`

Use `Build Windows` to select the Windows target, architecture, edition, language, optional revision, compression, .NET Framework 3.5, Tiny11 optimization, artifact validation, full installation audit, and optional Yandex Disk import.

The workflow owns the complete lifecycle:

1. Map user-facing inputs to UUP parameters.
2. Prepare media on a managed Windows runner.
3. Optionally optimize the prepared directory with Tiny11.
4. Create and upload one raw ISO artifact plus separate verification files.
5. Optionally fan out to Yandex Disk import, quick ISO validation, or a full KVM installation audit.

Do not invoke the worker scripts as independent product interfaces. Their parameters, environment variables, temporary paths, and cleanup behavior follow the workflow contract.

## Test an existing ISO

Workflow: `.github/workflows/test-iso-url.yml`

Use `Test Windows ISO from URL` with a direct HTTPS URL and optional SHA256. Structural validation always runs. The Windows PE boot test and full installation audit are opt-in workflow inputs; the full audit requires x64 KVM.

## Validation strategy

- Review YAML and PowerShell changes statically first.
- For workflow-input or mapping changes, verify every corresponding mapping and documentation entry.
- Dispatch `Test Windows ISO from URL` when validation can use an existing artifact.
- Dispatch a full build only for changes that affect UUP preparation, image servicing, answer-file generation, or ISO creation.
- Keep full installation auditing intentional because it uses a long-running KVM guest and substantial temporary disk space.

## Safety

- Runner cleanup commands target disposable GitHub-hosted environments and must remain scoped there.
- Generated ISO, WIM, ESD, VHD, logs, checksums, and temporary directories must remain untracked.
- The Tiny11 worker modifies its workflow-provided media directory in place; the finalization step verifies and removes that directory.
- Never weaken the path-boundary checks protecting recursive cleanup.
- Keep secrets in GitHub Actions secrets. Yandex Disk access uses `YANDEX_DISK_TOKEN` with only `cloud_api:disk.app_folder`.
