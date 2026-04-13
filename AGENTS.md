# Agent Guide

This repository keeps agent-facing documentation in `.agents/`.

Start here:

- `.agents/README.md` - overview and operating rules
- `.agents/repository-map.md` - file responsibilities and generated artifacts
- `.agents/workflow.md` - GitHub Actions build pipeline
- `.agents/local-runbook.md` - local commands, validation, and safety notes

Important defaults for automation agents:

- Treat full ISO builds as heavy operations. They require Windows, administrator privileges, network access, and significant free disk space.
- Do not commit generated ISO/image/log artifacts. The expected generated files are already covered by `.gitignore`.
- Prefer focused validation before invoking a full build.
- Keep changes compatible with both GitHub Actions and local PowerShell usage.
