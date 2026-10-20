#!/usr/bin/env python3
"""Host controls for exact pinned SPR builders; no DRM device or source writes."""
import argparse
import hashlib
import json
from pathlib import Path
import re
import shutil
import subprocess
import tempfile


REVISION = "0f7831d3240f4c3925a0b5fd7d2c907ddf8704c2"
BLOB = "0cc80f5cb0c00368556174c35dac0dbfe54ec6f9"
FILE = "minuitwrp/graphics_drm.cpp"
PORT = Path(__file__).resolve().parent


def require(condition, message):
    if not condition:
        raise RuntimeError(message)


def pinned_source(source_dir):
    result = subprocess.run(
        ["git", "-C", str(source_dir / "bootable/recovery"),
         "show", f"{REVISION}:{FILE}"], check=True, capture_output=True,
    )
    raw = result.stdout
    digest = hashlib.sha1(b"blob " + str(len(raw)).encode() + b"\0" + raw).hexdigest()
    require(digest == BLOB, "Unexpected pinned graphics_drm Git blob")
    return raw.decode("utf-8")


def apply_fragment(original):
    entries = json.loads((PORT / "display-source-edits.json").read_text())
    require(len(entries) == 8, "Unexpected display edit count")
    source = original
    for edit in entries:
        require(set(edit) == {"project", "file", "before", "after"}, "Invalid edit schema")
        require(edit["project"] == "bootable/recovery" and edit["file"] == FILE,
                "Unexpected display edit target")
        require(source.count(edit["before"]) == 1, "Nonunique display source match")
        source = source.replace(edit["before"], edit["after"], 1)
    return source


def harness(source):
    definitions = source[source.index("#define SPR_INIT_PARAM_SIZE_1"):source.index("struct Crtc {")]
    structs = []
    for name in ("drm_msm_spr_init_cfg", "drm_msm_spr_init_cfg_v2"):
        match = re.search(r"struct " + name + r" \{.*?\n\};", source, re.S)
        require(match is not None, f"Missing SPR struct: {name}")
        structs.append(match.group())
    functions = source[source.index("static int SetupSprBlobV1("):
                       source.index("static int atomic_populate_plane(")]
    reads = re.findall(r'^  spr_(?:enabled|bypass) = android::base::GetIntProperty\([^\n]+\);$',
                       source, re.M)
    require(len(reads) == 2, "Missing exact SPR property reads")
    return r'''
#include <algorithm>
#include <array>
#include <cerrno>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <map>
#include <string>
#include <vector>
using __u8 = std::uint8_t;
using __u16 = std::uint16_t;
using __u32 = std::uint32_t;
using __u64 = std::uint64_t;
''' + definitions + "\n" + "\n".join(structs) + r'''
static uint32_t spr_enabled;
static uint32_t spr_bypass;
static std::map<std::string, int> properties;
namespace android::base {
static int GetIntProperty(const char* name, int fallback) {
    auto it = properties.find(name);
    return it == properties.end() ? fallback : it->second;
}
}
static void read_properties() {
''' + "\n".join(reads) + r'''
}
static std::vector<unsigned char> captured;
static bool fail_blob;
static int last_fd;
static int drmModeCreatePropertyBlob(int fd, const void* data, size_t size, uint32_t* id) {
    last_fd = fd;
    if (fail_blob) return -1;
    const auto* bytes = static_cast<const unsigned char*>(data);
    captured.assign(bytes, bytes + size);
    *id = 73;
    return 0;
}
''' + functions + r'''
static void check(bool condition, const char* message) {
    if (!condition) {
        std::fprintf(stderr, "SPR invariant failed: %s\n", message);
        std::exit(1);
    }
}
template<class T> static T payload() {
    check(captured.size() == sizeof(T), "exact kernel blob size");
    T value;
    std::memcpy(&value, captured.data(), sizeof(value));
    return value;
}
template<class T> static void common(const T& value, bool bypass) {
    check(value.flags == (bypass ? 1u : 0u), "bypass bit/default preserved");
    check(value.cfg0 == 1 && value.cfg1 == 1 && value.cfg2 == 1 && value.cfg3 == 0,
          "existing enable/config fields preserved");
    check(value.cfg4 == 0 && value.cfg5 == 8 && value.cfg6 == 2,
          "existing Pentile parameters preserved");
    check(value.cfg7 == static_cast<uint16_t>(SPRFilterType::kFourTap) &&
          value.cfg8 == static_cast<uint16_t>(SPRAdaptiveModeType::kYYGM),
          "existing filter/adaptive mode preserved");
    check(value.cfg9 == 0 && value.cfg10 == 0, "unused scalar fields zero");
    check(std::all_of(std::begin(value.cfg12), std::end(value.cfg12),
                      [](auto n) { return n == 0; }), "unused cfg12 zero");
    const auto& decimation = kDecimationRatioMap.at(SPRPackType::kPentile);
    const auto& coefficients = kDefaultFilterCoeffsMap.at(SPRFilterType::kFourTap);
    const auto& phases = kDefaultColorPhaseMap.at(SPRPackType::kPentile);
    check(std::equal(std::begin(value.cfg11), std::end(value.cfg11), decimation.begin()),
          "decimation unchanged");
    check(std::equal(std::begin(value.cfg13), std::end(value.cfg13), kDefaultOPRGains.begin()),
          "OPR gains unchanged");
    check(std::equal(std::begin(value.cfg14), std::end(value.cfg14), kDefaultAdaptiveStrengths.begin()),
          "adaptive strengths unchanged");
    check(std::equal(std::begin(value.cfg15), std::end(value.cfg15), kDefaultOPROffsets.begin()),
          "OPR offsets unchanged");
    check(std::equal(std::begin(value.cfg16), std::end(value.cfg16), coefficients.begin()),
          "filter coefficients unchanged");
    check(std::equal(std::begin(value.cfg17), std::end(value.cfg17), phases.begin()),
          "color phases unchanged");
}
int main() {
    read_properties();
    check(spr_enabled == 0 && spr_bypass == 0, "absent properties default to zero");
    for (int bypass : {0, 1}) {
        properties["vendor.display.enable_spr"] = 1;
        properties["vendor.display.enable_spr_bypass"] = bypass;
        read_properties();
        check(spr_enabled == 1 && spr_bypass == static_cast<uint32_t>(bypass),
              "device properties read independently");
        for (const std::string version : {"SDE_SPR_INIT_CFG_V1", "SDE_SPR_INIT_CFG_V2"}) {
            uint32_t id = 0;
            check(SetupSprBlob(41, version, &id) == 0 && id == 73 && last_fd == 41,
                  "successful dispatch/kernel handle");
            const auto first = captured;
            if (version == "SDE_SPR_INIT_CFG_V1") {
                common(payload<drm_msm_spr_init_cfg>(), bypass);
            } else {
                const auto value = payload<drm_msm_spr_init_cfg_v2>();
                common(value, bypass);
                check(value.cfg18_en == 0 &&
                      std::all_of(std::begin(value.cfg18), std::end(value.cfg18),
                                  [](auto n) { return n == 0; }), "unused V2 cfg18 zero");
            }
            for (int repeat = 0; repeat < 32; ++repeat) {
                check(SetupSprBlob(41, version, &id) == 0 && captured == first,
                      "repeatable complete kernel payload");
            }
            fail_blob = true;
            captured.clear();
            id = 99;
            check(SetupSprBlob(41, version, &id) == -EINVAL && id == 99 && captured.empty(),
                  "kernel failure propagated without output");
            fail_blob = false;
        }
    }
    captured.clear();
    uint32_t id = 99;
    check(SetupSprBlob(41, "UNKNOWN", &id) == -ENOENT && id == 99 && captured.empty(),
          "unknown SPR property rejected");
    return 0;
}
'''


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source-dir", type=Path, default=Path("/home/android/OrangeFox"))
    parser.add_argument("--cxx", default="c++")
    args = parser.parse_args()
    compiler = shutil.which(args.cxx)
    require(compiler is not None, "Host C++ compiler not found")
    original = pinned_source(args.source_dir)
    source = apply_fragment(original)
    controls = {
        "patched": (source, 0),
        "missing-bypass": (source.replace(".flags = spr_bypass ? SPR_FLAG_BYPASS : 0;",
                                          ".flags = 0;"), 1),
        "missing-zero-init": (source.replace("spr_init_cfg = {};", "spr_init_cfg;")
                             .replace("spr_init_cfg_v2 = {};", "spr_init_cfg_v2;"), 1),
    }
    with tempfile.TemporaryDirectory(prefix="android-dev-display-spr-") as temporary:
        temp = Path(temporary)
        for name, (text, expected) in controls.items():
            cpp, binary = temp / (name + ".cpp"), temp / name
            cpp.write_text(harness(text))
            subprocess.run([compiler, "-std=gnu++20", "-fno-exceptions", "-O0",
                            "-ftrivial-auto-var-init=pattern", "-Wall", "-Wextra", "-Werror",
                            str(cpp), "-o", str(binary)], check=True, cwd=temp)
            result = subprocess.run([str(binary)], capture_output=True, text=True, cwd=temp)
            require(result.returncode == expected,
                    f"{name}: exit {result.returncode}, expected {expected}: {result.stderr}")
            print(f"PASS: {name}" + (f" rejected: {result.stderr.strip()}" if expected else ""))
    print("PASS: exact V1/V2 builders, bypass 0/1, zero defaults, payload repeatability, dispatch/errors")
    print("Pinned Git blob: " + BLOB)
    print("Patched file SHA256: " + hashlib.sha256(source.encode()).hexdigest())


if __name__ == "__main__":
    main()
