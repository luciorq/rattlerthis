#!/usr/bin/env bash
# Download the micromamba release binary for this runner, check its SHA-256,
# and export its path as CONDATHIS_MICROMAMBA_PATH: the binary condathis uses
# for `method = "micromamba"`, which rattlerthis's parity tests compare with
# `method = "rattler"`. The tests never download micromamba themselves.
#
# usage: install-micromamba.sh <version>   (e.g. 2.10.0-0, condathis's default)
set -euo pipefail

version="${1:?usage: install-micromamba.sh <version>}"

case "${RUNNER_OS}-${RUNNER_ARCH}" in
  Linux-X64) platform="linux-64" ;;
  Linux-ARM64) platform="linux-aarch64" ;;
  macOS-X64) platform="osx-64" ;;
  macOS-ARM64) platform="osx-arm64" ;;
  Windows-X64) platform="win-64" ;;
  Windows-ARM64) platform="win-arm64" ;;
  *)
    echo "No micromamba build for ${RUNNER_OS} on ${RUNNER_ARCH}." >&2
    exit 1
    ;;
esac

# Git Bash on Windows: work with a POSIX path, export a C:/... path for R.
if [ "${RUNNER_OS}" = "Windows" ]; then
  dir="$(cygpath -u "${RUNNER_TEMP}")/micromamba"
  exe="micromamba.exe"
else
  dir="${RUNNER_TEMP}/micromamba"
  exe="micromamba"
fi
mkdir -p "${dir}"

base="https://github.com/mamba-org/micromamba-releases/releases/download/${version}"
curl -fsSL --retry 5 --retry-delay 5 -o "${dir}/${exe}" "${base}/micromamba-${platform}"
curl -fsSL --retry 5 --retry-delay 5 -o "${dir}/micromamba.sha256" "${base}/micromamba-${platform}.sha256"

# The .sha256 file holds the hash of the raw binary, nothing else.
expected="$(tr -d ' \r\n' < "${dir}/micromamba.sha256")"
if command -v sha256sum > /dev/null 2>&1; then
  actual="$(sha256sum "${dir}/${exe}" | cut -d ' ' -f 1)"
else
  actual="$(shasum -a 256 "${dir}/${exe}" | cut -d ' ' -f 1)"
fi
if [ "${expected}" != "${actual}" ]; then
  echo "SHA-256 mismatch for micromamba-${platform} ${version}:" >&2
  echo "  expected ${expected}" >&2
  echo "  got      ${actual}" >&2
  exit 1
fi

chmod +x "${dir}/${exe}"
"${dir}/${exe}" --version

if [ "${RUNNER_OS}" = "Windows" ]; then
  path="$(cygpath -m "${dir}/${exe}")"
else
  path="${dir}/${exe}"
fi
echo "CONDATHIS_MICROMAMBA_PATH=${path}" >> "${GITHUB_ENV}"
echo "CONDATHIS_MICROMAMBA_PATH=${path}"
