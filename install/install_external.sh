#!/usr/bin/env bash
# Dispatcher for OS-specific external tool installers.
#
# Usage:
#   install/install_external.sh <CHISEL_dir>
#
# FASTA36: FASTA36_MODE=custom (default, bundled CHISEL tree) or legacy (upstream + patch).
#   Optional: FASTA36_CUSTOM_REPO / FASTA36_CUSTOM_REF when the CHISEL fork is published.
#   Legacy: FASTA36_LEGACY_REPO / FASTA36_LEGACY_REF (defaults: wrpearson/fasta36, master).
#
# Routes to:
#   install/linux/install_external_linux.sh
#   install/macos/install_external_macos.sh
#   install/windows/install_external_windows.ps1

set -euo pipefail

die() { echo "[install_external] ERROR: $*" >&2; exit 1; }

if [[ $# -ne 1 ]]; then
  echo "Usage: $0 <CHISEL_dir>" >&2
  exit 2
fi

[[ -d "$1" ]] || die "not a directory: $1"
CHISEL_DIR="$(cd "$1" && pwd)"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OS_NAME="$(uname -s)"

case "${OS_NAME}" in
  Linux)
    exec "${SCRIPT_DIR}/linux/install_external_linux.sh" "${CHISEL_DIR}"
    ;;
  Darwin)
    exec "${SCRIPT_DIR}/macos/install_external_macos.sh" "${CHISEL_DIR}"
    ;;
  MINGW*|MSYS*|CYGWIN*)
    if command -v powershell.exe >/dev/null 2>&1; then
      exec powershell.exe -ExecutionPolicy Bypass -File "${SCRIPT_DIR}/windows/install_external_windows.ps1" -ChiselDir "${CHISEL_DIR}"
    fi
    die "Windows shell detected. Run install/windows/install_external_windows.ps1 from PowerShell."
    ;;
  *)
    die "unsupported OS: ${OS_NAME}"
    ;;
esac
