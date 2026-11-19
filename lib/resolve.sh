#!/bin/bash
# Source resolution for setup-macos: turns a *source spec* from the manifest
# into the concrete {version, download URL} of the newest release.
#
# A spec lives in the manifest's url column. Anything starting with http(s)
# is a pinned vendor URL and passes through untouched; the rest are resolved
# here, at run time, against the vendor:
#
#   github:<owner>/<repo>[|<ERE>]
#       GitHub Releases API, latest non-prerelease. The optional extended
#       regex filters asset *file names*. Picks universal > arm64 builds.
#   release-template:<owner>/<repo>|<url template>
#       Version comes from the latest GitHub tag, then {version} is expanded
#       in the template. For vendors that publish versions on GitHub but
#       host the download themselves (Signal).
#   sparkle:<appcast url>
#       Parses the Sparkle/Apple-style appcast feed an app uses to update
#       itself; picks the highest sparkle:version's enclosure.
#   cask:<name>
#       Asks Homebrew (if present) what its continuously-maintained cask
#       currently points at. Discovery only — the artifact is still
#       verified against the pinned Team ID before install.
#   page:<url with trailing />[|<ERE>]
#       Last resort: fetches the HTML, harvests every href that looks like
#       an installer, filters, and picks universal > arm64 > highest
#       version. Fine for Apache/nginx directory indexes; treat results for
#       JavaScript-only pages with suspicion — that is what the pinned
#       Team ID in the manifest is for.
#   redirect:<url>
#       Follows HEAD redirects to the final URL and extracts any version
#       from it. For vendor "latest" endpoints (Brave, Slack style).
#
# Resolution results are cached in ${STATE_DIR}/lock.tsv for RESOLVE_TTL
# seconds so repeated runs don't hammer vendor APIs; a changed spec or an
# expired entry re-resolves. SETUP_RESOLVE_TTL=0 disables the cache, and
# update.sh always bypasses it. Resolution only ever picks a URL: whether
# anything gets *installed* is still decided by the notarization + Team-ID
# gate in install_verified. A vendor swap or a poisoned scrape fails there,
# exactly as with a hand-pinned URL.

[ -n "${_SETUP_MACOS_RESOLVE:-}" ] && return 0
_SETUP_MACOS_RESOLVE=1

LOCK_FILE="${STATE_DIR}/lock.tsv"
RESOLVE_TTL="${SETUP_RESOLVE_TTL:-86400}"   # seconds; 0 = always re-resolve

# ------------------------------------------------------------------ http ----

_resolve_get() {
    curl -fsSL --retry 2 --retry-delay 2 --max-time 90 \
        -H 'User-Agent: setup-macos' "$1"
}

# _version_from_url <url> — highest dotted number in the final path segment,
# empty when the URL carries no version. Best-effort by design: "unknown" is
# reported, never fabricated.
_version_from_url() {
    local path="${1%%\?*}"
    printf '%s' "${path##*/}" | grep -oE '[0-9]+(\.[0-9]+)+' | sort -V | tail -1
}

# ------------------------------------------------------------- selection ----

# _resolve_filter <ERE> — stdin: URLs; stdout: those whose bare file name
# matches the regex. Empty regex passes everything through.
_resolve_filter() {
    local re="$1" url base
    while IFS= read -r url; do
        [ -n "$url" ] || continue
        base="${url##*/}"; base="${base%%\?*}"
        if [ -z "$re" ] || printf '%s' "$base" | grep -Eq -- "$re"; then
            printf '%s\n' "$url"
        fi
    done
}

# _resolve_prefer — stdin: candidate URLs; stdout: the single best one.
# Apple Silicon first (universal beats arm64 beats anything), then the
# highest version seen in the URL.
_resolve_prefer() {
    local all uni arm pool ver
    all="$(cat)"
    [ -n "$all" ] || return 1
    uni="$(printf '%s\n' "$all" | grep -i universal || true)"
    arm="$(printf '%s\n' "$all" | grep -iE 'arm64|aarch64' || true)"
    pool="$all"
    [ -n "$arm" ] && pool="$arm"
    [ -n "$uni" ] && pool="$uni"
    ver="$(printf '%s\n' "$pool" | while IFS= read -r u; do _version_from_url "$u"; done \
        | grep -v '^$' | sort -V | tail -1)"
    if [ -n "$ver" ]; then
        printf '%s\n' "$pool" | grep -F -- "$ver" | tail -1
    else
        printf '%s\n' "$pool" | tail -1
    fi
}

# -------------------------------------------------------------- sources ----

_resolve_github() { # $1=owner/repo $2=asset-name ERE — prints ver<TAB>url
    local repo="$1" re="${2:-}" json tag url
    json="$(_resolve_get "https://api.github.com/repos/${repo}/releases/latest")" || {
        warn "github:${repo}: API request failed (rate-limited? offline?)"
        return 1; }
    json="$(printf '%s' "$json" | tr '{' '\n')"
    # ": *" tolerates both compact and pretty-printed API responses —
    # GitHub serves either, and a parser that only handles one silently
    # reports "no matching asset" against the other.
    tag="$(printf '%s\n' "$json" | sed -n 's/.*"tag_name": *"\([^"]*\)".*/\1/p' | head -1)"
    url="$(printf '%s\n' "$json" \
        | sed -n 's/.*"browser_download_url": *"\([^"]*\)".*/\1/p' \
        | _resolve_filter "$re" | _resolve_prefer)"
    if [ -z "$url" ]; then
        warn "github:${repo}: no release asset matches '${re:-any}'"
        return 1
    fi
    printf '%s\t%s' "${tag:-$(_version_from_url "$url")}" "$url"
}

_resolve_release_template() { # $1=owner/repo $2=url template with {version}
    local repo="$1" tmpl="$2" json tag
    json="$(_resolve_get "https://api.github.com/repos/${repo}/releases/latest")" || {
        warn "release-template:${repo}: API request failed"; return 1; }
    tag="$(printf '%s' "$json" | tr ',' '\n' \
        | sed -n 's/^ *"tag_name": *"\([^"]*\)".*/\1/p' | head -1)"
    if [ -z "$tag" ]; then
        warn "release-template:${repo}: no tag_name in API response"
        return 1
    fi
    tag="${tag#v}"
    printf '%s\t%s' "$tag" "${tmpl//\{version\}/${tag}}"
}

_resolve_sparkle() { # $1=appcast url — prints ver<TAB>url
    local feed item v u best_v='' best_u=''
    feed="$(_resolve_get "$1" | tr '\n' ' ')" || {
        warn "sparkle: feed request failed for $1"; return 1; }
    while IFS= read -r item; do
        u="$(printf '%s' "$item" | sed -n 's/.*<enclosure[^>]*url="\([^"]*\)".*/\1/p' | head -1)"
        [ -n "$u" ] || continue
        v="$(printf '%s' "$item" | sed -n 's/.*sparkle:version="\([^"]*\)".*/\1/p')"
        [ -n "$v" ] || v="$(_version_from_url "$u")"
        if [ -z "$best_u" ]; then best_v="$v"; best_u="$u"; continue; fi
        version_newer "${v:-}" "${best_v:-0}"
        if [ "$V_STATUS" = newer ]; then best_v="$v"; best_u="$u"; fi
    done <<< "$(printf '%s' "$feed" | sed 's/<item>/\n<item>/g')"
    if [ -z "$best_u" ]; then
        warn "sparkle: no enclosure found in $1"; return 1
    fi
    printf '%s\t%s' "${best_v:-unknown}" "$best_u"
}

_resolve_cask() { # $1=cask token — prints ver<TAB>url
    local name="$1" json url ver
    if ! command -v brew >/dev/null 2>&1; then
        warn "cask:${name}: brew is not installed on this machine"
        return 1
    fi
    json="$(brew info --cask "$name" --json=v2 2>/dev/null)" || {
        warn "cask:${name}: brew does not know this cask"; return 1; }
    url="$(printf '%s' "$json" | tr ',' '\n' | sed -n 's/.*"url":"\([^"]*\)".*/\1/p' | head -1)"
    ver="$(printf '%s' "$json" | tr ',' '\n' | sed -n 's/.*"version":"\([^"]*\)".*/\1/p' | head -1)"
    if [ -z "$url" ]; then
        warn "cask:${name}: no url in brew output"; return 1
    fi
    printf '%s\t%s' "${ver:-unknown}" "$url"
}

_resolve_redirect() { # $1=url — prints ver<TAB>final-url (HEAD only, no body)
    local final
    final="$(curl -fsIL --retry 2 --max-time 60 -H 'User-Agent: setup-macos' \
        -o /dev/null -w '%{url_effective}' "$1" 2>/dev/null)" || {
        warn "redirect: HEAD failed for $1"; return 1; }
    [ -n "$final" ] || { warn "redirect: no final URL for $1"; return 1; }
    printf '%s\t%s' "$(_version_from_url "$final")" "$final"
}

# _absolutize <base> <href> — resolve one href against the page URL.
# A case statement rather than [[ ]] pattern matching: bash 3.2 does not
# support "|" alternation inside [[ patterns, which silently truncates the
# whole function's body at parse time.
_absolutize() {
    local base="$1" href="$2" origin
    case "$href" in http:*|https:*) printf '%s\n' "$href"; return 0 ;; esac
    case "$href" in //*) printf 'https:%s\n' "$href"; return 0 ;; esac
    origin="$(printf '%s' "$base" | sed -n 's#^\(https\{0,1\}://[^/]*\).*#\1#p')"
    case "$href" in /*) printf '%s%s\n' "$origin" "$href"; return 0 ;; esac
    printf '%s/%s\n' "${base%/}" "$href"
}

_resolve_page() { # $1=page url (trailing /) $2=file-name ERE — prints ver<TAB>url
    local base="$1" re="${2:-}" html path cands url
    html="$(_resolve_get "$base")" || { warn "page: fetch failed for $1"; return 1; }
    cands="$(printf '%s' "$html" \
        | grep -oiE 'href="[^"]+\.(dmg|pkg|zip)([?&][^"]*)?"' \
        | sed -e 's/^href="//' -e 's/"$//' \
        | while IFS= read -r path; do _absolutize "$base" "$path"; done | sort -u)"
    url="$(printf '%s\n' "$cands" | _resolve_filter "$re" | _resolve_prefer)"
    if [ -z "$url" ]; then
        warn "page: no installer candidate found at ${base} (regex '${re:-any}')"
        return 1
    fi
    printf '%s\t%s' "$(_version_from_url "$url")" "$url"
}

# ------------------------------------------------------------- dispatch ----

resolve_source() { # <spec> — prints version<TAB>url
    local spec="$1" rest re
    case "$spec" in
    github:*)
        rest="${spec#github:}"
        re="${rest#*|}"; [ "$re" = "$rest" ] && re=""
        _resolve_github "${rest%%|*}" "$re" ;;
    release-template:*)
        rest="${spec#release-template:}"
        case "$rest" in
            *"|"*) _resolve_release_template "${rest%%|*}" "${rest#*|}" ;;
            *) warn "release-template: missing URL template in ${spec}"; return 1 ;;
        esac ;;
    sparkle:*) _resolve_sparkle "${spec#sparkle:}" ;;
    cask:*)    _resolve_cask "${spec#cask:}" ;;
    redirect:*) _resolve_redirect "${spec#redirect:}" ;;
    page:*)
        rest="${spec#page:}"
        re="${rest#*|}"; [ "$re" = "$rest" ] && re=""
        _resolve_page "${rest%%|*}" "$re" ;;
    http://*|https://*)
        # Pinned vendor URL: already concrete, nothing to discover.
        printf '%s\t%s' "$(_version_from_url "$spec")" "$spec" ;;
    *)
        warn "unsupported source spec: ${spec}"
        return 1 ;;
    esac
}

# ------------------------------------------------------------------ lock ----
# lock.tsv: name<TAB>spec<TAB>version<TAB>url<TAB>epoch — regenerated
# wholesale on every write (grep-out + append), so stale names never
# accumulate. A spec edit in the manifest invalidates its own entry because
# the stored spec must match for the cache to be used.

lock_put() { # name spec version url
    local tmp
    tmp="$(mktemp "${STATE_DIR}/lock.XXXXXX")" || return 1
    awk -F'\t' -v n="$1" '$1 != n' "$LOCK_FILE" 2>/dev/null > "$tmp"
    printf '%s\t%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$4" "$(date +%s)" >> "$tmp"
    mv "$tmp" "$LOCK_FILE"
}

lock_fresh() { # name spec — prints cached version<TAB>url when still valid
    local name="$1" spec="$2" line n s v u ts now
    [ -f "$LOCK_FILE" ] || return 1
    [ "${RESOLVE_TTL:-0}" -gt 0 ] 2>/dev/null || return 1
    line="$(awk -F'\t' -v n="$name" '$1 == n { print; exit }' "$LOCK_FILE")"
    [ -n "$line" ] || return 1
    IFS=$'\t' read -r n s v u ts <<< "$line"
    [ "$s" = "$spec" ] || return 1
    now="$(date +%s)"
    [ $((now - ts)) -lt "$RESOLVE_TTL" ] || return 1
    printf '%s\t%s' "${v:-unknown}" "$u"
}

# resolve_entry <name> <spec> — prints version<TAB>url, using the lockfile
# cache when it is fresh and still matches this exact spec.
resolve_entry() {
    local name="$1" spec="$2" out v u
    if out="$(lock_fresh "$name" "$spec")"; then
        _log "RESOLVE $name cached ${out%%$'\t'*} ${out#*$'\t'}"
        printf '%s' "$out"
        return 0
    fi
    out="$(resolve_source "$spec")" || return 1
    v="${out%%$'\t'*}"; u="${out#*$'\t'}"
    lock_put "$name" "$spec" "${v:-unknown}" "$u"
    _log "RESOLVE $name ${v:-unknown} $u"
    printf '%s\t%s' "${v:-unknown}" "$u"
}
