# resolveRepackage

[![CI](https://github.com/iamteedoh/resolveRepackage/actions/workflows/ci.yml/badge.svg)](https://github.com/iamteedoh/resolveRepackage/actions/workflows/ci.yml)
![License](https://img.shields.io/badge/license-GPL--3.0-blue)
[![GitHub Sponsors](https://img.shields.io/badge/GitHub%20Sponsors-%E2%9D%A4-ea4aaa?logo=githubsponsors)](https://github.com/sponsors/iamteedoh)
[![Patreon](https://img.shields.io/badge/Patreon-support-f96854?logo=patreon)](https://patreon.com/iamteedoh)
[![Buy Me a Coffee](https://img.shields.io/badge/Buy%20Me%20a%20Coffee-support-ffdd00?logo=buymeacoffee&logoColor=black)](https://buymeacoffee.com/iamteedoh)

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
- [Updating Resolve](#updating-resolve)
- [Frequently Asked Questions](#frequently-asked-questions)
- [Contributing](#contributing)
- [Security](#security)
- [License](#license)

## Overview
`repackageResolve.sh` downloads the latest DaVinci Resolve for GNU/Linux from Blackmagic Design, converts the official `.run` installer into Debian packages and installs them. Resolve's legacy library dependencies are bundled inside the package under `/opt/resolve/libs`, so it runs on current Debian, Ubuntu and Pop!_OS releases without downgrading system libraries and without those old libraries leaking into the rest of the system. When Blackmagic ships a new release, run the script again and it upgrades in place.

<p align="center">
  <img src="assets/resolveRepackage_appThumbnail.png" alt="resolveRepackage repackaging DaVinci Resolve into a .deb" width="820">
</p>

## Key Features
- **Both editions:** Installs DaVinci Resolve Studio or the free DaVinci Resolve. The script asks which one on the first run (or takes `--edition studio|free`) and remembers the choice through the installed package, so updates never ask again.
- **Automatic download:** Looks up the latest stable release on Blackmagic Design's site and downloads it. An up-to-date `.run` already in the directory is reused, and an interrupted download resumes on the next run.
- **One-command upgrades:** `sudo ./repackageResolve.sh --update` compares the installed package with the latest release, exits right away when nothing is newer, and otherwise downloads, builds and upgrades in place without asking anything. `--check` only reports the versions.
- **Installs its own tools:** Missing tools (`xz-utils`, `curl`, `jq`, `unzip`, ...) are installed through `apt`.
- **Fits the `.deb` format:** Resolve is larger than a single Debian package can hold, so files are spread over a main package plus `-data-N` parts that depend on each other and are always installed, upgraded and removed as a set.
- **Dependency bundling:** Downloads Resolve's missing shared-library dependencies (ALSA, GLU, APR, xcb, OpenCL, ...) and places them in `opt/resolve/libs` instead of touching host libraries. Bundled libraries that also exist on the host (GLib, Kerberos) are disabled when the host copy is at least as new, so nothing old can leak into other programs.
- **Official desktop integration:** The package's maintainer scripts run the post-install and uninstall scripts Blackmagic ships inside the installer, so menu entries, MIME types, udev rules and control-panel drivers match an official install for every Resolve release.
- **Self-contained launcher:** Automatically swaps the upstream `resolve` binary for a small wrapper that injects `LD_LIBRARY_PATH=/opt/resolve/libs` only for Resolve itself.
- **No repeated work:** Skips the download when the installer is current and the build when matching `.deb` files already exist (override with `--force`).
- **Safeguards:** Detects a Resolve installed by Blackmagic's own installer, offers to uninstall it, and asks before installing. `--yes` answers every prompt for unattended runs.
- **Cleans up after itself:** Once Resolve is installed, the `.run` installer and the `.deb` files (about 20 GB for Studio) are offered for deletion; `--update` and `--yes` delete them without asking, `--keep-files` keeps them.
- **Clear progress:** Color-coded output with numbered steps.

## Prerequisites
- **Operating system:** Debian, Ubuntu, Pop!_OS, or derivative with `apt`.
- **Required packages:** `xz-utils`, `tar`, and `dpkg` (which provides `dpkg-deb`), plus `curl`, `jq`, and `unzip` for the automatic download. The script installs any that are missing.
- **Privileges:** Run the script with `sudo` to install (it configures `/opt`, `/usr`, and `apt`). `--check`, `--download-only` and `--build-only` work without it.
- **Disk space:** About 45 GB free next to the script while it runs for Studio: the download (~10 GB), the extracted installer (~15 GB) and the packages (~10 GB). The free edition is roughly half that. After the install the script offers to delete the `.run` and `.deb` files, so nothing large remains.
- **Installer:** None needed; the latest stable release is downloaded for you. To use a specific version instead, place its `.run` file (for example `DaVinci_Resolve_Studio_20.2.1_Linux.run`) beside the script and pass `--no-download`.
- **License:** DaVinci Resolve Studio still needs your own activation key or dongle; this tool only fetches and repackages the official installer.
- **Free edition registration:** Blackmagic only hands out the free edition after its registration form (name, email, address) is filled in, exactly as on their website; Studio can be downloaded without it. If you pick the free edition, the script asks for those details once, sends them only to `blackmagicdesign.com`, and keeps them in `${CONFIG_ROOT:-$HOME/.config/resolve-repackage}/registration.json` (mode `600`) so updates run unattended. Delete that file to be asked again.

## Getting Started
```bash
git clone https://github.com/iamteedoh/resolveRepackage.git
cd resolveRepackage
chmod +x repackageResolve.sh
sudo ./repackageResolve.sh
```

That is the whole install. The script asks whether you want Studio or the free edition, downloads the latest release, builds the packages and asks before installing them. Pass `--edition studio` or `--edition free` to skip the question.

If you only want the installer file, for example to keep a copy of a specific release or to build on another machine, `./repackageResolve.sh --download-only` fetches the latest `.run` into the current directory without `sudo` and stops there. `--build-only` goes one step further and produces the `.deb` files without installing them.

## Usage
```bash
sudo ./repackageResolve.sh [OPTIONS]
```

### Run Modes and Flags
| Flag | Description |
|------|-------------|
| `--edition <studio\|free>` | Which DaVinci Resolve to install. Without it the script uses the installed edition, then the edition of a local `.run` file, and otherwise asks. |
| `--update` | Upgrade the installed Resolve to the latest release without asking anything; exits at once when it is already current. |
| `-y`, `--yes` | Answer yes to every prompt (uninstall an old install, install the new packages). |
| `-f`, `--force` | Rebuild the packages even if matching `.deb` files exist, and reinstall even if the installed Resolve is already current. |
| `--force-install` | Install without asking, even if Resolve is already installed. |
| `--check` | Only report the installed and latest versions, then exit. Does not need `sudo`. |
| `--download-only` | Fetch the latest installer into the current directory and exit. Does not need `sudo`. |
| `--build-only` | Download and build the `.deb` files but do not install them. Does not need `sudo`. |
| `--no-download` | Never contact Blackmagic Design; use the `.run` file in the current directory. |
| `--clean-cache` | Clear cached dependency archives before bundling. |
| `--keep-files` | Keep the `.run` installer and the `.deb` files after installing. Without it the script asks whether to delete them; `--update` and `--yes` delete them without asking. |
| `-h`, `--help` | Show usage information and exit. |

The script stores dependency downloads in `CACHE_ROOT` (`/var/cache/resolve-repackage` when run as root, `$HOME/.cache/resolve-repackage` otherwise) so subsequent runs are faster. Use `--clean-cache` if the cache becomes stale or corrupted.

### What the Script Does
1. **Picks the edition:** Studio or free, from `--edition`, the installed package, a local `.run` file, or a prompt.
2. **Checks the environment:** Confirms root privileges (unless a no-install mode is used), installs any missing tools, and prepares the cache directory.
3. **Fetches the installer:** Asks Blackmagic Design for the latest stable release and compares it with the installed package. If Resolve is already current the script stops here. Otherwise, if the newest `.run` in the current directory is older (or there is none), it downloads and unpacks the latest one; if Blackmagic cannot be reached, it falls back to the local `.run`.
4. **Prepares dependencies:** Downloads the shared libraries Resolve needs as `.deb` archives for bundling. Skipped when a finished package set is already present.
5. **Builds the packages:**
   - Extracts the `.run` installer headlessly with the official installer in `--nonroot` mode.
   - Detects the Resolve version from the bundled documentation. If packages for that version already exist, the build is skipped.
   - Adds the downloaded dependency libraries to `opt/resolve/libs`, disables bundled libraries that would clash with a newer host copy, and replaces the upstream `resolve` binary with a wrapper.
   - Spreads the files over as many packages as the `.deb` size limit requires (`davinci-resolve-studio` plus `davinci-resolve-studio-data-N`), each depending on the others at the same version.
   - Writes the maintainer scripts. `postinst` runs Blackmagic's own `post_install.sh` from the installer (desktop entries, MIME types, udev rules, panel drivers, writable directories) and links `/usr/bin/resolve`; `prerm` runs Blackmagic's `uninstall.sh` on removal.
   - Builds each package with `dpkg-deb` (zstd compression when available).
6. **Existing install check:** If Resolve was installed by Blackmagic's installer rather than by this tool, offers to run its uninstaller first. A package installed by this tool is simply upgraded.
7. **Install:** Asks for confirmation (skipped with `--yes`, `--force` or `--force-install`) and installs the whole set via `apt`.
8. **Cleanup:** Offers to delete the installer and package files for the installed edition, including any from older releases (`--keep-files` skips this). The temporary work tree (`resolve_temp_*` next to the script) is always removed, even when the script fails.

## Workflow Diagram
```mermaid
flowchart TD
    A[Start Script] --> B[Parse CLI Flags]
    B --> B1[Pick edition: installed / local .run / prompt]
    B1 --> C[Check Root Privileges & Tools]
    C --> D[Query Blackmagic for latest release]
    D --> D1{Installed Resolve already latest?}
    D1 -- Yes --> Z[Exit: up to date]
    D1 -- No --> D2{Local .run up to date?}
    D2 -- Yes --> E[Prepare Cache & Resolve Dependencies]
    D2 -- No --> D3[Download latest installer]
    D3 --> E
    E --> H[Headless Extraction]
    H --> I[Detect Resolve Version]
    I --> I1{Packages for version exist?}
    I1 -- Yes --> P
    I1 -- No --> K[Bundle External Libraries]
    K --> M[Disable Conflicting GLib/Kerberos Libs]
    M --> N[Create Wrapper + Split into Packages]
    N --> O[Build .deb set with dpkg-deb]
    O --> P{Blackmagic-installed Resolve present?}
    P -- Yes --> P1[Prompt: run official uninstaller]
    P -- No --> Q
    P1 --> Q{Install now?}
    Q -- Yes --> R[apt install ./*.deb]
    Q -- No --> S2[Print Manual Install Instructions]
    R --> T[Cleanup Temporary Files]
    S2 --> T
```

Detailed map (each item links to the implementation):
- Pick edition → [select_edition](./repackageResolve.sh#L345-L405)
- Start Script → [parse_args](./repackageResolve.sh#L1175-L1244) → [main](./repackageResolve.sh#L1266-L1319) → [check_root](./repackageResolve.sh#L287-L291) → [check_tools](./repackageResolve.sh#L623-L650)
- Fetch installer / up-to-date check → [acquire_installer](./repackageResolve.sh#L567-L621) → [fetch_latest_release](./repackageResolve.sh#L436-L451) → [find_installed_version](./repackageResolve.sh#L424-L432) → [download_installer](./repackageResolve.sh#L508-L562) → [ensure_registration](./repackageResolve.sh#L469-L503) (free edition only)
- Prepare dependencies → [ensure_bundled_packages](./repackageResolve.sh#L652-L694)
- Headless extraction & version detection → [create_deb_package](./repackageResolve.sh#L880-L1064)
- Bundle external packages → [bundle_system_libraries](./repackageResolve.sh#L696-L722)
- Disable conflicting GLib/Kerberos libs → [disable_conflicting_libs](./repackageResolve.sh#L734-L758)
- Split files into packages → [pack_tree](./repackageResolve.sh#L822-L848)
- Package metadata → [_write_control](./repackageResolve.sh#L796-L817)
- Existing install check → [handle_existing_install](./repackageResolve.sh#L765-L793)
- Install → [install_package](./repackageResolve.sh#L1066-L1086)
- Version check only (`--check`) → [check_for_updates](./repackageResolve.sh#L1246-L1264)
- Delete installer and packages → [remove_build_artifacts](./repackageResolve.sh#L1091-L1123)
- Cleanup → [cleanup](./repackageResolve.sh#L1125-L1131)

## Generated Files
- `davinci-resolve-studio_<version>_amd64.deb` plus `davinci-resolve-studio-data-<N>_<version>_amd64.deb` (or `davinci-resolve_...` / `davinci-resolve-data-<N>_...` for the free edition): the Debian package set. Install all of them together (`sudo apt install ./davinci-resolve*_<version>_amd64.deb`); they depend on each other at the same version. Deleted after a successful install unless you keep them.
- `DaVinci_Resolve_*_Linux.run`: the downloaded installer. Deleted after a successful install unless you keep them; while it is there, later runs skip the download.
- `/opt/resolve` after installation contains Resolve plus bundled libraries under `/opt/resolve/libs`.
- Cache directory (`/var/cache/resolve-repackage` as root, `$HOME/.cache/resolve-repackage` otherwise) stores downloaded dependency `.deb` archives for reuse, plus any partially downloaded installer.

## Troubleshooting
| Issue | Possible Cause | Suggested Fix |
|-------|----------------|---------------|
| `No DaVinci Resolve installer (.run) found` | `--no-download` was passed (or Blackmagic was unreachable) and no installer is in the current directory. | Drop `--no-download`, or place the `.run` file alongside `repackageResolve.sh` and re-run. |
| `Blackmagic rejected the download request` | For the free edition: the saved registration details were rejected. Otherwise Blackmagic changed or throttled their download service. | Delete `~/.config/resolve-repackage/registration.json` and re-run to enter the details again; or download the installer manually and use `--no-download`. |
| `Download failed` | Network interruption during the multi-GB download. | Re-run; the download resumes where it left off. |
| `Missing required packages` | Tools are missing and the script is running without `sudo`, so it cannot install them. | Install them with the `sudo apt install ...` command shown in the error. |
| Extraction failure (`Failed to extract the installer archive`) | Corrupted `.run` download or insufficient disk space. | Re-download the installer; ensure adequate disk space. |
| Bundled library warnings | Dependency `.deb` files missing in cache. | Check network connectivity; rerun with `--clean-cache` to refresh. |
| `Package file '<deb>' not found` | One of the packages in the set is missing. | Run with `--force` to rebuild the whole set. |
| `dpkg-deb: error: ar member size ... too large` | Seen with versions of this script before 0.3.0: Resolve no longer fits in one `.deb`. | Run `git pull`; the current script splits Resolve into several packages. |
| Menu entry missing after install | Blackmagic's post-install script failed. | Run `sudo /opt/resolve/scripts/post_install.sh` manually after replacing `PRODUCT_INSTALL_LOCATION` with `/opt/resolve`, and check its output. |
| Installation fails with dependency complaints | Host machine lacks required base packages (`libgl1`, `libx11-6`, etc.). | Install missing packages via `sudo apt install <package>`. |
| `No apt candidate found for group: ...` | The host distribution names that library package differently. | Harmless when Resolve ships the library itself; otherwise add the package name to `BUNDLED_PACKAGE_GROUPS` in the script. |
| Resolve or system binaries fail with `undefined symbol` errors referencing GLib/OpenSSL/Kerberos | Older bundled libraries from Resolve were on the dynamic loader path. | The script disables those copies automatically whenever the host copy is at least as new. If you had a previous install, rename any `libglib*`, `libgio*`, `libgobject*`, `libgmodule*`, `libgthread*`, `libkrb5*`, `libk5crypto*`, `libgssapi_krb5*` under `/opt/resolve/libs` to `*.disabled` and reinstall with the latest script. |

## Updating Resolve
Once Resolve has been installed with this script, upgrading to a new release is a single command:

```bash
cd /path/to/resolveRepackage
git pull            # pick up script improvements
sudo ./repackageResolve.sh --update
```

The script knows which edition is installed, asks Blackmagic Design for its latest release and compares it with the installed package:

- **Already current:** it says so and exits without downloading anything.
- **Newer release available:** it downloads the new installer, builds the package set and upgrades in place, with no questions asked. Nothing needs to be uninstalled first: `apt` replaces the old package set with the new one, Blackmagic's post-install script re-registers the desktop integration, and your license activation, LUTs and settings stay where they are.

Running without `--update` does the same but asks before installing.

To only find out whether an update exists (no `sudo` required):

```bash
./repackageResolve.sh --check
```

`--update` never prompts, so it is safe to put in a cron job or an alias. It also deletes the downloaded installer and the package files once the upgrade is in, so each release does not leave 20 GB behind; add `--keep-files` if you want them.

To switch editions, run `sudo ./repackageResolve.sh --edition free` (or `studio`); `apt` replaces the other edition. To remove Resolve entirely: `sudo apt remove 'davinci-resolve*'`.

## Frequently Asked Questions
**Q: Can I run the script without `sudo`?**  
Only in the modes that do not install anything: `--check`, `--download-only` and `--build-only`. Installing modifies `/opt`, `/usr`, and the dpkg database, so it needs elevated privileges.

**Q: Does the script support the free (non-Studio) Resolve edition?**  
Yes. Pick it at the prompt or pass `--edition free`; it is packaged as `davinci-resolve` instead of `davinci-resolve-studio`. Blackmagic requires the registration form for the free edition, so the script asks for those details once.

**Q: Where are the temporary working files created?**  
In a `resolve_temp_*` directory next to the script (the extracted installer is ~15 GB, too large for a tmpfs `/tmp`). It is removed automatically unless the script crashes midway.

**Q: Why several `.deb` files?**  
A `.deb` cannot hold a payload above roughly 9 GB, and Resolve is larger than that. The script splits the files into a main package plus `-data-N` parts that depend on each other, so `apt` always treats them as one unit.

**Q: How do I remove the cached dependency downloads?**  
Run with the `--clean-cache` flag or manually delete the cache directory (`/var/cache/resolve-repackage` as root, `$HOME/.cache/resolve-repackage` otherwise).

## Contributing
1. Fork the repo and create a feature branch.
2. Make your changes.
3. Run the script end-to-end to ensure the workflow still succeeds.
4. Submit a pull request describing your updates.

Bug reports and enhancement ideas are welcome via GitHub issues. See
[CONTRIBUTING.md](CONTRIBUTING.md) for the validation suite (ShellCheck,
`bash -n`, gitleaks) and the full pull request process.

## Security
Please report vulnerabilities privately through GitHub's
[Report a vulnerability](https://github.com/iamteedoh/resolveRepackage/security/advisories/new)
form rather than public issues. See [SECURITY.md](SECURITY.md) for details.

## License
This project is licensed under the GNU General Public License v3.0. See [`LICENSE`](LICENSE) for the full text.
