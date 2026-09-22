#!/bin/bash
#
# Installs applications listed in manifest.tsv, then applies post-install
# configuration. Safe to re-run: anything already present is skipped.

set -uo pipefail
SETUP_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SETUP_ROOT}/lib/common.sh"

MANIFEST="${SETUP_ROOT}/manifest.tsv"
PROFILE_FILE="${STATE_DIR}/profiles"
PROFILES=""

# ------------------------------------------------------------ profiles ----

usage() {
    cat <<USAGE
Usage: install.sh [--profile LIST] [--list-profiles]

  --profile LIST    comma-separated profiles to install, e.g. dev,desktop
  --list-profiles   show profiles and what each contains
  --help            this message

The selection is remembered in ${PROFILE_FILE}, so re-runs and reboot
resumes install the same set. SETUP_PROFILES=... works as an alternative.
USAGE
}

list_profiles() {
    local p
    for p in $KNOWN_PROFILES; do
        printf '\n%s%s%s\n' "$_B" "$p" "$_0"
        awk -F'\t' -v want="$p" '
            !/^#/ && NF {
                split($2, a, ",")
                for (i in a) if (a[i] == want) { printf "  %s\n", $1; break }
            }' "$MANIFEST"
    done
}

# Order of precedence: --profile, $SETUP_PROFILES, a previous saved choice,
# then an interactive prompt. Non-interactive runs with no prior choice fail
# rather than guessing at what a machine is for.
resolve_profiles() {
    [ -n "$PROFILES" ] && return 0
    if [ -n "${SETUP_PROFILES:-}" ]; then PROFILES="$SETUP_PROFILES"; return 0; fi
    if [ -s "$PROFILE_FILE" ]; then
        PROFILES="$(cat "$PROFILE_FILE")"
        info "using saved profiles: ${PROFILES}"
        return 0
    fi
    if [ ! -t 0 ]; then
        err "no profile selected and stdin is not a terminal"
        err "pass --profile ${KNOWN_PROFILES// /,} or set SETUP_PROFILES"
        return 1
    fi
    printf '\nAvailable profiles: %s\n' "$KNOWN_PROFILES" >&2
    printf 'Select one or more, comma-separated: ' >&2
    read -r PROFILES
    [ -n "$PROFILES" ] || { err "no profile selected"; return 1; }
}

# ------------------------------------------------------------ manifest ----

install_from_manifest() {
    local name profiles method dest team url selected=0
    [ -f "$MANIFEST" ] || { record_fail "manifest" "not found at ${MANIFEST}"; return 1; }

    while IFS=$'\t' read -r name profiles method dest team url; do
        case "$name" in ''|\#*) continue ;; esac
        if [ -z "${url:-}" ]; then
            record_fail "$name" "malformed manifest line"; continue
        fi
        profile_matches "$profiles" "$PROFILES" || continue
        selected=$((selected + 1))
        # npm and mas entries need Node and mas respectively, both of which
        # are set up after this pass.
        case "$method" in npm|mas) continue ;; esac
        install_verified "$name" "$method" "$dest" "$team" "$url"
    done < "$MANIFEST"

    info "${selected} entries matched profiles: ${PROFILES}"
}

# -------------------------------------------------------------- oMLX ------
#
# Port defaults to 60001 already; only the bind address needs changing.
# The file is patched in place and never shipped from this repo — it holds
# auth.api_key and auth.secret_key, which are per-install secrets.

configure_omlx() {
    local cfg="${HOME}/.omlx/settings.json" host port

    if [ ! -f "$cfg" ]; then
        record_skip "oMLX server config" "settings.json does not exist yet"
        record_note "oMLX: launch it once to create ~/.omlx/settings.json, then re-run install.sh"
        return 0
    fi

    cp "$cfg" "${cfg}.bak.$(date +%Y%m%d%H%M%S)" 2>/dev/null

    if ! plutil -replace server.host -string "0.0.0.0" "$cfg" 2>/dev/null ||
       ! plutil -replace server.port -integer 60001 "$cfg" 2>/dev/null; then
        record_fail "oMLX server config" "plutil could not patch settings.json"
        return 1
    fi

    host="$(plutil -extract server.host raw "$cfg" 2>/dev/null)"
    port="$(plutil -extract server.port raw "$cfg" 2>/dev/null)"
    if [ "$host" = "0.0.0.0" ] && [ "$port" = "60001" ]; then
        record_pass "oMLX listening on ${host}:${port}"
        record_note "oMLX: restart the app for the new bind address to take effect"
    else
        record_fail "oMLX server config" "read back ${host}:${port}"
        return 1
    fi
}

# --------------------------------------------------------- App Store ------
#
# Homebrew is installed for exactly one reason: `mas`, the only command-line
# interface to the Mac App Store. Xcode and Final Cut Pro are App Store
# exclusives with no vendor download, so there is no signature-checked path
# to them. Nothing else in this repo comes from Homebrew — every other
# application is fetched from its vendor and verified against a pinned
# Team ID. `mas` is a CLI formula built by Homebrew's own infrastructure,
# not a cask redirecting to a third-party URL.
#
# This runs only when the selected profiles actually contain App Store
# entries, so an `ai`-only machine never gets Homebrew at all.

manifest_has_mas_entries() {
    local name profiles method rest
    while IFS=$'\t' read -r name profiles method rest; do
        case "$name" in ''|\#*) continue ;; esac
        [ "$method" = mas ] || continue
        profile_matches "$profiles" "$PROFILES" && return 0
    done < "$MANIFEST"
    return 1
}

install_homebrew() {
    info "Installing Homebrew (needed only for mas)"
    if NONINTERACTIVE=1 /bin/bash -c \
        "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)" >/dev/null 2>&1
    then
        record_pass "Homebrew"
    else
        record_fail "Homebrew" "install script failed"
        return 1
    fi
}

ensure_mas() {
    if command -v mas >/dev/null 2>&1; then
        record_skip "mas" "already installed"
        return 0
    fi
    if ! manifest_has_mas_entries; then
        record_skip "mas" "no App Store titles in selected profiles"
        return 0
    fi
    if [ "${SETUP_DRY_RUN:-0}" = "1" ]; then
        record_skip "mas" "dry run — would install Homebrew, then mas"
        return 0
    fi

    if ! command -v brew >/dev/null 2>&1 && [ ! -x /opt/homebrew/bin/brew ]; then
        install_homebrew || return 1
    fi
    [ -x /opt/homebrew/bin/brew ] && eval "$(/opt/homebrew/bin/brew shellenv)"

    if brew install mas >/dev/null 2>&1; then
        record_pass "mas"
        # mas can no longer sign in to the App Store itself; Apple removed
        # that. An unsigned-in machine makes every mas install fail.
        record_note "App Store: sign in to the App Store app before Xcode and Final Cut Pro can install"
    else
        record_fail "mas" "brew install mas failed"
        return 1
    fi
}

# App Store entries are deferred until mas exists, the same way npm entries
# wait for Node.
install_mas_from_manifest() {
    local name profiles method dest team url
    while IFS=$'\t' read -r name profiles method dest team url; do
        case "$name" in ''|\#*) continue ;; esac
        [ "$method" = mas ] || continue
        profile_matches "$profiles" "$PROFILES" || continue
        install_verified "$name" "$method" "$dest" "$team" "$url"
    done < "$MANIFEST"
}

# ------------------------------------------------------------- Node -------

install_node() {
    if [ -s "${HOME}/.nvm/nvm.sh" ]; then
        record_skip "nvm" "already installed"
    else
        # A shell script, not a signed artifact: no notarization to verify.
        # Pinned to a tagged release rather than a moving branch.
        if curl -fsSL https://raw.githubusercontent.com/nvm-sh/nvm/v0.40.7/install.sh | bash >/dev/null 2>&1; then
            record_pass "nvm v0.40.7"
        else
            record_fail "nvm" "install script failed"
            return 1
        fi
    fi

    # shellcheck disable=SC1091
    export NVM_DIR="${HOME}/.nvm"
    [ -s "${NVM_DIR}/nvm.sh" ] && . "${NVM_DIR}/nvm.sh"

    if command -v node >/dev/null 2>&1; then
        record_skip "Node.js" "already present ($(node -v 2>/dev/null))"
    elif nvm install --lts >/dev/null 2>&1; then
        record_pass "Node.js $(node -v 2>/dev/null)"
    else
        record_fail "Node.js" "nvm install failed"
    fi
}

# ------------------------------------------------------------- misc -------

add_to_dock() {
    local app="$1"
    [ -d "$app" ] || return 0
    defaults write com.apple.dock persistent-apps -array-add \
        "<dict><key>tile-data</key><dict><key>file-data</key><dict><key>_CFURLString</key><string>${app}</string><key>_CFURLStringType</key><integer>0</integer></dict></dict></dict>" 2>/dev/null
}

setup_huggingface() {
    # Directory only. The token is a credential and belongs in the keychain,
    # not in this repo — the previous script committed one in plain text.
    if [ -d "${HOME}/.cache/huggingface" ]; then
        record_skip "Hugging Face cache dir" "exists"
    else
        mkdir -p "${HOME}/.cache/huggingface" && record_pass "Hugging Face cache dir"
    fi
    [ -f "${HOME}/.cache/huggingface/token" ] || \
        record_note "Hugging Face: add your token to ~/.cache/huggingface/token (do not commit it)"
}

# -------------------------------------------------------------- main ------

# npm entries are re-run after Node exists, since the first pass skipped them.
install_npm_from_manifest() {
    local name profiles method dest team url
    while IFS=$'\t' read -r name profiles method dest team url; do
        case "$name" in ''|\#*) continue ;; esac
        [ "$method" = npm ] || continue
        profile_matches "$profiles" "$PROFILES" || continue
        install_verified "$name" "$method" "$dest" "$team" "$url"
    done < "$MANIFEST"
}

main() {
    while [ $# -gt 0 ]; do
        case "$1" in
            --profile|--profiles)   PROFILES="${2:-}"; shift 2 ;;
            --profile=*|--profiles=*) PROFILES="${1#*=}"; shift ;;
            --list-profiles) list_profiles; exit 0 ;;
            --help|-h)  usage; exit 0 ;;
            *) err "unknown option: $1"; usage; exit 1 ;;
        esac
    done

    info "setup-macos — install (macOS $(macos_full))"
    check_macos_version || exit 1
    resolve_profiles || exit 1
    validate_profiles "$PROFILES" || exit 1
    printf '%s' "$PROFILES" > "$PROFILE_FILE"
    # A dry run installs nothing, so it must not demand a password. This also
    # keeps it usable from CI and from non-interactive shells.
    if [ "${SETUP_DRY_RUN:-0}" != "1" ]; then
        require_sudo || { err "sudo required"; exit 1; }
    fi

    mkdir -p "${HOME}/projects"

    install_from_manifest

    # Node is a prerequisite for the npm entries, so it runs before them on
    # profiles that have any.
    if profile_matches "dev,ai" "$PROFILES"; then
        install_node
        install_npm_from_manifest
    fi

    ensure_mas && install_mas_from_manifest

    if profile_matches "ai" "$PROFILES"; then
        configure_omlx
        fw_allow "${HOME}/.omlx/bin/omlx" "oMLX server"
    fi

    if profile_matches "dev,ai" "$PROFILES"; then
        setup_huggingface
    fi

    for a in /Applications/Emacs.app /Applications/Firefox.app "/Applications/Brave Browser.app"; do
        add_to_dock "$a"
    done
    killall Dock 2>/dev/null

    print_summary
}

main "$@"
