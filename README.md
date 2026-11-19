# setup-macos

Provisions a Mac: system preferences, applications, and shell configuration.
Tested on macOS 26; newer releases are handled adaptively rather than blocked.

## Getting started

### On a new Mac

1. Finish Setup Assistant and log in. Nothing can run before this point
   without MDM enrollment, which this repo deliberately does not use.
2. Connect to a network.
3. Open Terminal and run, naming what the machine is for:

       curl -fsSL https://raw.githubusercontent.com/pjain/setup-macos/main/bootstrap.sh | bash -s -- --profile desktop

   Omit `--profile` and you will be prompted to choose.

That is the whole thing. The repository is public and holds no credentials,
so nothing needs authenticating first. The script downloads itself to
`~/projects/setup-macos` and continues from there.

Expect it to take 30-60 minutes, mostly Command Line Tools and downloads.
You will be asked for your password once at the start, and for a browser
sign-in at the very end when GitHub keys are set up.

If the machine reboots, the run resumes on its own — a LaunchAgent restarts
it at the next incomplete phase and removes itself when everything finishes.

### Without a network, or before pushing changes

Copy the repository to a USB stick and run `./bootstrap.sh` from it. The
entry point behaves identically whether it was piped from curl or run from
a local copy.

### Look before you leap

To see what would be installed without changing anything:

    SETUP_DRY_RUN=1 ./install.sh

This resolves every manifest entry, reports what is already present and what
would be downloaded, and writes nothing.

### Useful invocations

    ./bootstrap.sh                 run, or resume where it stopped
    ./bootstrap.sh --status        list completed phases
    ./bootstrap.sh --reset         clear state and start over
    ./defaults.sh                  system preferences only
    ./defaults.sh --profile dev    ...for specific profiles
    ./install.sh                   applications only
    SETUP_DRY_RUN=1 ./install.sh   report, change nothing
    ./update.sh --check            installed vs latest, change nothing
    ./update.sh                    upgrade anything outdated (verified)

Each script prints a summary and exits non-zero if anything failed. The full
log is at `~/.local/state/setup-macos/run.log`.

### Reading the summary

Three outcomes are reported, and the distinction matters:

- **passed** — done and verified.
- **skipped** — deliberately not done: already installed, not applicable to
  this machine, or a preference key this macOS release no longer accepts.
  Skips are normal and worth scanning.
- **failed** — something went wrong. A signature mismatch appears here, and
  should be treated as serious rather than retried blindly.

Anything needing a human is collected under **manual steps still required**
at the end.

## Profiles

A machine installs only the software its profile calls for. Profiles can be
combined, and the result is the union — a machine that is both a dev box and
a desktop gets everything from each, installed once.

| Profile   | For                                                       |
|-----------|-----------------------------------------------------------|
| `dev`     | Development: Xcode, Python, Node, Postgres, Arduino, browsers |
| `ai`      | Inference host: oMLX, LM Studio, n8n, Tailscale            |
| `desktop` | Daily driver: Office, Final Cut, media, messaging, finance |

    ./install.sh --list-profiles        show exactly what each contains
    ./install.sh --profile dev          one profile
    ./install.sh --profile dev,desktop  several; union of both
    ./bootstrap.sh --profile ai         same flag on the full run

The choice is saved to `~/.local/state/setup-macos/profiles`, so re-runs and
reboot resumes install the same set without being told again. `SETUP_PROFILES`
works as an environment variable alternative.

Which profile an entry belongs to is a column in `manifest.tsv`, so moving
software between profiles is a text edit, not a code change.

There is no separate laptop profile — combine the existing ones instead, for
example `--profile dev,desktop` on a portable workstation.

### The one Homebrew exception

Xcode and Final Cut Pro are Mac App Store exclusives with no vendor download,
so no signature-checked path to them exists. `mas` is the only command-line
interface to the App Store, and it is a Homebrew formula.

So Homebrew is installed for that single purpose, and only when the selected
profiles actually contain App Store titles — `--profile ai` never installs it.
Nothing else here comes from Homebrew: every other application is fetched from
its vendor and checked against a pinned Team ID.

You must be signed in to the App Store app before those two can install; `mas`
cannot sign in on your behalf. The run reports this rather than failing.

## Trying it in a VM first

Worth doing before running against a machine you care about. UTM with the
Apple backend works well.

Share this directory into the guest (VM settings → Sharing → Add the folder;
requires a macOS 13+ guest, and it then appears under `/Volumes/` inside),
or skip sharing and let bootstrap fetch the repo from GitHub itself.
Either way, the one command inside the VM is:

    curl -fsSL https://raw.githubusercontent.com/pjain/setup-macos/main/bootstrap.sh | bash -s -- --profile dev,desktop --no-app-store

(App Store apps are skipped there anyway: VMs cannot sign in to an Apple ID,
and no headless sign-in exists. `--no-app-store` makes that a clean skip and
keeps Homebrew off the VM. `--profile` selects whichever set you're testing.)

With a shared folder, you can instead run the local copy identically:

    cp -R "/Volumes/<shared folder>" ~/projects/setup-macos && cd ~/projects/setup-macos
    ./bootstrap.sh --profile dev,desktop --no-app-store

The Apple backend has no snapshots, so clone the VM bundle between runs
instead. On APFS this is copy-on-write and costs no extra space until the
copies diverge:

    cp -c -R "macOS.utm" "setup-test.utm"

Four things genuinely cannot be tested in an Apple Silicon VM, and the
script reports each as a skip rather than a failure:

| Not testable in a VM        | Reason                                |
|-----------------------------|---------------------------------------|
| Mac App Store titles        | VMs cannot sign in to an Apple ID     |
| Touch ID for sudo           | No Secure Enclave passthrough         |
| oMLX serving                | Needs a real GPU                      |
| Trackpad, Bluetooth, display| No corresponding hardware             |

If any of those comes back as a *failure* rather than a skip, that is a bug.

## Phases

Phases are recorded as they finish, and a LaunchAgent re-invokes the script
after a reboot, so an interrupted run resumes instead of restarting.

| Phase      | Does                                                    |
|------------|---------------------------------------------------------|
| `clt`      | Xcode Command Line Tools, headless where possible        |
| `defaults` | System preferences from `prefs.tsv` (`defaults.sh`)      |
| `install`  | Applications from `manifest.tsv` (`install.sh`)          |
| `shell`    | Links `shell/zshrc` and `shell/profile` into `$HOME`     |
| `github`   | `gh` sign-in, SSH keygen, key uploaded via `gh ssh-key`  |

Only `github` needs a human, and only for a browser sign-in. No key is ever
pasted into a web form by hand.

## How software is installed

Applications are downloaded straight from the vendor, never through a package
manager acting as a middleman. Each artifact is checked twice before it is
installed:

1. Gatekeeper must report it as notarized by Apple.
2. The signing Team ID must equal the value pinned in `manifest.tsv`.

A mismatch aborts that item and is reported as a failure. Forging a package
would require the vendor's own Developer ID certificate.

Entries pinned to `-` have no Team ID recorded yet. They still require
notarization, but cannot detect a vendor swap; `install.sh` prints the
observed ID so it can be pinned. Adding software is one line in
`manifest.tsv`, not a block of shell.

## Finding the newest version: sources and updates

The url column of `manifest.tsv` does not have to be a fixed URL. A
*source spec* names where to discover the newest release, resolved at run
time (implemented in `lib/resolve.sh`):

    github:<owner>/<repo>|<regex>     latest release asset, filtered by name
    release-template:<owner>/<repo>|https://…{version}…
    sparkle:<appcast url>             the app's own self-update feed
    cask:<name>                       Homebrew's continuously-updated pointer
    page:<index or download url with trailing />|<regex>
    redirect:<latest url>             follow to the final versioned URL

Resolution results are cached for 24 hours in
`~/.local/state/setup-macos/lock.tsv` (name, spec, version, URL; a changed
spec re-resolves). Discovery only ever picks a *URL*: what gets installed is
still decided by the notarization + pinned-Team-ID gate above, so a vendor
swap or a poisoned page scrape fails verification exactly as it would with a
hand-pinned URL. Entries whose vendor gives no scriptable version source
stay pinned URLs and are flagged by the update check instead.

    ./update.sh --check        report installed vs latest per profile
    ./update.sh                download, verify, replace; restore the old
                               version if verification fails

`update.sh` bypasses the cache and re-resolves every entry. Version
comparison is numeric-only; anything unparseable (`7.2.1 (88329)`) or any
vendor URL with no version in it is reported to a human rather than
auto-upgraded. App Store titles (`mas upgrade`) and npm/pip packages are
pointed at their native updaters rather than duplicated here.

## Preferences are data too

`defaults.sh` is an engine; `prefs.tsv` is the inventory. Each line is one
preference: domain, key, type, value, profiles, and the macOS major versions
the key is known to work on:

    com.apple.dock  mru-spaces  -bool  false  dev,ai,desktop  -  -

Adding a setting is one line. Retiring one that Apple killed in some release
means filling in its `max_macos`, after which it reports as a clean
version-filtered skip on newer systems instead of noise. Values support
`{HOME}` and `{SCREENSHOTS_DIR}` tokens; machine-specific values come from
`~/.config/setup-macos/config` (`SETUP_TIMEZONE`, `SETUP_SCREENSHOT_DIR`)
rather than edits to the data. Dock, Finder and friends respect the profile
selection like software does — a headless `ai` host can be given only the
entries that apply to it.

What cannot be expressed as one key/value write (PlistBuddy paths,
`systemsetup`, the firewall, Touch ID sudo) stays as actions in
`defaults.sh`, and reports itself the same way.

Every entry's outcome — pass, skip, fail, filtered — is appended to
`~/.local/state/setup-macos/prefs-audit.tsv`. That file is the
compatibility matrix: `.github/workflows/prefs-matrix.yml` runs the engine
on Apple's GitHub runners weekly and uploads one audit per macOS release,
so a new major version tells you exactly which keys died before a fresh Mac
ever has to find out.

## Credentials

Nothing secret belongs in this repository. `shell/zshrc` sources two
untracked files at the end:

- `~/.zshrc.local` — credentials and machine-local settings
- `~/.zshrc.<shortname>` — per-machine overrides

Migrating these values into the login keychain is a planned follow-up.

## Notes

- `oMLX` is configured by patching `~/.omlx/settings.json` in place, because
  that file also holds per-install API secrets and must never be shipped from
  here. The app must be launched once before the patch can apply, and
  restarted afterwards.
- The firewall and stealth mode are enabled, with an explicit allow rule for
  the oMLX listener so it stays reachable on `0.0.0.0:60001`.
- Three entries (`Inkscape`, `Ledger Live`, `oMLX`) have no scriptable
  download and are reported as manual steps rather than failing.

See `docs/specs/` for the design and the reasoning behind these choices.
