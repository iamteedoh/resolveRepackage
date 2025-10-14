#!/bin/bash

# ==============================================================================
# DaVinci Resolve .run to .deb Repackager
#
# This script automates the process of converting the official DaVinci Resolve
# installer (.run) into a Debian package (.deb). This method resolves common
# library incompatibility issues (like the 'libpango' error) by bundling the
# necessary older libraries within the Resolve application directory, preventing
# conflicts with modern system libraries.
#
# Author: Tito Valentín
# Version: 1.0
# License: GNU General Public License v3.0 (see LICENSE)
# ==============================================================================

set -euo pipefail
IFS=$'\n\t'
shopt -s nullglob

# --- Configuration & Globals ---
RESOLVE_INSTALLER_RUN=""
TEMP_DIR=$(mktemp -d -t resolve_temp_XXXXXX)
PACKAGE_NAME="davinci-resolve-studio" # Change if using the free version
REQUIRED_TOOLS=(fakeroot xz tar dpkg-deb)
BUNDLED_PACKAGES=(libapr1 libaprutil1 libasound2 libasound2:i386 libglib2.0-0 libglu1-mesa libxcb-composite0 libxcb-cursor0 libxcb-damage0 libxcb-xinerama0 ocl-icd-libopencl1 libopengl0)
DEB_FILE=""
PKG_VERSION=""
FORCE_REBUILD=false
FORCE_INSTALL=false
CLEAN_CACHE=false
STEP_COUNTER=0
TOTAL_STEPS=4
CACHE_ROOT="${CACHE_ROOT:-$HOME/.cache/resolve-repackage}"
DOWNLOAD_DIR="${CACHE_ROOT}/archives"
trap cleanup EXIT

# --- Helper Functions ---
print_info() {
    printf '\e[34m[INFO]\e[0m %s\n' "$1"
}

print_success() {
    printf '\e[32m[SUCCESS]\e[0m %s\n' "$1"
}

print_warning() {
    printf '\e[33m[WARNING]\e[0m %s\n' "$1"
}

print_error() {
    printf '\e[31m[ERROR]\e[0m %s\n' "$1" >&2
    exit 1
}

print_step() {
    STEP_COUNTER=$((STEP_COUNTER + 1))
    printf '\n\e[36m[STEP %d/%d]\e[0m %s\n' "$STEP_COUNTER" "$TOTAL_STEPS" "$1"
}

# --- Utility & Validation Functions ---
check_root() {
    if [ "${EUID:-$(id -u)}" -ne 0 ]; then
        print_error "This script needs to be run with sudo privileges. Please run as: sudo $0"
    fi
}

check_installer() {
    local matches=(DaVinci_Resolve*_Linux.run)

    if [ ${#matches[@]} -eq 0 ]; then
        print_error "No DaVinci Resolve installer (.run) found in the current directory."
    fi

    if [ ${#matches[@]} -gt 1 ]; then
        print_error "Multiple installer files found. Please keep only one DaVinci Resolve .run file in the directory."
    fi

    RESOLVE_INSTALLER_RUN="${matches[0]}"
    print_info "Found installer: $RESOLVE_INSTALLER_RUN"
}

check_tools() {
    print_step "Checking prerequisites"
    print_info "Verifying required packaging tools are installed..."
    for tool in "${REQUIRED_TOOLS[@]}"; do
        if ! command -v "$tool" >/dev/null 2>&1; then
            print_error "Required tool '$tool' is not installed. Please install it before proceeding."
        fi
    done

    mkdir -p "$CACHE_ROOT"
    if [ "$CLEAN_CACHE" = true ] && [ -d "$CACHE_ROOT" ]; then
        print_info "Clearing cache at $CACHE_ROOT"
        rm -rf "$CACHE_ROOT"
        mkdir -p "$CACHE_ROOT"
    fi
}

ensure_bundled_packages() {
    print_step "Preparing dependency bundle"
    print_info "Ensuring required shared libraries are available for bundling..."
    apt-get update
    mkdir -p "$DOWNLOAD_DIR"
    apt-get install -y --download-only --reinstall -o Dir::Cache::archives="$DOWNLOAD_DIR" "${BUNDLED_PACKAGES[@]}"
}

bundle_system_libraries() {
    local libs_dir="$1"
    local bundle_tmp
    bundle_tmp=$(mktemp -d -p "$TEMP_DIR" bundle_pkg_XXXX)

    for pkg in "${BUNDLED_PACKAGES[@]}"; do
        local deb_candidates=("${DOWNLOAD_DIR}"/${pkg}_*.deb)
        if [ ${#deb_candidates[@]} -eq 0 ]; then
            print_warning "No cached .deb found for package '$pkg'; its libraries may be missing from the bundle."
            continue
        fi

        local deb_path
        deb_path=$(printf '%s\n' "${deb_candidates[@]}" | sort -V | tail -n 1)
        print_info "Bundling libraries from $pkg"
        dpkg-deb -x "$deb_path" "$bundle_tmp/$pkg"
        find "$bundle_tmp/$pkg" -type f -name 'lib*.so*' -exec cp -an {} "$libs_dir/" \;
    done
}

# --- Main Logic Functions ---
prompt_uninstall_and_repackage() {
    local choice
    printf '\n'
    read -r -p $'\e[36m[Q1]\e[0m Would you like me to uninstall DaVinci Resolve and repackage it? (y/n): ' choice
    if [[ "${choice}" =~ ^[Yy]$ ]]; then
        if [ -f "/opt/resolve/bin/uninstall-resolve" ]; then
            print_info "Uninstalling existing DaVinci Resolve installation..."
            /opt/resolve/bin/uninstall-resolve --yes || print_warning "Uninstaller finished, but may have encountered a non-critical error."
            print_success "Uninstallation complete."
        else
            print_warning "No existing installation found to uninstall. Proceeding with repackaging."
        fi
        return 0 # Proceed
    else
        echo "Exiting. If you wish to create a .deb package, please ensure any existing version of Resolve is uninstalled first."
        exit 0
    fi
}

prompt_install_after_repackage() {
    local choice
    printf '\n'
    read -r -p $'\e[36m[Q2]\e[0m Automatically install the new package and its dependencies? (y/n): ' choice
    if [[ "${choice}" =~ ^[Yy]$ ]]; then
        return 0 # User wants automatic installation
    else
        return 1 # User wants to install manually
    fi
}

create_deb_package() {
    print_step "Building package contents"
    print_info "Starting repackaging process..."

    # 1. Extract the .run installer
    print_info "Extracting installer contents..."
    if ! tail -n +5 "$RESOLVE_INSTALLER_RUN" | xz -d -c | tar -x -C "$TEMP_DIR"; then
        print_error "Failed to extract the installer archive."
    fi
    
    local installer_script
    installer_script=$(find "$TEMP_DIR" -maxdepth 2 -type f -name installer.sh | head -n 1)
    if [ -z "$installer_script" ]; then
        print_error "Could not locate installer.sh inside the extracted archive."
    fi

    local resolve_version
    resolve_version=$(grep -E "^RESOLVE_VERSION_H=" "$installer_script" | cut -d'"' -f2)
    if [ -z "${resolve_version}" ]; then
        print_error "Could not determine DaVinci Resolve version from installer.sh"
    fi

    local pkg_version="${resolve_version}-1"
    PKG_VERSION="$pkg_version"
    DEB_FILE="${PACKAGE_NAME}_${PKG_VERSION}_amd64.deb"

    if [ "$FORCE_REBUILD" = false ] && [ -f "$DEB_FILE" ]; then
        local existing_version
        existing_version=$(dpkg-deb -f "$DEB_FILE" Version 2>/dev/null || true)
        if [ "${existing_version}" = "${PKG_VERSION}" ]; then
            print_info "Existing package $DEB_FILE matches version $PKG_VERSION. Skipping rebuild."
            return 0
        fi
    fi

    print_info "Detected Resolve Version: $resolve_version"

    local pkg_build_dir="${TEMP_DIR}/pkg"
    local debian_dir="${pkg_build_dir}/DEBIAN"
    mkdir -p "$debian_dir"

    # 2. Create the DEBIAN/control file
    print_info "Creating DEBIAN/control file..."
    cat > "$debian_dir/control" << EOF
Package: $PACKAGE_NAME
Version: $pkg_version
Architecture: amd64
Maintainer: Yourself <user@localhost>
Description: Blackmagic Design DaVinci Resolve Studio
 Professional video editing, color correction, visual effects and audio post production.
Depends: libc6 (>= 2.31), libstdc++6 (>= 10), libgl1, libx11-6, libxcb1
Recommends: nvidia-driver
EOF

    # 3. Create the file structure and move files
    print_info "Arranging application files..."
    local app_dir="${pkg_build_dir}/opt/resolve"
    mkdir -p "$app_dir"
    local rel_dir
    rel_dir=$(find "$TEMP_DIR" -maxdepth 2 -type d -name rel | head -n 1)
    if [ -z "$rel_dir" ]; then
        print_error "Could not locate the 'rel' directory inside the extracted installer."
    fi

    if ! cp -a "$rel_dir"/. "$app_dir"/; then
        print_error "Failed to copy Resolve application files into the package directory."
    fi

    # The critical fix: Move bundled libraries to a location where Resolve can find them
    local libs_dir="${app_dir}/libs"
    mkdir -p "$libs_dir"

    # Copy bundled shared libraries into libs directory
    while IFS= read -r -d '' bundled_lib; do
        cp -an "$bundled_lib" "$libs_dir/"
    done < <(find "$app_dir" -type f -name 'lib*.so*' ! -path "$libs_dir/*" -print0)

    bundle_system_libraries "$libs_dir"
    
    # 4. Create post-installation script
    print_info "Creating DEBIAN/postinst script..."
    cat > "$debian_dir/postinst" << EOF
#!/bin/bash
set -e
echo "Running post-installation script for DaVinci Resolve..."
# Create a symbolic link to the executable in a standard location
ln -sf /opt/resolve/bin/resolve /usr/bin/resolve
# Update desktop database for the .desktop file
if [ -f "/opt/resolve/DaVinci_Resolve.desktop" ]; then
    cp /opt/resolve/DaVinci_Resolve.desktop /usr/share/applications/
    update-desktop-database -q
fi
# Add libs path to ld config
echo "/opt/resolve/libs" > /etc/ld.so.conf.d/resolve.conf
ldconfig
echo "Post-installation script finished."
exit 0
EOF
    chmod 0755 "$debian_dir/postinst"

    # 5. Build the .deb package
    print_info "Building the Debian package..."
    fakeroot dpkg-deb --build "$pkg_build_dir" "$DEB_FILE"
    print_success "Successfully created package: $DEB_FILE"
}

install_package() {
    print_step "Installing package"
    print_info "Installing DaVinci Resolve package..."

    if [ -z "$DEB_FILE" ] || [ ! -f "$DEB_FILE" ]; then
        print_error "Package file '$DEB_FILE' not found. Did the build step succeed?"
    fi

    apt-get update
    apt-get install -y "./${DEB_FILE}"
    
    print_success "DaVinci Resolve has been successfully installed!"
    print_info "You can now launch it from your application menu."
}

cleanup() {
    if [ -n "$TEMP_DIR" ] && [ -d "$TEMP_DIR" ]; then
        print_info "Cleaning up temporary files..."
        rm -rf "$TEMP_DIR"
    fi
}

# --- CLI & Main Execution ---
show_help() {
    cat <<'EOF'
DaVinci Resolve Repackager

Usage: sudo ./repackageResolve.sh [OPTIONS]

Options:
  -f, --force           Rebuild the package even if an existing .deb is available
  --force-install       Reinstall the generated package even if already installed
  --clean-cache         Clear cached dependency archives before bundling
  -h, --help            Show this help message

Environment variables:
  CACHE_ROOT            Override the cache directory (default: $HOME/.cache/resolve-repackage)
EOF
}

parse_args() {
    while [ $# -gt 0 ]; do
        case "$1" in
            -f|--force)
                FORCE_REBUILD=true
                ;;
            --force-install)
                FORCE_INSTALL=true
                ;;
            --clean-cache)
                CLEAN_CACHE=true
                ;;
            -h|--help)
                show_help
                exit 0
                ;;
            --)
                shift
                break
                ;;
            -* )
                print_error "Unknown option: $1"
                ;;
            * )
                break
                ;;
        esac
        shift
    done
}

main() {
    parse_args "$@"

    check_root
    check_installer
    check_tools
    ensure_bundled_packages

    prompt_uninstall_and_repackage

    create_deb_package || true

    if [ -f "$DEB_FILE" ]; then
        if prompt_install_after_repackage || [ "$FORCE_INSTALL" = true ]; then
            install_package
        else
            print_info "Repackaging complete."
            echo "To install, run the following command:"
            echo "sudo apt install ./$DEB_FILE"
        fi
    else
        print_warning "Package file was not created; skipping installation instructions."
    fi

    print_info "All done."
}

main "$@"

