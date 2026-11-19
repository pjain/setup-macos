#!/bin/bash
#
# Installs applications listed in manifest.tsv, then applies post-install
# configuration. Safe to re-run: anything already present is skipped.

set -uo pipefail
SETUP_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RUN_LABEL="$(basename "$0" .sh)"
# shellcheck source=lib/common.sh
source "${SETUP_ROOT}/lib/common.sh"
# shellcheck source=lib/resolve.sh
source "${SETUP_ROOT}/lib/resolve.sh"

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

# ------------------------------------------------------------ manifest ----

install_from_manifest() {
    local name profiles method dest team url resolved selected=0
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

        # Resolve a source spec (github:, page:, ...) to a concrete URL.
        # Pinned http URLs and non-download methods pass straight through.
        case "$method" in dmg|dmgpkg|zip|pkg|upkg)
            case "$url" in
            http://*|https://*) : ;;
            *)
                if resolved="$(resolve_entry "$name" "$url")"; then
                    _log "RESOLVE $name ${resolved%%$'\t'*} $(printf '%s' "${resolved#*$'\t'}" | head -c 100)"
                    url="${resolved#*$'\t'}"
                else
                    record_fail "$name" "could not resolve source: ${url%%|*}"
                    continue
                fi ;;
            esac ;;
        esac

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

    if [ "${SETUP_DRY_RUN:-0}" = "1" ]; then
        record_skip "oMLX server config" "dry run — would patch settings.json if present"
        return 0
    fi
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
    if [ "${SETUP_SKIP_APP_STORE:-0}" = "1" ]; then
        record_skip "Homebrew + mas" "App Store disabled (SETUP_SKIP_APP_STORE)"
        return 0
    fi
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
    if [ "${SETUP_DRY_RUN:-0}" = "1" ]; then
        record_skip "dock pin $(basename "$app")" "dry run"
        return 0
    fi
    # Idempotency: defaults write -array-add appends on every run, so without
    # this check repeated runs pile up duplicate tiles.
    if defaults read com.apple.dock persistent-apps 2>/dev/null | grep -qF "$app"; then
        return 0
    fi
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
            --yes|-y)               export SETUP_UNATTENDED=1; shift ;;
            --list-profiles) list_profiles; exit 0 ;;
            --help|-h)  usage; exit 0 ;;
            *) err "unknown option: $1"; usage; exit 1 ;;
        esac
    done

    info "setup-macos — install (macOS $(macos_full))"
    acquire_run_lock || exit 1
    check_macos_version || exit 1
    PROFILES="$(resolve_profiles "$PROFILES")" || exit 1
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
    [ "${SETUP_DRY_RUN:-0}" = "1" ] || killall Dock 2>/dev/null

    print_summary
}

main "$@"
