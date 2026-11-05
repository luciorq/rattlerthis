#!/usr/bin/env python3
"""Build the local conda channels of rattlerthis's tests.

usage: python3 -I tools/make-test-channels.py [out_dir]

out_dir defaults to tests/testthat/fixtures/channels next to this script's
directory. Every channel is rebuilt from scratch; the output is
deterministic (fixed timestamps, owners and order), so a rebuild of an
unchanged spec leaves git with nothing to commit.

The packages are tiny `.tar.bz2` archives with only `info/` metadata and a
README (plink: link scripts too). Channels and packages:

  chA        foo 1.0                          noarch
  chB        foo 2.0, bar 1.0 (foo >=2)       noarch
  chC        baz 1.0                          noarch
  chD        devtool 1.0                      noarch
  plink      plink 1.0, with pre-link, post-link and pre-unlink scripts
             (`bin/.plink-<kind>.sh` and `Scripts/.plink-<kind>.bat`), each
             writing `<prefix>/<kind>-ran` when it runs           noarch
  osxonly    osxonly 1.0                      osx-64 only
  winonly    winonly 1.0                      win-64 only
  intelonly  intelonly 1.0                    linux-64, osx-64 and win-64

Each channel has a repodata.json in `noarch` and in every subdir of
SUBDIRS (empty where the channel has no package for it), so both backends
find every subdir they query for the platforms the tests use. The test
helper adds an empty repodata.json for the other known subdirs of
condathis when it copies the channels.

The env-file fixtures (tests/testthat/fixtures/envfiles) name these
archives (`chA/noarch/foo-1.0-0.tar.bz2`) and take their hashes from the
repodata.json files.
"""

import hashlib
import io
import json
import os
import shutil
import sys
import tarfile

MTIME = 1700000000
TIMESTAMP = MTIME * 1000
SUBDIRS = (
    "noarch",
    "linux-64",
    "linux-aarch64",
    "osx-64",
    "osx-arm64",
    "win-64",
    "win-arm64",
)


def sh_script(kind):
    return '#!/bin/sh\necho ran > "$PREFIX/' + kind + '-ran"\n'


def bat_script(kind):
    return '@echo ran> "%PREFIX%\\' + kind + '-ran"\r\n'


def plink_files(version):
    files = {"share/plink/README": "plink " + version + "\n"}
    for kind in ("pre-link", "post-link", "pre-unlink"):
        files["bin/.plink-" + kind + ".sh"] = sh_script(kind)
        files["Scripts/.plink-" + kind + ".bat"] = bat_script(kind)
    return files


def pkg(name, version, depends=(), subdirs=("noarch",), files=None):
    return {
        "name": name,
        "version": version,
        "depends": list(depends),
        "subdirs": list(subdirs),
        "files": files,
    }


CHANNELS = {
    "chA": [pkg("foo", "1.0")],
    "chB": [pkg("foo", "2.0"), pkg("bar", "1.0", depends=["foo >=2"])],
    "chC": [pkg("baz", "1.0")],
    "chD": [pkg("devtool", "1.0")],
    "plink": [pkg("plink", "1.0", files=plink_files("1.0"))],
    "osxonly": [pkg("osxonly", "1.0", subdirs=["osx-64"])],
    "winonly": [pkg("winonly", "1.0", subdirs=["win-64"])],
    "intelonly": [pkg("intelonly", "1.0", subdirs=["linux-64", "osx-64", "win-64"])],
}


def encode(content):
    return content if isinstance(content, bytes) else content.encode("utf-8")


def add_member(tf, name, data, mode):
    info = tarfile.TarInfo(name)
    info.size = len(data)
    info.mtime = MTIME
    info.mode = mode
    info.uid = 0
    info.gid = 0
    info.uname = ""
    info.gname = ""
    tf.addfile(info, io.BytesIO(data))


def build_package(subdir_dir, spec, subdir):
    name, version = spec["name"], spec["version"]
    files = spec["files"] or {
        "share/" + name + "/README": name + " " + version + "\n"
    }
    files = {path: encode(content) for path, content in sorted(files.items())}
    paths = [
        {
            "_path": path,
            "path_type": "hardlink",
            "sha256": hashlib.sha256(data).hexdigest(),
            "size_in_bytes": len(data),
        }
        for path, data in files.items()
    ]
    index = {
        "build": "0",
        "build_number": 0,
        "depends": spec["depends"],
        "license": "MIT",
        "name": name,
        "subdir": subdir,
        "timestamp": TIMESTAMP,
        "version": version,
    }
    if subdir == "noarch":
        index["noarch"] = "generic"
    meta = {
        "info/index.json": encode(json.dumps(index, sort_keys=True)),
        "info/paths.json": encode(
            json.dumps({"paths": paths, "paths_version": 1}, sort_keys=True)
        ),
        "info/files": encode("\n".join(files) + "\n"),
    }
    buf = io.BytesIO()
    with tarfile.open(fileobj=buf, mode="w:bz2", format=tarfile.USTAR_FORMAT) as tf:
        for member, data in list(meta.items()) + list(files.items()):
            mode = 0o755 if member.endswith(".sh") else 0o644
            add_member(tf, member, data, mode)
    data = buf.getvalue()
    filename = name + "-" + version + "-0.tar.bz2"
    with open(os.path.join(subdir_dir, filename), "wb") as out:
        out.write(data)
    record = dict(index)
    record.update(
        {
            "md5": hashlib.md5(data).hexdigest(),
            "sha256": hashlib.sha256(data).hexdigest(),
            "size": len(data),
        }
    )
    return filename, record


def write_repodata(subdir_dir, subdir, records):
    repodata = {
        "info": {"subdir": subdir},
        "packages": records,
        "packages.conda": {},
        "repodata_version": 1,
    }
    with open(os.path.join(subdir_dir, "repodata.json"), "w", newline="\n") as out:
        json.dump(repodata, out, indent=1, sort_keys=True)
        out.write("\n")


def main():
    here = os.path.dirname(os.path.abspath(__file__))
    default_out = os.path.join(
        os.path.dirname(here), "tests", "testthat", "fixtures", "channels"
    )
    out_dir = sys.argv[1] if len(sys.argv) > 1 else default_out
    os.makedirs(out_dir, exist_ok=True)
    for channel, packages in CHANNELS.items():
        channel_dir = os.path.join(out_dir, channel)
        if os.path.isdir(channel_dir):
            shutil.rmtree(channel_dir)
        records = {subdir: {} for subdir in SUBDIRS}
        for spec in packages:
            for subdir in spec["subdirs"]:
                subdir_dir = os.path.join(channel_dir, subdir)
                os.makedirs(subdir_dir, exist_ok=True)
                filename, record = build_package(subdir_dir, spec, subdir)
                records.setdefault(subdir, {})[filename] = record
        for subdir, subdir_records in records.items():
            subdir_dir = os.path.join(channel_dir, subdir)
            os.makedirs(subdir_dir, exist_ok=True)
            write_repodata(subdir_dir, subdir, subdir_records)
        summary = {
            subdir + "/" + fn: rec["md5"]
            for subdir, recs in sorted(records.items())
            for fn, rec in sorted(recs.items())
        }
        print(channel, summary)


if __name__ == "__main__":
    main()
