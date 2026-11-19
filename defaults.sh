#!/bin/bash
#
# System preferences. Nearly all of it is data — see prefs.tsv for the
# format and the version-gating mechanism. Every write is read back to
# confirm it took effect, so a key Apple removed in a newer macOS is
# reported rather than silently ignored, and every result lands in
# ${STATE_DIR}/prefs-audit.tsv — diff that file across macOS releases and
# you have the compatibility matrix (.github/workflows/prefs-matrix.yml
# regenerates it on Apple's runners).
#
# What stays as shell are the operations that are not key/value writes:
# PlistBuddy paths, chflags, systemsetup, pmset, the firewall, Touch ID
# sudo. Each reports itself the same way data entries do.

set -uo pipefail
SETUP_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SETUP_ROOT}/lib/common.sh"

PREFS_FILE="${SETUP_ROOT}/prefs.tsv"
AUDIT_FILE="${STATE_DIR}/prefs-audit.tsv"
PROFILES=""

# ------------------------------------------------------------ machine ----
# Values that differ per machine are config knobs, not edits to the data:
# ~/.config/setup-macos/config holds plain KEY=VALUE lines, e.g.
#   SETUP_TIMEZONE=Asia/Kolkata
#   SETUP_SCREENSHOT_DIR=$HOME/Pictures/Screenshots

SETUP_CONFIG="${SETUP_CONFIG:-${HOME}/.config/setup-macos/config}"
# shellcheck disable=SC1090
[ -f "$SETUP_CONFIG" ] && . "$SETUP_CONFIG"
SCREENSHOTS_DIR="${SETUP_SCREENSHOT_DIR:-${HOME}/Desktop}"
TIMEZONE="${SETUP_TIMEZONE:-America/New_York}"

dw()  { defaults_write_verified "$@"; }

usage() {
    cat <<USAGE
Usage: defaults.sh [--profile LIST]

  --profile LIST  comma-separated profiles whose preferences to apply;
                  defaults to the saved selection from install.sh
  --help          this message

SETUP_DRY_RUN=1 resolves and reports without writing anything, including
the sudo-requiring actions. Per-key results append to ${AUDIT_FILE}.
Machine-specific values come from ${SETUP_CONFIG} (see header).
USAGE
}

# ---------------------------------------------------------------- audit ----

audit_log() { # domain key result [detail]
    printf '%s\t%s\t%s\t%s\t%s\t%s\n' \
        "$(date '+%Y-%m-%dT%H:%M:%S')" "$(macos_full)" "$1" "$2" "$3" "${4:-}" \
        >> "$AUDIT_FILE"
}

# ------------------------------------------------------------- the data ----

prefs_apply() {
    info "Preferences (prefs.tsv, profiles: ${PROFILES}, macOS $(macos_full))"
    local domain key type value profiles min max host note major
    local nfail nskip result detail

    [ -f "$PREFS_FILE" ] || { record_fail "prefs.tsv" "not found at ${PREFS_FILE}"; return 1; }
    [ -s "$AUDIT_FILE" ] || \
        printf 'timestamp\tmacos\tdomain\tkey\tresult\tdetail\n' > "$AUDIT_FILE"
    major="$(macos_major)"

    if [ "${SETUP_DRY_RUN:-0}" != "1" ]; then
        # Updates are switched off while the defaults cache is rewritten,
        # then back on, to avoid the daemon racing these writes.
        sudo softwareupdate --schedule OFF >/dev/null 2>&1
    fi

    while IFS=$'\t' read -r domain key type value profiles min max host note; do
        case "$domain" in ''|\#*) continue ;; esac

        if ! profile_matches "$profiles" "$PROFILES"; then
            _log "PREFS filtered-profile $domain $key"
            audit_log "$domain" "$key" "filtered" "profile"
            continue
        fi
        if [ -n "${min:-}" ] && [ "$min" != "-" ] && [ "$major" -lt "$min" ]; then
            _log "PREFS filtered-version $domain $key (needs >= ${min})"
            audit_log "$domain" "$key" "filtered" "version<${min}"
            continue
        fi
        if [ -n "${max:-}" ] && [ "$max" != "-" ] && [ "$major" -gt "$max" ]; then
            _log "PREFS filtered-version $domain $key (last worked on ${max})"
            audit_log "$domain" "$key" "filtered" "version>${max}"
            continue
        fi

        value="${value//\{HOME\}/${HOME}}"
        value="${value//\{SCREENSHOTS_DIR\}/${SCREENSHOTS_DIR}}"

        if [ "${SETUP_DRY_RUN:-0}" = "1" ]; then
            _log "PREFS dry-run $domain $key $type $value"
            audit_log "$domain" "$key" "dry-run"
            continue
        fi

        nfail=${#FAIL[@]}; nskip=${#SKIP[@]}
        if [ "${host:-}" = "currentHost" ]; then
            defaults_write_verified "$domain" "$key" "$type" "$value" --currentHost
        else
            defaults_write_verified "$domain" "$key" "$type" "$value"
        fi

        result=pass; detail=""
        if [ "${#FAIL[@]}" -gt "$nfail" ]; then
            result=fail; detail="${FAIL[$((${#FAIL[@]} - 1))]}"
        elif [ "${#SKIP[@]}" -gt "$nskip" ]; then
            result=skip; detail="${SKIP[$((${#SKIP[@]} - 1))]}"
        fi
        audit_log "$domain" "$key" "$result" "$detail"
    done < "$PREFS_FILE"

    if [ "${SETUP_DRY_RUN:-0}" != "1" ]; then
        sudo softwareupdate --schedule ON >/dev/null 2>&1
    fi
}

# ------------------------------------------------------------- actions -----
# Everything here needs more than one defaults write, or none at all.

finder_actions() {
    info "Finder actions"
    [ "${SETUP_DRY_RUN:-0}" = "1" ] && { record_skip "finder actions" "dry run"; return 0; }

    # Snap-to-grid. PlistBuddy, not defaults, so it cannot be read back the
    # same way; failure is reported rather than assumed.
    local plist="${HOME}/Library/Preferences/com.apple.finder.plist"
    if /usr/libexec/PlistBuddy -c "Set :DesktopViewSettings:IconViewSettings:arrangeBy grid" "$plist" 2>/dev/null; then
        record_pass "desktop icon snap-to-grid"
        audit_log com.apple.finder IconViewSettings:arrangeBy pass
    else
        record_skip "desktop icon snap-to-grid" "PlistBuddy path not present yet"
        audit_log com.apple.finder IconViewSettings:arrangeBy skip "plist path absent"
    fi

    chflags nohidden "${HOME}/Library" 2>/dev/null && record_pass "~/Library visible" \
        || record_skip "~/Library visible" "chflags failed"
    sudo chflags nohidden /Volumes 2>/dev/null && record_pass "/Volumes visible" \
        || record_skip "/Volumes visible" "chflags failed"
}

time_actions() {
    info "Time"
    [ "${SETUP_DRY_RUN:-0}" = "1" ] && { record_skip "time actions" "dry run"; return 0; }
    sudo /usr/sbin/systemsetup -setusingnetworktime on >/dev/null 2>&1 \
        && record_pass "network time" || record_fail "network time" "systemsetup failed"
    sudo /usr/sbin/systemsetup -settimezone "$TIMEZONE" >/dev/null 2>&1 \
        && record_pass "timezone ${TIMEZONE}" || record_fail "timezone" "systemsetup failed"
}

misc_actions() {
    info "Power and Full Disk Access"
    [ "${SETUP_DRY_RUN:-0}" = "1" ] && { record_skip "power/Safari actions" "dry run"; return 0; }
    sudo pmset -a sms 0 >/dev/null 2>&1 \
        && record_pass "sudden motion sensor off" || record_skip "sudden motion sensor" "not applicable"

    # Safari is sandboxed; this domain is unreadable without Full Disk Access.
    if has_full_disk_access; then
        dw com.apple.Safari ShowFavoritesBar-v2 -bool true
    else
        record_skip "Safari favorites bar" "needs Full Disk Access for Terminal"
        record_note "Grant Terminal Full Disk Access (System Settings > Privacy & Security), then re-run defaults.sh"
    fi
}

firewall_prefs() {
    info "Firewall"
    [ "${SETUP_DRY_RUN:-0}" = "1" ] && { record_skip "firewall" "dry run"; return 0; }
    sudo "$FW" --setglobalstate on   >/dev/null 2>&1 \
        && record_pass "firewall on" || record_fail "firewall" "could not enable"
    sudo "$FW" --setstealthmode on   >/dev/null 2>&1 \
        && record_pass "stealth mode on" || record_fail "stealth mode" "could not enable"
    # install.sh adds the matching allow rule for the oMLX listener.
}

touchid_sudo() {
    local f=/etc/pam.d/sudo_local
    [ "${SETUP_DRY_RUN:-0}" = "1" ] && { record_skip "Touch ID for sudo" "dry run"; return 0; }
    if [ -f "$f" ] && grep -q '^auth.*pam_tid\.so' "$f"; then
        record_skip "Touch ID for sudo" "already configured"
        return 0
    fi
    if [ ! -f "${f}.template" ]; then
        record_skip "Touch ID for sudo" "no template on this macOS release"
        return 0
    fi
    if sudo cp "${f}.template" "$f" && sudo sed -i '' 's/^#auth/auth/' "$f" &&
       grep -q '^auth.*pam_tid\.so' "$f"; then
        record_pass "Touch ID for sudo"
    else
        record_fail "Touch ID for sudo" "could not edit ${f}"
    fi
}

# ---------------------------------------------------------------- main -----

main() {
    while [ $# -gt 0 ]; do
        case "$1" in
            --profile|--profiles)     PROFILES="${2:-}"; shift 2 ;;
            --profile=*|--profiles=*) PROFILES="${1#*=}"; shift ;;
            --help|-h)                usage; exit 0 ;;
            *) err "unknown option: $1"; usage; exit 1 ;;
        esac
    done

    info "setup-macos — defaults (macOS $(macos_full))"
    check_macos_version || exit 1
    PROFILES="$(resolve_profiles "$PROFILES")" || exit 1
    validate_profiles "$PROFILES" || exit 1
    [ "${SETUP_DRY_RUN:-0}" = "1" ] || osascript -e 'tell application "System Settings" to quit' 2>/dev/null
    if [ "${SETUP_DRY_RUN:-0}" != "1" ]; then
        require_sudo || { err "sudo required"; exit 1; }
    fi

    prefs_apply
    finder_actions
    time_actions
    misc_actions
    firewall_prefs
    touchid_sudo

    if [ "${SETUP_DRY_RUN:-0}" != "1" ]; then
        info "Restarting affected services"
        for p in cfprefsd SystemUIServer ControlCenter Finder Dock WindowManager; do
            killall "$p" 2>/dev/null
        done
    fi

    info "audit: ${AUDIT_FILE}"
    print_summary
}

# Sourced rather than executed? Provide the functions, run nothing — lets
# tests drive prefs_apply against a scratch HOME without touching this Mac.
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    main "$@"
fi
