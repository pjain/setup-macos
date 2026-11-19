#!/bin/bash
#
# Checks for, and applies, application updates.
#
#   ./update.sh --check     report installed vs latest, change nothing
#   ./update.sh             upgrade anything outdated (verified like installs)
#
# Sources are re-resolved on every run — the lockfile cache is bypassed,
# because "is there a new version?" is exactly the question caching defeats.
# An upgrade downloads the new artifact, runs it through the same
# notarization + pinned-Team-ID gate as install.sh, and only then replaces
# the old copy; a failed verification leaves the previous version restored
# in place. Version comparison is numeric-only: anything not comparable is
# reported to a human, never auto-upgraded.

set -uo pipefail
SETUP_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RUN_LABEL="$(basename "$0" .sh)"
# shellcheck source=lib/common.sh
source "${SETUP_ROOT}/lib/common.sh"
# shellcheck source=lib/resolve.sh
source "${SETUP_ROOT}/lib/resolve.sh"

RESOLVE_TTL=0
PROFILES=""
CHECK_ONLY=0
UPDATES=()

usage() {
    cat <<USAGE
Usage: update.sh [--profile LIST] [--check]

  --check         only report version drift; download, move or install
                  nothing (SETUP_DRY_RUN=1 does the same)
  --profile LIST  comma-separated profiles to consider, e.g. dev,desktop
  --help          this message

Runs after install.sh; considers the same profile selection by default.
App Store titles: run 'mas upgrade'. npm/pip packages: 'npm update -g' /
'python3 -m pip install -U'. Those report as skips here rather than being
duplicated through a second code path.
USAGE
}

# upgrade_entry <name> <method> <dest> <team> <url> <latest-version>
# dest must be an .app bundle path that already exists. The old bundle is
# moved aside so install_verified's idempotency check does not short-circuit,
# and is restored if download or verification fails.
upgrade_entry() {
    local name="$1" method="$2" dest="$3" team="$4" url="$5" latest="$6"
    local installed backup rc=0

    installed="$(installed_version "$dest")" || true
    version_newer "${latest:-}" "$installed"
    case "$V_STATUS" in
        newer)  : ;;
        same)   _log "UP-TO-DATE $name ${installed}"; return 0 ;;
        older)  record_note "${name}: installed ${installed} is newer than site's ${latest}; leaving alone"
                return 0 ;;
        *)      record_skip "${name} update" "cannot compare versions (installed ${installed}, latest ${latest:-unknown})"
                return 0 ;;
    esac

    UPDATES+=("${name}  ${installed} -> ${latest}")
    if [ "$CHECK_ONLY" = 1 ]; then
        record_note "update available: ${name} ${installed} -> ${latest}"
        return 0
    fi

    info "${name} — upgrading ${installed} -> ${latest}"
    backup="${dest}.setup-old"
    rm -rf "$backup"
    if ! mv "$dest" "$backup" 2>/dev/null && ! sudo mv "$dest" "$backup"; then
        record_fail "${name} update" "could not move aside ${dest}"
        return 1
    fi
    if install_verified "$name" "$method" "$dest" "$team" "$url"; then
        rm -rf "$backup"
        record_pass "${name} updated to ${latest}"
    else
        rc=1
        [ -e "$dest" ] && rm -rf "$dest"
        if sudo mv "$backup" "$dest" 2>/dev/null || mv "$backup" "$dest"; then
            info "${name} — previous version (${installed}) restored"
        else
            record_fail "${name}" "previous version left at ${backup}"
        fi
    fi
    return "$rc"
}

update_from_manifest() {
    local name profiles method dest team url resolved latest installed
    [ -f "$MANIFEST" ] || { record_fail "manifest" "not found at ${MANIFEST}"; return 1; }

    while IFS=$'\t' read -r name profiles method dest team url; do
        case "$name" in ''|\#*) continue ;; esac
        profile_matches "$profiles" "$PROFILES" || continue
        case "$method" in
            dmg|dmgpkg|zip|pkg|upkg) : ;;
            mas) record_note "${name}: App Store — run 'mas upgrade'"; continue ;;
            npm) record_note "${name}: run 'npm update -g ${dest}'"; continue ;;
            pip) record_note "${name}: run 'python3 -m pip install -U ${dest}'"; continue ;;
            *)   continue ;;
        esac

        # Resolve (freshly) to a versioned URL. Pinned URLs yield whatever
        # version the URL itself names — enough to flag installed-vs-pinned
        # drift for entries whose upgrade still needs a human.
        if ! resolved="$(resolve_entry "$name" "$url")"; then
            record_fail "${name} update check" "could not resolve source: ${url%%|*}"
            continue
        fi
        latest="${resolved%%$'\t'*}"; url="${resolved#*$'\t'}"

        case "$dest" in
            *.app) : ;;
            *)  if [ -n "${latest:-}" ] && [ "$latest" != "unknown" ]; then
                    record_note "${name}: latest is ${latest}; ${dest} has no version to compare — update by hand"
                fi
                continue ;;
        esac

        if [ ! -e "$dest" ]; then
            record_skip "${name} update" "not installed — run install.sh"
            continue
        fi

        upgrade_entry "$name" "$method" "$dest" "$team" "$url" "$latest"
    done < "$MANIFEST"
}

main() {
    while [ $# -gt 0 ]; do
        case "$1" in
            --check)          CHECK_ONLY=1; shift ;;
            --yes|-y)         export SETUP_UNATTENDED=1; shift ;;
            --profile|--profiles)     PROFILES="${2:-}"; shift 2 ;;
            --profile=*|--profiles=*) PROFILES="${1#*=}"; shift ;;
            --help|-h)        usage; exit 0 ;;
            *) err "unknown option: $1"; usage; exit 1 ;;
        esac
    done
    [ "${SETUP_DRY_RUN:-0}" = "1" ] && CHECK_ONLY=1

    info "setup-macos — update (macOS $(macos_full))"
    acquire_run_lock || exit 1
    check_macos_version || exit 1
    PROFILES="$(resolve_profiles "$PROFILES")" || exit 1
    validate_profiles "$PROFILES" || exit 1

    # sudo is only reached for pkg installs and root-owned bundles, but a
    # prompt mid-run breaks unattended flows; take it up front like install.
    if [ "$CHECK_ONLY" != 1 ]; then
        require_sudo || { err "sudo required"; exit 1; }
    fi

    update_from_manifest

    if [ "${#UPDATES[@]}" -gt 0 ]; then
        if [ "$CHECK_ONLY" = 1 ]; then
            printf '\n%supdates available:%s\n' "$_Y" "$_0" >&2
        else
            printf '\n%supdates applied:%s\n' "$_G" "$_0" >&2
        fi
        printf '  %s\n' "${UPDATES[@]}" >&2
    fi

    print_summary
}

main "$@"
