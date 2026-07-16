#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later

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
BUNDLED_PACKAGE_GROUPS=(
    "libapr1 libapr1t64"
    "libaprutil1 libaprutil1t64"
    "libasound2 libasound2t64"
    "libasound2:i386 libasound2t64:i386"
    "libglib2.0-0 libglib2.0-0t64"
    "libglu1-mesa"
    "libxcb-composite0"
    "libxcb-cursor0"
    "libxcb-damage0"
    "libxcb-xinerama0"
    "ocl-icd-libopencl1"
    "libopengl0 libopengl0t64"
)
CONFLICTING_LIB_PATTERNS=(
    "libglib-2.0.so"
    "libgobject-2.0.so"
    "libgmodule-2.0.so"
    "libgthread-2.0.so"
    "libgio-2.0.so"
    "libk5crypto.so.3"
    "libkrb5.so.3"
    "libgssapi_krb5.so.2"
)
RESOLVED_PACKAGES=()
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

# --- Presentation / Theme ---
# TRAIL:theme
# Colours, glyphs and box characters are populated by init_theme(). They start
# empty so that output stays clean when stdout is not a terminal, NO_COLOR is
# set, or the locale cannot render Unicode. Everything below reads these
# variables instead of hard-coding escape sequences.
C_RESET='' C_BOLD='' C_DIM=''
C_RED='' C_GREEN='' C_YELLOW='' C_BLUE='' C_MAGENTA='' C_CYAN='' C_GREY=''
SPINNER_FRAMES='|/-\'
GLYPH_OK='[ok]' GLYPH_FAIL='[x]' GLYPH_INFO='*' GLYPH_WARN='!' GLYPH_STEP='>' GLYPH_ASK='?'
BAR_FILL='#' BAR_EMPTY='-'
BOX_TL='+' BOX_TR='+' BOX_BL='+' BOX_BR='+' BOX_H='-' BOX_V='|'
UI_UTF8=false

init_theme() {
    local want_color=true
    if [ -n "${NO_COLOR:-}" ]; then want_color=false; fi
    if [ ! -t 1 ]; then want_color=false; fi
    case "${TERM:-}" in dumb|'') want_color=false ;; esac

    if [ "$want_color" = true ]; then
        C_RESET=$'\e[0m' C_BOLD=$'\e[1m' C_DIM=$'\e[2m'
        C_RED=$'\e[31m' C_GREEN=$'\e[32m' C_YELLOW=$'\e[33m'
        C_BLUE=$'\e[34m' C_MAGENTA=$'\e[35m' C_CYAN=$'\e[36m' C_GREY=$'\e[90m'
    fi

    # Prettier Unicode glyphs, spinner and box only when the locale is UTF-8.
    case "${LC_ALL:-${LC_CTYPE:-${LANG:-}}}" in
        *[Uu][Tt][Ff]*)
            UI_UTF8=true
            SPINNER_FRAMES='⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏'
            GLYPH_OK='✔' GLYPH_FAIL='✖' GLYPH_INFO='•' GLYPH_WARN='▲' GLYPH_STEP='▶' GLYPH_ASK='◆'
            BAR_FILL='█' BAR_EMPTY='░'
            BOX_TL='╭' BOX_TR='╮' BOX_BL='╰' BOX_BR='╯' BOX_H='─' BOX_V='│'
            ;;
    esac
}

# _repeat CHAR COUNT -> prints CHAR repeated COUNT times (no trailing newline).
_repeat() {
    local ch="$1" n="$2" out=''
    if [ "$n" -le 0 ]; then return 0; fi
    printf -v out '%*s' "$n" ''
    printf '%s' "${out// /$ch}"
}

# _banner_line PLAIN COLOR -> prints PLAIN centred inside a 61-wide box row.
# Centring is computed from the plain text so colour codes never skew it.
_banner_line() {
    local plain="$1" color="${2:-}" width=61
    local len=${#plain} pad left right ls rs
    pad=$(( width - len ))
    if [ "$pad" -lt 0 ]; then pad=0; fi
    left=$(( pad / 2 ))
    right=$(( pad - left ))
    printf -v ls '%*s' "$left" ''
    printf -v rs '%*s' "$right" ''
    printf '%s\n' "${C_GREY}${BOX_V}${C_RESET}${ls}${color}${plain}${C_RESET}${rs}${C_GREY}${BOX_V}${C_RESET}"
}

# print_banner -> the big title + description shown when the tool starts.
print_banner() {
    local width=61 rule
    rule=$(_repeat "$BOX_H" "$width")

    printf '\n'
    printf '%s\n' "${C_GREY}${BOX_TL}${rule}${BOX_TR}${C_RESET}"
    _banner_line '' ''
    if [ "$UI_UTF8" = true ]; then
        local art=(
            '██████╗ ███████╗███████╗ ██████╗ ██╗    ██╗   ██╗███████╗'
            '██╔══██╗██╔════╝██╔════╝██╔═══██╗██║    ██║   ██║██╔════╝'
            '██████╔╝█████╗  ███████╗██║   ██║██║    ██║   ██║█████╗  '
            '██╔══██╗██╔══╝  ╚════██║██║   ██║██║    ╚██╗ ██╔╝██╔══╝  '
            '██║  ██║███████╗███████║╚██████╔╝███████╗╚████╔╝ ███████╗'
            '╚═╝  ╚═╝╚══════╝╚══════╝ ╚═════╝ ╚══════╝ ╚═══╝  ╚══════╝'
        )
        local line
        for line in "${art[@]}"; do
            _banner_line "$line" "${C_BOLD}${C_CYAN}"
        done
    else
        _banner_line 'R  E  S  O  L  V  E' "${C_BOLD}${C_CYAN}"
    fi
    _banner_line '' ''
    _banner_line 'DaVinci Resolve Repackager' "${C_BOLD}"
    _banner_line 'Turn the official .run installer into a clean .deb' "$C_DIM"
    _banner_line 'so Resolve just works on modern Debian & Ubuntu' "$C_DIM"
    _banner_line '' ''
    printf '%s\n' "${C_GREY}${BOX_BL}${rule}${BOX_BR}${C_RESET}"
    printf '\n'
}

# print_done MESSAGE -> a closing flourish framed by a green rule.
print_done() {
    local rule
    rule=$(_repeat "$BOX_H" 61)
    printf '\n  %s%s%s\n' "$C_GREEN" "$rule" "$C_RESET"
    printf '  %s%s %s%s\n' "${C_GREEN}${C_BOLD}" "$GLYPH_OK" "$1" "$C_RESET"
    printf '  %s%s%s\n\n' "$C_GREEN" "$rule" "$C_RESET"
}

# --- Helper Functions ---
# TRAIL:helper_functions
start_spinner() {
    local msg="$1"
    local spin="$SPINNER_FRAMES"
    local n=${#spin}
    local i=0
    printf '%s ' "$msg"
    while :; do
        printf '\r  %s%s%s %s%s%s' "$C_CYAN" "${spin:i++%n:1}" "$C_RESET" "$C_DIM" "$msg" "$C_RESET"
        sleep 0.1
    done
}

stop_spinner() {
    local spinner_pid=$1
    local exit_code=$2
    local msg="${3:-}"
    if [ -n "$spinner_pid" ]; then
        kill "$spinner_pid" >/dev/null 2>&1 || true
        wait "$spinner_pid" >/dev/null 2>&1 || true
    fi
    local clear
    clear=$(tput el 2>/dev/null || true)
    if [ "$exit_code" -eq 0 ]; then
        printf '\r  %s%s%s %s%s\n' "$clear" "$C_GREEN" "$GLYPH_OK" "$C_RESET" "$msg"
    else
        printf '\r  %s%s%s %s%s\n' "$clear" "$C_RED" "$GLYPH_FAIL" "$C_RESET" "$msg"
    fi
}

print_info() {
    printf '  %s%s%s %s\n' "$C_BLUE" "$GLYPH_INFO" "$C_RESET" "$1"
}

print_success() {
    printf '  %s%s%s %s\n' "$C_GREEN" "$GLYPH_OK" "$C_RESET" "$1"
}

print_warning() {
    printf '  %s%s%s %s%s%s\n' "$C_YELLOW" "$GLYPH_WARN" "$C_RESET" "$C_YELLOW" "$1" "$C_RESET"
}

print_error() {
    printf '  %s%s %s%s\n' "${C_RED}${C_BOLD}" "$GLYPH_FAIL" "$1" "$C_RESET" >&2
    exit 1
}

print_step() {
    STEP_COUNTER=$((STEP_COUNTER + 1))
    local label="$1" bar_w=28 filled empty pct fbar ebar
    filled=$(( bar_w * STEP_COUNTER / TOTAL_STEPS ))
    if [ "$filled" -gt "$bar_w" ]; then filled=$bar_w; fi
    empty=$(( bar_w - filled ))
    pct=$(( 100 * STEP_COUNTER / TOTAL_STEPS ))
    fbar=$(_repeat "$BAR_FILL" "$filled")
    ebar=$(_repeat "$BAR_EMPTY" "$empty")
    printf '\n%s%s Step %d of %d%s  %s%s%s\n' \
        "${C_BOLD}${C_MAGENTA}" "$GLYPH_STEP" "$STEP_COUNTER" "$TOTAL_STEPS" "$C_RESET" \
        "${C_BOLD}${C_CYAN}" "$label" "$C_RESET"
    printf '  %s%s%s%s%s %s%d%%%s\n' \
        "$C_CYAN" "$fbar" "$C_GREY" "$ebar" "$C_RESET" "$C_DIM" "$pct" "$C_RESET"
}

# --- Utility & Validation Functions ---
# TRAIL:utility_functions
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
# TRAIL:ensure_bundled_packages
    print_step "Preparing dependency bundle"
    print_info "Ensuring required shared libraries are available for bundling..."
    apt-get update
    mkdir -p "$DOWNLOAD_DIR"
    RESOLVED_PACKAGES=()
    for group in "${BUNDLED_PACKAGE_GROUPS[@]}"; do
        local selected_pkg=""
        for candidate in $group; do
            if apt-cache show "$candidate" >/dev/null 2>&1; then
                selected_pkg="$candidate"
                break
            fi
        done
        if [ -n "$selected_pkg" ]; then
            RESOLVED_PACKAGES+=("$selected_pkg")
        else
            print_info "No apt candidate found for group: $group (will rely on bundled libraries)"
        fi
    done

    if [ ${#RESOLVED_PACKAGES[@]} -eq 0 ]; then
        print_warning "No external dependency packages resolved; relying entirely on installer-bundled libraries."
        return
    fi

    apt-get install -y --download-only --reinstall -o Dir::Cache::archives="$DOWNLOAD_DIR" "${RESOLVED_PACKAGES[@]}"
}

bundle_system_libraries() {
# TRAIL:bundle_system_libraries
    local libs_dir="$1"
    local bundle_tmp
    bundle_tmp=$(mktemp -d -p "$TEMP_DIR" bundle_pkg_XXXX)

    if [ ${#RESOLVED_PACKAGES[@]} -eq 0 ]; then
        print_info "No external packages to bundle; skipping additional system libraries."
        return
    fi

    for pkg in "${RESOLVED_PACKAGES[@]}"; do
        local deb_candidates=("${DOWNLOAD_DIR}"/${pkg}_*.deb)
        if [ ${#deb_candidates[@]} -eq 0 ]; then
            print_warning "No cached .deb found for package '$pkg'; its libraries may be missing from the bundle."
            continue
        fi

        local deb_path
        deb_path=$(printf '%s\n' "${deb_candidates[@]}" | sort -V | tail -n 1)
        print_info "Bundling libraries from $pkg"
        dpkg-deb -x "$deb_path" "$bundle_tmp/$pkg"
        find "$bundle_tmp/$pkg" -type f -name 'lib*.so*' -exec cp -a --update=none {} "$libs_dir/" \;
    done
}

disable_conflicting_libs() {
# TRAIL:disable_conflicting_libs
    local libs_dir="$1"
    for pattern in "${CONFLICTING_LIB_PATTERNS[@]}"; do
        while IFS= read -r -d '' lib_file; do
            local backup="${lib_file}.disabled"
            if [ ! -f "$backup" ]; then
                mv "$lib_file" "$backup"
            fi
        done < <(find "$libs_dir" -maxdepth 1 -type f -name "$pattern" -print0)
    done
}

# --- Main Logic Functions ---
# TRAIL:main_logic
prompt_uninstall_and_repackage() {
    local choice prompt
    printf '\n'
    printf -v prompt '  %s%s%s Uninstall the current DaVinci Resolve and repackage it? %s[y/N]%s ' \
        "${C_BOLD}${C_MAGENTA}" "$GLYPH_ASK" "$C_RESET" "$C_DIM" "$C_RESET"
    read -r -p "$prompt" choice
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
        print_info "Exiting. To create a .deb, first uninstall any existing version of Resolve."
        exit 0
    fi
}

prompt_install_after_repackage() {
# TRAIL:prompt_install
    local choice prompt
    printf '\n'
    printf -v prompt '  %s%s%s Automatically install the new package and its dependencies? %s[y/N]%s ' \
        "${C_BOLD}${C_MAGENTA}" "$GLYPH_ASK" "$C_RESET" "$C_DIM" "$C_RESET"
    read -r -p "$prompt" choice
    if [[ "${choice}" =~ ^[Yy]$ ]]; then
        return 0 # User wants automatic installation
    else
        return 1 # User wants to install manually
    fi
}

create_deb_package() {
# TRAIL:create_deb_package
    print_step "Building package contents"
    print_info "Starting repackaging process..."

    # 1. Extract the .run installer using its own non-root install
    print_info "Extracting installer contents..."
    local extract_dir="$TEMP_DIR/extracted"
    mkdir -p "$extract_dir"
    local xdg_dir="$TEMP_DIR/xdg"
    mkdir -p "$xdg_dir"
    QT_QPA_PLATFORM=offscreen DISPLAY= XDG_RUNTIME_DIR="$xdg_dir" SKIP_PACKAGE_CHECK=1 "$PWD/$RESOLVE_INSTALLER_RUN" --install --noconfirm --nonroot --directory "$extract_dir" >/dev/null &
    local extract_pid=$!
    start_spinner "    Extracting (this can take a few minutes, please wait)" &
    local spinner_pid=$!
    wait "$extract_pid"
    local extract_exit=$?
    stop_spinner "$spinner_pid" "$extract_exit" "Installer extracted"
    if [ "$extract_exit" -ne 0 ]; then
        print_error "Failed to extract the installer archive using built-in installer."
    fi

    if [ ! -d "$extract_dir/bin" ] || [ ! -f "$extract_dir/docs/ReadMe.html" ]; then
        print_error "Extraction succeeded but expected directories were not found."
    fi

    # Determine Resolve version from documentation (fallback to README)
    local resolve_version
    resolve_version=$(grep -oE 'DaVinci Resolve [0-9]+\.[0-9]+(\.[0-9]+)?' "$extract_dir/docs/ReadMe.html" | head -n 1 | awk '{print $3}' )
    if [ -z "$resolve_version" ]; then
        resolve_version=$(grep -oE 'DaVinci Resolve [0-9]+\.[0-9]+(\.[0-9]+)?' "$extract_dir/docs/Welcome.txt" | head -n 1 | awk '{print $3}' )
    fi
    if [ -z "$resolve_version" ]; then
        print_error "Could not determine DaVinci Resolve version from extracted files."
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

    if ! cp -a "$extract_dir"/. "$app_dir"/; then
        print_error "Failed to copy Resolve application files into the package directory."
    fi

    # The critical fix: Move bundled libraries to a location where Resolve can find them
    local libs_dir="${app_dir}/libs"
    mkdir -p "$libs_dir"

    # Copy bundled shared libraries into libs directory
    while IFS= read -r -d '' bundled_lib; do
        cp -a --update=none "$bundled_lib" "$libs_dir/"
    done < <(find "$app_dir" -type f -name 'lib*.so*' ! -path "$libs_dir/*" -print0)

    bundle_system_libraries "$libs_dir"
    disable_conflicting_libs "$libs_dir"

    # Create shim wrapper to ensure Resolve uses bundled libraries without polluting system
    mv "$app_dir/bin/resolve" "$app_dir/bin/resolve.bin"
    cat > "$app_dir/bin/resolve" <<'SHIM'
#!/bin/bash
RESOLVE_ROOT="/opt/resolve"
export LD_LIBRARY_PATH="${RESOLVE_ROOT}/libs:${LD_LIBRARY_PATH}"
exec "${RESOLVE_ROOT}/bin/resolve.bin" "$@"
SHIM
    chmod 0755 "$app_dir/bin/resolve"

    # 4. Create post-installation script
    print_info "Creating DEBIAN/postinst script..."
    cat > "$debian_dir/postinst" << EOF
#!/bin/bash
set -e
echo "Running post-installation script for DaVinci Resolve..."
# Create a symbolic link to the wrapper executable
ln -sf /opt/resolve/bin/resolve /usr/bin/resolve
# Update desktop database for the .desktop file
if [ -f "/opt/resolve/DaVinci_Resolve.desktop" ]; then
    cp /opt/resolve/DaVinci_Resolve.desktop /usr/share/applications/
    update-desktop-database -q
fi
if [ -f "/etc/ld.so.conf.d/resolve.conf" ]; then
    rm -f /etc/ld.so.conf.d/resolve.conf
    ldconfig
fi
echo "Post-installation script finished."
exit 0
EOF
    chmod 0755 "$debian_dir/postinst"

    # 5. Build the .deb package
    print_info "Building the Debian package..."
    fakeroot dpkg-deb --build "$pkg_build_dir" "$DEB_FILE" &
    local build_pid=$!
    start_spinner "    Packaging (dpkg-deb running, may take a while)" &
    local spinner_pid=$!
    wait "$build_pid"
    local build_exit=$?
    stop_spinner "$spinner_pid" "$build_exit" "Debian package built"
    if [ "$build_exit" -ne 0 ]; then
        print_error "Package build failed."
    fi
    print_success "Successfully created package: $DEB_FILE"
}

install_package() {
# TRAIL:install_package
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
# TRAIL:cleanup
    if [ -n "$TEMP_DIR" ] && [ -d "$TEMP_DIR" ]; then
        print_info "Cleaning up temporary files..."
        rm -rf "$TEMP_DIR"
    fi
}

# --- CLI & Main Execution ---
# TRAIL:cli_and_main
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
# TRAIL:parse_args
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
# TRAIL:main
    init_theme
    parse_args "$@"
    print_banner

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
            printf '  %sTo install, run:%s\n' "$C_DIM" "$C_RESET"
            printf '    %ssudo apt install ./%s%s\n' "${C_BOLD}${C_CYAN}" "$DEB_FILE" "$C_RESET"
        fi
    else
        print_warning "Package file was not created; skipping installation instructions."
    fi

    print_done "All done — enjoy DaVinci Resolve!"
}

main "$@"

