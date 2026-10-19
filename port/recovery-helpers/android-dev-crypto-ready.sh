#!/system/bin/sh
# Recovery-only readiness retry; no credentials, disk data, or HAL restarts.

helper_log() {
    printf 'android-dev-crypto-ready: %s\n' "$*" >&2
}

read_property() {
    /system/bin/getprop "$1"
}

monotonic_seconds() {
    IFS=' ' read -r uptime_value _uptime_unused < /proc/uptime || return 1
    uptime_value=${uptime_value%%.*}
    case "$uptime_value" in ''|*[!0-9]*) return 1;; esac
    printf '%s\n' "$uptime_value"
}

running_adsp() {
    for remoteproc in /sys/class/remoteproc/remoteproc*; do
        [ -d "$remoteproc" ] || continue
        IFS= read -r processor_name < "$remoteproc/name" || continue
        case "$processor_name" in adsp|*remoteproc-adsp) ;; *) continue;; esac
        IFS= read -r processor_state < "$remoteproc/state" || continue
        [ "$processor_state" = running ] && return 0
    done
    return 1
}

set_property_command() {
    /system/bin/timeout "$1" /system/bin/setprop "$2" "$3"
}

write_property() {
    property_now=$(monotonic_seconds) || return 1
    property_budget=$((deadline - property_now))
    [ "$property_budget" -gt 0 ] || return 1
    [ "$property_budget" -le 2 ] || property_budget=2
    set_property_command "$property_budget" "$1" "$2"
}

retry_sleep() {
    /system/bin/sleep 1
}

hardware_ready() {
    running_adsp && [ "$(read_property vendor.sys.listeners.registered)" = true ]
}

crypto_ready_main() {
    if [ "$(read_property ro.boot.hardware.sku)" != popsicle ] ||
       [ "$(read_property ro.twrp.weaver)" != nxp ]; then
        helper_log 'Unsupported SKU/Weaver; no properties changed.'
        return 2
    fi
    started=$(monotonic_seconds) || {
        helper_log 'Cannot read the monotonic clock; refusing to start.'
        return 1
    }
    deadline=$((started + 60))
    helper_log 'Waiting up to 60 seconds for running ADSP and registered listeners.'
    while :; do
        current=$(monotonic_seconds) || return 1
        [ "$current" -lt "$deadline" ] || break
        if hardware_ready; then
            if write_property twrp.adsp.ready true &&
               [ "$(read_property twrp.adsp.ready)" = true ] &&
               hardware_ready &&
               write_property ctl.start vendor.secure_element &&
               [ "$(read_property init.svc.vendor.secure_element)" = running ]; then
                helper_log 'ADSP/listeners verified; readiness readback and Secure Element start confirmed.'
                return 0
            fi
            helper_log 'Readiness publication or Secure Element start not confirmed; retrying.'
        fi
        current=$(monotonic_seconds) || return 1
        [ "$current" -lt "$deadline" ] || break
        retry_sleep || {
            helper_log 'Retry sleep failed; refusing an unbounded retry loop.'
            return 1
        }
    done
    helper_log 'Timed out; readiness/start was not confirmed.'
    return 1
}

# Main invocation is the only entry; host tests load function definitions only.
crypto_ready_main
exit $?
