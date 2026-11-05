#!/usr/bin/env python3
"""Build the local wheel of rattlerthis's pip tests.

usage: python3 -I tools/make-test-wheel.py [out_dir]

out_dir defaults to tests/testthat/fixtures/pip next to this script's
directory. The output is deterministic (fixed timestamps and order), so a
rebuild leaves git with nothing to commit.

The wheel is `rtwheel-1.0-py3-none-any.whl`: a pure Python package
`rtwheel` (`rtwheel.__version__ == "1.0"`) without dependencies, which
pip installs from the file without an index. The pip tests install it
from the `pip:` section of an environment file and from the pip packages
of lock files, with both backends.
"""

import base64
import hashlib
import os
import sys
import zipfile

NAME = "rtwheel"
VERSION = "1.0"
TAG = "py3-none-any"
DATE_TIME = (2020, 1, 1, 0, 0, 0)


def record_hash(data):
    digest = hashlib.sha256(data).digest()
    return "sha256=" + base64.urlsafe_b64encode(digest).decode("ascii").rstrip("=")


def wheel_files():
    dist_info = NAME + "-" + VERSION + ".dist-info"
    files = [
        (NAME + "/__init__.py", '__version__ = "' + VERSION + '"\n'),
        (
            dist_info + "/METADATA",
            "Metadata-Version: 2.1\n"
            "Name: " + NAME + "\n"
            "Version: " + VERSION + "\n"
            "Summary: The test wheel of rattlerthis\n",
        ),
        (
            dist_info + "/WHEEL",
            "Wheel-Version: 1.0\n"
            "Generator: rattlerthis make-test-wheel.py\n"
            "Root-Is-Purelib: true\n"
            "Tag: " + TAG + "\n",
        ),
    ]
    files = [(path, text.encode("ascii")) for path, text in files]
    record = "".join(
        path + "," + record_hash(data) + "," + str(len(data)) + "\n"
        for path, data in files
    )
    record += dist_info + "/RECORD,,\n"
    files.append((dist_info + "/RECORD", record.encode("ascii")))
    return files


def main():
    here = os.path.dirname(os.path.abspath(__file__))
    default_out = os.path.join(here, "..", "tests", "testthat", "fixtures", "pip")
    out_dir = sys.argv[1] if len(sys.argv) > 1 else default_out
    os.makedirs(out_dir, exist_ok=True)
    path = os.path.join(out_dir, NAME + "-" + VERSION + "-" + TAG + ".whl")
    with zipfile.ZipFile(path, "w", compression=zipfile.ZIP_DEFLATED) as zf:
        for name, data in wheel_files():
            info = zipfile.ZipInfo(name, date_time=DATE_TIME)
            info.compress_type = zipfile.ZIP_DEFLATED
            info.external_attr = 0o644 << 16
            zf.writestr(info, data)
    with open(path, "rb") as fh:
        print(path, hashlib.sha256(fh.read()).hexdigest())


if __name__ == "__main__":
    main()
