#!/bin/bash
#
# chisel_filter.sh — Run pHMMER, MMseqs2, BLAST, and/or SW filters with sequential two-pass pruning.
# Unlike sledge_filter.sh, each tool runs REMOVE-as-query first, prunes REMOVE, then runs the reverse
# direction against the pruned REMOVE file and prunes again before the next tool.
#
# Required: --order, --config, --fixed-file, --db-file. Other parameters come from the config file.
#
# Usage:
#   --order STRING           Order of tools: p=phmmer, m=mmseqs, b=blast, s=sw (e.g. pmb, spm)
#   --config FILE            Path to config file (required)
#   --fixed-file FILE        Fixed/reference FASTA (e.g. test set)
#   --db-file FILE           DB FASTA (shard / sequence database to be filtered against fixed file)
#   --out-suffix SUFFIX      Optional. Suffix for tool output dirs (phmmer_<suffix>, mmseqs_<suffix>, etc.).
#                            Default: TASK_ID from config. Use to separate outputs per run (e.g. 0_vs_0_0).
#
# Example: ./chisel_filter.sh --order pmb --config install/chisel.config --fixed-file test.fasta --db-file train.fasta
#
# Set OUT_DIR, REMOVE_TARGET (db|fixed), KEEP_INTERMEDIATES, etc. in the config file.

set -euo pipefail

# Best-effort recursive remove (NFS stale handles, open files). Never aborts the script.
rm_rf_retry() {
  local path attempt
  [[ $# -eq 0 ]] && return 0
  for path in "$@"; do
    [[ -e "$path" || -L "$path" ]] || continue
    for attempt in 1 2 3 4 5; do
      chmod -R u+w "$path" 2>/dev/null || true
      rm -rf "$path" 2>/dev/null && break
      find "$path" -depth -mindepth 1 -delete 2>/dev/null || true
      rm -rf "$path" 2>/dev/null && break
      sleep "$attempt"
    done
    rm -rf "$path" 2>/dev/null || true
  done
  return 0
}

# Remove scratch paths unless KEEP_INTERMEDIATES is set.
cleanup_unless_kept() {
  [[ -n "${KEEP_INTERMEDIATES:-}" ]] && return 0
  rm_rf_retry "$@"
}

# --- Argument parsing: required --order, --config, --fixed-file, --db-file; optional --out-suffix ---
ORDER=""
CONFIG_FILE=""
FIXED_FILE=""
DB_FILE=""
OUT_SUFFIX_ARG=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --order)
      ORDER="$2"
      shift 2
      ;;
    --config)
      CONFIG_FILE="$2"
      shift 2
      ;;
    --fixed-file)
      FIXED_FILE="$2"
      shift 2
      ;;
    --db-file)
      DB_FILE="$2"
      shift 2
      ;;
    --out-suffix)
      OUT_SUFFIX_ARG="$2"
      shift 2
      ;;
    *)
      echo "Unknown option: $1" >&2
      exit 1
      ;;
  esac
done

if [[ -z "$ORDER" || -z "$CONFIG_FILE" || -z "$FIXED_FILE" || -z "$DB_FILE" ]]; then
  echo "Usage: $0 --order STRING --config FILE --fixed-file FILE --db-file FILE"
  echo "  Order: p=phmmer, m=mmseqs, b=blast, s=sw (e.g. pmb, spm)"
  exit 1
fi

# --- Validate --order before loading config (clear errors without needing valid tool paths) ---
for (( _oi=0; _oi<${#ORDER}; _oi++ )); do
  case "${ORDER:${_oi}:1}" in
    p|P|m|M|b|B|s|S) ;;
    *)
      echo "Unknown tool in --order: ${ORDER:${_oi}:1}" >&2
      exit 1
      ;;
  esac
done

# --- Load config ---
if [[ ! -f "$CONFIG_FILE" ]]; then
  echo "Config file not found: $CONFIG_FILE" >&2
  exit 1
fi
source "$CONFIG_FILE"

# Required from config
for var in OUT_DIR; do
  if [[ -z "${!var:-}" ]]; then
    echo "Config must set $var" >&2
    exit 1
  fi
done

# Optional defaults from config if not set (KEEP_INTERMEDIATES is in config only)
KEEP_INTERMEDIATES="${KEEP_INTERMEDIATES:-}"

# BUILD_FILTER_* (chisel_build subprocess) vs FILTER_* (standalone chisel_filter).
CHISEL_PROFILE="${CHISEL_PROFILE:-filter}"
if [[ "$CHISEL_PROFILE" == "build" ]]; then
  PROFILE_PREFIX="BUILD_FILTER"
else
  PROFILE_PREFIX="FILTER"
fi

# TASK_ID resolution:
# - If config sets TASK_ID=SLURM, use $SLURM_ARRAY_TASK_ID when available (else 0).
# - Otherwise, use the numeric TASK_ID from config, defaulting to 0 when unset.
if [[ "${TASK_ID:-}" == "SLURM" ]]; then
  if [[ -n "${SLURM_ARRAY_TASK_ID:-}" ]]; then
    TASK_ID="${SLURM_ARRAY_TASK_ID}"
  else
    TASK_ID="0"
  fi
else
  TASK_ID="${TASK_ID:-0}"
fi

# Tool output dirs use OUT_SUFFIX (default TASK_ID); TASK_ID stays integer for internal use (e.g. sledge --task_id)
OUT_SUFFIX="${OUT_SUFFIX_ARG:-${OUT_SUFFIX:-$TASK_ID}}"
REMOVE_TARGET="${REMOVE_TARGET:-db}"
E_VALUE="${E_VALUE:-0.01}"
Z_SIZE="${Z_SIZE:-81514348}"
PHMMER_CORES="${PHMMER_CORES:-96}"
MMSEQS_CORES="${MMSEQS_CORES:-96}"
BLAST_CORES="${BLAST_CORES:-96}"
SW_CORES="${SW_CORES:-96}"
BLAST_DBSIZE="${BLAST_DBSIZE:-32596740121}"
BLAST_MAX_TARGET_SEQS="${BLAST_MAX_TARGET_SEQS:-12000000}"
MMSEQS_MAX_SEQS="${MMSEQS_MAX_SEQS:-12000000}"

if [[ "$REMOVE_TARGET" != "db" && "$REMOVE_TARGET" != "fixed" ]]; then
  echo "REMOVE_TARGET must be 'db' or 'fixed'" >&2
  exit 1
fi

is_uint() { [[ "${1:-}" =~ ^[0-9]+$ ]]; }
is_positive_uint() { [[ "${1:-}" =~ ^[1-9][0-9]*$ ]]; }

if ! is_positive_uint "$Z_SIZE"; then
  echo "Z_SIZE must be a positive integer (got: ${Z_SIZE:-})" >&2
  exit 1
fi
for _cname in PHMMER_CORES MMSEQS_CORES BLAST_CORES SW_CORES; do
  _cv="${!_cname}"
  if ! is_uint "${_cv}"; then
    echo "${_cname} must be a non-negative integer (got: ${_cv:-})" >&2
    exit 1
  fi
done

# Only require binaries for tools listed in --order (e.g. pms skips BLAST if b is absent).
NEED_PHMMER=0
NEED_MMSEQS=0
NEED_BLAST=0
NEED_SW=0
for (( _ni=0; _ni<${#ORDER}; _ni++ )); do
  case "${ORDER:${_ni}:1}" in
    p|P) NEED_PHMMER=1 ;;
    m|M) NEED_MMSEQS=1 ;;
    b|B) NEED_BLAST=1 ;;
    s|S) NEED_SW=1 ;;
  esac
done

if [[ "${NEED_PHMMER}" -eq 1 ]]; then
  if [[ ! -x "${PHMMER_FILTER}" ]]; then
    echo "PHMMER_FILTER is not executable or missing: ${PHMMER_FILTER}" >&2
    exit 1
  fi
fi
if [[ "${NEED_MMSEQS}" -eq 1 ]]; then
  if [[ ! -x "${MMSEQS}" ]]; then
    echo "MMSEQS is not executable or missing: ${MMSEQS}" >&2
    exit 1
  fi
fi
if [[ "${NEED_BLAST}" -eq 1 ]]; then
  if [[ ! -d "${BLAST_DIR}" ]] || [[ ! -x "${BLAST_DIR}/makeblastdb" ]] || [[ ! -x "${BLAST_DIR}/blastp" ]]; then
    echo "BLAST_DIR must be a directory containing makeblastdb and blastp: ${BLAST_DIR}" >&2
    exit 1
  fi
fi
if [[ "${NEED_SW}" -eq 1 ]]; then
  if [[ ! -d "${FASTA_DIR}" ]] || [[ ! -x "${FASTA_DIR}/ssearch36" ]]; then
    echo "FASTA_DIR must be a directory containing ssearch36: ${FASTA_DIR}" >&2
    exit 1
  fi
fi

mkdir -p "$OUT_DIR"

# Summary (timing, removal counts, completion) → stdout.
# Tool verbose output (MMseqs, BLAST, makeblastdb, errors) → stderr via log_detail.
log_detail() { echo "$*" >&2; }

# Read ${PROFILE_PREFIX}_${suffix} from config; echo default if unset/empty.
profile_cfg() {
  local suffix="$1"
  local default="${2:-}"
  local var="${PROFILE_PREFIX}_${suffix}"
  if [[ -n "${!var+x}" && -n "${!var}" ]]; then
    echo "${!var}"
  else
    echo "$default"
  fi
}

# Append whitespace-separated extra flags from config onto a bash array.
append_profile_extras() {
  local -n _arr=$1
  local suffix="$2"
  local extras
  extras="$(profile_cfg "$suffix" "")"
  [[ -z "$extras" ]] && return 0
  read -ra _extra <<< "$extras"
  _arr+=("${_extra[@]}")
}

# --- Reusable: remove sequences by ID list (pure bash/awk, no Python) ---
# remove_seqs_bash <input_fasta> <omit_ids_file> <output_fasta> [--long]
remove_seqs_bash() {
  local input_fasta="$1"
  local id_file="$2"
  local output_fasta="$3"
  local long_opt="${4:-}"
  if [[ ! -f "$input_fasta" ]]; then
    log_detail "remove_seqs_bash: input not found: $input_fasta"
    return 1
  fi
  if [[ ! -f "$id_file" ]]; then
    log_detail "remove_seqs_bash: id file not found: $id_file"
    return 1
  fi
  # If no IDs are listed to omit, keep the FASTA unchanged.
  if ! awk 'NF { found=1; exit } END { exit(found ? 0 : 1) }' "$id_file"; then
    cp "$input_fasta" "$output_fasta"
    return $?
  fi
  local use_long=0
  [[ "$long_opt" == "--long" ]] && use_long=1
  awk -v id_file="$id_file" -v use_long="$use_long" '
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
      if (use_long && length(id) >= 3 && substr(id, 3, 1) == "|") {
        n = split(id, a, "|")
        id = (n >= 2 ? a[2] : id)
      } else {
        sub(/[ \t].*$/, "", id)
      }
      next
    }
    { rec = rec (rec == "" ? "" : "\n") $0 }
    END {
      if (rec != "" && !(id in omit)) printf "%s\n", rec
    }
  ' "$input_fasta" > "$output_fasta"
}

# MMseqs per-direction e-value: E_VALUE * n_seqs / Z_SIZE (10 decimal places).
# Uses POSIX awk only (no bc); same math as before.
mmseqs_scaled_e() {
  awk -v e="$1" -v n="$2" -v z="$3" 'BEGIN { printf "%.10f\n", e * n / z }'
}

# --- Exit if a tool's output FASTA has no sequences ---
check_fasta_nonempty() {
  local fasta="$1"
  local tool_label="$2"
  local n
  n=$(grep -c ">" "$fasta" 2>/dev/null) || true
  n=${n:-0}
  if [[ "$n" -eq 0 ]]; then
    echo "No sequence survived the filtering (after $tool_label)."
    exit 0
  fi
}

# Print wall-clock elapsed since $start (bash SECONDS) for a pipeline tool step.
# Optional third argument: number of sequences removed in this stage.
print_tool_elapsed() {
  local label="$1"
  local start="$2"
  local removed="${3:-}"
  if [[ -n "$removed" ]]; then
    echo "${label} took $((SECONDS - start))s and removed ${removed} sequences"
  else
    echo "${label} took $((SECONDS - start))s"
  fi
}

# Count unique non-empty lines in a file (0 if missing or empty).
count_unique_ids() {
  local id_file="$1"
  if [[ ! -s "$id_file" ]]; then
    echo 0
    return
  fi
  sort -u "$id_file" | wc -l
}

# --- PHMMER (sequential two-pass: REMOVE as query, prune, reverse with --all_hits, prune) ---
run_phmmer() {
  local start=$SECONDS
  local out_p="${OUT_DIR}/phmmer_${OUT_SUFFIX}"
  mkdir -p "$out_p"
  local phmmer_out="${out_p}/phmmer_${TASK_ID}.fasta"
  local remove_file other_file
  local remove_pruned pass1_hits pass2_hits pass1_ids pass2_ids
  local n_remove n_other

  append_omit_ids() {
    local filt_file="$1"
    local col="${2:-1}"
    local out_file="$3"
    awk -v c="$col" 'NR>2 {print $c}' "$filt_file" | sort -u > "$out_file"
  }

  if [[ "$REMOVE_TARGET" == "db" ]]; then
    remove_file="$DB_FILE"
    other_file="$FIXED_FILE"
  else
    remove_file="$FIXED_FILE"
    other_file="$DB_FILE"
  fi

  pass1_ids="${out_p}/phmmer_pass1_hits_${TASK_ID}.txt"
  pass2_ids="${out_p}/phmmer_pass2_hits_${TASK_ID}.txt"
  remove_pruned="${out_p}/phmmer_remove_pass1_${TASK_ID}.fasta"

  # Pass 1: REMOVE as query, other as target.
  n_remove=$(grep -c ">" "$remove_file" || true)
  n_other=$(grep -c ">" "$other_file" || true)
  local -a phmmer_p1=()
  phmmer_p1=(
    --cpu "$PHMMER_CORES"
    --qsize "$(profile_cfg PHMMER_QSIZE 100)"
    --qblock "$n_remove"
    --tblock "$n_other"
    --phigh "$(profile_cfg PHMMER_PHIGH 0)"
    --plow "$(profile_cfg PHMMER_PLOW 0)"
    -E "$E_VALUE"
    -Z "$Z_SIZE"
    --task_id "$TASK_ID"
    -o "${out_p}/phmmer_hits_pass1"
  )
  append_profile_extras phmmer_p1 PHMMER_EXTRA
  phmmer_p1+=("$remove_file" "$other_file")
  $PHMMER_FILTER "${phmmer_p1[@]}"
  # Pass 1: REMOVE is query → offending IDs are in column 1.
  append_omit_ids "${out_p}/phmmer_hits_pass1_${TASK_ID}.txt" 1 "$pass1_ids"
  pass1_hits=$(wc -l < "$pass1_ids")
  remove_seqs_bash "$remove_file" "$pass1_ids" "$remove_pruned"
  check_fasta_nonempty "$remove_pruned" "pHMMER pass 1"

  # Pass 2: other as query, pruned REMOVE as target (--all_hits on reverse direction).
  n_remove=$(grep -c ">" "$remove_pruned" || true)
  n_other=$(grep -c ">" "$other_file" || true)
  local -a phmmer_p2=()
  phmmer_p2=(
    --all_hits
    --cpu "$PHMMER_CORES"
    --qsize "$(profile_cfg PHMMER_QSIZE 100)"
    --qblock "$n_other"
    --tblock "$n_remove"
    --phigh "$(profile_cfg PHMMER_PHIGH 0)"
    --plow "$(profile_cfg PHMMER_PLOW 0)"
    -E "$E_VALUE"
    -Z "$Z_SIZE"
    --task_id "$TASK_ID"
    -o "${out_p}/phmmer_hits_pass2"
  )
  append_profile_extras phmmer_p2 PHMMER_EXTRA
  phmmer_p2+=("$other_file" "$remove_pruned")
  $PHMMER_FILTER "${phmmer_p2[@]}"
  if [[ "$REMOVE_TARGET" == "db" ]]; then
    append_omit_ids "${out_p}/phmmer_hits_pass2_${TASK_ID}.txt" 2 "$pass2_ids"
    remove_seqs_bash "$remove_pruned" "$pass2_ids" "$phmmer_out"
    DB_FILE="$phmmer_out"
    check_fasta_nonempty "$phmmer_out" "pHMMER"
  else
    append_omit_ids "${out_p}/phmmer_hits_pass2_${TASK_ID}.txt" 2 "$pass2_ids"
    remove_seqs_bash "$remove_pruned" "$pass2_ids" "${out_p}/fixed_phmmer_${TASK_ID}.fasta"
    FIXED_FILE="${out_p}/fixed_phmmer_${TASK_ID}.fasta"
    check_fasta_nonempty "$FIXED_FILE" "pHMMER"
  fi
  pass2_hits=$(wc -l < "$pass2_ids")
  local total_removed=$((pass1_hits + pass2_hits))

  if [[ -z "$KEEP_INTERMEDIATES" ]]; then
    rm -f "${out_p}/results_phmmer_pass1_${TASK_ID}.txt" "${out_p}/results_phmmer_pass2_${TASK_ID}.txt"
    rm -f "$pass1_ids" "$pass2_ids" "$remove_pruned"
  fi
  print_tool_elapsed "phmmer" "$start" "$total_removed"
}

# --- MMSEQS2 (iterative sequential two-pass pruning) ---
run_mmseqs() {
  local start=$SECONDS
  local out_mm="${OUT_DIR}/mmseqs_${OUT_SUFFIX}"
  mkdir -p "$out_mm"
  local iteration=0
  local mm_remove_file mm_other_file
  local long_arg=""
  [[ -n "${USE_LONG_ID:-}" ]] && long_arg="--long"
  local mm_all_hits="${out_mm}/mm_all_hits_${TASK_ID}.txt"
  : > "$mm_all_hits"

  if [[ "$REMOVE_TARGET" == "db" ]]; then
    mm_remove_file="$DB_FILE"
    mm_other_file="$FIXED_FILE"
  else
    mm_remove_file="$FIXED_FILE"
    mm_other_file="$DB_FILE"
  fi

  run_mm_iteration() {
    local mm_out="${out_mm}/mm_iteration_${iteration}_${TASK_ID}.fasta"
    local pass1_ids="${out_mm}/mm_pass1_hits_${iteration}_${TASK_ID}.txt"
    local pass2_ids="${out_mm}/mm_pass2_hits_${iteration}_${TASK_ID}.txt"
    local remove_pruned="${out_mm}/mm_remove_pass1_${iteration}_${TASK_ID}.fasta"
    local n_remove n_other e_remove e_other
    local pass1_hits pass2_hits
    local -a mm_search_extra=() mm_convert_extra=()

    read -ra mm_search_extra <<< "$(profile_cfg MMSEQS_SEARCH_EXTRA "--alignment-mode 2 --cov-mode 0 -c 0")"
    read -ra mm_convert_extra <<< "$(profile_cfg MMSEQS_CONVERTALIS_EXTRA "--format-mode 2")"

    n_remove=$(grep -c ">" "$mm_remove_file" || true)
    n_other=$(grep -c ">" "$mm_other_file" || true)
    e_remove=$(mmseqs_scaled_e "$E_VALUE" "$n_remove" "$Z_SIZE")
    e_other=$(mmseqs_scaled_e "$E_VALUE" "$n_other" "$Z_SIZE")

    mkdir -p "${out_mm}/mm_remove_${iteration}_${TASK_ID}" "${out_mm}/mm_other_${iteration}_${TASK_ID}" "${out_mm}/tmp_${iteration}_${TASK_ID}"

    # Pass 1: REMOVE as query, other as target.
    $MMSEQS createdb "$mm_remove_file" "${out_mm}/mm_remove_${iteration}_${TASK_ID}/db" >&2
    $MMSEQS createdb "$mm_other_file" "${out_mm}/mm_other_${iteration}_${TASK_ID}/db" >&2

    if $MMSEQS search "${out_mm}/mm_remove_${iteration}_${TASK_ID}/db" "${out_mm}/mm_other_${iteration}_${TASK_ID}/db" \
        "${out_mm}/tmp_${iteration}_${TASK_ID}/pass1" "${out_mm}/tmp_pass1_${iteration}_${TASK_ID}" \
        "${mm_search_extra[@]}" -e "$e_remove" --threads "$MMSEQS_CORES" --max-seqs "$MMSEQS_MAX_SEQS" >&2; then
      $MMSEQS convertalis "${out_mm}/mm_remove_${iteration}_${TASK_ID}/db" "${out_mm}/mm_other_${iteration}_${TASK_ID}/db" \
        "${out_mm}/tmp_${iteration}_${TASK_ID}/pass1" "${out_mm}/mm_hits_pass1_${iteration}_${TASK_ID}.tsv" \
        "${mm_convert_extra[@]}" >&2
    else
      log_detail "Error: mmseqs search failed (pass 1: REMOVE -> other)"
      exit 1
    fi
    cleanup_unless_kept "${out_mm}/tmp_${iteration}_${TASK_ID}/pass1"*

    awk '{print $1}' "${out_mm}/mm_hits_pass1_${iteration}_${TASK_ID}.tsv" | sort -u > "$pass1_ids"
    pass1_hits=$(wc -l < "$pass1_ids")
    remove_seqs_bash "$mm_remove_file" "$pass1_ids" "$remove_pruned" $long_arg
    check_fasta_nonempty "$remove_pruned" "MMseqs iteration $iteration pass 1"

    # Pass 2: other as query, pruned REMOVE as target.
    n_remove=$(grep -c ">" "$remove_pruned" || true)
    e_other=$(mmseqs_scaled_e "$E_VALUE" "$n_other" "$Z_SIZE")

    mkdir -p "${out_mm}/mm_remove_pruned_${iteration}_${TASK_ID}"
    $MMSEQS createdb "$remove_pruned" "${out_mm}/mm_remove_pruned_${iteration}_${TASK_ID}/db" >&2

    if $MMSEQS search "${out_mm}/mm_other_${iteration}_${TASK_ID}/db" "${out_mm}/mm_remove_pruned_${iteration}_${TASK_ID}/db" \
        "${out_mm}/tmp_${iteration}_${TASK_ID}/pass2" "${out_mm}/tmp_pass2_${iteration}_${TASK_ID}" \
        "${mm_search_extra[@]}" -e "$e_other" --threads "$MMSEQS_CORES" --max-seqs "$MMSEQS_MAX_SEQS" >&2; then
      $MMSEQS convertalis "${out_mm}/mm_other_${iteration}_${TASK_ID}/db" "${out_mm}/mm_remove_pruned_${iteration}_${TASK_ID}/db" \
        "${out_mm}/tmp_${iteration}_${TASK_ID}/pass2" "${out_mm}/mm_hits_pass2_${iteration}_${TASK_ID}.tsv" \
        "${mm_convert_extra[@]}" >&2
    else
      log_detail "Error: mmseqs search failed (pass 2: other -> pruned REMOVE)"
      exit 1
    fi
    cleanup_unless_kept "${out_mm}/tmp_${iteration}_${TASK_ID}"* \
      "${out_mm}/mm_remove_${iteration}_${TASK_ID}" \
      "${out_mm}/mm_other_${iteration}_${TASK_ID}" \
      "${out_mm}/mm_remove_pruned_${iteration}_${TASK_ID}"

    awk '{print $2}' "${out_mm}/mm_hits_pass2_${iteration}_${TASK_ID}.tsv" | sort -u > "$pass2_ids"
    pass2_hits=$(wc -l < "$pass2_ids")
    cat "$pass1_ids" "$pass2_ids" >> "$mm_all_hits"

    if [[ "$pass2_hits" -gt 0 ]]; then
      remove_seqs_bash "$remove_pruned" "$pass2_ids" "$mm_out" $long_arg
      mm_remove_file="$mm_out"
      check_fasta_nonempty "$mm_out" "MMseqs iteration $iteration pass 2"
    else
      mm_remove_file="$remove_pruned"
      cp "$remove_pruned" "$mm_out"
    fi

    MMSEQS_ITERATION_PASS1_HITS=$pass1_hits
    MMSEQS_ITERATION_PASS2_HITS=$pass2_hits

    if [[ -z "$KEEP_INTERMEDIATES" ]]; then
      rm -f "${out_mm}/mm_hits_pass1_${iteration}_${TASK_ID}.tsv" "${out_mm}/mm_hits_pass2_${iteration}_${TASK_ID}.tsv"
      rm -f "$pass1_ids" "$pass2_ids" "$remove_pruned"
    fi
  }

  while true; do
    run_mm_iteration
    echo "MMseqs2 iteration $iteration: pass1 hits=$MMSEQS_ITERATION_PASS1_HITS pass2 hits=$MMSEQS_ITERATION_PASS2_HITS"
    if [[ "$MMSEQS_ITERATION_PASS1_HITS" -eq 0 && "$MMSEQS_ITERATION_PASS2_HITS" -eq 0 ]]; then
      break
    fi
    iteration=$((iteration + 1))
  done

  local mm_total_removed
  mm_total_removed=$(count_unique_ids "$mm_all_hits")

  if [[ "$REMOVE_TARGET" == "db" ]]; then
    DB_FILE="$mm_remove_file"
    check_fasta_nonempty "$DB_FILE" "MMseqs"
  else
    FIXED_FILE="$mm_remove_file"
    check_fasta_nonempty "$FIXED_FILE" "MMseqs"
  fi

  echo "MMseqs2 stopping at iteration $iteration and removed ${mm_total_removed} seqs, took $((SECONDS - start))s"

  cleanup_unless_kept \
    "${out_mm}"/tmp_"${TASK_ID}"* \
    "${out_mm}"/tmp_pass*_"${TASK_ID}"* \
    "${out_mm}"/mm_remove_*_"${TASK_ID}" \
    "${out_mm}"/mm_other_*_"${TASK_ID}" \
    "${out_mm}"/mm_remove_pruned_*_"${TASK_ID}"
}

# --- BLAST (sequential two-pass pruning) ---
run_blast() {
  local start=$SECONDS
  local out_blast="${OUT_DIR}/blast_${OUT_SUFFIX}"
  mkdir -p "$out_blast"
  local blast_out="${out_blast}/blast_${TASK_ID}.fasta"
  local remove_file other_file remove_pruned
  local pass1_ids pass2_ids pass1_hits pass2_hits

  if [[ "$REMOVE_TARGET" == "db" ]]; then
    remove_file="$DB_FILE"
    other_file="$FIXED_FILE"
  else
    remove_file="$FIXED_FILE"
    other_file="$DB_FILE"
  fi

  pass1_ids="${out_blast}/blast_pass1_hits_${TASK_ID}.txt"
  pass2_ids="${out_blast}/blast_pass2_hits_${TASK_ID}.txt"
  remove_pruned="${out_blast}/blast_remove_pass1_${TASK_ID}.fasta"
  local -a blast_extra=()

  read -ra blast_extra <<< "$(profile_cfg BLASTP_EXTRA "")"

  mkdir -p "${out_blast}/tmp_${TASK_ID}" "${out_blast}/b_other_${TASK_ID}" "${out_blast}/b_remove_pruned_${TASK_ID}"

  # Pass 1: REMOVE as query, other as target DB.
  $BLAST_DIR/makeblastdb -in "$other_file" -dbtype prot -out "${out_blast}/b_other_${TASK_ID}/db" >&2
  $BLAST_DIR/blastp -query "$remove_file" -db "${out_blast}/b_other_${TASK_ID}/db" \
    -out "${out_blast}/blast_hits_pass1_${TASK_ID}.tsv" \
    -outfmt "6 qseqid sseqid pident length evalue bitscore" -evalue "$E_VALUE" -dbsize "$BLAST_DBSIZE" \
    -max_target_seqs "$BLAST_MAX_TARGET_SEQS" -num_threads "$BLAST_CORES" \
    "${blast_extra[@]}" >&2
  awk '{print $1}' "${out_blast}/blast_hits_pass1_${TASK_ID}.tsv" | sort -u > "$pass1_ids"
  pass1_hits=$(wc -l < "$pass1_ids")
  remove_seqs_bash "$remove_file" "$pass1_ids" "$remove_pruned"
  check_fasta_nonempty "$remove_pruned" "BLAST pass 1"

  # Pass 2: other as query, pruned REMOVE as target DB.
  $BLAST_DIR/makeblastdb -in "$remove_pruned" -dbtype prot -out "${out_blast}/b_remove_pruned_${TASK_ID}/db" >&2
  $BLAST_DIR/blastp -query "$other_file" -db "${out_blast}/b_remove_pruned_${TASK_ID}/db" \
    -out "${out_blast}/blast_hits_pass2_${TASK_ID}.tsv" \
    -outfmt "6 qseqid sseqid pident length evalue bitscore" -evalue "$E_VALUE" -dbsize "$BLAST_DBSIZE" \
    -max_target_seqs "$BLAST_MAX_TARGET_SEQS" -num_threads "$BLAST_CORES" \
    "${blast_extra[@]}" >&2
  awk '{print $2}' "${out_blast}/blast_hits_pass2_${TASK_ID}.tsv" | sort -u > "$pass2_ids"
  pass2_hits=$(wc -l < "$pass2_ids")
  local total_removed=$((pass1_hits + pass2_hits))

  cleanup_unless_kept "${out_blast}/tmp_${TASK_ID}"* \
    "${out_blast}/b_other_${TASK_ID}" \
    "${out_blast}/b_remove_pruned_${TASK_ID}"

  if [[ "$REMOVE_TARGET" == "db" ]]; then
    remove_seqs_bash "$remove_pruned" "$pass2_ids" "$blast_out"
    DB_FILE="$blast_out"
    check_fasta_nonempty "$blast_out" "BLAST"
  else
    remove_seqs_bash "$remove_pruned" "$pass2_ids" "${out_blast}/fixed_blast_${TASK_ID}.fasta"
    FIXED_FILE="${out_blast}/fixed_blast_${TASK_ID}.fasta"
    check_fasta_nonempty "$FIXED_FILE" "BLAST"
  fi

  if [[ -z "$KEEP_INTERMEDIATES" ]]; then
    rm -f "${out_blast}/blast_hits_pass1_${TASK_ID}.tsv" "${out_blast}/blast_hits_pass2_${TASK_ID}.tsv"
    rm -f "$pass1_ids" "$pass2_ids" "$remove_pruned"
  fi
  print_tool_elapsed "BLAST" "$start" "$total_removed"
}

# --- SW (Smith-Waterman, sequential two-pass pruning) ---
sw_run_pass() {
  local query_fasta="$1"
  local target_fasta="$2"
  local out_tsv="$3"
  local pass_tag="$4"
  local -a sw_cmd=()

  sw_cmd=(
    -m 8 -T "$SW_CORES" -E "$E_VALUE" -Z "$Z_SIZE"
  )
  append_profile_extras sw_cmd SW_EXTRA
  sw_cmd+=("$query_fasta" "$target_fasta")
  if ! $FASTA_DIR/ssearch36 "${sw_cmd[@]}" > "$out_tsv"; then
    log_detail "Error: ssearch36 failed (${pass_tag})"
    exit 1
  fi
}

run_sw() {
  local start=$SECONDS
  local out_sw="${OUT_DIR}/sw_${OUT_SUFFIX}"
  mkdir -p "$out_sw"
  local sw_out="${out_sw}/sw_${TASK_ID}.fasta"
  local remove_file other_file remove_pruned
  local pass1_ids pass2_ids pass1_hits pass2_hits

  if [[ "$REMOVE_TARGET" == "db" ]]; then
    remove_file="$DB_FILE"
    other_file="$FIXED_FILE"
  else
    remove_file="$FIXED_FILE"
    other_file="$DB_FILE"
  fi

  pass1_ids="${out_sw}/sw_pass1_hits_${TASK_ID}.txt"
  pass2_ids="${out_sw}/sw_pass2_hits_${TASK_ID}.txt"
  remove_pruned="${out_sw}/sw_remove_pass1_${TASK_ID}.fasta"

  sw_run_pass "$remove_file" "$other_file" \
    "${out_sw}/sw_hits_pass1_${TASK_ID}.tsv" "pass1"
  awk '{print $1}' "${out_sw}/sw_hits_pass1_${TASK_ID}.tsv" | sort -u > "$pass1_ids"
  pass1_hits=$(wc -l < "$pass1_ids")
  remove_seqs_bash "$remove_file" "$pass1_ids" "$remove_pruned"
  check_fasta_nonempty "$remove_pruned" "Smith-Waterman pass 1"

  sw_run_pass "$other_file" "$remove_pruned" \
    "${out_sw}/sw_hits_pass2_${TASK_ID}.tsv" "pass2"
  awk '{print $2}' "${out_sw}/sw_hits_pass2_${TASK_ID}.tsv" | sort -u > "$pass2_ids"
  pass2_hits=$(wc -l < "$pass2_ids")
  local total_removed=$((pass1_hits + pass2_hits))

  if [[ "$REMOVE_TARGET" == "db" ]]; then
    remove_seqs_bash "$remove_pruned" "$pass2_ids" "$sw_out"
    DB_FILE="$sw_out"
    check_fasta_nonempty "$sw_out" "Smith-Waterman"
  else
    remove_seqs_bash "$remove_pruned" "$pass2_ids" "${out_sw}/fixed_sw_${TASK_ID}.fasta"
    FIXED_FILE="${out_sw}/fixed_sw_${TASK_ID}.fasta"
    check_fasta_nonempty "$FIXED_FILE" "Smith-Waterman"
  fi

  if [[ -z "$KEEP_INTERMEDIATES" ]]; then
    rm -f "${out_sw}/sw_hits_pass1_${TASK_ID}.tsv" "${out_sw}/sw_hits_pass2_${TASK_ID}.tsv"
    rm -f "$pass1_ids" "$pass2_ids" "$remove_pruned"
  fi
  print_tool_elapsed "ssearch36" "$start" "$total_removed"
}

# --- Dispatch by --order (characters validated before config load) ---
echo "chisel_filter: order=${ORDER} REMOVE_TARGET=${REMOVE_TARGET} fixed=${FIXED_FILE} db=${DB_FILE}"

for (( i=0; i<${#ORDER}; i++ )); do
  case "${ORDER:i:1}" in
    p|P) run_phmmer ;;
    m|M) run_mmseqs ;;
    b|B) run_blast ;;
    s|S) run_sw ;;
    *) echo "Unknown tool in --order: ${ORDER:i:1}" >&2; exit 1 ;;
  esac
done

echo "Completed (chisel). Removed from $REMOVE_TARGET  DB_FILE=$DB_FILE  FIXED_FILE=$FIXED_FILE"
