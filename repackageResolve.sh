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
# Version: 0.3.0
# License: GNU General Public License v3.0 (see LICENSE)
# ==============================================================================

set -euo pipefail
IFS=$'\n\t'
shopt -s nullglob

# --- Configuration & Globals ---
RESOLVE_INSTALLER_RUN=""
TEMP_DIR=""
# Edition: "studio" (paid, needs a license key) or "free". Chosen by
# select_edition() from --edition, the installed package, a local installer or
# a prompt. PACKAGE_NAME is derived from it ("davinci-resolve-studio" or
# "davinci-resolve") and doubles as Blackmagic's product slug.
EDITION=""
PACKAGE_NAME=""
REQUIRED_TOOLS=(xz tar dpkg-deb)
DOWNLOAD_TOOLS=(curl jq unzip) # Only needed when fetching the installer
# Maps each tool to the apt package that provides it.
declare -A TOOL_PACKAGES=(
    [xz]=xz-utils [tar]=tar [dpkg-deb]=dpkg
    [curl]=curl [jq]=jq [unzip]=unzip
)
# Blackmagic Design's public support API. The product slug matches PACKAGE_NAME
# ("davinci-resolve-studio" or "davinci-resolve").
BMD_API="https://www.blackmagicdesign.com/api"
BMD_USER_AGENT="Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0 Safari/537.36"
LATEST_VERSION=""
LATEST_RELEASE_ID=""
LATEST_DOWNLOAD_ID=""
INSTALLED_VERSION=""
UPDATE_MODE=false
# Host libraries Resolve needs that its installer does not ship. Each entry
# lists alternative package names; the first one apt knows about is used.
BUNDLED_PACKAGE_GROUPS=(
    "libapr1t64 libapr1"
    "libaprutil1t64 libaprutil1"
    "libasound2t64 libasound2"
    "libglib2.0-0t64 libglib2.0-0"
    "libglu1-mesa"
    "libxcb-composite0"
    "libxcb-cursor0"
    "libxcb-damage0"
    "libxcb-xinerama0"
    "ocl-icd-libopencl1"
    "libopengl0t64 libopengl0"
)
# Libraries Resolve bundles that also live on the host. The bundled copy is
# disabled when the host's is at least as new, so programs Resolve launches
# never pick up an older copy through LD_LIBRARY_PATH.
CONFLICTING_LIB_SONAMES=(
    "libglib-2.0.so.0"
    "libgobject-2.0.so.0"
    "libgmodule-2.0.so.0"
    "libgthread-2.0.so.0"
    "libgio-2.0.so.0"
    "libk5crypto.so.3"
    "libkrb5.so.3"
    "libgssapi_krb5.so.2"
)
# A .deb cannot hold a payload above ~9.3 GiB (ar member size limit), and
# Resolve is bigger than that, so files are spread over several packages.
# This is the largest uncompressed payload placed in a single package.
MAX_PART_BYTES=$((6 * 1024 * 1024 * 1024))
RESOLVED_PACKAGES=()
DEB_FILES=()
PKG_VERSION=""
FORCE_REBUILD=false
FORCE_INSTALL=false
CLEAN_CACHE=false
NO_DOWNLOAD=false
DOWNLOAD_ONLY=false
BUILD_ONLY=false
CHECK_ONLY=false
ASSUME_YES=false
STEP_COUNTER=0
TOTAL_STEPS=5
# apt downloads run as the _apt user, which cannot read /root, so root uses a
# system-wide cache.
if [ "${EUID:-$(id -u)}" -eq 0 ]; then
    CACHE_ROOT="${CACHE_ROOT:-/var/cache/resolve-repackage}"
else
    CACHE_ROOT="${CACHE_ROOT:-$HOME/.cache/resolve-repackage}"
fi
DOWNLOAD_DIR="${CACHE_ROOT}/archives"
INSTALLER_CACHE_DIR="${CACHE_ROOT}/installers"
# Blackmagic hands out the free edition only after its registration form is
# filled in (Studio has a "Download Only" button). The details are asked for
# once and kept in the invoking user's home so updates run unattended.
INVOKER_HOME="$HOME"
if [ -n "${SUDO_USER:-}" ]; then
    INVOKER_HOME=$(getent passwd "$SUDO_USER" | cut -d: -f6 || true)
    INVOKER_HOME="${INVOKER_HOME:-$HOME}"
fi
CONFIG_ROOT="${CONFIG_ROOT:-$INVOKER_HOME/.config/resolve-repackage}"
REGISTRATION_FILE="${CONFIG_ROOT}/registration.json"
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
    # No animation when output is not a terminal (logs, pipes).
    if [ ! -t 1 ]; then
        printf '  %s\n' "$msg"
        while :; do sleep 1; done
    fi
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

# confirm QUESTION -> asks a yes/no question (default no). --yes answers yes.
confirm() {
    local prompt choice
    if [ "$ASSUME_YES" = true ]; then return 0; fi
    printf '\n'
    printf -v prompt '  %s%s%s %s %s[y/N]%s ' \
        "${C_BOLD}${C_MAGENTA}" "$GLYPH_ASK" "$C_RESET" "$1" "$C_DIM" "$C_RESET"
    read -r -p "$prompt" choice
    [[ "${choice}" =~ ^[Yy]$ ]]
}

# _chown_to_invoker PATH... -> hands files created under sudo back to the user.
_chown_to_invoker() {
    if [ -n "${SUDO_UID:-}" ] && [ -n "${SUDO_GID:-}" ]; then
        chown "${SUDO_UID}:${SUDO_GID}" "$@" 2>/dev/null || true
    fi
}

# _installer_version FILE -> prints the version embedded in an installer name,
# e.g. DaVinci_Resolve_Studio_20.2.1_Linux.run -> 20.2.1 (empty if none).
_installer_version() {
    local name="${1##*/}"
    if [[ "$name" =~ _([0-9]+(\.[0-9]+)+)_Linux\.run$ ]]; then
        printf '%s' "${BASH_REMATCH[1]}"
    fi
}

# _installed_edition -> prints "studio" or "free" when one of the two editions
# is installed through dpkg (nothing otherwise).
_installed_edition() {
    local name
    for name in davinci-resolve-studio davinci-resolve; do
        if [ "$(dpkg-query -W -f='${db:Status-Status}' "$name" 2>/dev/null || true)" = "installed" ]; then
            case "$name" in *-studio) printf 'studio' ;; *) printf 'free' ;; esac
            return 0
        fi
    done
}

# _edition_name [EDITION] -> the product name Blackmagic uses.
_edition_name() {
    case "${1:-$EDITION}" in
        studio) printf 'DaVinci Resolve Studio' ;;
        *) printf 'DaVinci Resolve' ;;
    esac
}

# select_edition -> settles EDITION and PACKAGE_NAME. The installed package
# wins so that updates never ask; then a local installer's name; then --edition
# or a prompt.
select_edition() {
# TRAIL:select_edition
    local installed studio_runs free_runs
    installed=$(_installed_edition)

    if [ "$UPDATE_MODE" = true ]; then
        if [ -z "$installed" ]; then
            print_error "--update needs a DaVinci Resolve installed by this tool. Run without --update to install it."
        fi
        if [ -n "$EDITION" ] && [ "$EDITION" != "$installed" ]; then
            print_error "The installed edition is '$installed'; drop --edition or run without --update to switch editions."
        fi
        EDITION="$installed"
    fi

    if [ -z "$EDITION" ] && [ -n "$installed" ]; then
        EDITION="$installed"
        print_info "Installed edition: $(_edition_name)"
    fi

    if [ -z "$EDITION" ]; then
        studio_runs=(DaVinci_Resolve_Studio_*_Linux.run)
        free_runs=(DaVinci_Resolve_[0-9]*_Linux.run)
        if [ ${#studio_runs[@]} -gt 0 ] && [ ${#free_runs[@]} -eq 0 ]; then
            EDITION=studio
        elif [ ${#free_runs[@]} -gt 0 ] && [ ${#studio_runs[@]} -eq 0 ]; then
            EDITION=free
        fi
        if [ -n "$EDITION" ]; then
            print_info "Edition taken from the local installer: $(_edition_name)"
        fi
    fi

    if [ -z "$EDITION" ]; then
        if [ ! -t 0 ] || [ "$ASSUME_YES" = true ]; then
            print_error "Choose the edition with --edition studio or --edition free."
        fi
        local prompt choice
        printf '\n'
        printf '  %s%s%s Which edition of DaVinci Resolve do you want?\n' "${C_BOLD}${C_MAGENTA}" "$GLYPH_ASK" "$C_RESET"
        printf '    %s1%s  DaVinci Resolve Studio %s(paid; needs a license key or dongle)%s\n' "${C_BOLD}${C_CYAN}" "$C_RESET" "$C_DIM" "$C_RESET"
        printf '    %s2%s  DaVinci Resolve %s(free)%s\n' "${C_BOLD}${C_CYAN}" "$C_RESET" "$C_DIM" "$C_RESET"
        printf -v prompt '  %s%s%s Enter 1 or 2 %s[1]%s ' "${C_BOLD}${C_MAGENTA}" "$GLYPH_ASK" "$C_RESET" "$C_DIM" "$C_RESET"
        while :; do
            read -r -p "$prompt" choice
            case "${choice:-1}" in
                1|[Ss]*) EDITION=studio; break ;;
                2|[Ff]*) EDITION=free; break ;;
            esac
        done
    fi

    case "$EDITION" in
        studio) PACKAGE_NAME="davinci-resolve-studio" ;;
        free) PACKAGE_NAME="davinci-resolve" ;;
    esac
    print_info "Edition: $(_edition_name)"
    if [ -n "$installed" ] && [ "$installed" != "$EDITION" ]; then
        print_warning "$(_edition_name "$installed") is installed; installing $(_edition_name) will replace it."
    fi
}

# find_local_installer -> sets RESOLVE_INSTALLER_RUN to the newest .run for the
# chosen edition in the current directory (empty if there is none).
find_local_installer() {
    local matches
    if [ "$EDITION" = studio ]; then
        matches=(DaVinci_Resolve_Studio_*_Linux.run)
    else
        matches=(DaVinci_Resolve_[0-9]*_Linux.run)
    fi
    RESOLVE_INSTALLER_RUN=""
    if [ ${#matches[@]} -gt 0 ]; then
        RESOLVE_INSTALLER_RUN=$(printf '%s\n' "${matches[@]}" | sort -V | tail -n 1)
    fi
}

# find_installed_version -> sets INSTALLED_VERSION from dpkg (empty if the
# package is not installed).
find_installed_version() {
    local status
    INSTALLED_VERSION=""
    status=$(dpkg-query -W -f='${db:Status-Status} ${Version}' "$PACKAGE_NAME" 2>/dev/null || true)
    if [[ "$status" == installed\ * ]]; then
        INSTALLED_VERSION="${status#installed }"
        INSTALLED_VERSION="${INSTALLED_VERSION%-*}"
    fi
}

# fetch_latest_release -> asks Blackmagic for the latest stable release and sets
# LATEST_VERSION / LATEST_RELEASE_ID / LATEST_DOWNLOAD_ID. Returns 1 on failure.
fetch_latest_release() {
# TRAIL:fetch_latest_release
    local json fields major minor patch
    json=$(curl -fsSL --max-time 30 -A "$BMD_USER_AGENT" \
        "${BMD_API}/support/latest-stable-version/${PACKAGE_NAME}/linux") || return 1
    fields=$(jq -er '.linux | [.major, .minor, .releaseNum, .releaseId, .downloadId] | @tsv' <<<"$json") || return 1
    IFS=$'\t' read -r major minor patch LATEST_RELEASE_ID LATEST_DOWNLOAD_ID <<<"$fields"
    if [ -z "$LATEST_DOWNLOAD_ID" ] || [ "$LATEST_DOWNLOAD_ID" = "null" ]; then
        return 1
    fi
    # Blackmagic drops a zero patch level from installer names (21.1, not 21.1.0).
    LATEST_VERSION="${major}.${minor}"
    if [ "${patch:-0}" != "0" ]; then
        LATEST_VERSION+=".${patch}"
    fi
}

# _ask_field LABEL [DEFAULT] -> prompts until a non-empty answer is given and
# leaves it in REPLY.
_ask_field() {
    local label="$1" default="${2:-}" prompt hint=''
    if [ -n "$default" ]; then hint=" [$default]"; fi
    printf -v prompt '  %s%s%s %s%s%s%s: ' \
        "${C_BOLD}${C_MAGENTA}" "$GLYPH_ASK" "$C_RESET" "$label" "$C_DIM" "$hint" "$C_RESET"
    while :; do
        read -r -p "$prompt" REPLY
        REPLY="${REPLY:-$default}"
        if [ -n "$REPLY" ]; then return 0; fi
    done
}

# ensure_registration -> makes sure REGISTRATION_FILE holds the contact details
# Blackmagic's download form requires for the free edition.
ensure_registration() {
# TRAIL:ensure_registration
    if [ -f "$REGISTRATION_FILE" ] && jq -e '.email and .firstname and .lastname' "$REGISTRATION_FILE" >/dev/null 2>&1; then
        return 0
    fi
    if [ ! -t 0 ]; then
        print_error "Blackmagic requires registration to download the free edition and there is no terminal to ask for it. Run once interactively, or download the installer yourself and pass --no-download."
    fi

    printf '\n'
    print_info "Blackmagic Design requires contact details before downloading the free edition"
    print_info "(the same form as on their website). They are sent only to blackmagicdesign.com"
    print_info "and saved to $REGISTRATION_FILE so future updates do not ask again."
    local firstname lastname email phone country state city street
    _ask_field "First name"; firstname="$REPLY"
    _ask_field "Last name"; lastname="$REPLY"
    _ask_field "Email"; email="$REPLY"
    _ask_field "Phone"; phone="$REPLY"
    _ask_field "Country (2-letter code)" "us"; country="${REPLY,,}"
    _ask_field "State / province"; state="$REPLY"
    _ask_field "City"; city="$REPLY"
    _ask_field "Street address"; street="$REPLY"

    mkdir -p "$CONFIG_ROOT"
    (
        umask 077
        jq -n --arg firstname "$firstname" --arg lastname "$lastname" --arg email "$email" \
            --arg phone "$phone" --arg country "$country" --arg state "$state" \
            --arg city "$city" --arg street "$street" \
            '{firstname: $firstname, lastname: $lastname, email: $email, phone: $phone,
              country: $country, state: $state, city: $city, street: $street}' > "$REGISTRATION_FILE"
    )
    _chown_to_invoker "$CONFIG_ROOT" "$REGISTRATION_FILE"
    print_success "Registration details saved."
}

# download_installer -> downloads the latest release found by
# fetch_latest_release, unpacks its .run into the current directory and sets
# RESOLVE_INSTALLER_RUN.
download_installer() {
# TRAIL:download_installer
    local product request url
    product=$(_edition_name)

    if [ "$EDITION" = studio ]; then
        # Same request the website's "Download Only" button sends: no contact details.
        request=$(jq -nc --arg product "$product" \
            '{platform: "Linux", policy: true, product: $product, country: "us", downloadOnly: true}')
    else
        ensure_registration
        request=$(jq -c --arg product "$product" \
            '. + {product: $product, platform: "Linux", policy: true}' "$REGISTRATION_FILE")
    fi
    print_info "Requesting download link for $product $LATEST_VERSION..."
    url=$(curl -fsSL --max-time 60 -A "$BMD_USER_AGENT" \
        -H 'Accept: application/json, text/plain, */*' \
        -H 'Content-Type: application/json;charset=UTF-8' \
        -H 'Origin: https://www.blackmagicdesign.com' \
        -H "Referer: https://www.blackmagicdesign.com/support/download/${LATEST_RELEASE_ID}/Linux" \
        --data "$request" \
        "${BMD_API}/register/us/download/${LATEST_DOWNLOAD_ID}") \
        || print_error "Blackmagic rejected the download request. Check $REGISTRATION_FILE if this is the free edition, or download the installer manually and re-run with --no-download."
    if [[ ! "$url" =~ ^https:// ]]; then
        print_error "Unexpected response from Blackmagic's download service. Download the installer manually and re-run."
    fi

    mkdir -p "$INSTALLER_CACHE_DIR"
    local zip_path="${INSTALLER_CACHE_DIR}/${PACKAGE_NAME}_${LATEST_VERSION}_linux.zip"

    # The .part file lets an interrupted download resume on the next run.
    print_info "Downloading $product $LATEST_VERSION (several GB)..."
    if ! curl -fL -C - --retry 3 --progress-bar -A "$BMD_USER_AGENT" -o "${zip_path}.part" "$url"; then
        print_error "Download failed. Re-run to resume where it left off."
    fi
    mv "${zip_path}.part" "$zip_path"

    local run_name
    run_name=$(unzip -Z1 "$zip_path" | grep -E '^[^/]*_Linux\.run$' | head -n 1 || true)
    if [ -z "$run_name" ]; then
        rm -f "$zip_path"
        print_error "Downloaded archive does not contain a .run installer."
    fi

    print_info "Unpacking $run_name..."
    if ! unzip -oq "$zip_path" "$run_name" -d "$PWD"; then
        rm -f "$zip_path"
        print_error "Failed to unpack the downloaded archive (it may be corrupt). Re-run to download it again."
    fi
    rm -f "$zip_path"
    chmod +x "$run_name"
    _chown_to_invoker "$run_name"
    RESOLVE_INSTALLER_RUN="$run_name"
    print_success "Downloaded installer: $RESOLVE_INSTALLER_RUN"
}

# acquire_installer -> settles on the .run to repackage: the latest release from
# Blackmagic when it is newer than anything local, otherwise the local file.
# Exits early when the installed Resolve is already the latest release.
acquire_installer() {
# TRAIL:acquire_installer
    print_step "Fetching installer"
    find_local_installer
    find_installed_version

    if [ "$NO_DOWNLOAD" = true ]; then
        if [ -z "$RESOLVE_INSTALLER_RUN" ]; then
            print_error "No DaVinci Resolve installer (.run) found in the current directory."
        fi
        print_info "Found installer: $RESOLVE_INSTALLER_RUN"
        return 0
    fi

    print_info "Checking Blackmagic Design for the latest release..."
    if ! fetch_latest_release; then
        if [ -z "$RESOLVE_INSTALLER_RUN" ]; then
            print_error "Could not reach Blackmagic Design and no local installer (.run) was found."
        fi
        print_warning "Could not check for the latest release; using local installer $RESOLVE_INSTALLER_RUN"
        return 0
    fi
    print_info "Latest stable release: $LATEST_VERSION"

    if [ -n "$INSTALLED_VERSION" ]; then
        if dpkg --compare-versions "$INSTALLED_VERSION" ge "$LATEST_VERSION"; then
            print_success "Installed $(_edition_name) $INSTALLED_VERSION is already the latest release."
            if [ "$FORCE_REBUILD" = false ] && [ "$FORCE_INSTALL" = false ] \
                && [ "$DOWNLOAD_ONLY" = false ] && [ "$BUILD_ONLY" = false ]; then
                print_info "Nothing to do. Pass --force to rebuild and reinstall anyway."
                print_done "DaVinci Resolve is up to date"
                exit 0
            fi
        else
            print_info "Installed version $INSTALLED_VERSION will be upgraded to $LATEST_VERSION."
        fi
    fi

    if [ -n "$RESOLVE_INSTALLER_RUN" ]; then
        local local_version
        local_version=$(_installer_version "$RESOLVE_INSTALLER_RUN")
        if [ -z "$local_version" ] || dpkg --compare-versions "$local_version" ge "$LATEST_VERSION"; then
            print_success "Local installer is up to date: $RESOLVE_INSTALLER_RUN"
            return 0
        fi
        print_info "Local installer $RESOLVE_INSTALLER_RUN is older ($local_version)."
    fi

    local free_kb
    free_kb=$(df -Pk "$PWD" | awk 'NR==2 {print $4}')
    if [ "${free_kb:-0}" -lt $((45 * 1024 * 1024)) ]; then
        print_warning "Less than 45 GB free on $(df -P "$PWD" | awk 'NR==2 {print $6}'); downloading, extracting and packaging Resolve may run out of space."
    fi
    download_installer
}

check_tools() {
    print_step "Checking prerequisites"
    print_info "Verifying required tools are installed..."
    local tools=() missing=() tool
    if [ "$DOWNLOAD_ONLY" = false ]; then tools+=("${REQUIRED_TOOLS[@]}"); fi
    if [ "$NO_DOWNLOAD" = false ]; then tools+=("${DOWNLOAD_TOOLS[@]}"); fi
    for tool in "${tools[@]}"; do
        if ! command -v "$tool" >/dev/null 2>&1; then
            missing+=("${TOOL_PACKAGES[$tool]}")
        fi
    done

    if [ ${#missing[@]} -gt 0 ]; then
        if [ "${EUID:-$(id -u)}" -ne 0 ]; then
            print_error "Missing required packages: ${missing[*]}. Install them with: sudo apt install ${missing[*]}"
        fi
        print_info "Installing missing packages: ${missing[*]}"
        apt-get update -qq
        apt-get install -y "${missing[@]}"
    fi

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
    if _packages_prebuilt; then
        print_info "Existing packages for $PKG_VERSION will be reused; no dependencies to download."
        return 0
    fi
    print_info "Ensuring required shared libraries are available for bundling..."
    if [ "${EUID:-$(id -u)}" -eq 0 ]; then
        apt-get update -qq
    fi
    mkdir -p "$DOWNLOAD_DIR"
    RESOLVED_PACKAGES=()
    local group candidates candidate selected_pkg
    for group in "${BUNDLED_PACKAGE_GROUPS[@]}"; do
        selected_pkg=""
        IFS=' ' read -ra candidates <<<"$group"
        for candidate in "${candidates[@]}"; do
            # A virtual package makes apt-cache succeed with no output.
            if apt-cache show "$candidate" 2>/dev/null | grep -q '^Package:'; then
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

    # apt-get download works without root and never touches the dpkg database.
    # It runs as the _apt user when it can, so let that user write to the cache.
    if [ "${EUID:-$(id -u)}" -eq 0 ] && id _apt >/dev/null 2>&1; then
        chown _apt "$DOWNLOAD_DIR" 2>/dev/null || true
    fi
    (cd "$DOWNLOAD_DIR" && apt-get download "${RESOLVED_PACKAGES[@]}")
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
        local deb_candidates=("${DOWNLOAD_DIR}/${pkg}_"*.deb)
        if [ ${#deb_candidates[@]} -eq 0 ]; then
            print_warning "No cached .deb found for package '$pkg'; its libraries may be missing from the bundle."
            continue
        fi

        local deb_path
        deb_path=$(printf '%s\n' "${deb_candidates[@]}" | sort -V | tail -n 1)
        print_info "Bundling libraries from $pkg"
        dpkg-deb -x "$deb_path" "$bundle_tmp/$pkg"
        # Copy the libraries and their soname symlinks (the loader looks up the
        # symlink names), but never overwrite what Resolve ships itself.
        find "$bundle_tmp/$pkg" \( -type f -o -type l \) -name 'lib*.so*' ! -name '*.gz' -exec cp -a --update=none {} "$libs_dir/" \;
    done
}

# _lib_release FILE -> prints the release suffix of a real library file, e.g.
# libglib-2.0.so.0.8200.4 -> 8200.4 (empty when the name has no suffix).
_lib_release() {
    local real soname="$2"
    real=$(basename "$(readlink -f "$1")")
    if [[ "$real" == "$soname".* ]]; then
        printf '%s' "${real#"$soname".}"
    fi
}

disable_conflicting_libs() {
# TRAIL:disable_conflicting_libs
    local libs_dir="$1"
    local soname bundled host bundled_rel host_rel entry
    for soname in "${CONFLICTING_LIB_SONAMES[@]}"; do
        bundled="$libs_dir/$soname"
        [ -e "$bundled" ] || continue
        host=$(ldconfig -p 2>/dev/null | awk -v n="$soname" '$1 == n && /x86-64/ {print $NF; exit}')
        [ -n "$host" ] && [ -e "$host" ] || continue
        bundled_rel=$(_lib_release "$bundled" "$soname")
        host_rel=$(_lib_release "$host" "$soname")
        # Keep the bundled copy when the host's is older; it may lack symbols
        # Resolve was built against.
        if [ -n "$bundled_rel" ] && [ -n "$host_rel" ] \
            && dpkg --compare-versions "$host_rel" lt "$bundled_rel"; then
            print_info "Keeping bundled $soname ($bundled_rel is newer than host $host_rel)"
            continue
        fi
        print_info "Disabling bundled $soname in favour of the host copy"
        for entry in "$libs_dir/${soname%.so*}.so"*; do
            case "$entry" in *.disabled) continue ;; esac
            mv "$entry" "$entry.disabled"
        done
    done
}

# --- Main Logic Functions ---
# TRAIL:main_logic
# handle_existing_install -> a Resolve installed by Blackmagic's own installer
# (not by dpkg) is offered for removal so its files cannot mix with ours. A
# dpkg-managed install is simply upgraded in place.
handle_existing_install() {
# TRAIL:handle_existing_install
    if [ -n "$INSTALLED_VERSION" ] || [ ! -d /opt/resolve ]; then
        return 0
    fi
    if dpkg-query -W -f='${db:Status-Status}' davinci-resolve 2>/dev/null | grep -q installed \
        || dpkg-query -W -f='${db:Status-Status}' davinci-resolve-studio 2>/dev/null | grep -q installed; then
        return 0
    fi

    print_warning "A DaVinci Resolve installed by Blackmagic's installer was found in /opt/resolve."
    if ! confirm "Uninstall it before installing the repackaged version?"; then
        print_info "Leaving the existing installation alone; the package will overwrite its files."
        return 0
    fi

    print_info "Uninstalling the existing DaVinci Resolve..."
    if [ -x /opt/resolve/installer ]; then
        QT_QPA_PLATFORM=offscreen /opt/resolve/installer --uninstall --noconfirm \
            || print_warning "Uninstaller finished, but may have encountered a non-critical error."
    elif [ -x /opt/resolve/bin/uninstall-resolve ]; then
        /opt/resolve/bin/uninstall-resolve --yes \
            || print_warning "Uninstaller finished, but may have encountered a non-critical error."
    else
        print_warning "No uninstaller found in /opt/resolve; removing the directory."
        rm -rf /opt/resolve
    fi
    print_success "Uninstallation complete."
}

# write_control PKG_DIR NAME DEPENDS EXTRA_DESC -> writes DEBIAN/control.
_write_control() {
    local pkg_dir="$1" name="$2" depends="$3" extra_desc="$4"
    local edition other="davinci-resolve"
    edition=$(_edition_name)
    if [ "$EDITION" = studio ]; then other="davinci-resolve"; else other="davinci-resolve-studio"; fi
    mkdir -p "$pkg_dir/DEBIAN"
    cat > "$pkg_dir/DEBIAN/control" << EOF
Package: $name
Version: $PKG_VERSION
Architecture: amd64
Maintainer: resolveRepackage <user@localhost>
Section: video
Priority: optional
Installed-Size: $(du -sk --apparent-size "$pkg_dir" | cut -f1)
Depends: $depends
Conflicts: $other
Description: Blackmagic Design $edition$extra_desc
 Professional video editing, color correction, visual effects and audio post
 production. Repackaged from the official installer with its bundled libraries
 kept under /opt/resolve.
EOF
}

# pack_tree SRC_ROOT REL_PATH SIZE -> moves REL_PATH (relative to SRC_ROOT)
# into the first package part with room for it, descending into directories
# too large for any part. PART_DIRS/PART_SIZES track the parts.
pack_tree() {
    local src_root="$1" rel="$2" size="$3"
    local i=""
    if [ "$size" -gt "$MAX_PART_BYTES" ] && [ -d "$src_root/$rel" ] && [ ! -L "$src_root/$rel" ]; then
        local child_size child_path
        while IFS=$'\t' read -r child_size child_path; do
            pack_tree "$src_root" "${child_path#"$src_root"/}" "$child_size"
        done < <(find "$src_root/$rel" -mindepth 1 -maxdepth 1 -exec du -sb {} + | sort -rn)
        rmdir "$src_root/$rel" 2>/dev/null || true
        return 0
    fi
    for i in "${!PART_DIRS[@]}"; do
        if [ $((PART_SIZES[i] + size)) -le "$MAX_PART_BYTES" ]; then
            break
        fi
        i=""
    done
    if [ -z "$i" ]; then
        i=${#PART_DIRS[@]}
        PART_DIRS+=("$TEMP_DIR/pkg$i")
        PART_SIZES+=(0)
    fi
    local dest="${PART_DIRS[i]}/opt/resolve/$rel"
    mkdir -p "$(dirname "$dest")"
    mv "$src_root/$rel" "$dest"
    PART_SIZES[i]=$((PART_SIZES[i] + size))
}

# _existing_package_set -> when a complete set of .deb files for PKG_VERSION
# is already in the current directory, lists them in DEB_FILES and returns 0.
_existing_package_set() {
    local main_deb="${PACKAGE_NAME}_${PKG_VERSION}_amd64.deb" dep
    DEB_FILES=()
    if [ "$FORCE_REBUILD" = true ] || [ ! -f "$main_deb" ] \
        || [ "$(dpkg-deb -f "$main_deb" Version 2>/dev/null || true)" != "$PKG_VERSION" ]; then
        return 1
    fi
    DEB_FILES=("$main_deb")
    for dep in $(dpkg-deb -f "$main_deb" Depends | tr ',' '\n' | awk -v p="${PACKAGE_NAME}-data-" 'index($1, p) == 1 {print $1}'); do
        if [ ! -f "${dep}_${PKG_VERSION}_amd64.deb" ]; then
            DEB_FILES=()
            return 1
        fi
        DEB_FILES+=("${dep}_${PKG_VERSION}_amd64.deb")
    done
}

# _packages_prebuilt -> returns 0 when a complete package set already exists
# for the version in the installer's name, without extracting anything. Sets
# PKG_VERSION and DEB_FILES accordingly.
_packages_prebuilt() {
    local name_version
    name_version=$(_installer_version "$RESOLVE_INSTALLER_RUN")
    [ -n "$name_version" ] || return 1
    PKG_VERSION="${name_version}-1"
    _existing_package_set
}

create_deb_package() {
# TRAIL:create_deb_package
    print_step "Building package contents"

    # The installer name carries the version; when packages for it already
    # exist there is no need to extract 10+ GB again.
    if _packages_prebuilt; then
        print_info "Existing packages for $PKG_VERSION found. Skipping rebuild (use --force to rebuild)."
        return 0
    fi
    print_info "Starting repackaging process..."

    # 1. Extract the .run installer using its own non-root install
    print_info "Extracting installer contents..."
    local extract_dir="$TEMP_DIR/extracted"
    mkdir -p "$extract_dir"
    local xdg_dir="$TEMP_DIR/xdg"
    mkdir -p "$xdg_dir"
    QT_QPA_PLATFORM=offscreen DISPLAY='' XDG_RUNTIME_DIR="$xdg_dir" SKIP_PACKAGE_CHECK=1 "$PWD/$RESOLVE_INSTALLER_RUN" --install --noconfirm --nonroot --directory "$extract_dir" >/dev/null &
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
    print_info "Detected Resolve Version: $resolve_version"

    PKG_VERSION="${resolve_version}-1"
    if _existing_package_set; then
        print_info "Existing packages for $PKG_VERSION found. Skipping rebuild."
        return 0
    fi

    # 2. Gather host libraries Resolve needs and settle library conflicts
    print_info "Arranging application files..."
    local libs_dir="$extract_dir/libs"
    mkdir -p "$libs_dir"
    bundle_system_libraries "$libs_dir"
    disable_conflicting_libs "$libs_dir"

    # Create shim wrapper to ensure Resolve uses bundled libraries without polluting system
    mv "$extract_dir/bin/resolve" "$extract_dir/bin/resolve.bin"
    cat > "$extract_dir/bin/resolve" <<'SHIM'
#!/bin/bash
RESOLVE_ROOT="/opt/resolve"
export LD_LIBRARY_PATH="${RESOLVE_ROOT}/libs${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
exec "${RESOLVE_ROOT}/bin/resolve.bin" "$@"
SHIM
    chmod 0755 "$extract_dir/bin/resolve"

    # 3. Spread the files over as many packages as the .deb size limit needs
    print_info "Splitting files into packages (max $((MAX_PART_BYTES / 1024 / 1024 / 1024)) GiB each)..."
    PART_DIRS=()
    PART_SIZES=()
    local entry_size entry_path
    while IFS=$'\t' read -r entry_size entry_path; do
        pack_tree "$extract_dir" "${entry_path#"$extract_dir"/}" "$entry_size"
    done < <(find "$extract_dir" -mindepth 1 -maxdepth 1 -exec du -sb {} + | sort -rn)

    local part_names=() i
    for i in "${!PART_DIRS[@]}"; do
        if [ "$i" -eq 0 ]; then
            part_names+=("$PACKAGE_NAME")
        else
            part_names+=("${PACKAGE_NAME}-data-$i")
        fi
    done

    # 4. Package metadata. Every package depends on the others at the same
    # version, so they are always installed, upgraded and removed as a set, and
    # may take over files that lived in another part in an older release.
    print_info "Creating package metadata..."
    local main_dir="${PART_DIRS[0]}"
    local debian_dir="$main_dir/DEBIAN"
    for i in "${!PART_DIRS[@]}"; do
        local depends="libc6 (>= 2.31), libstdc++6 (>= 10), libgl1, libx11-6, libxcb1" replaces="" j
        for j in "${!part_names[@]}"; do
            [ "$j" -eq "$i" ] && continue
            depends+=", ${part_names[j]} (= $PKG_VERSION)"
            replaces+="${replaces:+, }${part_names[j]} (<< $PKG_VERSION)"
        done
        local extra_desc=""
        if [ "$i" -gt 0 ]; then extra_desc=" (data part $i of $((${#PART_DIRS[@]} - 1)))"; fi
        _write_control "${PART_DIRS[i]}" "${part_names[i]}" "$depends" "$extra_desc"
        if [ -n "$replaces" ]; then
            printf 'Replaces: %s\n' "$replaces" >> "${PART_DIRS[i]}/DEBIAN/control"
        fi
    done

    # Blackmagic's own post-install / uninstall scripts ship inside the
    # installer. Running them from the maintainer scripts gives the desktop
    # entries, MIME types, udev rules, panel drivers and writable directories
    # exactly as the official installer would, for every Resolve release.
    cat > "$debian_dir/postinst" << 'EOF'
#!/bin/bash
set -e
INSTALL_DIR=/opt/resolve
# Blackmagic's script writes its menu file here and assumes the directory
# exists, which is not the case on every distribution.
mkdir -p /etc/xdg/menus/applications-merged
if [ -f "$INSTALL_DIR/scripts/post_install.sh" ]; then
    sed -e "s:PRODUCT_INSTALL_LOCATION:$INSTALL_DIR:g" "$INSTALL_DIR/scripts/post_install.sh" | bash || true
fi
ln -sf "$INSTALL_DIR/bin/resolve" /usr/bin/resolve
# Resolve writes into these directories at run time (as the desktop user) and
# refuses to start when it cannot create them. Blackmagic's GUI installer
# creates them; its post_install.sh only covers a few, so do it here.
for dir in .license .crashreport .LUT .ScriptsCache configs DolbyVision easyDCP Fairlight \
    GPUCache logs LUT Media "Apple Immersive" Immersive "Resolve Disk Database"; do
    mkdir -p "$INSTALL_DIR/$dir"
    chmod 0777 "$INSTALL_DIR/$dir"
done
# Older releases of this tool registered the bundled libraries system wide.
if [ -f /etc/ld.so.conf.d/resolve.conf ]; then
    rm -f /etc/ld.so.conf.d/resolve.conf
    ldconfig
fi
command -v update-desktop-database >/dev/null 2>&1 && update-desktop-database -q || true
exit 0
EOF
    cat > "$debian_dir/prerm" << 'EOF'
#!/bin/bash
set -e
INSTALL_DIR=/opt/resolve
# Only on removal; an upgrade keeps the desktop integration in place.
if [ "$1" = "remove" ] && [ -f "$INSTALL_DIR/scripts/uninstall.sh" ]; then
    sed -e "s:PRODUCT_INSTALL_LOCATION:$INSTALL_DIR:g" "$INSTALL_DIR/scripts/uninstall.sh" | bash >/dev/null 2>&1 || true
fi
exit 0
EOF
    cat > "$debian_dir/postrm" << 'EOF'
#!/bin/bash
set -e
if [ "$1" = "remove" ] || [ "$1" = "purge" ]; then
    rm -f /usr/bin/resolve
    command -v update-desktop-database >/dev/null 2>&1 && update-desktop-database -q || true
fi
exit 0
EOF
    chmod 0755 "$debian_dir/postinst" "$debian_dir/prerm" "$debian_dir/postrm"

    # 5. Build the .deb packages. Resolve's payload is mostly already
    # compressed, so a light zstd pass keeps build time short.
    local compress=(-Zzstd -z3)
    if ! dpkg-deb --help 2>/dev/null | grep -q zstd; then
        compress=(-Zxz -z1)
    fi
    if dpkg-deb --help 2>/dev/null | grep -q -- '--threads-max'; then
        compress+=("--threads-max=$(nproc)")
    fi
    DEB_FILES=()
    for i in "${!PART_DIRS[@]}"; do
        local deb_file="${part_names[i]}_${PKG_VERSION}_amd64.deb"
        dpkg-deb --root-owner-group "${compress[@]}" --build "${PART_DIRS[i]}" "$deb_file" >/dev/null &
        local build_pid=$!
        start_spinner "    Packaging ${part_names[i]} ($((PART_SIZES[i] / 1024 / 1024)) MB)" &
        local spinner_pid=$!
        wait "$build_pid"
        local build_exit=$?
        stop_spinner "$spinner_pid" "$build_exit" "Built $deb_file"
        if [ "$build_exit" -ne 0 ]; then
            print_error "Package build failed."
        fi
        _chown_to_invoker "$deb_file"
        DEB_FILES+=("$deb_file")
    done
    print_success "Successfully created ${#DEB_FILES[@]} package(s)."
}

install_package() {
# TRAIL:install_package
    print_step "Installing package"
    print_info "Installing DaVinci Resolve package..."

    local deb
    for deb in "${DEB_FILES[@]}"; do
        if [ ! -f "$deb" ]; then
            print_error "Package file '$deb' not found. Did the build step succeed?"
        fi
    done

    local local_debs=()
    for deb in "${DEB_FILES[@]}"; do local_debs+=("./$deb"); done
    # Local .deb files need no download sandbox; skipping it avoids a warning
    # when the current directory is not readable by the _apt user.
    apt-get install -y --allow-downgrades -o APT::Sandbox::User=root "${local_debs[@]}"

    print_success "DaVinci Resolve $PKG_VERSION has been successfully installed!"
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

Downloads the latest stable DaVinci Resolve from Blackmagic Design, turns it
into Debian packages and installs them. Run it again later to upgrade: when the
installed Resolve is already the latest release it exits without downloading.

Options:
  --edition <studio|free>
                        Which DaVinci Resolve to install. Without it the script
                        uses the installed edition, then the edition of a local
                        .run file, and otherwise asks.
  --update              Upgrade the installed Resolve to the latest release
                        without asking anything; exits when already current
  -y, --yes             Answer yes to every prompt (uninstall, install)
  -f, --force           Rebuild the packages even if matching .deb files exist
                        and reinstall even if the installed Resolve is current
  --force-install       Install without asking, even if Resolve is already installed
  --check               Only report the installed and latest versions, then exit
  --download-only       Fetch the latest installer and exit (does not need sudo)
  --build-only          Download and build the .deb files but do not install
                        them (does not need sudo)
  --no-download         Never contact Blackmagic; use the .run in the current directory
  --clean-cache         Clear cached dependency archives before bundling
  -h, --help            Show this help message

Environment variables:
  CACHE_ROOT            Override the cache directory
                        (default: /var/cache/resolve-repackage as root,
                        $HOME/.cache/resolve-repackage otherwise)
  CONFIG_ROOT           Override where the free edition's download registration
                        is kept (default: $HOME/.config/resolve-repackage)
EOF
}

parse_args() {
# TRAIL:parse_args
    while [ $# -gt 0 ]; do
        case "$1" in
            --edition)
                shift
                case "${1:-}" in
                    studio|free) EDITION="$1" ;;
                    *) print_error "--edition expects 'studio' or 'free'." ;;
                esac
                ;;
            --edition=*)
                case "${1#--edition=}" in
                    studio|free) EDITION="${1#--edition=}" ;;
                    *) print_error "--edition expects 'studio' or 'free'." ;;
                esac
                ;;
            --update)
                UPDATE_MODE=true
                ASSUME_YES=true
                ;;
            -y|--yes)
                ASSUME_YES=true
                ;;
            -f|--force)
                FORCE_REBUILD=true
                FORCE_INSTALL=true
                ;;
            --force-install)
                FORCE_INSTALL=true
                ;;
            --check)
                CHECK_ONLY=true
                ;;
            --download-only)
                DOWNLOAD_ONLY=true
                ;;
            --build-only)
                BUILD_ONLY=true
                ;;
            --no-download)
                NO_DOWNLOAD=true
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
    if [ "$NO_DOWNLOAD" = true ] && { [ "$DOWNLOAD_ONLY" = true ] || [ "$CHECK_ONLY" = true ]; }; then
        print_error "--no-download cannot be combined with --download-only or --check."
    fi
}

check_for_updates() {
# TRAIL:check_for_updates
    find_installed_version
    if [ -n "$INSTALLED_VERSION" ]; then
        print_info "Installed: $(_edition_name) $INSTALLED_VERSION"
    else
        print_info "Installed: none ($(_edition_name) is not installed)"
    fi
    if ! fetch_latest_release; then
        print_error "Could not reach Blackmagic Design to check the latest release."
    fi
    print_info "Latest stable release: $LATEST_VERSION"
    if [ -n "$INSTALLED_VERSION" ] && dpkg --compare-versions "$INSTALLED_VERSION" ge "$LATEST_VERSION"; then
        print_done "DaVinci Resolve is up to date"
    else
        printf '\n  %sUpdate available. Run:%s\n' "$C_DIM" "$C_RESET"
        printf '    %ssudo %s --update%s\n\n' "${C_BOLD}${C_CYAN}" "$0" "$C_RESET"
    fi
}

main() {
# TRAIL:main
    init_theme
    parse_args "$@"
    print_banner
    select_edition

    if [ "$CHECK_ONLY" = true ]; then
        TOTAL_STEPS=1
        check_for_updates
        return 0
    fi

    if [ "$DOWNLOAD_ONLY" = true ]; then
        TOTAL_STEPS=2
        check_tools
        acquire_installer
        print_done "Installer ready: $RESOLVE_INSTALLER_RUN"
        return 0
    fi

    if [ "$BUILD_ONLY" = true ]; then
        TOTAL_STEPS=4
    else
        check_root
    fi

    # The work tree is several times the installer's size, so it lives next to
    # the script rather than in /tmp, which is often a small tmpfs.
    TEMP_DIR=$(mktemp -d -p "$PWD" resolve_temp_XXXXXX)

    check_tools
    acquire_installer
    ensure_bundled_packages
    create_deb_package

    if [ "$BUILD_ONLY" = true ]; then
        print_info "Build complete. To install, run:"
        printf '    %ssudo apt install %s%s\n' "${C_BOLD}${C_CYAN}" "$(printf './%s ' "${DEB_FILES[@]}")" "$C_RESET"
        print_done "Packages ready"
        return 0
    fi

    handle_existing_install
    if [ "$FORCE_INSTALL" = true ] || confirm "Install DaVinci Resolve $PKG_VERSION now?"; then
        install_package
    else
        print_info "Repackaging complete. To install, run:"
        printf '    %ssudo apt install %s%s\n' "${C_BOLD}${C_CYAN}" "$(printf './%s ' "${DEB_FILES[@]}")" "$C_RESET"
    fi

    print_done "All done. Enjoy DaVinci Resolve!"
}

main "$@"
