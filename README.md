# Windows ISO Builder

**Automated pipeline for building and optimizing Windows ISO images via GitHub Actions.**

Combines [UUP dump](https://uupdump.net) ISO assembly with [Tiny11](https://github.com/ntdevlabs/tiny11builder) optimization into a single workflow.

---

## 🔄 Pipeline

```
UUP dump API → Download UUP files → Build ISO → Tiny11 optimization → Upload artifact
                                                  (optional)
```

1. **UUP dump** — fetches Windows update packages and builds a clean ISO
2. **Tiny11** — removes bloatware, applies registry tweaks, bypasses system requirements

---

## 🚀 Quick Start (GitHub Actions)

1. **Fork** this repository
2. Go to **Actions** → **Build Windows**
3. Select parameters and click **Run workflow**
4. Download the ISO from **Artifacts**

---

## ⚙️ Workflow Inputs

### Windows Configuration

| Input | Options | Default |
|-------|---------|---------|
| **Version** | Windows 10 22H2, Windows 11 23H2/24H2/24H2 BETA/25H2/25H2 BETA/26H1, DEV, CANARY | Windows 11 25H2 |
| **Architecture** | x64, arm64 | x64 |
| **Edition** | Pro, Home, Multi | Pro |
| **Language** | 38 languages (ar-sa → zh-tw) | English (United States) |
| **Revision** | Optional build revision number | — |

### Build Options

| Input | Description | Default |
|-------|-------------|---------|
| **ESD** | Use ESD compression | false |
| **NetFx3** | Add .NET Framework 3.5 | false |
| **Tiny11** | Apply Tiny11 optimization | **true** |

---

## 🛠️ Tiny11 Optimization

When enabled, the built ISO is processed through Tiny11 which:

### Removes Bloatware (40+ apps)
- Teams, OneDrive, Edge, Copilot, Recall
- Xbox Game Bar & Gaming Services
- Clipchamp, Paint 3D, 3D Viewer, Mixed Reality Portal
- Weather, News, Maps, Bing Search, Cortana
- Office Hub, Solitaire, Sticky Notes, To Do, and more

### Registry Optimizations
- TPM 2.0 / Secure Boot / CPU / RAM requirement bypass
- All telemetry endpoints disabled
- Sponsored apps and consumer features blocked
- OneDrive backup prompts disabled
- BitLocker encryption disabled
- Chat icon / Widgets / Cortana startup removed

### Post-Install (autounattend.xml)
- OOBE bypass (local account, no Microsoft account required)
- Additional app/capability/feature cleanup on first boot
- Privacy-focused defaults

---

## 💻 Manual Usage

### Build ISO only (UUP dump)

```powershell
pwsh uup-dump-get-windows-iso.ps1 windows-11new c:/output -architecture x64 -edition pro -lang en-us -esd -netfx3
```

### Optimize existing ISO (Tiny11)

```powershell
# Option A: Pass ISO file path (auto-mounts)
.\scripts\tiny11maker-headless.ps1 -ISOPath "C:\path\to\windows.iso" -INDEX 1

# Option B: Pass mounted drive letter
.\scripts\tiny11maker-headless.ps1 -ISO E -INDEX 1

# With custom output path
.\scripts\tiny11maker-headless.ps1 -ISOPath "C:\path\to\windows.iso" -INDEX 1 -OutputPath "C:\output\optimized.iso"
```

---

## 🤖 Agent Documentation

Agent-facing documentation is available in [`AGENTS.md`](AGENTS.md) and [`.agents/`](.agents/):

- [`.agents/README.md`](.agents/README.md) — overview and operating rules
- [`.agents/repository-map.md`](.agents/repository-map.md) — file responsibilities and generated artifacts
- [`.agents/workflow.md`](.agents/workflow.md) — GitHub Actions pipeline notes
- [`.agents/local-runbook.md`](.agents/local-runbook.md) — local commands, validation, and safety notes

---

## 📁 Repository Structure

```
windows-iso-builder/
├── .agents/
│   ├── README.md                   # Agent docs entry point
│   ├── local-runbook.md            # Local validation and safety notes
│   ├── repository-map.md           # File ownership map
│   └── workflow.md                 # GitHub Actions pipeline notes
├── .github/workflows/
│   └── build.yml                    # Unified CI/CD workflow
├── scripts/
│   └── tiny11maker-headless.ps1     # Tiny11 optimizer
├── AGENTS.md                        # Root pointer for IDE/CLI agents
├── uup-dump-get-windows-iso.ps1     # UUP dump ISO builder
├── CustomAppsList.txt               # UUP dump app selection
├── autounattend.xml                 # OOBE bypass & post-install
├── .gitignore
├── README.md
└── LICENSE
```

---

## 💾 Requirements

### For Building (GitHub Actions / Local)

| Requirement | Minimum | Recommended |
|------------|---------|-------------|
| **OS** | Windows 10 | Windows 11 |
| **PowerShell** | 5.1 | 7.0+ |
| **RAM** | 8GB | 16GB+ |
| **Free Disk** | 30GB | 50GB+ |
| **Permissions** | Administrator | Administrator |

### For Running Built ISOs (with Tiny11)

System requirements are **bypassed**:
- Any x64 processor
- 1GB+ RAM (2GB+ recommended)
- 10GB+ storage
- No TPM / Secure Boot required

---

## 🙏 Credits

- **UUP dump**: [uupdump.net](https://uupdump.net) / [source](https://git.uupdump.net/uup-dump)
- **Tiny11 builder**: [ntdevlabs/tiny11builder](https://github.com/ntdevlabs/tiny11builder)
- **Tiny11 headless**: [kelexine](https://github.com/kelexine)

---

## ⚠️ Disclaimer

This tool is provided "as is" without warranty. You **must** have a valid Windows license. Use at your own risk.
