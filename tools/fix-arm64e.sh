#!/usr/bin/env bash
#
# Some Linux Theos toolchains link an arm64e object into a Mach-O whose
# cpusubtype is 0 instead of the ptrauth ABI value iOS expects (0x80000002).
# This script patches the header and re-signs the image.
#
# Usage: ./tools/fix-arm64e.sh .theos/obj/debug/FilesFullName.dylib
#
set -euo pipefail

DYLIB="${1:?usage: $0 <path-to-dylib>}"

python3 - "$DYLIB" <<'PY'
import struct
import sys

path = sys.argv[1]
data = bytearray(open(path, "rb").read())
magic, cputype, cpusubtype, filetype = struct.unpack("<Iiii", data[:16])
if cputype != 0x0100000C:
    raise SystemExit("not an arm64e image (build with ARCHS = arm64e)")
data[8:12] = struct.pack("<I", 0x80000002)  # ptrauth ABI + ARM64E
open(path, "wb").write(data)
print("patched cpusubtype to 0x80000002:", path)
PY

LDID="${THEOS:-/opt/theos}/toolchain/linux/iphone/bin/ldid"
if [ ! -x "$LDID" ]; then
    LDID="$(command -v ldid)"
fi
"$LDID" -S "$DYLIB"
echo "re-signed $DYLIB"
