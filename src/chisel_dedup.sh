#!/bin/bash
#
# chisel_dedup.sh — Self-deduplicate a FASTA file via phmmer_filter.
#
# The input is searched against itself (--no_self). Query IDs that hit a homolog
# are removed; survivors are written as <stem>_dedup.fasta (e.g. test.fasta ->
# test_dedup.fasta). By default the output sits next to the input; use
# --output-dir to choose a different destination. Run once per file.
#
# Usage:
#   chisel_dedup.sh --config CONFIG --file FASTA [--output-dir DIR]
#
# Settings come from CONFIG; see install/chisel.config.

set -euo pipefail

die() { echo "[chisel_dedup] ERROR: $*" >&2; exit 1; }
# Progress and final stats → stdout (e.g. SLURM .out); errors only via die() → stderr.
log() { echo "[chisel_dedup] $*"; }

require_config() {
  local name="$1"
  [[ -n "${!name+x}" && -n "${!name}" ]] || die "config must set ${name}"
}

dedup_stem() {
  local base="$1"
  case "$base" in
    *.fasta) echo "${base%.fasta}" ;;
    *.fa) echo "${base%.fa}" ;;
    *.faa) echo "${base%.faa}" ;;
    *) echo "$base" ;;
  esac
}

CONFIG_FILE=""
INPUT_FILE=""
OUTPUT_DIR_ARG=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --config) CONFIG_FILE="$2"; shift 2 ;;
    --file) INPUT_FILE="$2"; shift 2 ;;
    --output-dir) OUTPUT_DIR_ARG="$2"; shift 2 ;;
    -h|--help)
      sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *)
      die "unknown option: $1"
      ;;
  esac
done

[[ -n "$CONFIG_FILE" && -n "$INPUT_FILE" ]] \
  || die "usage: $0 --config FILE --file FASTA [--output-dir DIR]"

[[ -f "$CONFIG_FILE" ]] || die "config not found: $CONFIG_FILE"
[[ -f "$INPUT_FILE" ]] || die "input file not found: $INPUT_FILE"

INPUT_FILE="$(cd "$(dirname "$INPUT_FILE")" && pwd)/$(basename "$INPUT_FILE")"
INPUT_DIR="$(dirname "$INPUT_FILE")"
INPUT_BASE="$(basename "$INPUT_FILE")"
INPUT_STEM="$(dedup_stem "$INPUT_BASE")"
if [[ -n "$OUTPUT_DIR_ARG" ]]; then
  mkdir -p "$OUTPUT_DIR_ARG"
  OUTPUT_DIR="$(cd "$OUTPUT_DIR_ARG" && pwd)"
else
  OUTPUT_DIR="$INPUT_DIR"
fi
OUTPUT_FILE="${OUTPUT_DIR}/${INPUT_STEM}_dedup.fasta"

# shellcheck disable=SC1090
source "$CONFIG_FILE"

CHISEL_ROOT="${CHISEL_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
PHMMER_FILTER="${PHMMER_FILTER:-${CHISEL_ROOT}/bin/phmmer_filter}"

for var in TASK_ID E_VALUE Z_SIZE PHMMER_CORES PHMMER_FILTER \
  DEDUP_PHIGH DEDUP_PLOW DEDUP_QSIZE; do
  require_config "$var"
done

if [[ "${TASK_ID}" == "SLURM" ]]; then
  if [[ -n "${SLURM_ARRAY_TASK_ID:-}" ]]; then
    TASK_ID="${SLURM_ARRAY_TASK_ID}"
  else
    TASK_ID="0"
  fi
fi

abs_from_chisel_root() {
  local p="$1"
  [[ -z "$p" ]] && { echo ""; return; }
  if [[ "$p" == /* ]]; then
    echo "$p"
  else
    echo "${CHISEL_ROOT}/${p}"
  fi
}

PHMMER_FILTER="$(abs_from_chisel_root "${PHMMER_FILTER}")"
[[ -x "$PHMMER_FILTER" ]] || die "phmmer_filter not found or not executable: ${PHMMER_FILTER}"

KEEP_WORK=""
[[ -n "${KEEP_INTERMEDIATES:-}" && "${KEEP_INTERMEDIATES}" != "0" ]] && KEEP_WORK="1"

DEDUP_SUPPRESS="${DEDUP_SUPPRESS:-0}"

WORKDIR="${OUTPUT_DIR}/.chisel_dedup_${INPUT_STEM}.work"
rm -rf "$WORKDIR"
mkdir -p "$WORKDIR"

# remove_seqs_bash <input_fasta> <omit_ids_file> <output_fasta>
remove_seqs_bash() {
  local input_fasta="$1"
  local id_file="$2"
  local output_fasta="$3"
  if [[ ! -f "$input_fasta" ]]; then
    die "remove_seqs_bash: input not found: $input_fasta"
  fi
  if [[ ! -f "$id_file" ]]; then
    die "remove_seqs_bash: id file not found: $id_file"
  fi
  if ! awk 'NF { found=1; exit } END { exit(found ? 0 : 1) }' "$id_file"; then
    cp "$input_fasta" "$output_fasta"
    return 0
  fi
  awk -v id_file="$id_file" '
    BEGIN {
      while ((getline line < id_file) > 0) {
        sub(/[ \t\r]+$/, "", line)
        if (line != "") omit[line] = 1
      }
      close(id_file)
      rec = ""
      id = ""
    }
    /^>/ {
      if (rec != "" && !(id in omit)) printf "%s\n", rec
      rec = $0
      id = substr($0, 2)
      sub(/[ \t].*$/, "", id)
      next
    }
    { rec = rec (rec == "" ? "" : "\n") $0 }
    END {
      if (rec != "" && !(id in omit)) printf "%s\n", rec
    }
  ' "$input_fasta" > "$output_fasta"
}

dedup_fasta() {
  local input_fasta="$1"
  local output_fasta="$2"
  local summary_log="${WORKDIR}/dedup.log"
  local detail_log="${WORKDIR}/dedup.err"
  local out_prefix="${WORKDIR}/phmmer_dedup"
  local hits_file="${out_prefix}_${TASK_ID}.txt"
  local omit_ids="${WORKDIR}/omit_ids_${TASK_ID}.txt"
  local n_in n_omit n_out start=$SECONDS
  local -a phmmer_args=() dedup_extra=()

  n_in=$(grep -c '^>' "$input_fasta" || true)
  [[ "$n_in" -gt 0 ]] || die "input has no sequences: ${input_fasta}"

  log "phmmer_filter self-dedup (${n_in} seqs) -> ${output_fasta}"
  log "dedup process logs: ${WORKDIR}/ (dedup.log, dedup.err)"
  {
    echo "chisel_dedup: $(basename "$input_fasta")"
    echo "  input:  ${input_fasta} (${n_in} seqs)"
    echo "  output: ${output_fasta}"
    echo "  phigh/plow: ${DEDUP_PHIGH} / ${DEDUP_PLOW}"
    echo "  E=${E_VALUE} Z=${Z_SIZE} cpu=${PHMMER_CORES} qsize=${DEDUP_QSIZE}"
  } >"$summary_log"

  phmmer_args=(
    --cpu "$PHMMER_CORES"
    --qsize "$DEDUP_QSIZE"
    --qblock "$n_in"
    --tblock "$n_in"
    --phigh "$DEDUP_PHIGH"
    --plow "$DEDUP_PLOW"
    -E "$E_VALUE"
    -Z "$Z_SIZE"
    --task_id "$TASK_ID"
    --no_self
    -o "$out_prefix"
  )
  [[ -n "${DEDUP_EXTRA:-}" ]] && read -ra dedup_extra <<< "$DEDUP_EXTRA" && phmmer_args+=("${dedup_extra[@]}")
  phmmer_args+=("$input_fasta" "$input_fasta")
  [[ "$DEDUP_SUPPRESS" == "1" ]] && phmmer_args=(--suppress "${phmmer_args[@]}")

  if ! "$PHMMER_FILTER" "${phmmer_args[@]}" >>"$summary_log" 2>"$detail_log"; then
    cat "$summary_log" "$detail_log" >&2
    die "phmmer_filter failed; see ${summary_log} and ${detail_log}"
  fi

  [[ -f "$hits_file" ]] || die "expected hits file missing: ${hits_file}"

  awk 'NR>2 && NF>=2 {print $1}' "$hits_file" | sort -u >"$omit_ids"
  n_omit=$(wc -l < "$omit_ids")
  remove_seqs_bash "$input_fasta" "$omit_ids" "$output_fasta"
  n_out=$(grep -c '^>' "$output_fasta" || true)
  [[ "$n_out" -gt 0 ]] || die "no sequences survived deduplication"

  {
    echo "removed ${n_omit} duplicate query id(s)"
    echo "output: ${output_fasta} (${n_out} seqs)"
    echo "dedup took $((SECONDS - start))s"
  } >>"$summary_log"

  log "${n_in} -> ${n_out} seqs (removed ${n_omit}, $((SECONDS - start))s)"
}

dedup_fasta "$INPUT_FILE" "$OUTPUT_FILE"

if [[ -z "$KEEP_WORK" ]]; then
  rm -rf "$WORKDIR"
else
  log "keeping intermediates under ${WORKDIR}"
fi

log "chisel_dedup complete."
log "  output: $(grep -c '^>' "$OUTPUT_FILE") seqs  ${OUTPUT_FILE}"
