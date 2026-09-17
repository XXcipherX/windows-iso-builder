# Agent Guide

This repository keeps agent-facing documentation in `.agents/`.

Start here:

- `.agents/README.md` - overview and operating rules
- `.agents/repository-map.md` - file responsibilities and generated artifacts
- `.agents/workflow.md` - GitHub Actions build pipeline
- `.agents/ci-runbook.md` - GitHub Actions operation, validation, and safety notes

Important defaults for automation agents:

- Treat full ISO builds as heavy operations. They require Windows, administrator privileges, network access, and significant free disk space.
- Do not commit generated ISO/image/log artifacts. The expected generated files are already covered by `.gitignore`.
- Prefer focused validation before invoking a full build.
- Treat GitHub Actions workflows as the only supported automation entry points.
