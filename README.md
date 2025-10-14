# resolveRepackage

## Table of Contents
- [Overview](#overview)
- [Key Features](#key-features)
- [Prerequisites](#prerequisites)
- [Getting Started](#getting-started)
- [Usage](#usage)
  - [Run Modes and Flags](#run-modes-and-flags)
  - [What the Script Does](#what-the-script-does)
- [Workflow Diagram](#workflow-diagram)
- [Generated Files](#generated-files)
- [Troubleshooting](#troubleshooting)
- [Frequently Asked Questions](#frequently-asked-questions)
- [Contributing](#contributing)
- [License](#license)

## Overview
`repackageResolve.sh` converts the official DaVinci Resolve GNU/Linux `.run` installer into a Debian-compatible `.deb` package. The script vendors Resolve’s required legacy libraries inside the package so you can install the editor on modern Debian/Ubuntu systems without downgrading core system libraries.

## Key Features
- **Idempotent builds:** Skips rebuilding when a matching `.deb` already exists (override with `--force`).
- **Dependency bundling:** Downloads Resolve’s shared-library dependencies and packages them into `opt/resolve/libs` to avoid touching host libraries.
- **Interactive safeguards:** Warns about existing Resolve installations, offers to uninstall, and prompts before installing the freshly built `.deb`.
- **Verbose progress:** Color-coded logging with numbered steps so you can follow along.
- **Cache-aware:** Reuses downloaded dependency `.deb` files between runs (with an option to clear the cache).

## Prerequisites
- **Operating system:** Debian, Ubuntu, Pop!_OS, or derivative with `apt`.
- **Required packages:** `xar`, `fakeroot`, `xz-utils`, `tar`, `dpkg-deb`. Install them via `sudo apt install xar fakeroot xz-utils tar dpkg-deb`.
- **Privileges:** Run the script with `sudo` (it configures `/opt`, `/usr`, and `apt`).
- **Installer:** Place the official DaVinci Resolve `.run` file (e.g., `DaVinci_Resolve_18.6.2_Linux.run`) in the same directory as the script.

## Getting Started
```bash
# clone or copy this repository
git clone https://github.com/<you>/resolveRepackage.git
cd resolveRepackage

# place the .run installer beside the script
cp ~/Downloads/DaVinci_Resolve_*_Linux.run .

# ensure the script is executable
chmod +x repackageResolve.sh
```

## Usage
```bash
sudo ./repackageResolve.sh [OPTIONS]
```

### Run Modes and Flags
| Flag | Description |
|------|-------------|
| `-f`, `--force` | Rebuild the `.deb` even if a matching version already exists. |
| `--force-install` | Install the generated `.deb` even if Resolve seems already installed. |
| `--clean-cache` | Clear cached dependency archives before bundling. |
| `-h`, `--help` | Show usage information and exit. |

The script stores dependency downloads in `${CACHE_ROOT:-$HOME/.cache/resolve-repackage}` so subsequent runs are faster. Use `--clean-cache` if the cache becomes stale or corrupted.

### What the Script Does
1. **Checks environment:** Confirms root privileges, finds the `.run` installer, verifies tooling, and prepares the cache directory.
2. **Prep dependencies:** Downloads required shared libraries as `.deb` archives (download-only) for bundling.
3. **User prompts:** Offers to uninstall any prior Resolve installation and asks whether to auto-install the new `.deb` when finished.
4. **Builds the package:**
   - Extracts the `.run` installer to a temp directory.
   - Detects the Resolve version and creates a Debian staging tree.
   - Copies Resolve binaries into `opt/resolve` and gathers bundled libs into `opt/resolve/libs` (including the downloaded dependency libraries).
   - Generates the Debian control metadata and `postinst` script.
   - Builds the `.deb` with `fakeroot dpkg-deb` and emits `davinci-resolve-studio_<version>_amd64.deb`.
5. **Optional install:** If you consent (or pass `--force-install`), installs the package via `apt`.
6. **Cleanup:** Temporary work directories are removed automatically via a trap handler.

## Workflow Diagram
```mermaid
flowchart TD
    A[Start Script] --> B[Parse CLI Flags]
    B --> C[Check Root Privileges]
    C --> D[Locate .run Installer]
    D --> E[Verify Required Tools]
    E --> F[Prepare Cache & Downloads]
    F --> G[Prompt: Uninstall existing Resolve?]
    G --> H[Prompt: Auto-install new package?]
    H --> I[Extract .run Archive]
    I --> J[Detect Resolve Version]
    J --> K[Prepare Debian Tree]
    K --> L[Copy Resolve Files into opt/resolve]
    L --> M[Collect Bundled Libraries]
    M --> N[Bundle Dependency Libraries]
    N --> O[Write Debian Metadata & postinst]
    O --> P[Build .deb with fakeroot dpkg-deb]
    P --> Q{Auto-install?}
    Q -- Yes --> R[apt install ./<deb>]
    Q -- No --> S[Print Manual Install Instructions]
    R --> T[Cleanup & Finish]
    S --> T[Cleanup & Finish]
```

## Generated Files
- `davinci-resolve-studio_<version>_amd64.deb` — the Debian package you can install or distribute.
- `opt/resolve` inside the `.deb` contains Resolve binaries plus bundled libraries under `opt/resolve/libs`.
- Cache directory `${CACHE_ROOT:-$HOME/.cache/resolve-repackage}` stores downloaded dependency `.deb` archives for reuse.

## Troubleshooting
| Issue | Possible Cause | Suggested Fix |
|-------|----------------|---------------|
| `No DaVinci Resolve installer (.run) found` | Installer not present in script directory. | Place the `.run` file alongside `repackageResolve.sh` and re-run. |
| `Required tool '<tool>' is not installed` | Missing prerequisite packages. | Install via `sudo apt install xar fakeroot xz-utils tar dpkg-deb`. |
| Extraction failure (`Failed to extract the installer archive`) | Corrupted `.run` download or insufficient disk space. | Re-download the installer; ensure adequate disk space. |
| Bundled library warnings | Dependency `.deb` files missing in cache. | Check network connectivity; rerun with `--clean-cache` to refresh. |
| `Package file '<deb>' not found` | Build skipped because existing package matched; or build failed earlier. | Run with `--force` to rebuild; inspect prior log output for errors. |
| Installation fails with dependency complaints | Host machine lacks required base packages (`libgl1`, `libx11-6`, etc.). | Install missing packages via `sudo apt install <package>`. |

## Frequently Asked Questions
**Q: Can I run the script without `sudo`?**  
No. The script modifies `/opt`, `/usr`, and manages apt operations, so elevated privileges are required.

**Q: Does the script support the free (non-Studio) Resolve edition?**  
Yes—adjust `PACKAGE_NAME` inside the script if you are targeting the free edition.

**Q: Where are the temporary working files created?**  
Under a randomly named directory in `/tmp` (via `mktemp`). They are removed automatically unless the script crashes midway.

**Q: How do I remove the cached dependency downloads?**  
Run with the `--clean-cache` flag or manually delete `${CACHE_ROOT:-$HOME/.cache/resolve-repackage}`.

## Contributing
1. Fork the repo and create a feature branch.
2. Make your changes.
3. Run the script end-to-end to ensure the workflow still succeeds.
4. Submit a pull request describing your updates.

Bug reports and enhancement ideas are welcome via GitHub issues.

## License
This project is licensed under the GNU General Public License v3.0. See [`LICENSE`](LICENSE) for the full text.
