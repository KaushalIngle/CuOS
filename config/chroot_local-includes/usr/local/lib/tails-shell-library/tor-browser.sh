#!/bin/sh

TBB_INSTALL=/usr/local/lib/tor-browser
# shellcheck disable=SC2034
TBB_PROFILE=/etc/tor-browser/profile
TBB_EXT=/usr/local/share/tor-browser-extensions

# For strings it's up to the caller to add double-quotes ("") around
# the value.
set_mozilla_pref() {
    local file name value prefix
    file="${1}"
    name="${2}"
    value="${3}"
    # Sometimes we might want to do e.g. user_pref
    prefix="${4:-pref}"
    [ -e "${file}" ] && sed -i "/^${prefix}(\"${name}\",/d" "${file}"
    echo "${prefix}(\"${name}\", ${value});" >> "${file}"
}

exec_firefox() {
    export LD_LIBRARY_PATH="${TBB_INSTALL}"
    export FONTCONFIG_PATH="${TBB_INSTALL}/TorBrowser/Data/fontconfig"
    export FONTCONFIG_FILE="fonts.conf"
    export GNOME_ACCESSIBILITY=1

    # Since Tor Browser 9.0 it has become integrated into the browser,
    # so let's make it the responsibility of callers to explicitly set
    # this variable to 0 if they want to enable Tor Launcher.
    if [ -z "${TOR_SKIP_LAUNCH:-}" ]; then
        export TOR_SKIP_LAUNCH=1
    fi
    # Since Tor Browser 10.5 it use an integrated alternative to Tor
    # Launcher (and TCA) that we disable.
    export TOR_USE_LEGACY_LAUNCHER='yes'

    # New in 9.5: Avoid overwriting user's dconf values. Fixes #27903.
    export GSETTINGS_BACKEND=memory

    # The Tor Browser often assumes that the current directory is
    # where the browser lives, e.g. for the fixed set of fonts set by
    # fontconfig above.
    cd "${TBB_INSTALL}"

    # From start-tor-browser:
    unset SESSION_MANAGER

    exec "${TBB_INSTALL}"/firefox.real "${@}"
}

guess_best_tor_browser_locale() {
    local long_locale short_locale similar_locale
    long_locale="$(echo "${LANG}" | sed -e 's/\..*$//' -e 's/_/-/')"
    short_locale="$(echo "${long_locale}" | cut -d"-" -f1)"
    if [ -e "${TBB_EXT}/langpack-${long_locale}@firefox.mozilla.org.xpi" ]; then
        echo "${long_locale}"
        return
    elif [ -e "${TBB_EXT}/langpack-${short_locale}@firefox.mozilla.org.xpi" ]; then
        echo "${short_locale}"
        return
    fi
    # If we use locale xx-YY and there is no langpack for xx-YY nor xx
    # there may be a similar locale xx-ZZ that we should use instead.
    # shellcheck disable=SC2012
    similar_locale="$(ls -1 "${TBB_EXT}" | \
        sed -n "s,^langpack-\(${short_locale}-[A-Z]\+\)@firefox.mozilla.org.xpi$,\1,p" | \
        head -n 1)" || :
    if [ -n "${similar_locale:-}" ]; then
        echo "${similar_locale}"
        return
    fi

    echo 'en-US'
}

configure_xulrunner_app_locale() {
    local profile locale
    profile="${1}"
    locale="${2}"
    mkdir -p "${profile}"/preferences
    set_mozilla_pref "${profile}"/prefs.js \
                     "intl.locale.requested" "\"${locale}\"" \
                     "user_pref"
}

configure_best_tor_browser_locale() {
    local profile best_locale
    profile="${1}"
    best_locale="$(guess_best_tor_browser_locale)"
    configure_xulrunner_app_locale "${profile}" "${best_locale}"
    cat "/etc/tor-browser/locale-profiles/${best_locale}.js" \
        >> "${profile}/prefs.js"
}

supported_tor_browser_locales() {
    # The default is always supported
    echo en-US
    for langpack in "${TBB_EXT}"/langpack-*@firefox.mozilla.org.xpi; do
        basename "${langpack}" | sed 's,^langpack-\([^@]\+\)@.*$,\1,'
    done
}

set_firefox_content_process_count() {
    local profile="$1"
    local count="$2"

        set_mozilla_pref "${profile}/prefs.js" \
                         "dom.ipc.processCount" "$count" \
                         user_pref
}

configure_tor_browser_memory_usage() {
    local profile="${1}"

    # Unit: KiB
    system_ram=$(awk '/^MemTotal:/ { print $2 }' /proc/meminfo)

    if [ "$system_ram" -lt "$((3 * 1024 * 1024))" ]; then
        set_firefox_content_process_count "$profile" 2
    fi
}
