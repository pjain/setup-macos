#!/bin/bash
#
# System preferences. Every `defaults` write is read back to confirm it took
# effect, so a key Apple removed in a newer macOS is reported rather than
# silently ignored.

set -uo pipefail
SETUP_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SETUP_ROOT}/lib/common.sh"

dw()  { defaults_write_verified "$@"; }
dwh() { defaults_write_verified "$1" "$2" "$3" "$4" --currentHost; }

# ------------------------------------------------------------- Finder -----

finder_prefs() {
    info "Finder"
    dw com.apple.finder ShowExternalHardDrivesOnDesktop -bool true
    dw com.apple.finder ShowHardDrivesOnDesktop         -bool true
    dw com.apple.finder ShowMountedServersOnDesktop     -bool true
    dw com.apple.finder ShowRemovableMediaOnDesktop     -bool true
    dw com.apple.finder AppleShowAllFiles               -bool true
    dw com.apple.finder ShowStatusBar                   -bool true
    dw com.apple.finder ShowPathbar                     -bool true
    dw com.apple.finder FXEnableExtensionChangeWarning  -bool false
    dw com.apple.finder NewWindowTarget                 -string "PfHm"
    dw com.apple.finder FXPreferredViewStyle            -string "Nlsv"
    dw com.apple.finder OpenWindowForNewRemovableDisk   -bool true
    dw com.apple.finder QLEnableTextSelection           -bool true
    dw NSGlobalDomain   AppleShowAllExtensions          -bool true
    dw NSGlobalDomain   com.apple.springing.enabled     -bool true
    dw NSGlobalDomain   com.apple.springing.delay       -float 0.5
    dw NSGlobalDomain   AppleShowScrollBars             -string "Always"
    dw NSGlobalDomain   NSDocumentSaveNewDocumentsToCloud -bool false
    dw com.apple.desktopservices DSDontWriteNetworkStores -bool true
    dw com.apple.desktopservices DSDontWriteUSBStores     -bool true
    dw com.apple.frameworks.diskimages auto-open-ro-root  -bool true
    dw com.apple.frameworks.diskimages auto-open-rw-root  -bool true

    # Snap-to-grid. PlistBuddy, not defaults, so it cannot be read back the
    # same way; failure is reported rather than assumed.
    local plist="${HOME}/Library/Preferences/com.apple.finder.plist"
    if /usr/libexec/PlistBuddy -c "Set :DesktopViewSettings:IconViewSettings:arrangeBy grid" "$plist" 2>/dev/null; then
        record_pass "desktop icon snap-to-grid"
    else
        record_skip "desktop icon snap-to-grid" "PlistBuddy path not present yet"
    fi

    chflags nohidden "${HOME}/Library" 2>/dev/null && record_pass "~/Library visible" \
        || record_skip "~/Library visible" "chflags failed"
    sudo chflags nohidden /Volumes 2>/dev/null && record_pass "/Volumes visible" \
        || record_skip "/Volumes visible" "chflags failed"
}

# ------------------------------------------------- Dock, trackpad, keys ---

dock_prefs() {
    info "Dock and Mission Control"
    dw com.apple.dock autohide               -bool true
    dw com.apple.dock showhidden             -bool true
    dw com.apple.dock show-recents           -bool true
    dw com.apple.dock autohide-delay         -float 0
    dw com.apple.dock autohide-time-modifier -float 0.2
    dw com.apple.dock expose-animation-duration -float 0.1
    dw com.apple.dock expose-group-by-app    -bool true
    dw com.apple.dock mru-spaces             -bool false

    # The previous script set the bottom-right corner twice (5 = screen
    # saver, then 10 = display sleep). The second write won, so 10 is what
    # the machine actually does today; that behaviour is kept deliberately.
    dw com.apple.dock wvous-br-corner   -int 10
    dw com.apple.dock wvous-br-modifier -int 0
}

input_prefs() {
    info "Trackpad and keyboard"
    dw com.apple.driver.AppleBluetoothMultitouch.trackpad Clicking -bool true
    dw com.apple.driver.AppleBluetoothMultitouch.trackpad Dragging -bool false
    dw com.apple.AppleMultitouchTrackpad Dragging -bool false
    dw NSGlobalDomain com.apple.mouse.tapBehavior   -int 1
    dwh NSGlobalDomain com.apple.mouse.tapBehavior  -int 1
    dw NSGlobalDomain com.apple.trackpad.forceClick -int 1
    dw NSGlobalDomain com.apple.trackpad.scaling    -float 0.875
    dw NSGlobalDomain com.apple.sound.beep.flash    -int 0
}

menubar_prefs() {
    info "Menu bar"
    dwh com.apple.controlcenter Bluetooth -int 18
    dwh com.apple.controlcenter Sound     -int 18
}

# ------------------------------------------------------------- screen -----

screen_prefs() {
    info "Screen and screenshots"
    dw com.apple.screensaver askForPassword      -int 1
    dw com.apple.screensaver askForPasswordDelay -int 0
    dw com.apple.screencapture location -string "${HOME}/Desktop"
    dw com.apple.screencapture type     -string "png"
    dw com.apple.screencapture disable-shadow -bool true
    dw NSGlobalDomain AppleFontSmoothing -int 2
    dw /Library/Preferences/com.apple.windowserver DisplayResolutionEnabled -bool true
}

# --------------------------------------------------- time and calendar ----

time_prefs() {
    info "Date, time and calendar"
    dw com.apple.iCal "Default duration in minutes for new event" -int 30
    dw com.apple.iCal "TimeZone support enabled" -int 1

    sudo /usr/sbin/systemsetup -setusingnetworktime on >/dev/null 2>&1 \
        && record_pass "network time" || record_fail "network time" "systemsetup failed"
    sudo /usr/sbin/systemsetup -settimezone "America/New_York" >/dev/null 2>&1 \
        && record_pass "timezone America/New_York" || record_fail "timezone" "systemsetup failed"
}

# ---------------------------------------------------------- printing ------

print_prefs() {
    info "Printing"
    dw com.apple.print.PrintingPrefs "Quit When Finished" -bool true
    dw NSGlobalDomain PMPrintingExpandedStateForPrint  -bool true
    dw NSGlobalDomain PMPrintingExpandedStateForPrint2 -bool true
}

# --------------------------------------------------- software updates ----

update_prefs() {
    info "Software updates"
    # Updates are switched off while the defaults cache is rewritten, then
    # switched back on, to avoid the daemon racing these writes.
    sudo softwareupdate --schedule OFF >/dev/null 2>&1

    dw com.apple.SoftwareUpdate ScheduleFrequency -int 1
    dw /Library/Preferences/com.apple.SoftwareUpdate AutomaticCheckEnabled -bool true
    dw /Library/Preferences/com.apple.SoftwareUpdate AutomaticDownload     -bool true
    dw /Library/Preferences/com.apple.SoftwareUpdate ConfigDataInstall     -bool true
    dw /Library/Preferences/com.apple.SoftwareUpdate CriticalUpdateInstall -bool true
    dw /Library/Preferences/com.apple.commerce AutoUpdate -bool true
    dw /Library/Preferences/com.apple.commerce AutoUpdateRestartRequired -bool true

    sudo softwareupdate --schedule ON >/dev/null 2>&1
}

# ------------------------------------------------------------- misc -------

misc_prefs() {
    info "Terminal, privacy and power"
    dw com.apple.terminal StringEncodings -array 4
    dw com.apple.Terminal "Default Window Settings" -string "Ocean"
    dw com.apple.Terminal "Startup Window Settings" -string "Ocean"
    dw com.apple.AdLib allowApplePersonalizedAdvertising -int 0
    dw com.apple.assistant.support "Dictation Enabled" -int 1
    dw com.apple.TV automaticallyDeleteVideoAssetsAfterWatching -int 1

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

# --------------------------------------------------------- firewall ------

firewall_prefs() {
    info "Firewall"
    sudo "$FW" --setglobalstate on   >/dev/null 2>&1 \
        && record_pass "firewall on" || record_fail "firewall" "could not enable"
    sudo "$FW" --setstealthmode on   >/dev/null 2>&1 \
        && record_pass "stealth mode on" || record_fail "stealth mode" "could not enable"
    # install.sh adds the matching allow rule for the oMLX listener.
}

# ------------------------------------------------------ Touch ID sudo ----

touchid_sudo() {
    local f=/etc/pam.d/sudo_local
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

# -------------------------------------------------------------- main -----

main() {
    info "setup-macos — defaults (macOS $(macos_full))"
    check_macos_version || exit 1
    osascript -e 'tell application "System Settings" to quit' 2>/dev/null
    require_sudo || { err "sudo required"; exit 1; }

    finder_prefs; dock_prefs; input_prefs; menubar_prefs
    screen_prefs; time_prefs; print_prefs; update_prefs
    misc_prefs; firewall_prefs; touchid_sudo

    info "Restarting affected services"
    for p in cfprefsd SystemUIServer ControlCenter Finder Dock WindowManager; do
        killall "$p" 2>/dev/null
    done

    print_summary
}

main "$@"
