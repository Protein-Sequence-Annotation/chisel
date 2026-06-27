#!/usr/bin/env bash
# Build ssearch36 and install to <chisel_dir>/external_tools/fasta36/bin.
#
# Usage:
#   install/fasta36_install.sh <chisel_dir> <makefile-relative-to-src>...
#
# Environment:
#   FASTA36_MODE          custom (default) | legacy
#   FASTA36_JOBS          parallel make -j (default: nproc / sysctl)
#   FASTA36_CUSTOM_REPO   optional git URL for CHISEL fasta36 when published
#   FASTA36_CUSTOM_REF    branch/tag for FASTA36_CUSTOM_REPO (default: main)
#   FASTA36_LEGACY_REPO   upstream clone URL (default: wrpearson/fasta36)
#   FASTA36_LEGACY_REF    upstream branch/tag (default: master)
#
# custom: bundled external_tools/fasta36, or FASTA36_CUSTOM_REPO when set.
# legacy: clone upstream, apply install/patches/fasta36-gcc-prototypes.patch, build.

set -euo pipefail

log() { echo "[fasta36_install] $*"; }
die() { echo "[fasta36_install] ERROR: $*" >&2; exit 1; }

need_cmd() { command -v "$1" >/dev/null 2>&1 || die "required command not found: $1"; }

fasta36_default_jobs() {
  if command -v nproc >/dev/null 2>&1; then
    nproc
  elif command -v sysctl >/dev/null 2>&1; then
    sysctl -n hw.ncpu 2>/dev/null || echo 4
  else
    echo 4
  fi
}

fasta36_try_build() {
  local src_root="$1"
  shift
  local -a makefiles=("$@")
  local jobs="${FASTA36_JOBS:-$(fasta36_default_jobs)}"
  local mk built=0

  [[ -d "${src_root}/src" ]] || die "missing src/ under ${src_root}"
  mkdir -p "${src_root}/bin"
  pushd "${src_root}/src" >/dev/null
  for mk in "${makefiles[@]}"; do
    [[ -f "${mk}" ]] || continue
    log "trying ${mk}"
    if make -f "${mk}" -j"${jobs}" ssearch36; then
      built=1
      break
    fi
  done
  popd >/dev/null
  [[ "${built}" -eq 1 ]] || return 1
  [[ -x "${src_root}/bin/ssearch36" ]] || die "ssearch36 missing after build in ${src_root}/bin"
  return 0
}

fasta36_install_legacy() {
  local chisel_dir="$1"
  shift
  local -a makefiles=("$@")
  local external="${chisel_dir}/external_tools"
  local workdir="${external}/.downloads"
  local patch="${chisel_dir}/install/patches/fasta36-gcc-prototypes.patch"
  local legacy_repo="${FASTA36_LEGACY_REPO:-https://github.com/wrpearson/fasta36.git}"
  local legacy_ref="${FASTA36_LEGACY_REF:-master}"
  local src_root="${external}/fasta36-src"
  local bin_dir="${external}/fasta36/bin"
  local clone_dir="${workdir}/fasta36-legacy-clone"

  need_cmd git
  need_cmd patch
  [[ -f "${patch}" ]] || die "missing patch file: ${patch}"

  mkdir -p "${workdir}" "${bin_dir}"
  rm -rf "${clone_dir}" "${src_root}"
  log "legacy mode: cloning ${legacy_repo} (${legacy_ref})"
  if ! git clone --depth 1 --branch "${legacy_ref}" "${legacy_repo}" "${clone_dir}" 2>/dev/null; then
    git clone --depth 1 "${legacy_repo}" "${clone_dir}"
  fi
  mv "${clone_dir}" "${src_root}"

  log "applying ${patch}"
  patch -d "${src_root}" -p1 --forward <"${patch}" || die "fasta36 GCC prototype patch failed"

  fasta36_try_build "${src_root}" "${makefiles[@]}" \
    || die "legacy fasta36 build failed"
  cp -f "${src_root}/bin/ssearch36" "${bin_dir}/ssearch36"
  chmod +x "${bin_dir}/ssearch36"
  log "installed legacy ssearch36 -> ${bin_dir}/ssearch36"
}

fasta36_install_custom() {
  local chisel_dir="$1"
  shift
  local -a makefiles=("$@")
  local external="${chisel_dir}/external_tools"
  local workdir="${external}/.downloads"
  local bundled="${external}/fasta36"
  local src_root="${bundled}"
  local bin_dir="${external}/fasta36/bin"
  local custom_repo="${FASTA36_CUSTOM_REPO:-}"
  local custom_ref="${FASTA36_CUSTOM_REF:-main}"
  local clone_dir="${workdir}/fasta36-custom-clone"

  mkdir -p "${bin_dir}"
  if [[ -n "${custom_repo}" ]]; then
    need_cmd git
    src_root="${external}/fasta36-custom-src"
    mkdir -p "${workdir}"
    rm -rf "${clone_dir}" "${src_root}"
    log "custom mode: cloning ${custom_repo} (${custom_ref})"
    if ! git clone --depth 1 --branch "${custom_ref}" "${custom_repo}" "${clone_dir}" 2>/dev/null; then
      git clone --depth 1 "${custom_repo}" "${clone_dir}"
    fi
    mv "${clone_dir}" "${src_root}"
  else
    [[ -d "${bundled}/src" ]] || die "bundled fasta36 not found at ${bundled} (set FASTA36_CUSTOM_REPO to fetch remotely)"
    log "custom mode: building bundled tree at ${bundled}"
  fi

  fasta36_try_build "${src_root}" "${makefiles[@]}" \
    || die "custom fasta36 build failed"

  if [[ "${src_root}" != "${bundled}" ]]; then
    cp -f "${src_root}/bin/ssearch36" "${bin_dir}/ssearch36"
    chmod +x "${bin_dir}/ssearch36"
    log "installed custom ssearch36 -> ${bin_dir}/ssearch36"
  else
    log "built ssearch36 -> ${bundled}/bin/ssearch36"
  fi
}

fasta36_install() {
  local chisel_dir="$1"
  shift
  local -a makefiles=("$@")
  local mode="${FASTA36_MODE:-custom}"

  [[ -d "${chisel_dir}" ]] || die "not a directory: ${chisel_dir}"
  [[ ${#makefiles[@]} -gt 0 ]] || die "supply at least one FASTA makefile path (relative to src/)"

  need_cmd make
  case "${mode}" in
    custom)
      fasta36_install_custom "${chisel_dir}" "${makefiles[@]}"
      ;;
    legacy)
      fasta36_install_legacy "${chisel_dir}" "${makefiles[@]}"
      ;;
    *)
      die "FASTA36_MODE must be 'custom' or 'legacy' (got: ${mode})"
      ;;
  esac
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  [[ $# -ge 2 ]] || die "usage: $0 <chisel_dir> <makefile-relative-to-src>..."
  fasta36_install "$@"
fi
