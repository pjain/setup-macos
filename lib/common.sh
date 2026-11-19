#!/bin/bash
# Shared helpers for setup-macos.
#
# Targets /bin/bash, which is 3.2.57 on every Mac — a factory machine has no
# newer bash. `env bash` was avoided deliberately: it resolves to whatever is
# first on PATH, so a machine with Homebrew or MacPorts bash 5.x would run
# different code than a fresh one, which is how an empty-array bug survived
# testing here. Use no bash 4+ features, and guard empty array expansion.
# Sourced by bootstrap.sh, defaults.sh and install.sh.

[ -n "${_SETUP_MACOS_COMMON:-}" ] && return 0
_SETUP_MACOS_COMMON=1

set -o pipefail

# ---------------------------------------------------------------- paths ----

SETUP_ROOT="${SETUP_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
STATE_DIR="${SETUP_STATE_DIR:-${HOME}/.local/state/setup-macos}"
STATE_FILE="${STATE_DIR}/state"
LOG_FILE="${STATE_DIR}/run.log"
MANIFEST="${MANIFEST:-${SETUP_ROOT}/manifest.tsv}"
mkdir -p "$STATE_DIR"

# --------------------------------------------------------------- output ----

if [ -t 1 ]; then
    _R=$'\033[31m'; _G=$'\033[32m'; _Y=$'\033[33m'; _B=$'\033[34m'; _0=$'\033[0m'
else
    _R=; _G=; _Y=; _B=; _0=
fi

_stamp() { date '+%Y-%m-%d %H:%M:%S'; }
_log()   { printf '%s %s\n' "$(_stamp)" "$*" >> "$LOG_FILE"; }

# All human-readable output goes to stderr so that stdout stays clean for
# functions whose contract is to return a value (verify_artifact returns a
# Team ID). Only print_summary writes to stdout.
info() { printf '%s==>%s %s\n' "$_B" "$_0" "$*" >&2; _log "INFO  $*"; }
ok()   { printf '%s  ok%s %s\n' "$_G" "$_0" "$*" >&2; _log "OK    $*"; }
warn() { printf '%swarn%s %s\n' "$_Y" "$_0" "$*" >&2; _log "WARN  $*"; }
err()  { printf '%s ERR%s %s\n' "$_R" "$_0" "$*" >&2; _log "ERR   $*"; }

# ------------------------------------------------------------ results ------
# Every step records exactly one outcome. print_summary decides exit status.

PASS=(); FAIL=(); SKIP=(); NOTE=()

record_pass() { PASS+=("$1"); ok "$1"; }
record_skip() { SKIP+=("$1${2:+ — $2}"); printf '%sskip%s %s\n' "$_Y" "$_0" "$1${2:+ — $2}" >&2; _log "SKIP  $1 ${2:-}"; }
record_fail() { FAIL+=("$1${2:+ — $2}"); err "$1${2:+ — $2}"; }
record_note() { NOTE+=("$1"); _log "NOTE  $1"; }

print_summary() {
    printf '\n%s────────────── summary ──────────────%s\n' "$_B" "$_0"
    printf 'passed  %d\nskipped %d\nfailed  %d\n' "${#PASS[@]}" "${#SKIP[@]}" "${#FAIL[@]}"

    if [ "${#SKIP[@]}" -gt 0 ]; then
        printf '\n%sskipped:%s\n' "$_Y" "$_0"
        printf '  %s\n' "${SKIP[@]}"
    fi
    if [ "${#NOTE[@]}" -gt 0 ]; then
        printf '\n%smanual steps still required:%s\n' "$_Y" "$_0"
        printf '  %s\n' "${NOTE[@]}"
    fi
    if [ "${#FAIL[@]}" -gt 0 ]; then
        printf '\n%sfailed:%s\n' "$_R" "$_0"
        printf '  %s\n' "${FAIL[@]}"
        printf '\nlog: %s\n' "$LOG_FILE"
        return 1
    fi
    printf '\nlog: %s\n' "$LOG_FILE"
    return 0
}

# --------------------------------------------------------------- state ----
# Phase completion survives reboots so the run can resume.

phase_done()     { grep -qxF "$1" "$STATE_FILE" 2>/dev/null; }
mark_phase_done(){ phase_done "$1" || echo "$1" >> "$STATE_FILE"; }
reset_state()    { rm -f "$STATE_FILE"; }

# ----------------------------------------------------------------- lock ----
# One run at a time. The log evidence: a manual install.sh and the resume
# agent's bootstrap running interleaved, each with its own sudo timestamp
# keeper — installs failing with nothing to explain them. The lock is a
# directory; its owner pid decides live vs stale. Child scripts launched by
# bootstrap inherit SETUP_LOCK_HELD instead of deadlocking on their parent.

RUN_LOCK="${STATE_DIR}/run.lock"
acquire_run_lock() {
    local owner pid rest
    [ "${SETUP_LOCK_HELD:-}" = 1 ] && return 0   # child of a locked parent
    owner="$(basename "${BASH_SOURCE[1]:-$0}")"
    if ! mkdir "$RUN_LOCK" 2>/dev/null; then
        read -r pid rest < "${RUN_LOCK}/owner" 2>/dev/null || true
        if [ -n "${pid:-}" ] && kill -0 "$pid" 2>/dev/null; then
            err "another setup-macos run is in progress (pid ${pid}${rest:+: $rest})"
            err "wait for it to finish, or remove ${RUN_LOCK} if that process is gone"
            return 1
        fi
        warn "stale lock from pid ${pid:-unknown}; taking over"
        rm -rf "$RUN_LOCK"
        mkdir "$RUN_LOCK" || return 1
    fi
    printf '%s %s\n' "$$" "$owner" > "${RUN_LOCK}/owner"
    export SETUP_LOCK_HELD=1
    # rm -rf, not rmdir: the directory holds the owner file and would
    # otherwise never be removable, leaving a stale lock after every run.
    trap 'rm -rf "${RUN_LOCK}"' EXIT INT TERM
}

# -------------------------------------------------------------- macOS ----

macos_major() { sw_vers -productVersion | cut -d. -f1; }
macos_full()  { sw_vers -productVersion; }

# Highest major version this repo has been exercised against. Newer releases
# are allowed through with a warning rather than blocked: the defaults layer
# verifies each write individually, so an unknown version degrades to
# "reports what no longer works" instead of failing outright.
MACOS_KNOWN_MAX=26

check_macos_version() {
    local major; major="$(macos_major)"
    if [ "$major" -lt 15 ]; then
        err "macOS $(macos_full) is older than this repo supports (15+)."
        return 1
    elif [ "$major" -gt "$MACOS_KNOWN_MAX" ]; then
        warn "macOS $(macos_full) is newer than this repo has been tested against (${MACOS_KNOWN_MAX}.x)."
        warn "Preferences are verified individually; anything Apple removed is reported, not silently skipped."
        record_note "Untested on macOS ${major}. Review the skipped list above."
    fi
    return 0
}

# Full Disk Access is required for a handful of sandboxed domains (Safari in
# particular). Detect rather than assume, so the summary can explain a skip.
has_full_disk_access() {
    [ -r "${HOME}/Library/Safari/Bookmarks.plist" ] 2>/dev/null && return 0
    /usr/bin/sqlite3 "${HOME}/Library/Safari/History.db" '.tables' >/dev/null 2>&1
}

require_sudo() {
    sudo -n true 2>/dev/null && return 0
    info "Administrator password required."
    sudo -v || return 1
    # Keep the timestamp warm for the length of the run.
    while true; do sudo -n true; sleep 60; kill -0 "$$" 2>/dev/null || exit; done 2>/dev/null &
}

# =========================================================================
# Signature verification
#
# Packages are fetched straight from the vendor, then checked two ways:
#   1. Gatekeeper must report the artifact as notarized by Apple.
#   2. The signing Team ID must equal the value pinned in manifest.tsv.
#
# Both must pass. Forging an artifact would require the vendor's own
# Developer ID certificate, which is what makes this stronger than either a
# bare curl (no check at all) or a package manager acting as middleman.
# =========================================================================

# Team ID out of an .app bundle.
sig_team_app() {
    codesign -dv --verbose=2 "$1" 2>&1 | sed -n 's/^TeamIdentifier=//p' | head -1
}

# Team ID out of an installer package's certificate chain.
sig_team_pkg() {
    pkgutil --check-signature "$1" 2>/dev/null \
        | sed -n 's/.*Developer ID Installer: .*(\([A-Z0-9]\{10\}\)).*/\1/p' | head -1
}

# Gatekeeper acceptance. kind is "exec" (app) or "install" (pkg).
sig_notarized() {
    local path="$1" kind="$2" out
    out="$(spctl -a -vv -t "$kind" "$path" 2>&1)" || return 1
    printf '%s' "$out" | grep -q 'source=Notarized Developer ID'
}

# verify_artifact <path> <exec|install> <expected_team|-> [label]
# Prints the observed Team ID on success. Empty pin ("-") still requires
# notarization but cannot detect a vendor swap, so it is reported loudly.
# The optional label names the manifest entry; without it packages show up
# under their temp-dir name ("download"), which helped nobody reading a log.
verify_artifact() {
    local path="$1" kind="$2" want="$3" label="${4:-$(basename "$1")}" got

    if ! sig_notarized "$path" "$kind"; then
        err "notarization check FAILED for ${label}"
        err "  $(spctl -a -vv -t "$kind" "$path" 2>&1 | head -2 | tr '\n' ' ')"
        return 1
    fi

    if [ "$kind" = install ]; then got="$(sig_team_pkg "$path")"; else got="$(sig_team_app "$path")"; fi

    if [ -z "$got" ]; then
        err "could not read Team ID from ${label}"
        return 1
    fi

    if [ "$want" = "-" ] || [ -z "$want" ]; then
        warn "Team ID not pinned for ${label} — observed ${got}"
        record_note "Pin Team ID ${got} for ${label} in manifest.tsv"
        printf '%s' "$got"; return 0
    fi

    if [ "$got" != "$want" ]; then
        err "Team ID MISMATCH for ${label}: expected ${want}, got ${got}"
        err "  refusing to install — this may indicate a compromised download"
        return 1
    fi

    printf '%s' "$got"; return 0
}

# A disk image mounted inside the work directory must be detached before the
# directory is removed. Deleting the mountpoint directly makes rm descend into
# the mounted volume — harmless on a read-only image beyond a flood of errors,
# but it would delete real data on a writable one, and it leaves the image
# attached either way.
cleanup_workdir() {
    local dir="$1"
    [ -n "$dir" ] || return 0
    if is_mounted "${dir}/mnt"; then
        hdiutil detach "${dir}/mnt" -force -quiet 2>/dev/null
    fi
    # Refuse to delete while anything is still mounted underneath, whatever
    # the reason — rm would otherwise descend into the mounted volume.
    if is_mounted "${dir}/mnt"; then
        warn "volume still mounted at ${dir}/mnt; leaving ${dir} in place"
        warn "detach it with: hdiutil detach '${dir}/mnt' -force"
        return 0
    fi
    rm -rf "$dir"
}

# is_mounted <path> — true when <path> is a mount point.
#
# Compares the device id of the directory with its parent's rather than
# matching text from `mount`: mktemp yields /var/folders/... while mount
# reports /private/var/folders/..., so a string comparison silently never
# matches. That mismatch is what let a mounted image reach `rm -rf`.
is_mounted() {
    local d="$1" dev_d dev_p
    [ -d "$d" ] || return 1
    dev_d="$(stat -f %d "$d" 2>/dev/null)" || return 1
    dev_p="$(stat -f %d "$(dirname "$d")" 2>/dev/null)" || return 1
    [ "$dev_d" != "$dev_p" ]
}

# bundle_sane <dest> — an installed application must be a *complete*
# application: readable Info.plist naming its executable, and that binary
# present. Existence alone lies — a ditto interrupted by disk pressure or a
# killed run leaves partial bundles that a later pass would otherwise
# report as "already installed". Non-bundle destinations (framework dirs,
# /opt/miniconda3) can only be checked for existence.
bundle_sane() {
    local dest="$1" plist exe
    case "$dest" in
    *.app)
        plist="${dest%/}/Contents/Info.plist"
        [ -f "$plist" ] || return 1
        plutil -lint "$plist" >/dev/null 2>&1 || return 1
        exe="$(plutil -extract CFBundleExecutable raw "$plist" 2>/dev/null)"
        [ -n "$exe" ] && [ -x "${dest%/}/Contents/MacOS/${exe}" ]
        ;;
    *) [ -e "$dest" ] ;;
    esac
}

# =========================================================================
# install_verified <name> <method> <dest> <team_id> <url>
#   method: pkg | dmg | zip
#   dest:   absolute path used both as the idempotency check and, for
#           dmg/zip, the install destination
# =========================================================================
install_verified() {
    local name="$1" method="$2" dest="$3" team="$4" url="$5"
    local tmp file mnt app

    case "$method" in
    npm)
        if npm ls -g --depth=0 "$dest" >/dev/null 2>&1; then
            record_skip "$name" "already installed"; return 0
        fi ;;
    pip)
        if python3 -m pip show "$dest" >/dev/null 2>&1; then
            record_skip "$name" "already installed"; return 0
        fi ;;
    *)
        if [ -e "$dest" ]; then
            if bundle_sane "$dest"; then
                record_skip "$name" "already installed"; return 0
            fi
            # Partial bundle from an interrupted earlier run: only .app
            # bundles are safe to delete; other destinations (frameworks,
            # package roots) are left in place and re-run through anyway.
            record_note "${name}: ${dest} exists but is incomplete — replacing"
            case "$dest" in
                *.app) rm -rf "${dest:?}" ;;
            esac
        fi ;;
    esac

    tmp="$(mktemp -d "${TMPDIR:-/tmp}/setup-macos.XXXXXX")" || {
        record_fail "$name" "could not create temp dir"; return 1; }
    # shellcheck disable=SC2064
    trap "cleanup_workdir '$tmp'" RETURN

    if [ "$method" = manual ]; then
        record_note "${name}: install by hand from ${url}"
        record_skip "$name" "no scriptable download; see manual steps"
        return 0
    fi

    # SETUP_DRY_RUN=1 resolves and reports what would happen without
    # downloading or installing anything. Used to exercise the manifest.
    case "$method" in
    npm)
        if [ "${SETUP_DRY_RUN:-0}" = "1" ]; then
            record_skip "$name" "dry run — would npm install -g ${url}"; return 0
        fi
        if ! command -v npm >/dev/null 2>&1; then
            record_skip "$name" "npm not available"
            record_note "${name}: needs Node.js; re-run install.sh after Node is set up"
            return 0
        fi
        if npm install -g "$url" >/dev/null 2>&1; then
            record_pass "$name"
        else
            record_fail "$name" "npm install -g ${url} failed"
        fi
        return 0 ;;
    pip)
        if [ "${SETUP_DRY_RUN:-0}" = "1" ]; then
            record_skip "$name" "dry run — would pip install ${url}"; return 0
        fi
        if ! command -v python3 >/dev/null 2>&1; then
            record_skip "$name" "python3 not available"; return 0
        fi
        if python3 -m pip install --upgrade "$url" >/dev/null 2>&1; then
            record_pass "$name"
        else
            record_fail "$name" "pip install ${url} failed"
        fi
        return 0 ;;
    mas)
        # VMs cannot sign in to an Apple ID, and no headless sign-in path
        # exists; --no-app-store on bootstrap (or the env var directly)
        # turns these into deliberate skips instead of brew + guaranteed
        # mas failures.
        if [ "${SETUP_SKIP_APP_STORE:-0}" = "1" ]; then
            record_skip "$name" "App Store installs disabled (SETUP_SKIP_APP_STORE)"
            return 0
        fi
        # App Store titles cannot be fetched from a vendor URL, and mas is a
        # Homebrew formula that this repo deliberately does not depend on.
        if [ "${SETUP_DRY_RUN:-0}" = "1" ]; then
            record_skip "$name" "dry run — would mas install ${url}"; return 0
        fi
        if ! command -v mas >/dev/null 2>&1; then
            record_skip "$name" "mas not installed"
            record_note "${name}: install from the Mac App Store by hand (id ${url})"
            return 0
        fi
        if mas install "$url" >/dev/null 2>&1; then
            record_pass "$name"
        else
            record_fail "$name" "mas install ${url} failed (App Store sign-in required?)"
        fi
        return 0 ;;
    esac

    if [ "${SETUP_DRY_RUN:-0}" = "1" ]; then
        record_skip "$name" "dry run — would ${method} from ${url%%\?*}"
        return 0
    fi

    info "$name — downloading"
    file="${tmp}/download"
    if ! curl -fsSL --retry 3 --retry-delay 2 -o "$file" "$url"; then
        record_fail "$name" "download failed"
        return 1
    fi

    case "$method" in
    pkg)
        if ! verify_artifact "$file" install "$team" "$name" >/dev/null; then
            record_fail "$name" "signature verification failed"; return 1
        fi
        local ierr rc
        # installer reports progress AND errors on stdout — both must be
        # captured, or failures arrive with nothing to show.
        ierr="$(sudo installer -pkg "$file" -target / 2>&1)"; rc=$?
        _log "INSTALLER-OUT $name: $(printf '%s' "$ierr" | tr '\n' ' ')"
        if [ $rc -ne 0 ]; then
            record_fail "$name" "installer failed (rc ${rc}): $(printf '%s' "${ierr:-no output from installer}" | tr '\n' ' ' | tail -c 200)"
            return 1
        fi
        ;;
    dmg|zip)
        mnt="${tmp}/mnt"; mkdir -p "$mnt"
        if [ "$method" = dmg ]; then
            # Mount at a fixed point so volume names never need hardcoding —
            # the single largest source of breakage in the old script.
            #
            # hdiutil's exit status is not reliable here: it can report failure
            # on an image that mounted perfectly well. Check the mount table
            # instead, otherwise a successful mount is treated as an error and
            # left attached.
            hdiutil attach -nobrowse -readonly -noautoopen -noverify \
                -mountpoint "$mnt" "$file" >/dev/null 2>&1 </dev/null
            if ! is_mounted "$mnt"; then
                record_fail "$name" "could not mount disk image"; return 1
            fi
        else
            if ! ditto -x -k "$file" "$mnt" >/dev/null 2>&1; then
                record_fail "$name" "could not expand archive"; return 1
            fi
        fi

        app="$(find "$mnt" -maxdepth 2 -name '*.app' -print -quit 2>/dev/null)"
        if [ -z "$app" ]; then
            [ "$method" = dmg ] && hdiutil detach "$mnt" -quiet 2>/dev/null
            record_fail "$name" "no .app found in archive"; return 1
        fi

        if ! verify_artifact "$app" exec "$team" "$name" >/dev/null; then
            [ "$method" = dmg ] && hdiutil detach "$mnt" -quiet 2>/dev/null
            record_fail "$name" "signature verification failed"; return 1
        fi

        if ! ditto "$app" "$dest"; then
            [ "$method" = dmg ] && hdiutil detach "$mnt" -quiet 2>/dev/null
            record_fail "$name" "copy to ${dest} failed"; return 1
        fi
        [ "$method" = dmg ] && hdiutil detach "$mnt" -quiet 2>/dev/null
        # Downloads carry no quarantine flag, but strip defensively.
        xattr -dr com.apple.quarantine "$dest" 2>/dev/null
        ;;
    dmgpkg)
        # Disk image whose payload is an installer package (Google Drive).
        mnt="${tmp}/mnt"; mkdir -p "$mnt"
        hdiutil attach -nobrowse -readonly -noautoopen -noverify \
            -mountpoint "$mnt" "$file" >/dev/null 2>&1 </dev/null
        if ! is_mounted "$mnt"; then
            record_fail "$name" "could not mount disk image"; return 1
        fi
        local pkg
        pkg="$(find "$mnt" -maxdepth 2 -name '*.pkg' -print -quit 2>/dev/null)"
        if [ -z "$pkg" ]; then
            hdiutil detach "$mnt" -quiet 2>/dev/null
            record_fail "$name" "no .pkg found in disk image"; return 1
        fi
        if ! verify_artifact "$pkg" install "$team" "$name" >/dev/null; then
            hdiutil detach "$mnt" -quiet 2>/dev/null
            record_fail "$name" "signature verification failed"; return 1
        fi
        local perr prc
        perr="$(sudo installer -pkg "$pkg" -target / 2>&1)"; prc=$?
        hdiutil detach "$mnt" -quiet 2>/dev/null
        _log "INSTALLER-OUT $name: $(printf '%s' "$perr" | tr '\n' ' ')"
        if [ $prc -ne 0 ]; then
            record_fail "$name" "installer failed (rc ${prc}): $(printf '%s' "${perr:-no output from installer}" | tr '\n' ' ' | tail -c 200)"
            return 1
        fi
        ;;
    manual)
        # No scriptable download exists. Reported rather than silently dropped.
        record_note "${name}: install by hand from ${url}"
        record_skip "$name" "no scriptable download; see manual steps"
        return 0
        ;;
    *)
        record_fail "$name" "unknown install method '${method}'"; return 1 ;;
    esac

    # Confirmation, not assertion: the summary may only claim an install if
    # the artifact is genuinely in place and complete, with the installed
    # version as evidence. Anything else is reported as a failure even if
    # every command above succeeded.
    local cver
    cver="$(installed_version "$dest" 2>/dev/null)" || true
    [ "${cver:-unknown}" = "unknown" ] && cver=""
    if bundle_sane "$dest"; then
        record_pass "${name}${cver:+ $cver}"
    else
        record_fail "$name" "post-install check: ${dest} missing or incomplete after install"
        return 1
    fi
}

# =========================================================================
# Versions
#
# Comparison is best-effort numeric (sort -V): it answers "is X newer than Y"
# for dotted-numeric versions and honestly reports "unknown" for anything
# else, rather than guessing. Unknown must never trigger an automated
# upgrade — it is only ever reported to a human.
# =========================================================================

# version_newer <a> <b> — succeeds when a is strictly newer than b.
# Also sets V_STATUS to newer|older|same|unknown for the caller to branch on.
version_newer() {
    local a="${1#v}" b="${2#v}" first
    V_STATUS=unknown
    [ -n "$a" ] && [ -n "$b" ] || return 1
    if [ "$a" = "$b" ]; then V_STATUS=same; return 1; fi
    case "$a" in *[!0-9.]*|'') return 1 ;; esac
    case "$b" in *[!0-9.]*|'') return 1 ;; esac
    first="$(printf '%s\n%s\n' "$a" "$b" | sort -V | head -1)"
    if [ "$first" = "$b" ]; then V_STATUS=newer; return 0
    else V_STATUS=older; return 1; fi
}

# installed_version <dest> — CFBundleShortVersionString of an .app bundle,
# falling back to CFBundleVersion; "unknown" when neither can be read.
installed_version() {
    local plist v
    case "$1" in
        *.app) plist="${1%/}/Contents/Info.plist" ;;
        *)     plist="${1%/}/Contents/Info.plist" ;;
    esac
    [ -f "$plist" ] || { printf 'unknown'; return 1; }
    v="$(plutil -extract CFBundleShortVersionString raw "$plist" 2>/dev/null)"
    [ -n "$v" ] || v="$(plutil -extract CFBundleVersion raw "$plist" 2>/dev/null)"
    [ -n "$v" ] || { printf 'unknown'; return 1; }
    printf '%s' "$v"
}

# =========================================================================
# Preferences
#
# Writes are verified by reading the value back rather than by probing for
# the key beforehand. On a fresh Mac almost none of these keys exist yet, so
# a pre-write probe would skip everything. Read-back instead proves the
# write actually took effect, which is what makes an unknown macOS release
# degrade into "reports what no longer works" rather than failing silently.
# =========================================================================

# defaults_write_verified <domain> <key> <type> <value> [--currentHost]
defaults_write_verified() {
    local domain="$1" key="$2" type="$3" value="$4" host_flag="${5:-}"
    local want got pfx=() hostarg=()
    local label="${domain##*/} ${key}"

    # Domains under /Library are system-wide and need elevation.
    case "$domain" in /*) pfx=(sudo) ;; esac
    [ "$host_flag" = "--currentHost" ] && hostarg=(-currentHost)

    # macOS ships bash 3.2, where "${empty[@]}" under `set -u` aborts with
    # "unbound variable". The ${a[@]+"${a[@]}"} guard expands to nothing
    # instead. Do not simplify these without testing on /bin/bash.
    if ! ${pfx[@]+"${pfx[@]}"} defaults ${hostarg[@]+"${hostarg[@]}"} write "$domain" "$key" "$type" "$value" 2>/dev/null; then
        record_fail "$label" "write rejected"
        return 1
    fi

    got="$(${pfx[@]+"${pfx[@]}"} defaults ${hostarg[@]+"${hostarg[@]}"} read "$domain" "$key" 2>/dev/null)"
    case "$type" in
        -bool) case "$value" in true|TRUE|YES|yes|1) want=1 ;; *) want=0 ;; esac ;;
        -array) # defaults read renders arrays as "(\n    4\n)" — strip the
                # framing so it can be compared against the written value.
                want="$(printf '%s' "$value" | tr -d '  \n(),')"
                got="$(printf '%s' "$got" | tr -d '  \n(),')" ;;
        *)     want="$value" ;;
    esac

    if [ "$got" != "$want" ]; then
        # Most likely: Apple removed or renamed the key in this macOS release,
        # or the domain is sandboxed and needs Full Disk Access.
        record_skip "$label" "wrote '${want}' but read back '${got:-<nothing>}'"
        return 1
    fi
    PASS+=("$label")
    return 0
}

# =========================================================================
# Application firewall
#
# defaults.sh turns the firewall and stealth mode on, which blocks inbound
# connections to anything not explicitly allowed. oMLX is asked to listen on
# 0.0.0.0, so its listener needs a rule. The rule targets a binary inside
# ~/.omlx/bin rather than an .app bundle, so an oMLX upgrade that replaces
# that binary can invalidate it — hence this is re-run every invocation.
# =========================================================================
FW=/usr/libexec/ApplicationFirewall/socketfilterfw

fw_allow() {
    local path="$1" label="${2:-$(basename "$1")}"
    if [ "${SETUP_DRY_RUN:-0}" = "1" ]; then
        record_skip "firewall allow ${label}" "dry run — would add rule"
        return 0
    fi
    if [ ! -e "$path" ]; then
        record_skip "firewall allow ${label}" "not installed"
        return 1
    fi
    if sudo "$FW" --add "$path" >/dev/null 2>&1 &&
       sudo "$FW" --unblockapp "$path" >/dev/null 2>&1; then
        record_pass "firewall allow ${label}"
    else
        record_fail "firewall allow ${label}" "socketfilterfw rejected the rule"
        return 1
    fi
}

# =========================================================================
# Profiles
#
# Each manifest entry lists the profiles it belongs to. A machine can select
# several; an entry is installed if it appears in any selected profile.
# =========================================================================

KNOWN_PROFILES="dev ai desktop"
PROFILE_FILE="${STATE_DIR}/profiles"

profile_matches() {
    local entry="$1" selected="$2" p
    IFS=',' read -ra _want <<< "$selected"
    for p in ${_want[@]+"${_want[@]}"}; do
        [ -z "$p" ] && continue
        case ",${entry}," in *",${p},"*) return 0 ;; esac
    done
    return 1
}

validate_profiles() {
    local selected="$1" p bad=0
    IFS=',' read -ra _sel <<< "$selected"
    for p in ${_sel[@]+"${_sel[@]}"}; do
        [ -z "$p" ] && continue
        case " ${KNOWN_PROFILES} " in
            *" ${p} "*) ;;
            *) err "unknown profile: ${p}"; bad=1 ;;
        esac
    done
    [ "$bad" -eq 0 ] || { err "valid profiles: ${KNOWN_PROFILES}"; return 1; }
}

# list_profiles — human-readable inventory of the manifest, per profile.
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

# resolve_profiles <current-selection> — echoes the effective selection.
# Order of precedence: an explicit argument (--profile), $SETUP_PROFILES, a
# previous saved choice, then an interactive prompt. Non-interactive runs
# with no prior choice fail rather than guessing at what a machine is for.
resolve_profiles() {
    local selected="${1:-}" p
    [ -n "$selected" ] && { printf '%s' "$selected"; return 0; }
    if [ -n "${SETUP_PROFILES:-}" ]; then printf '%s' "$SETUP_PROFILES"; return 0; fi
    if [ -s "$PROFILE_FILE" ]; then
        info "using saved profiles: $(cat "$PROFILE_FILE")"
        cat "$PROFILE_FILE"
        return 0
    fi
    if [ ! -t 0 ]; then
        err "no profile selected and stdin is not a terminal"
        err "pass --profile ${KNOWN_PROFILES// /,} or set SETUP_PROFILES"
        return 1
    fi
    printf '\nAvailable profiles: %s\n' "$KNOWN_PROFILES" >&2
    printf 'Select one or more, comma-separated: ' >&2
    read -r p
    [ -n "$p" ] || { err "no profile selected"; return 1; }
    printf '%s' "$p"
}
