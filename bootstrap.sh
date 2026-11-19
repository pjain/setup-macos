#!/bin/bash
#
# setup-macos entry point.
#
#   curl -fsSL https://raw.githubusercontent.com/pjain/setup-macos/main/bootstrap.sh | bash
#
# The repository is public, so nothing here needs a credential. Phases are
# recorded as they complete and a LaunchAgent re-invokes this script after a
# reboot, so the run resumes instead of starting over.

set -uo pipefail

REPO_TARBALL="https://github.com/pjain/setup-macos/archive/refs/heads/main.tar.gz"
DEST="${HOME}/projects/setup-macos"
AGENT_LABEL="com.pjain.setup-macos"
AGENT_PLIST="${HOME}/Library/LaunchAgents/${AGENT_LABEL}.plist"

# ------------------------------------------------------------- locate -----
# When piped from curl there is no local checkout yet, so fetch one first and
# hand off to it. Uses a tarball rather than git, because git on a factory Mac
# is a stub that triggers the Command Line Tools prompt.

local_root() {
    local dir
    dir="$(cd "$(dirname "${BASH_SOURCE[0]:-/nonexistent}")" 2>/dev/null && pwd)" || return 1
    [ -f "${dir}/manifest.tsv" ] && printf '%s' "$dir"
}

fetch_repo() {
    printf '==> fetching setup-macos\n'
    mkdir -p "$(dirname "$DEST")"
    local tmp; tmp="$(mktemp -d)"
    if ! curl -fsSL --retry 3 "$REPO_TARBALL" | tar xz -C "$tmp" --strip-components=1; then
        printf 'ERR could not download the repository\n' >&2
        exit 1
    fi
    mkdir -p "$DEST"
    ditto "$tmp" "$DEST"
    rm -rf "$tmp"
    chmod +x "${DEST}"/*.sh 2>/dev/null
    printf '  ok fetched to %s\n' "$DEST"
}

ROOT="$(local_root || true)"
if [ -z "$ROOT" ]; then
    fetch_repo
    exec /bin/bash "${DEST}/bootstrap.sh" "$@"
fi

SETUP_ROOT="$ROOT"
# shellcheck source=lib/common.sh
source "${SETUP_ROOT}/lib/common.sh"

# -------------------------------------------------------- resume agent ----

install_resume_agent() {
    mkdir -p "$(dirname "$AGENT_PLIST")"
    cat > "$AGENT_PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key><string>${AGENT_LABEL}</string>
    <key>ProgramArguments</key>
    <array>
        <string>/bin/bash</string>
        <string>${SETUP_ROOT}/bootstrap.sh</string>
    </array>
    <key>RunAtLoad</key><true/>
    <key>StandardOutPath</key><string>${STATE_DIR}/resume.log</string>
    <key>StandardErrorPath</key><string>${STATE_DIR}/resume.log</string>
</dict>
</plist>
PLIST
    launchctl unload "$AGENT_PLIST" 2>/dev/null
    launchctl load "$AGENT_PLIST" 2>/dev/null
}

remove_resume_agent() {
    [ -f "$AGENT_PLIST" ] || return 0
    launchctl unload "$AGENT_PLIST" 2>/dev/null
    rm -f "$AGENT_PLIST"
}

# ------------------------------------------------------------- phases -----

# The tools are present if either the installer receipt exists or a full
# Xcode provides them. A bare `xcode-select -p` is not sufficient: it can
# report a stale developer directory.
clt_present() {
    pkgutil --pkg-info=com.apple.pkg.CLTools_Executables >/dev/null 2>&1 && return 0
    local dir
    dir="$(xcode-select -p 2>/dev/null)" || return 1
    [ -n "$dir" ] && [ -d "$dir" ] && [ -x /usr/bin/git ]
}

phase_clt() {
    if clt_present; then
        record_skip "Command Line Tools" "already installed"
        return 0
    fi

    info "Installing Command Line Tools (this can take several minutes)"
    # This placeholder makes the tools visible to softwareupdate, which
    # allows a headless install instead of the GUI prompt.
    local flag=/tmp/.com.apple.dt.CommandLineTools.installondemand.in-progress
    sudo touch "$flag"

    local prod
    prod="$(softwareupdate -l 2>/dev/null | grep -oE 'Command Line Tools for Xcode-[0-9.]+' | tail -1)"
    if [ -n "$prod" ]; then
        sudo softwareupdate -i "$prod" >/dev/null 2>&1
        sudo rm -f "$flag"
    else
        sudo rm -f "$flag"
        # No headless product available: fall back to the GUI installer,
        # which returns immediately while the dialog is still open. Waiting
        # here is the difference between resuming correctly and reporting a
        # false failure.
        xcode-select --install >/dev/null 2>&1
        info "Complete the Command Line Tools dialog when it appears."
        local waited=0 limit=1800
        while [ "$waited" -lt "$limit" ]; do
            clt_present && break
            sleep 15
            waited=$((waited + 15))
            [ $((waited % 120)) -eq 0 ] && info "still waiting for Command Line Tools (${waited}s)"
        done
    fi

    if clt_present; then
        record_pass "Command Line Tools"
    else
        record_fail "Command Line Tools" "not present after install attempt"
        return 1
    fi
}

phase_defaults() { bash "${SETUP_ROOT}/defaults.sh"; }
phase_install()  {
    if [ -n "${PROFILES:-}" ]; then
        bash "${SETUP_ROOT}/install.sh" --profile "$PROFILES"
    else
        bash "${SETUP_ROOT}/install.sh"
    fi
}

phase_shell() {
    local src dst name
    for name in zshrc profile; do
        src="${SETUP_ROOT}/shell/${name}"
        dst="${HOME}/.${name}"
        [ -f "$src" ] || { record_fail "shell/${name}" "missing from repo"; continue; }
        if [ -e "$dst" ] && [ ! -L "$dst" ]; then
            record_skip ".${name}" "existing file left untouched"
            continue
        fi
        ln -sfn "$src" "$dst" && record_pass ".${name} -> ${src}"
    done
    # Machine-local secrets live outside the repo.
    if [ ! -f "${HOME}/.zshrc.local" ]; then
        printf '# Machine-local settings and credentials. Never committed.\n' > "${HOME}/.zshrc.local"
        record_pass "~/.zshrc.local created"
        record_note "Put credentials in ~/.zshrc.local — it is git-ignored by design"
    fi
}

phase_github() {
    if ! command -v gh >/dev/null 2>&1; then
        record_skip "GitHub CLI" "gh not installed"
        record_note "Install gh, then re-run bootstrap.sh to finish SSH key setup"
        return 0
    fi
    if gh auth status >/dev/null 2>&1; then
        record_skip "GitHub auth" "already signed in"
    else
        info "Signing in to GitHub (a browser will open)"
        gh auth login --hostname github.com --git-protocol ssh --web || {
            record_fail "GitHub auth" "gh auth login did not complete"; return 1; }
        record_pass "GitHub auth"
    fi

    local key="${HOME}/.ssh/id_ed25519"
    if [ ! -f "$key" ]; then
        ssh-keygen -t ed25519 -N '' -f "$key" -C "$(whoami)@$(hostname -s)" >/dev/null 2>&1 \
            && record_pass "SSH key generated" || { record_fail "SSH key" "ssh-keygen failed"; return 1; }
    else
        record_skip "SSH key" "already exists"
    fi

    if gh ssh-key list 2>/dev/null | grep -q "$(awk '{print $2}' "${key}.pub" 2>/dev/null)"; then
        record_skip "SSH key upload" "already on GitHub"
    elif gh ssh-key add "${key}.pub" --title "$(hostname -s)" >/dev/null 2>&1; then
        record_pass "SSH key uploaded to GitHub"
    else
        record_fail "SSH key upload" "gh ssh-key add failed"
    fi
}

# -------------------------------------------------------------- main -----

run_phase() {
    local name="$1" fn="$2"
    if phase_done "$name"; then
        record_skip "phase ${name}" "already completed"
        return 0
    fi
    info "── phase: ${name}"
    if "$fn"; then
        mark_phase_done "$name"
    else
        warn "phase ${name} did not complete cleanly; it will be retried on the next run"
    fi
}

main() {
    PROFILES=""
    while [ $# -gt 0 ]; do
        case "$1" in
            --reset) reset_state; remove_resume_agent; info "state cleared"; exit 0 ;;
            --status)
                printf 'completed phases:\n'; cat "$STATE_FILE" 2>/dev/null || printf '  none\n'
                printf 'profiles: %s\n' "$(cat "${STATE_DIR}/profiles" 2>/dev/null || printf 'not yet selected')"
                exit 0 ;;
            --profile|--profiles)   PROFILES="${2:-}"; shift 2 ;;
            --profile=*|--profiles=*) PROFILES="${1#*=}"; shift ;;
            --no-app-store) export SETUP_SKIP_APP_STORE=1; shift ;;
            --help|-h)
                printf 'Usage: bootstrap.sh [--profile dev,ai,desktop] [--no-app-store] [--status] [--reset]\n'
                printf '  --no-app-store  skip Mac App Store titles entirely (VMs cannot sign in);\n'
                printf '                  they report as skips, and Homebrew is never installed\n'; exit 0 ;;
            *) err "unknown option: $1"; exit 1 ;;
        esac
    done

    # The profile choice must survive a reboot, since the resume agent
    # re-invokes this script with no arguments. Resolving it once here means
    # every phase — defaults included — sees the same selection.
    PROFILES="$(resolve_profiles "$PROFILES")" || exit 1
    validate_profiles "$PROFILES" || exit 1
    printf '%s' "$PROFILES" > "${STATE_DIR}/profiles"

    info "setup-macos on macOS $(macos_full)"
    acquire_run_lock || exit 1
    check_macos_version || exit 1
    require_sudo || { err "sudo required"; exit 1; }
    install_resume_agent

    run_phase clt      phase_clt
    run_phase defaults phase_defaults
    run_phase install  phase_install
    run_phase shell    phase_shell
    run_phase github   phase_github

    if [ "${#FAIL[@]}" -eq 0 ]; then
        remove_resume_agent
        info "All phases complete; resume agent removed."
    else
        warn "Some steps failed. Re-run bootstrap.sh to retry only those phases."
    fi

    print_summary
}

main "$@"
