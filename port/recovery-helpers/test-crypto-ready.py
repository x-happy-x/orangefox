#!/usr/bin/env python3
"""Offline readiness controls: no phone, real properties, services, or user data."""
from pathlib import Path
import shlex
import subprocess
import tempfile


HERE = Path(__file__).resolve().parent
SCRIPT = HERE / "android-dev-crypto-ready.sh"


def run_shell(text, expected=0):
    result = subprocess.run(["sh", "-c", text], text=True, capture_output=True, timeout=5)
    assert result.returncode == expected, (result.returncode, expected, result.stdout, result.stderr)
    return result.stdout


def main():
    source = SCRIPT.read_text()
    assert "\r" not in source
    functions = source.split("# Main invocation is the only entry;")[0]
    assert "/system/bin/timeout \"$1\" /system/bin/setprop \"$2\" \"$3\"" in functions
    assert "restart" not in "\n".join(line for line in functions.splitlines() if not line.startswith("#"))
    # Only these two property names can reach the production writer.
    assert "write_property twrp.adsp.ready true" in functions
    assert "write_property ctl.start vendor.secure_element" in functions
    setup = r'''
clock=0
published=
service_state=stopped
adsp_after=0
listeners_after=0
property_failures=0
readback_failures=0
start_failures=0
start_pending=0
drop_once=0
property_duration=0
sku=popsicle
weaver=nxp
monotonic_seconds() { printf '%s\n' "$clock"; }
retry_sleep() { clock=$((clock + 1)); }
running_adsp() {
    [ "$clock" -ge "$adsp_after" ] || return 1
    if [ "$drop_once" = 1 ] && [ -n "$published" ]; then drop_once=0; return 1; fi
    return 0
}
read_property() {
    case "$1" in
        ro.boot.hardware.sku) printf '%s' "$sku";;
        ro.twrp.weaver) printf '%s' "$weaver";;
        vendor.sys.listeners.registered) [ "$clock" -lt "$listeners_after" ] || printf true;;
        twrp.adsp.ready) printf '%s' "$published";;
        init.svc.vendor.secure_element) printf '%s' "$service_state";;
        *) return 99;;
    esac
}
set_property_command() {
    printf 'CALL|%s|%s|%s|%s\n' "$2" "$3" "$clock" "$1"
    elapsed=$property_duration
    [ "$elapsed" -le "$1" ] || elapsed=$1
    clock=$((clock + elapsed))
    case "$2:$3" in
        twrp.adsp.ready:true)
            if [ "$property_failures" -gt 0 ]; then property_failures=$((property_failures - 1)); return 1; fi
            if [ "$readback_failures" -gt 0 ]; then readback_failures=$((readback_failures - 1)); return 0; fi
            published=true;;
        ctl.start:vendor.secure_element)
            if [ "$start_failures" -gt 0 ]; then start_failures=$((start_failures - 1)); return 1; fi
            if [ "$start_pending" -gt 0 ]; then start_pending=$((start_pending - 1)); return 0; fi
            service_state=running;;
        *) return 99;;
    esac
}
'''
    cases = [
        ("immediate readiness", "", 0, 2),
        ("late ADSP", "adsp_after=4", 0, 2),
        ("late listeners", "listeners_after=3", 0, 2),
        ("setprop failures retry", "property_failures=2", 0, 4),
        ("readback failures retry", "readback_failures=2", 0, 4),
        ("readback never confirms", "readback_failures=100", 1, 60),
        ("start failures retry", "start_failures=2", 0, 6),
        ("running confirmation retry", "start_pending=2", 0, 6),
        ("ADSP loss before start", "drop_once=1", 0, 3),
        ("ADSP never ready", "adsp_after=100", 1, 0),
        ("listeners never ready", "listeners_after=100", 1, 0),
        ("hardware only ready after deadline", "adsp_after=60", 1, 0),
        ("last-second property budget", "adsp_after=59", 0, 2),
        ("setprop always fails", "property_failures=100", 1, 60),
        ("slow failed writes respect deadline", "property_failures=100; property_duration=2", 1, 20),
        ("clock failure refuses writes", "monotonic_seconds() { return 1; }", 1, 0),
        ("unsupported SKU", "sku=other", 2, 0),
        ("non-NXP Weaver", "weaver=thales", 2, 0),
    ]
    for title, settings, expected, count in cases:
        output = run_shell(functions + setup + settings + "\ncrypto_ready_main\n", expected)
        calls = [line.split("|") for line in output.splitlines() if line.startswith("CALL|")]
        assert len(calls) == count, (title, calls)
        for _, name, value, at, budget in calls:
            assert 0 <= int(at) < 60 and 0 < int(budget) <= min(2, 60 - int(at)), (title, calls)
            assert (name, value) in {("twrp.adsp.ready", "true"), ("ctl.start", "vendor.secure_element")}
        if expected == 0:
            assert calls[-1][1:3] == ["ctl.start", "vendor.secure_element"], title
    # Test the actual name/state scanner, substituting only its sysfs root.
    with tempfile.TemporaryDirectory(prefix="android-dev-adsp-fixture-") as temporary:
        root = Path(temporary)
        scan_functions = functions.replace("/sys/class/remoteproc/remoteproc*", str(root / "remoteproc*"))
        def processor(number, name, state):
            node = root / f"remoteproc{number}"
            node.mkdir(exist_ok=True)
            (node / "name").write_text(name + "\n")
            (node / "state").write_text(state + "\n")
        run_shell(scan_functions + "running_adsp", 1)
        processor(1, "cdsp", "running")
        processor(7, "3000000.remoteproc-adsp", "offline")
        run_shell(scan_functions + "running_adsp", 1)
        processor(7, "3000000.remoteproc-adsp", "running")
        run_shell(scan_functions + "running_adsp")
        processor(7, "3000000.remoteproc-adsp", "offline")
        processor(9, "adsp", "running")
        run_shell(scan_functions + "running_adsp")
        processor(9, "not-adsp", "running")
        run_shell(scan_functions + "running_adsp", 1)
    rc = (HERE / "android-dev-crypto-ready.rc").read_text()
    assert "disabled" in rc and "oneshot" in rc and "seclabel u:r:recovery:s0" in rc
    assert "property:twrp.variant.files_copied=1 && property:ro.twrp.weaver=nxp" in rc
    print(f"PASS: {len(cases)} readiness/retry/deadline controls; 5 actual ADSP scanner controls; RC guard; absolute property writer.")


if __name__ == "__main__":
    main()
