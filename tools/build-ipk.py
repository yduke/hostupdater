#!/usr/bin/env python3
"""Build an OpenWrt .ipk package locally without the OpenWrt SDK.

The .ipk layout (ar-like outer tar.gz with debian-binary, data.tar.gz and
control.tar.gz) is stable and can be assembled on any platform. The .apk format
used by OpenWrt snapshots is not; use build.sh/Docker or GitHub Actions for it.

All metadata and maintainer scripts are read from the Makefile so there is a
single source of truth.
"""
import argparse
import gzip
import hashlib
import io
import os
import re
import sys
import tarfile
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
DEFAULT_OUT = ROOT / "output"

FILES = [
    ("files/usr/bin/hostupdater", "usr/bin/hostupdater", 0o755),
    ("files/etc/config/hostupdater", "etc/config/hostupdater", 0o644),
    ("files/etc/hostupdater/sources.conf", "etc/hostupdater/sources.conf", 0o644),
    ("files/etc/init.d/hostupdater", "etc/init.d/hostupdater", 0o755),
    ("files/lib/upgrade/keep.d/hostupdater", "lib/upgrade/keep.d/hostupdater", 0o644),
    ("luasrc/luci/controller/hostupdater.lua", "usr/lib/lua/luci/controller/hostupdater.lua", 0o644),
    ("luasrc/luci/view/admin/services/hostupdater.htm", "usr/lib/lua/luci/view/admin/services/hostupdater.htm", 0o644),
    ("files/usr/lib/lua/luci/i18n/hostupdater.zh-cn.lmo", "usr/lib/lua/luci/i18n/hostupdater.zh-cn.lmo", 0o644),
    ("files/usr/share/rpcd/acl.d/luci-hostupdater.json", "usr/share/rpcd/acl.d/luci-hostupdater.json", 0o644),
    ("files/usr/share/luci/menu.d/luci-hostupdater.json", "usr/share/luci/menu.d/luci-hostupdater.json", 0o644),
    ("files/usr/share/luci/applications.d/luci-app-hostupdater.json", "usr/share/luci/applications.d/luci-app-hostupdater.json", 0o644),
    ("files/usr/share/luci/icons/hostupdater.svg", "usr/share/luci/icons/hostupdater.svg", 0o644),
]


def makefile_define(name):
    text = (ROOT / "Makefile").read_text(encoding="utf-8")
    match = re.search(r"^define Package/\$\(PKG_NAME\)/%s\s*\n(.*?)^endef" % re.escape(name), text, re.M | re.S)
    if not match:
        raise SystemExit("missing Makefile define: %s" % name)
    return match.group(1).replace("$$", "$")


def makefile_var(name):
    text = (ROOT / "Makefile").read_text(encoding="utf-8")
    match = re.search(r"^\s*%s:?=(.*)$" % re.escape(name), text, re.M)
    if not match:
        raise SystemExit("missing Makefile variable: %s" % name)
    return match.group(1).strip()


def tarinfo(name, mode, size=0, directory=False, epoch=0):
    info = tarfile.TarInfo(name=name)
    info.mode = mode
    info.uid = 0
    info.gid = 0
    info.uname = "root"
    info.gname = "root"
    info.mtime = epoch
    if directory:
        info.type = tarfile.DIRTYPE
    else:
        info.size = size
    return info


def add_bytes(tar, name, data, mode, epoch):
    info = tarinfo(name, mode, len(data), epoch=epoch)
    tar.addfile(info, io.BytesIO(data))


def build_data(epoch):
    buf = io.BytesIO()
    with tarfile.open(fileobj=buf, mode="w", format=tarfile.GNU_FORMAT) as tar:
        dirs = {"."}
        for source, destination, mode in FILES:
            parent = os.path.dirname(destination)
            while parent:
                dirs.add(parent)
                parent = os.path.dirname(parent)
        for directory in sorted(dirs):
            name = "." if directory == "." else "./" + directory
            tar.addfile(tarinfo(name, 0o755, directory=True, epoch=epoch))
        for source, destination, mode in FILES:
            path = ROOT / source
            if not path.is_file():
                raise SystemExit("missing file: %s" % path)
            add_bytes(tar, "./" + destination, path.read_bytes(), mode, epoch)
    return gzip.compress(buf.getvalue(), mtime=0)


def build_control(epoch):
    version = "%s-r%s" % (makefile_var("PKG_VERSION"), makefile_var("PKG_RELEASE"))
    depends = makefile_var("DEPENDS").replace("+", "").strip()
    description = makefile_define("description").strip().splitlines()
    description = [line.strip() for line in description if line.strip()]
    installed_size = sum((ROOT / source).stat().st_size for source, _, _ in FILES)
    control = [
        "Package: hostupdater",
        "Version: %s" % version,
        "Depends: %s" % depends,
        "Source: hostupdater",
        "SourceName: hostupdater",
        "License: %s" % makefile_var("PKG_LICENSE"),
        "LicenseFiles: %s" % makefile_var("PKG_LICENSE_FILES"),
        "Section: utils",
        "SourceDateEpoch: %d" % epoch,
        "Maintainer: %s" % makefile_var("PKG_MAINTAINER"),
        "Architecture: all",
        "Installed-Size: %d" % installed_size,
        "Description: %s" % description[0],
    ]
    control += [" " + line for line in description[1:]]

    conffiles = "\n".join(
        line.strip() for line in makefile_define("conffiles").strip().splitlines() if line.strip()
    ) + "\n"
    scripts = {}
    for name in ("postinst", "prerm", "postrm"):
        body = makefile_define(name)
        body = body.lstrip("\n")
        if not body.startswith("#!"):
            body = "#!/bin/sh\n" + body
        scripts[name] = body

    buf = io.BytesIO()
    with tarfile.open(fileobj=buf, mode="w", format=tarfile.GNU_FORMAT) as tar:
        tar.addfile(tarinfo("./", 0o755, directory=True, epoch=epoch))
        add_bytes(tar, "./control", ("\n".join(control) + "\n").encode(), 0o644, epoch)
        add_bytes(tar, "./conffiles", conffiles.encode(), 0o644, epoch)
        for name, body in scripts.items():
            add_bytes(tar, "./" + name, body.encode(), 0o755, epoch)
    return gzip.compress(buf.getvalue(), mtime=0), version


def build_ipk(output, epoch):
    data = build_data(epoch)
    control, version = build_control(epoch)
    output.parent.mkdir(parents=True, exist_ok=True)
    with tarfile.open(output, "w:gz", format=tarfile.GNU_FORMAT) as tar:
        for name, payload in (("./debian-binary", b"2.0\n"), ("./data.tar.gz", data), ("./control.tar.gz", control)):
            add_bytes(tar, name, payload, 0o644, epoch)
    return version, data, control


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("-o", "--output", default=None)
    parser.add_argument("--epoch", type=int, default=int(os.environ.get("SOURCE_DATE_EPOCH", "0")))
    args = parser.parse_args()

    output = Path(args.output) if args.output else DEFAULT_OUT / "hostupdater.ipk"
    version, data, control = build_ipk(output, args.epoch)
    final = output.parent / ("hostupdater_%s_all.ipk" % version)
    if output != final:
        output.replace(final)
    print("wrote %s" % final)
    print("  data.tar.gz    %d bytes  sha256=%s" % (len(data), hashlib.sha256(data).hexdigest()[:16]))
    print("  control.tar.gz %d bytes  sha256=%s" % (len(control), hashlib.sha256(control).hexdigest()[:16]))
    return 0


if __name__ == "__main__":
    sys.exit(main())
