# Agent Documentation

Use this directory as the agent knowledge base for the repository. The canonical entry point for tools that scan the repository root is `AGENTS.md`; detailed notes live here.

## Repository purpose

`windows-iso-builder` automates Windows ISO creation and optional Tiny11 optimization. The main path is:

1. Query UUP dump for the requested Windows build.
2. Download UUP packages and convert them into a Windows ISO.
3. Optionally run a headless Tiny11 pass to debloat the image, apply registry tweaks, bypass Windows setup requirements, and embed `autounattend.xml`.
4. Upload the final ISO, checksum, and verification instructions as a GitHub Actions artifact.

## Documentation index

- `repository-map.md` explains what each tracked file owns.
- `workflow.md` documents the GitHub Actions pipeline, inputs, stages, and outputs.
- `local-runbook.md` gives local commands and validation guidance.

## Agent operating rules

- Keep generated build outputs out of git. This includes ISO/WIM/ESD/VHD images, `Tiny11*/`, `tiny11/`, `scratchdir/`, logs, checksums, and temporary files.
- Be cautious with destructive cleanup. The workflow intentionally deletes runner directories to free disk space; do not copy that behavior into local scripts without explicit user approval.
- Do not run a full build just to validate a small documentation or mapping change.
- Prefer small PowerShell syntax checks, YAML review, and targeted script inspection before a full GitHub Actions run.
- Preserve Windows-first assumptions. The production pipeline runs on Windows runners and depends on Windows tooling such as DISM, mounted disk images, and `oscdimg.exe`.
- When changing workflow inputs, update all affected places: `workflow_dispatch` options, the mapping step, README references, and these agent docs.
- When changing Tiny11 behavior, check both `scripts/tiny11maker-headless.ps1` and `autounattend.xml`; they both remove or disable Windows components.
