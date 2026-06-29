#!/usr/bin/env bash
# Install MMseqs2, BLAST+, and FASTA36 for macOS.
# Uses Homebrew for MMseqs2/BLAST+ when available; otherwise falls back to
# upstream tarball downloads. FASTA36: clone upstream — see install/fasta36_install.sh.

set -euo pipefail

die() { echo "[install_external_macos] ERROR: $*" >&2; exit 1; }
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

if [[ $# -ne 1 ]]; then
  echo "Usage: $0 <chisel_dir>" >&2
  exit 2
fi
[[ -d "$1" ]] || die "not a directory: $1"
CHISEL_DIR="$(cd "$1" && pwd)"
[[ -f "${CHISEL_DIR}/Makefile" ]] || die "does not look like chisel root: ${CHISEL_DIR}"
[[ "$(uname -s)" == "Darwin" ]] || die "this script is macOS-only"

MAC_ARCH="$(uname -m)"
# Apple Silicon: try native darwin makefiles before x86_64/SSE4 variants.
case "${MAC_ARCH}" in
  arm64)
    FASTA_MAKEFILES=(
      ../make/Makefile.os_darwin
      ../make/Makefile.macosx
      ../make/Makefile.os_x86_64
      ../make/Makefile.os_x86_64_sse4
    )
    ;;
  x86_64|i386)
    FASTA_MAKEFILES=(
      ../make/Makefile.os_x86_64
      ../make/Makefile.os_x86_64_sse4
      ../make/Makefile.os_darwin
      ../make/Makefile.macosx
    )
    ;;
  *)
    FASTA_MAKEFILES=(
      ../make/Makefile.os_darwin
      ../make/Makefile.macosx
      ../make/Makefile.os_x86_64
      ../make/Makefile.os_x86_64_sse4
    )
    ;;
esac

INSTALL_MACOS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

USE_BREW=0
if command -v brew >/dev/null 2>&1; then
  USE_BREW=1
fi

if [[ "${USE_BREW}" -eq 1 ]]; then
  echo "[install_external_macos] uname -m=${MAC_ARCH} (using Homebrew for mmseqs2/blast)"
else
  echo "[install_external_macos] uname -m=${MAC_ARCH} (brew not found; using tarball fallback for mmseqs2/blast)"
fi

EXTERNAL="${CHISEL_DIR}/external_tools"
WORKDIR="${EXTERNAL}/.downloads"
mkdir -p "${WORKDIR}"

need_cmd make
need_cmd tar

MMSEQS_TAG="${MMSEQS_TAG:-18-8cc5c}"
MMSEQS_MACOS_ASSET="${MMSEQS_MACOS_ASSET:-osx-universal}"
BLAST_VERSION="${BLAST_VERSION:-2.15.0}"
BLAST_PLATFORM="${BLAST_PLATFORM:-x64-macosx}"

mkdir -p "${EXTERNAL}/mmseqs/bin" "${EXTERNAL}/ncbi-blast/bin" "${EXTERNAL}/fasta36/bin"

if [[ "${SKIP_MMSEQS:-0}" != "1" ]]; then
  if [[ "${USE_BREW}" -eq 1 ]]; then
    echo "[install_external_macos] Installing MMseqs2 via Homebrew..."
    brew list mmseqs2 >/dev/null 2>&1 || brew install mmseqs2
    mmseqs_path="$(command -v mmseqs || true)"
    [[ -x "${mmseqs_path}" ]] || die "mmseqs not found after brew install"
    ln -sf "${mmseqs_path}" "${EXTERNAL}/mmseqs/bin/mmseqs"
  else
    mmseqs_tgz="${WORKDIR}/mmseqs-${MMSEQS_MACOS_ASSET}.tar.gz"
    mmseqs_url="https://github.com/soedinglab/MMseqs2/releases/download/${MMSEQS_TAG}/mmseqs-${MMSEQS_MACOS_ASSET}.tar.gz"
    echo "[install_external_macos] Installing MMseqs2 from tarball (${MMSEQS_MACOS_ASSET})..."
    fetch "${mmseqs_url}" "${mmseqs_tgz}"
    rm -rf "${EXTERNAL}/mmseqs"
    tar xzf "${mmseqs_tgz}" -C "${EXTERNAL}"
    [[ -x "${EXTERNAL}/mmseqs/bin/mmseqs" ]] || die "MMseqs2 binary missing after extract"
  fi
fi

if [[ "${SKIP_BLAST:-0}" != "1" ]]; then
  if [[ "${USE_BREW}" -eq 1 ]]; then
    echo "[install_external_macos] Installing BLAST+ via Homebrew..."
    brew list blast >/dev/null 2>&1 || brew install blast
    blastp_path="$(command -v blastp || true)"
    makeblastdb_path="$(command -v makeblastdb || true)"
    [[ -x "${blastp_path}" && -x "${makeblastdb_path}" ]] || die "blast tools not found after brew install"
    ln -sf "${blastp_path}" "${EXTERNAL}/ncbi-blast/bin/blastp"
    ln -sf "${makeblastdb_path}" "${EXTERNAL}/ncbi-blast/bin/makeblastdb"
  else
    blast_tgz="${WORKDIR}/ncbi-blast-${BLAST_VERSION}+-${BLAST_PLATFORM}.tar.gz"
    blast_url="https://ftp.ncbi.nlm.nih.gov/blast/executables/blast+/${BLAST_VERSION}/ncbi-blast-${BLAST_VERSION}+-${BLAST_PLATFORM}.tar.gz"
    echo "[install_external_macos] Installing BLAST+ from tarball (${BLAST_PLATFORM})..."
    fetch "${blast_url}" "${blast_tgz}"
    rm -rf "${EXTERNAL}/ncbi-blast"
    tar xzf "${blast_tgz}" -C "${EXTERNAL}"
    blast_dir="$(ls -d "${EXTERNAL}"/ncbi-blast-*+ 2>/dev/null | sed -n '1p')"
    [[ -n "${blast_dir}" ]] || die "could not find extracted ncbi-blast-*+ directory"
    mv "${blast_dir}" "${EXTERNAL}/ncbi-blast"
    [[ -x "${EXTERNAL}/ncbi-blast/bin/blastp" && -x "${EXTERNAL}/ncbi-blast/bin/makeblastdb" ]] || die "BLAST+ binaries missing"
  fi
fi

if [[ "${SKIP_FASTA:-0}" != "1" ]]; then
  need_cmd codesign
  # shellcheck source=../fasta36_install.sh
  source "${INSTALL_MACOS_DIR}/../fasta36_install.sh"
  fasta36_install "${CHISEL_DIR}" "${FASTA_MAKEFILES[@]}"
  BUILT_SSEARCH="${EXTERNAL}/fasta36/bin/ssearch36"
  [[ -f "${BUILT_SSEARCH}" ]] || die "ssearch36 missing after build"
  # Build outputs written straight into bin/ confuse Gatekeeper/codesign; stage via tmp, sign, then install.
  tmp_exe="$(mktemp "${TMPDIR:-/tmp}/ssearch36.XXXXXX")"
  cleanup_tmp() { rm -f "${tmp_exe}"; }
  trap cleanup_tmp EXIT
  cp "${BUILT_SSEARCH}" "${tmp_exe}"
  chmod +x "${tmp_exe}"
  codesign --force --sign - "${tmp_exe}" || die "codesign failed for ssearch36 (tmp ${tmp_exe})"
  cp "${tmp_exe}" "${BUILT_SSEARCH}"
  chmod +x "${BUILT_SSEARCH}"
  cleanup_tmp
  trap - EXIT
fi

echo ""
echo "Done. Point chisel_filter config at:"
echo "  MMSEQS=\"${EXTERNAL}/mmseqs/bin/mmseqs\""
echo "  BLAST_DIR=\"${EXTERNAL}/ncbi-blast/bin\""
echo "  FASTA_DIR=\"${EXTERNAL}/fasta36/bin\""
