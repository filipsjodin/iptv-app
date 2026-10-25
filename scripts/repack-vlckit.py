#!/usr/bin/env python3
"""Packar om det officiella VLCKit-arkivet till en smal zip med bara iOS- och tvOS-skivor.

Varje kopierad fil (binärer, headers, resurser) skrivs byte för byte och med samma zip-metadata
(tid, rättigheter) som i originalet. dSYMs och övriga plattformar utelämnas. Bara
VLCKit.xcframework/Info.plist skrivs om så att den listar de behållna skivorna, utan DebugSymbolsPath.
COPYING.txt (LGPL-2.1) följer med.

Användning: python3 -I scripts/repack-vlckit.py <original.zip> <utdata.zip>
"""
import plistlib
import sys
import zipfile

KEEP = ["ios-arm64", "ios-arm64_x86_64-simulator", "tvos-arm64", "tvos-arm64_x86_64-simulator"]
ROOT = "VLCKit.xcframework/"
PLIST = ROOT + "Info.plist"


def keep(name: str) -> bool:
    if name == "COPYING.txt":
        return True
    if not name.startswith(ROOT):
        return False
    parts = name[len(ROOT):].split("/")
    return parts[0] in KEEP and (len(parts) < 2 or parts[1] != "dSYMs")


def main(src: str, dst: str) -> None:
    with zipfile.ZipFile(src) as zin, zipfile.ZipFile(dst, "w", zipfile.ZIP_DEFLATED, compresslevel=9) as zout:
        plist_info = zin.getinfo(PLIST)
        plist = plistlib.loads(zin.read(PLIST))
        libraries = [lib for lib in plist["AvailableLibraries"] if lib["LibraryIdentifier"] in KEEP]
        found = sorted(lib["LibraryIdentifier"] for lib in libraries)
        if found != sorted(KEEP):
            sys.exit(f"saknade skivor: {sorted(set(KEEP) - set(found))}")
        for lib in libraries:
            lib.pop("DebugSymbolsPath", None)
        plist["AvailableLibraries"] = libraries

        root_dir = zin.getinfo(ROOT) if ROOT in zin.namelist() else None
        if root_dir is not None:
            zout.writestr(root_dir, b"")
        for info in zin.infolist():
            if info.filename == PLIST or info.filename == ROOT or not keep(info.filename):
                continue
            data = zin.read(info)
            info.compress_type = zipfile.ZIP_STORED if info.is_dir() else zipfile.ZIP_DEFLATED
            zout.writestr(info, data)
        plist_info.compress_type = zipfile.ZIP_DEFLATED
        zout.writestr(plist_info, plistlib.dumps(plist, fmt=plistlib.FMT_XML))


if __name__ == "__main__":
    if len(sys.argv) != 3:
        sys.exit(__doc__)
    main(sys.argv[1], sys.argv[2])
