#!/usr/bin/env bash
# Clone upstream FASTA36 into external_tools/fasta36/, apply GCC patch, build ssearch36.
#
# Usage:
#   install/fasta36_install.sh <chisel_dir> <makefile-relative-to-src>...
#
# Environment:
#   FASTA36_JOBS   parallel make -j (default: nproc / sysctl)
#   FASTA36_REPO   git clone URL (default: https://github.com/wrpearson/fasta36.git)
#   FASTA36_REF    branch/tag to clone (default: master)

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

fasta36_apply_patch() {
  local src_root="$1"
  local patch="$2"

  [[ -f "${patch}" ]] || return 0
  need_cmd patch

  # Skip reverse dry-run probe (it prints scary "hunk FAILED" on fresh clones).
  if patch -d "${src_root}" -p1 --reverse --dry-run --force <"${patch}" >/dev/null 2>&1; then
    log "patch already applied (${patch})"
    return 0
  fi

  log "applying ${patch}"
  patch -d "${src_root}" -p1 --forward --force <"${patch}" \
    || die "fasta36 GCC prototype patch failed"
}

fasta36_install() {
  local chisel_dir="$1"
  shift
  local -a makefiles=("$@")
  local external="${chisel_dir}/external_tools"
  local workdir="${external}/.downloads"
  local src_root="${external}/fasta36"
  local patch="${chisel_dir}/install/patches/fasta36-gcc-prototypes.patch"
  local repo="${FASTA36_REPO:-https://github.com/wrpearson/fasta36.git}"
  local ref="${FASTA36_REF:-master}"
  local clone_dir="${workdir}/fasta36-clone"

  [[ -d "${chisel_dir}" ]] || die "not a directory: ${chisel_dir}"
  [[ ${#makefiles[@]} -gt 0 ]] || die "supply at least one FASTA makefile path (relative to src/)"

  need_cmd make
  need_cmd git
  need_cmd patch

  # Replace prior install (legacy layout used fasta36-src/ + bin-only fasta36/).
  rm -rf "${external}/fasta36-src" "${src_root}" "${clone_dir}"
  mkdir -p "${workdir}"

  log "cloning ${repo} (${ref})"
  if ! git clone --depth 1 --branch "${ref}" "${repo}" "${clone_dir}" 2>/dev/null; then
    git clone --depth 1 "${repo}" "${clone_dir}"
  fi
  mv "${clone_dir}" "${src_root}"

  fasta36_apply_patch "${src_root}" "${patch}"
  fasta36_try_build "${src_root}" "${makefiles[@]}" \
    || die "fasta36 build failed in ${src_root}"

  log "installed ssearch36 -> ${src_root}/bin/ssearch36"
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  [[ $# -ge 2 ]] || die "usage: $0 <chisel_dir> <makefile-relative-to-src>..."
  fasta36_install "$@"
fi
