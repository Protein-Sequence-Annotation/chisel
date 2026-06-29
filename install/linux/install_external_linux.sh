#!/usr/bin/env bash
# Install MMseqs2, NCBI BLAST+, and FASTA36 into <chisel_dir>/external_tools (Linux).
# Detects CPU (x86_64 vs aarch64) and picks matching upstream binaries / FASTA makefiles.
# FASTA36: clones upstream wrpearson/fasta36 — see install/fasta36_install.sh.

set -euo pipefail

die() { echo "[install_external_linux] ERROR: $*" >&2; exit 1; }

if [[ $# -ne 1 ]]; then
  echo "Usage: $0 <chisel_dir>" >&2
  exit 2
fi
[[ -d "$1" ]] || die "not a directory: $1"
CHISEL_DIR="$(cd "$1" && pwd)"
[[ -f "${CHISEL_DIR}/Makefile" ]] || die "does not look like CHISEL root: ${CHISEL_DIR}"

EXTERNAL="${CHISEL_DIR}/external_tools"
WORKDIR="${EXTERNAL}/.downloads"
mkdir -p "${WORKDIR}"

need_cmd() { command -v "$1" >/dev/null 2>&1 || die "required command not found: $1"; }
fetch() {
  local url="$1" dest="$2"
  if command -v curl >/dev/null 2>&1; then
    curl -fsSL --retry 3 --connect-timeout 30 -o "$dest" "$url"
  elif command -v wget >/dev/null 2>&1; then
    wget -q --tries=3 --timeout=30 -O "$dest" "$url"
  else
    die "need curl or wget to download"
  fi
}

[[ "$(uname -s)" == "Linux" ]] || die "this script is Linux-only"

machine="$(uname -m)"
# MMseqs2 release assets: mmseqs-linux-{sse2,sse41,avx2,arm64,...}.tar.gz
# NCBI BLAST+: ncbi-blast-VERSION+-{x64-linux,aarch64-linux}.tar.gz
case "${machine}" in
  x86_64|amd64)
    MMSEQS_ARCH="${MMSEQS_ARCH:-sse2}"
    BLAST_PLATFORM="${BLAST_PLATFORM:-x64-linux}"
    FASTA_MAKEFILES=(
      ../make/Makefile.linux64_sse2
      ../make/Makefile.linux64
      ../make/Makefile.linux_sse2
    )
    ;;
  aarch64|arm64)
    MMSEQS_ARCH="${MMSEQS_ARCH:-arm64}"
    BLAST_PLATFORM="${BLAST_PLATFORM:-aarch64-linux}"
    # No SSE on ARM — use generic 64-bit / portable Linux makefiles
    FASTA_MAKEFILES=(
      ../make/Makefile.linux64
      ../make/Makefile.linux
    )
    ;;
  *)
    die "unsupported Linux machine type '${machine}'. Supported: x86_64, aarch64. Install tools manually or set SKIP_MMSEQS/SKIP_BLAST/SKIP_FASTA and point chisel_filter at your own binaries."
    ;;
esac

need_cmd tar
need_cmd make

MMSEQS_TAG="${MMSEQS_TAG:-18-8cc5c}"
BLAST_VERSION="${BLAST_VERSION:-2.15.0}"

MMSEQS_URL="https://github.com/soedinglab/MMseqs2/releases/download/${MMSEQS_TAG}/mmseqs-linux-${MMSEQS_ARCH}.tar.gz"
BLAST_URL="https://ftp.ncbi.nlm.nih.gov/blast/executables/blast+/${BLAST_VERSION}/ncbi-blast-${BLAST_VERSION}+-${BLAST_PLATFORM}.tar.gz"

echo "[install_external_linux] CHISEL root: ${CHISEL_DIR}"
echo "[install_external_linux] Install prefix: ${EXTERNAL}"
echo "[install_external_linux] uname -m=${machine} MMseqs2 asset=mmseqs-linux-${MMSEQS_ARCH}.tar.gz BLAST platform=${BLAST_PLATFORM}"
mkdir -p "${EXTERNAL}"

if [[ "${SKIP_MMSEQS:-0}" != "1" ]]; then
  mmseqs_tgz="${WORKDIR}/mmseqs-linux-${MMSEQS_ARCH}.tar.gz"
  echo "[install_external_linux] Installing MMseqs2..."
  fetch "${MMSEQS_URL}" "${mmseqs_tgz}"
  rm -rf "${EXTERNAL}/mmseqs"
  tar xzf "${mmseqs_tgz}" -C "${EXTERNAL}"
  [[ -x "${EXTERNAL}/mmseqs/bin/mmseqs" ]] || die "MMseqs2 binary missing after extract"
fi

if [[ "${SKIP_BLAST:-0}" != "1" ]]; then
  blast_tgz="${WORKDIR}/ncbi-blast-${BLAST_VERSION}+-${BLAST_PLATFORM}.tar.gz"
  echo "[install_external_linux] Installing BLAST+..."
  fetch "${BLAST_URL}" "${blast_tgz}"
  rm -rf "${EXTERNAL}/ncbi-blast"
  tar xzf "${blast_tgz}" -C "${EXTERNAL}"
  blast_dir="$(ls -d "${EXTERNAL}"/ncbi-blast-*+ 2>/dev/null | sed -n '1p')"
  [[ -n "${blast_dir}" ]] || die "could not find extracted ncbi-blast-*+ directory"
  mv "${blast_dir}" "${EXTERNAL}/ncbi-blast"
  [[ -x "${EXTERNAL}/ncbi-blast/bin/blastp" && -x "${EXTERNAL}/ncbi-blast/bin/makeblastdb" ]] || die "BLAST+ binaries missing"
fi

if [[ "${SKIP_FASTA:-0}" != "1" ]]; then
  INSTALL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
  # shellcheck source=../fasta36_install.sh
  source "${INSTALL_DIR}/fasta36_install.sh"
  fasta36_install "${CHISEL_DIR}" "${FASTA_MAKEFILES[@]}"
fi

echo ""
echo "Done. Point chisel_filter config at:"
echo "  MMSEQS=\"${EXTERNAL}/mmseqs/bin/mmseqs\""
echo "  BLAST_DIR=\"${EXTERNAL}/ncbi-blast/bin\""
echo "  FASTA_DIR=\"${EXTERNAL}/fasta36/bin\""
