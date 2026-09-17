# Agent Documentation

Use this directory as the agent knowledge base for the repository. The canonical entry point for tools that scan the repository root is `AGENTS.md`; detailed notes live here.

## Repository purpose

`windows-iso-builder` automates Windows ISO creation and optional Tiny11 optimization. The main path is:

1. Query UUP dump for the requested Windows build.
2. Download UUP packages and convert them into a prepared Windows media directory.
3. Prepare and embed a build-specific `autounattend.xml`, optionally run a headless Tiny11 pass directly against the prepared media, and create one final ISO.
4. Upload the final ISO as a raw GitHub Actions artifact and the checksum files as a small separate artifact; optionally let Yandex Disk import the ISO directly from GitHub.
5. Optionally run a quick x64 ISO validation and verify that it reaches Windows PE under QEMU, using KVM when available and TCG otherwise.
6. Optionally validate the x64 ISO structure, install Windows under KVM, and audit the installed Tiny11 state after first logon; this full mode replaces the separate Windows PE boot test.

## Documentation index

- `repository-map.md` explains what each tracked file owns.
- `workflow.md` documents the GitHub Actions pipeline, inputs, stages, and outputs.
- `ci-runbook.md` gives GitHub Actions operation and validation guidance.

## Agent operating rules

- Keep generated build outputs out of git. This includes ISO/WIM/ESD/VHD images, workflow diagnostics, logs, checksums, and temporary files.
- Keep destructive cleanup scoped to disposable GitHub-hosted runners and explicit temporary directories.
- Do not run a full build just to validate a small documentation or mapping change.
- Prefer static YAML review and targeted script inspection before dispatching a full GitHub Actions run.
- Preserve runner-specific assumptions. The build job runs on managed Windows runners and depends on Windows tooling such as DISM, mounted disk images, and `oscdimg.exe`.
- Do not add standalone build or optimization entry points; the scripts are internal workflow workers.
- When changing workflow inputs, update all affected places: `workflow_dispatch` options, the mapping step, README references, and these agent docs.
- When changing Tiny11 behavior, check both `scripts/tiny11maker-headless.ps1` and `autounattend.xml`; they both remove or disable Windows components.
