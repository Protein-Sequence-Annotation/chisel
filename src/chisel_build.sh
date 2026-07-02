#!/bin/bash
#
# chisel_build.sh — Split input DB, filter test vs val, prune train.
#
# Steps:
#   1. chisel_splitter on input database → train, test, val, discard
#   2. chisel_filter test vs val — remove homologs from test (REMOVE_TARGET=fixed)
#   3. chisel_filter train vs pruned test — remove homologs from train
#   4. chisel_filter train vs val — remove homologs from train again
#
# Final outputs in --output-dir: test.fasta, val.fasta, train.fasta, discard.fasta
#
# Usage:
#   chisel_build.sh --config CONFIG --input-db FASTA --output-dir DIR
#
# All pipeline settings come from CONFIG; see install/chisel.config.

set -euo pipefail

die() { echo "[chisel_build] ERROR: $*" >&2; exit 1; }
# Progress and final stats → stdout (e.g. SLURM .out); errors only via die() → stderr.
log() { echo "[chisel_build] $*"; }

require_config() {
  local name="$1"
  [[ -n "${!name+x}" && -n "${!name}" ]] || die "config must set ${name}"
}

CONFIG_FILE=""
INPUT_DB=""
OUTPUT_DIR=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --config) CONFIG_FILE="$2"; shift 2 ;;
    --input-db) INPUT_DB="$2"; shift 2 ;;
    --output-dir) OUTPUT_DIR="$2"; shift 2 ;;
    -h|--help)
      sed -n '2,17p' "$0" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *)
      die "unknown option: $1"
      ;;
  esac
done

[[ -n "$CONFIG_FILE" && -n "$INPUT_DB" && -n "$OUTPUT_DIR" ]] \
  || die "usage: $0 --config FILE --input-db FASTA --output-dir DIR (run -h for help)"

[[ -f "$CONFIG_FILE" ]] || die "config not found: $CONFIG_FILE"
[[ -f "$INPUT_DB" ]] || die "input database not found: $INPUT_DB"

# --- Load config (single source for all pipeline variables) ---
# shellcheck disable=SC1090
source "$CONFIG_FILE"

CHISEL_ROOT="${CHISEL_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
CHISEL_SPLITTER="${CHISEL_SPLITTER:-${CHISEL_ROOT}/bin/chisel_splitter}"
CHISEL_FILTER="${CHISEL_FILTER:-${CHISEL_ROOT}/bin/chisel_filter}"

for var in ORDER TASK_ID \
  SPLIT_CPU SPLIT_DBBLOCK SPLIT_INIT_CHUNK SPLIT_TEST_LIMIT SPLIT_VAL_LIMIT SPLIT_SEED SPLIT_SUPPRESS \
  E_VALUE Z_SIZE \
  PHMMER_CORES MMSEQS_CORES BLAST_CORES SW_CORES \
  PHMMER_FILTER MMSEQS BLAST_DIR FASTA_DIR \
  BLAST_DBSIZE BLAST_MAX_TARGET_SEQS MMSEQS_MAX_SEQS; do
  require_config "$var"
done

# SPLIT_Z may be omitted; default to Z_SIZE from the same config.
SPLIT_Z="${SPLIT_Z:-$Z_SIZE}"
[[ -n "$SPLIT_Z" ]] || die "config must set SPLIT_Z or Z_SIZE"

if [[ "${TASK_ID}" == "SLURM" ]]; then
  if [[ -n "${SLURM_ARRAY_TASK_ID:-}" ]]; then
    TASK_ID="${SLURM_ARRAY_TASK_ID}"
  else
    TASK_ID="0"
  fi
fi

[[ -x "$CHISEL_SPLITTER" ]] || die "chisel_splitter not found or not executable: ${CHISEL_SPLITTER}"
[[ -x "$CHISEL_FILTER" ]] || die "chisel_filter not found or not executable: ${CHISEL_FILTER}"

KEEP_WORK=""
[[ -n "${KEEP_INTERMEDIATES:-}" && "${KEEP_INTERMEDIATES}" != "0" ]] && KEEP_WORK="1"

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
MMSEQS="$(abs_from_chisel_root "${MMSEQS}")"
BLAST_DIR="$(abs_from_chisel_root "${BLAST_DIR}")"
FASTA_DIR="$(abs_from_chisel_root "${FASTA_DIR}")"

mkdir -p "$OUTPUT_DIR"
OUTPUT_DIR="$(cd "$OUTPUT_DIR" && pwd)"
WORKDIR="${OUTPUT_DIR}/.work"
SPLIT_DIR="${WORKDIR}/split"
rm -rf "$WORKDIR"
mkdir -p "$SPLIT_DIR"

# --- Step 1: split input database ---
log "Step 1/4: running chisel_splitter on ${INPUT_DB}"
split_args=(
  --output_dir "$SPLIT_DIR"
  --task_id "$TASK_ID"
  --cpu "$SPLIT_CPU"
  --dbblock "$SPLIT_DBBLOCK"
  --init_chunk "$SPLIT_INIT_CHUNK"
  --test_limit "$SPLIT_TEST_LIMIT"
  --val_limit "$SPLIT_VAL_LIMIT"
  --split-seed "$SPLIT_SEED"
  -Z "$SPLIT_Z"
  -o stats
)
[[ "$SPLIT_SUPPRESS" == "1" ]] && split_args+=(--suppress)
if [[ -n "${SPLITTER_EXTRA:-}" ]]; then
  read -ra _split_extra <<< "$SPLITTER_EXTRA"
  split_args+=("${_split_extra[@]}")
fi

"$CHISEL_SPLITTER" "${split_args[@]}" "$INPUT_DB"

TRAIN_FASTA="${SPLIT_DIR}/train_${TASK_ID}.fasta"
TEST_FASTA="${SPLIT_DIR}/test_${TASK_ID}.fasta"
VAL_FASTA="${SPLIT_DIR}/val_${TASK_ID}.fasta"
DISCARD_FASTA="${SPLIT_DIR}/discard_${TASK_ID}.fasta"

for f in "$TRAIN_FASTA" "$TEST_FASTA" "$VAL_FASTA" "$DISCARD_FASTA"; do
  [[ -s "$f" ]] || die "splitter output missing or empty: $f"
done

log "split complete: train=$(grep -c '^>' "$TRAIN_FASTA") test=$(grep -c '^>' "$TEST_FASTA") val=$(grep -c '^>' "$VAL_FASTA") discard=$(grep -c '^>' "$DISCARD_FASTA")"

DISCARD_ACCUM="${WORKDIR}/discard_accum.fasta"
cp -f "$DISCARD_FASTA" "$DISCARD_ACCUM"

write_filter_config() {
  local out_cfg="$1"
  local filter_out_dir="$2"
  {
    echo 'CHISEL_PROFILE="build"'
    awk -v od="$filter_out_dir" \
        -v pf="$PHMMER_FILTER" -v mm="$MMSEQS" -v bd="$BLAST_DIR" -v fd="$FASTA_DIR" '
    /^SPLIT_/ { next }
    /^DEDUP_/ { next }
    /^ORDER=/ { next }
    /^CHISEL_ROOT=/ { next }
    /^CHISEL_SPLITTER=/ { next }
    /^CHISEL_FILTER=/ { next }
    /^CHISEL_P3=/ { next }
    /^CHISEL_PROFILE=/ { next }
    /^OUT_DIR=/ { print "OUT_DIR=\"" od "\""; next }
    /^REMOVE_TARGET=/ { print "REMOVE_TARGET=\"fixed\""; next }
    /^PHMMER_FILTER=/ { print "PHMMER_FILTER=\"" pf "\""; next }
    /^MMSEQS=/ { print "MMSEQS=\"" mm "\""; next }
    /^BLAST_DIR=/ { print "BLAST_DIR=\"" bd "\""; next }
    /^FASTA_DIR=/ { print "FASTA_DIR=\"" fd "\""; next }
    { print }
  ' "$CONFIG_FILE"
  } > "$out_cfg"
}

# Append sequences present in before_fasta but absent from after_fasta to discard (header short-id match).
append_filter_rejects_to_discard() {
  local before_fasta="$1"
  local after_fasta="$2"
  local discard_fasta="$3"
  local id_file removed

  id_file="$(mktemp "${TMPDIR:-/tmp}/chisel_discard_ids.XXXXXX")"
  comm -23 \
    <(awk '/^>/ { id=substr($0, 2); sub(/[ \t].*/, "", id); print id }' "$before_fasta" | sort -u) \
    <(awk '/^>/ { id=substr($0, 2); sub(/[ \t].*/, "", id); print id }' "$after_fasta" | sort -u) \
    >"$id_file"

  if ! awk 'NF { found=1; exit } END { exit(found ? 0 : 1) }' "$id_file"; then
    rm -f "$id_file"
    return 0
  fi

  removed=$(wc -l < "$id_file")
  awk -v id_file="$id_file" '
    BEGIN {
      while ((getline line < id_file) > 0) {
        sub(/[ \t\r]+$/, "", line)
        if (line != "") keep[line] = 1
      }
      close(id_file)
      rec = ""
      id = ""
    }
    /^>/ {
      if (rec != "" && (id in keep)) printf "%s\n", rec
      rec = $0
      id = substr($0, 2)
      sub(/[ \t].*$/, "", id)
      next
    }
    { rec = rec (rec == "" ? "" : "\n") $0 }
    END {
      if (rec != "" && (id in keep)) printf "%s\n", rec
    }
  ' "$before_fasta" >>"$discard_fasta"
  rm -f "$id_file"
  log "added ${removed} filtered seq(s) to discard"
}

run_filter_fixed() {
  local step_label="$1"
  local fixed_file="$2"
  local db_file="$3"
  local out_suffix="$4"
  local -n _out_path="$5"
  local cfg_dir="${WORKDIR}/config_${out_suffix}"
  local filter_out="${WORKDIR}/filter_${out_suffix}"
  local cfg="${cfg_dir}/filter.config"
  local summary_log="${filter_out}.log"
  local detail_log="${filter_out}.err"
  local fixed_out=""

  mkdir -p "$cfg_dir" "$filter_out"
  write_filter_config "$cfg" "$filter_out"

  log "${step_label}: chisel_filter --order ${ORDER} (fixed=${fixed_file}, db=${db_file})"
  if ! "$CHISEL_FILTER" --order "$ORDER" --config "$cfg" \
      --fixed-file "$fixed_file" --db-file "$db_file" --out-suffix "$out_suffix" \
      >"$summary_log" 2>"$detail_log"; then
    cat "$summary_log" "$detail_log" >&2
    die "chisel_filter failed (${step_label}); see ${summary_log} and ${detail_log}"
  fi

  fixed_out="$(sed -n 's/^Completed (chisel)\..*FIXED_FILE=\([^ ]*\).*/\1/p' "$summary_log" | tail -1)"
  [[ -n "$fixed_out" && -s "$fixed_out" ]] \
    || die "could not locate pruned fixed-file output for ${step_label} (log: ${summary_log})"

  append_filter_rejects_to_discard "$fixed_file" "$fixed_out" "$DISCARD_ACCUM"
  _out_path="$fixed_out"
}

# --- Step 2: test vs val — remove from test only ---
# chisel_filter two-pass pruning searches both directions (test→val, then val→pruned test)
# but with REMOVE_TARGET=fixed all removals are applied to the fixed file (test).
run_filter_fixed "Step 2/4: prune test vs val" "$TEST_FASTA" "$VAL_FASTA" "test_vs_val" TEST_PRUNED

# --- Step 3: train vs pruned test — remove from train ---
run_filter_fixed "Step 3/4: prune train vs test" "$TRAIN_FASTA" "$TEST_PRUNED" "train_vs_test" TRAIN_PRUNED

# --- Step 4: train vs val — remove from train ---
run_filter_fixed "Step 4/4: prune train vs val" "$TRAIN_PRUNED" "$VAL_FASTA" "train_vs_val" TRAIN_FINAL

FINAL_TEST="${OUTPUT_DIR}/test.fasta"
FINAL_VAL="${OUTPUT_DIR}/val.fasta"
FINAL_TRAIN="${OUTPUT_DIR}/train.fasta"
FINAL_DISCARD="${OUTPUT_DIR}/discard.fasta"

cp -f "$TEST_PRUNED" "$FINAL_TEST"
cp -f "$VAL_FASTA" "$FINAL_VAL"
cp -f "$TRAIN_FINAL" "$FINAL_TRAIN"
cp -f "$DISCARD_ACCUM" "$FINAL_DISCARD"

if [[ -z "$KEEP_WORK" ]]; then
  rm -rf "$WORKDIR"
else
  log "keeping intermediates under ${WORKDIR}"
fi

log "chisel_build complete."
log "  test:    ($(grep -c '^>' "$FINAL_TEST") seqs) ${FINAL_TEST}"
log "  val:     ($(grep -c '^>' "$FINAL_VAL") seqs) ${FINAL_VAL}"
log "  train:   ($(grep -c '^>' "$FINAL_TRAIN") seqs) ${FINAL_TRAIN}"
log "  discard: ($(grep -c '^>' "$FINAL_DISCARD") seqs) ${FINAL_DISCARD}"
