# CHISEL

CHISEL splits protein sequence databases into train / test / validation sets, filters sequence pairs for homology, and builds publication-ready benchmark splits. The suite includes:

| Tool | Role |
|------|------|
| `chisel_build` | End-to-end pipeline: split → filter test/val/train |
| `chisel_filter` | Multi-tool filter (pHMMER, MMseqs2, BLAST+, Smith–Waterman) |
| `chisel_dedup` | Self-deduplicate a FASTA file |
| `chisel_splitter` | Low-level Profmark-style splitter (used by `chisel_build`) |
| `phmmer_filter` | Low-level pHMMER-based pairwise filter |

CHISEL is released under the MIT License (see [License](#license)).

## Citation

To cite CHISEL, please use:

> [CHISEL_CITATION_PLACEHOLDER]
>
> [CHISEL_PAPER_LINK_PLACEHOLDER]

---

## Acknowledgements

We thank the developers of [HMMER3](http://hmmer.org) <sup><a href="#ref-eddy-2011">1</a></sup> for the EASEL tools and base pHMMER pipeline customized for `chisel_splitter` and `chisel_filter`.

---

## OS support matrix

| OS | Build support | Pipeline scripts | External tools | Notes |
|----|---------------|------------------|----------------|-------|
| Linux (x86_64) | Official | Official | Official | Primary supported platform. |
| macOS (Apple Silicon / Intel) | Official | Official | Official | Use Homebrew/system packages for dependencies. |
| Windows (WSL2) | Official (via Linux in WSL2) | Official (via Bash in WSL2) | Official (via Linux in WSL2) | Recommended Windows path. |
| Windows (native) | Planned | Planned | Planned | Not currently first-class. |

---

## Requirements

**Core build tools (all supported platforms)**
- C compiler (`gcc`/`clang`)
- GNU `make`
- `ar`, `ranlib`
- Bash (for pipeline scripts and install helpers)
- `pthread` and math library (`-lm`)

**Runtime dependencies for `chisel_filter`**
- [MMseqs2](https://github.com/soedinglab/MMseqs2)
- [NCBI BLAST+](https://ftp.ncbi.nlm.nih.gov/blast/executables/blast+/LATEST/) (`makeblastdb`, `blastp`)
- [FASTA package](https://github.com/wrpearson/fasta36) (`ssearch36`)

Install external tools via `make install-external` (see below).

---

## Installation

### 1) Clone and build

```bash
git clone https://github.com/Protein-Sequence-Annotation/chisel.git
cd chisel
./configure   # detects CPU (SSE on x86_64, NEON on aarch64/arm64); writes build-config.mk
make
```

`./configure` always runs under bash (`#!/usr/bin/env bash`); your login shell does not matter.

**Permission denied on scripts?** Run `make install-scripts` once after cloning. `make install-external` and `make test-install` do this automatically. You can also invoke scripts as `bash configure`.

Re-run `./configure` after changing machines or to force a backend (`./configure --with-impl=sse` or `--with-impl=neon`). `make distclean` removes `build-config.mk` and build products.

Executables land in `bin/`:

| Binary | Role |
|--------|------|
| `chisel_build` | Split + filter pipeline |
| `chisel_filter` | Multi-tool filter (`p` / `m` / `b` / `s` steps) |
| `chisel_dedup` | Self-deduplication |
| `chisel_splitter` | Standalone pHMMER splitter |
| `phmmer_filter` | Standalone pHMMER filter |

Add `bin` to your `PATH` or call tools with full paths:

```bash
export PATH="/path/to/chisel/bin:$PATH"
```

### 2) Install external tools

```bash
make install-external
```

This installs MMseqs2, BLAST+, and FASTA36 into `chisel/external_tools` by default.

**Linux** (`install/linux/install_external_linux.sh`) selects downloads from `uname -m`: **x86_64** uses MMseqs2 `sse2` binaries and NCBI **x64-linux** BLAST; **aarch64**/**arm64** uses MMseqs2 **arm64** and NCBI **aarch64-linux** BLAST. Override with `MMSEQS_ARCH` (e.g. `avx2`) or `BLAST_PLATFORM` if needed.

**macOS:** `install/macos/install_external_macos.sh` prefers **Homebrew** for MMseqs2 and BLAST+; otherwise falls back to upstream tarballs. FASTA36 is built from source.

**Windows (WSL2):**

```powershell
powershell -ExecutionPolicy Bypass -File .\install\windows\install_external_windows.ps1 -ChiselDir C:\path\to\chisel
```

If external tools are already installed, point CHISEL at them in your config (see [Configuration](#configuration)):

| Config key | Set this to |
|------------|-------------|
| `MMSEQS` | Full path to `mmseqs` executable |
| `BLAST_DIR` | Directory containing `makeblastdb` and `blastp` |
| `FASTA_DIR` | Directory containing `ssearch36` |

Only the tools listed in `--order` need to be installed. You can also call the dispatcher directly:

```bash
./install/install_external.sh /path/to/chisel
```

### 3) Run installation tests

```bash
make test-install
```

Linux/macOS runs `install/test_installation.sh`; Windows routes through WSL2 via `install/windows/test_installation_windows.ps1`.

---

## Configuration

Defaults live in **`install/chisel.config.in`**. Generate runnable configs with absolute paths:

```bash
make config          # writes install/chisel.config and install/test_filter.config
```

Re-run after cloning or moving the repo. `make all` and `make install-external` also refresh configs when templates change.

**Example for running different scripts**

| Script | Example |
|--------|---------|
| `chisel_build` | `chisel_build --config install/chisel.config --input-db seqDB.fasta --output-dir out/` |
| `chisel_dedup` | `chisel_dedup --config install/chisel.config --file test.fasta [--output-dir out/]` |
| `chisel_filter` | `chisel_filter --config install/chisel.config --order mbps --fixed-file test.fasta --db-file train.fasta` |

Phase-specific commandline options in config file:

| Prefix | Used by |
|--------|---------|
| `SPLIT_*`, `SPLITTER_EXTRA` | `chisel_build` (splitter step); `SPLIT_SEED` → `--split-seed` |
| `BUILD_FILTER_*` | `chisel_build` filter steps (`CHISEL_PROFILE=build`) |
| `FILTER_*` | standalone `chisel_filter` |
| `DEDUP_*` | `chisel_dedup` |

Common variables: `E_VALUE`, `Z_SIZE`, `PHMMER_CORES`, `MMSEQS_CORES`, `BLAST_CORES`, `SW_CORES`, `SW_SHARDS`, `REMOVE_TARGET` (`db` or `fixed`), `ORDER` (for `chisel_build`).

**Log output:** `chisel_build`, `chisel_dedup`, and `chisel_filter` print progress summaries on **stdout** and tool verbose output on **stderr**. With SLURM, point `#SBATCH --output` at stdout and `#SBATCH --error` at stderr.

---

## Quick start

Generate default config, then run the pipeline end-to-end (Phase 1-3):

**Phase 1: Build validation and test set**

```bash
make config
chisel_build --config install/chisel.config --input-db seqDB.fasta --output-dir results/
```

Outputs: `results/train.fasta`, `results/test.fasta`, `results/val.fasta`, `results/discard.fasta`.

**Phase 2: Self-deduplicate validation and test files from Phase 1:**

```bash
chisel_dedup --config install/chisel.config --file results/val.fasta
chisel_dedup --config install/chisel.config --file results/test.fasta
```

**Phase 3: Grow train set** (MMseqs2 → BLASTp → pHMMER → ssearch36):

```bash
chisel_filter --config install/chisel.config --order pmbs \
  --fixed-file test.fasta --db-file train_candidates.fasta
```

**Standalone splitter** (pHMMER based unidirectional splitter):

```bash
chisel_splitter --dbblock 100 --test_limit 20 --val_limit 10 -o stats --output_dir results seqDB.fasta
```

---

## `chisel_build`

Splits an input database, then runs three `chisel_filter` passes to remove cross-set homologs. Final outputs: `train.fasta`, `test.fasta`, `val.fasta`, `discard.fasta` in `--output-dir`.

| Option | Description |
|--------|-------------|
| `--config <file>` | Config file (required) |
| `--input-db <fasta>` | Input sequence database (required) |
| `--output-dir <dir>` | Output directory (required) |

Splitter and filter settings come from the config (`SPLIT_*`, `ORDER`, `BUILD_FILTER_*`, etc.).

---

## `chisel_filter`

Runs pHMMER, MMseqs2, BLAST+, and/or Smith–Waterman in the order given by `--order`. Each tool performs two-pass pruning: search the removal side as query, prune hits, then run the reverse direction against the pruned file before moving to the next tool.

### Required arguments

| Option | Description |
|--------|-------------|
| `--order <string>` | Tool order: `p` = pHMMER, `m` = MMseqs2, `b` = BLAST+, `s` = Smith–Waterman (`ssearch36`). Example: `pmbs`, `mbps`. |
| `--config <file>` | Config file |
| `--fixed-file <fasta>` | Fixed/reference side (e.g. test set) |
| `--db-file <fasta>` | Database to filter against the fixed set |

### Optional arguments

| Option | Description |
|--------|-------------|
| `--out-suffix <name>` | Suffix for per-tool output dirs; defaults to `TASK_ID` from config |

### Key config variables

| Variable | Role |
|----------|------|
| `OUT_DIR` | Base directory for outputs (required) |
| `REMOVE_TARGET` | `db` or `fixed` — which side loses sequences after hits |
| `PHMMER_FILTER`, `MMSEQS`, `BLAST_DIR`, `FASTA_DIR` | Tool paths |
| `E_VALUE`, `Z_SIZE` | E-value threshold and database size calibration |
| `PHMMER_CORES`, `MMSEQS_CORES`, `BLAST_CORES`, `SW_CORES` | Thread counts |
| `SW_SHARDS` | Parallel `ssearch36` shards (`SW_CORES` must be divisible by `SW_SHARDS`) |
| `FILTER_PHMMER_PHIGH`, `FILTER_PHMMER_PLOW`, `FILTER_PHMMER_QSIZE`, `FILTER_PHMMER_EXTRA` | pHMMER tuning (standalone) |
| `FILTER_MMSEQS_*`, `FILTER_BLASTP_EXTRA`, `FILTER_SW_EXTRA` | Per-tool extras |

See `src/chisel_filter.sh` for full defaults and behavior.

---

## `chisel_dedup`

Removes within-file homologs using `phmmer_filter` with `--no_self`. Writes `<stem>_dedup.fasta` (e.g. `test.fasta` → `test_dedup.fasta`).

| Option | Description |
|--------|-------------|
| `--config <file>` | Config file (required) |
| `--file <fasta>` | Input FASTA (required) |
| `--output-dir <dir>` | Output directory (default: same directory as input) |

Tuning via `DEDUP_PHIGH`, `DEDUP_PLOW`, `DEDUP_QSIZE`, `DEDUP_EXTRA` in config.

---

## `chisel_splitter`

Low-level splitter for one input FASTA into train / test / val / discard. Used internally by `chisel_build`; call directly for custom split workflows.

### Required arguments

| Argument | Description |
|----------|-------------|
| `<seqdb>` | Input protein sequence file (positional; must be last) |

### Essential options

| Option | Default | Description |
|--------|---------|-------------|
| `-o <prefix>` | `-` | Prefix for stats / summary output files |
| `-Z <n>` | *inferred from `--dbblock`* | Effective database size for E-value calculation |
| `--cpu <n>` | `1` | Worker threads |
| `--dbblock <n>` | `10000` | Sequences per database block |
| `--test_limit <n>` | `500` | Minimum test sequences before stopping |
| `--val_limit <n>` | `100` | Minimum validation sequences |
| `--init_chunk <n>` | `50` | Sequences considered per assignment round |
| `--split-seed <n>` | `0` | RNG seed for train/test/val assignment (`0` = random each run) |
| `--seed <n>` | `42` | RNG seed for internal pHMMER pipeline (`0` = arbitrary) |
| `--suppress` | off | Disable progress bar |
| `--task_id <id>` | `0` | Suffix for output files (`*_0.fasta`, etc.) |
| `--output_dir <dir>` | — | Write train/test/val/discard under `<dir>` |
| `-E <x>` | `0.01` | E-value threshold for significant hits |
| `--plow`, `--phigh` | `0.0` | PID window for accepting sequences |

For all options: `chisel_splitter -h`.

---

## `phmmer_filter`

Standalone pHMMER-based pairwise filter. Used internally by `chisel_filter` and `chisel_dedup`.

### Required arguments

| Argument | Description |
|----------|-------------|
| `<qdb>` | Query sequence database (first positional) |
| `<tdb>` | Target sequence database (second positional) |

One of `qdb` or `tdb` may be `-` (stdin), not both.

### Essential options

| Option | Default | Description |
|--------|---------|-------------|
| `-o <prefix>` | `-` | Output prefix for result files |
| `-Z <n>` | *inferred* | Database size for E-value calibration |
| `-E <x>` | `0.01` | Reporting E-value threshold |
| `--cpu <n>` | `1` | Threads |
| `--qsize <n>` | `1` | Queries per thread per batch |
| `--format <n>` | `1` | Output format (see below) |
| `--all_hits` | off | Report all hits, not just first failure |
| `--no_self` | off | Ignore self-comparison (used by `chisel_dedup`) |
| `--plow`, `--phigh` | `0.0` | PID limits for accepting sequences |
| `--seed <n>` | `42` | RNG seed for internal pHMMER pipeline (`0` = arbitrary) |

### Output formats (`--format`)

| Value | Meaning |
|-------|---------|
| `0` | Per-sequence ACCEPT/REJECT string |
| `1` | Full information for rejected hits (default) |
| `2` | IDs of accepted sequences |
| `3` | IDs of rejected queries |
| `4` | IDs of rejected targets (with `--all_hits`) |

For all options: `phmmer_filter -h`.

---

## Example use cases

1. **Benchmark split from one database** — `chisel_build` with tuned `SPLIT_TEST_LIMIT`, `SPLIT_VAL_LIMIT`, and `SPLIT_CPU` in config.

2. **Filter training candidates against a fixed test set** — `chisel_filter` with `REMOVE_TARGET=db` and strict `E_VALUE` / `Z_SIZE`.

3. **Remove overlap between two FASTA sets** — point `--fixed-file` and `--db-file` at the two pools; set `REMOVE_TARGET` to drop hits from either side.

4. **Out-of-distribution evaluation** — split with `chisel_build`, or filter training candidates with `chisel_filter` / `phmmer_filter` to strip test-set homologs.

5. **Within-set deduplication** — `chisel_dedup` on a FASTA file, or `chisel_filter` / `phmmer_filter` with the same file as both query and target.

6. **Tool order and speed** — MMseqs2 is fastest, then BLAST and pHMMER, then Smith–Waterman. Use `p` alone for fast homology removal, or `pmbs` for a full cascade. Omit letters to skip tools (e.g. `pm` skips BLAST and SW).

---

## Further help

```bash
chisel_splitter -h
phmmer_filter -h
chisel_build --help
chisel_dedup --help
```

For `chisel_filter` pipeline behavior and defaults, read the header of `src/chisel_filter.sh`.

---

## FASTA36 build notes

`make install-external` builds FASTA36 from upstream [wrpearson/fasta36](https://github.com/wrpearson/fasta36) with a GCC compatibility patch (`install/patches/fasta36-gcc-prototypes.patch`). Output: `external_tools/fasta36/bin/ssearch36`.

Optional overrides: `FASTA36_REPO`, `FASTA36_REF` (see `install/fasta36_install.sh`).

Upstream FASTA36 predates strict ISO C defaults on recent GCC/Clang. Legacy mode requires **`git`**, **`patch`**, and **`make`** on `PATH`. If upstream changes the patched files, regenerate the diff and retry `make install-external`.

---

## References

1. <a id="ref-eddy-2011"></a>Eddy SR (2011) Accelerated Profile HMM Searches. *PLOS Computational Biology* 7(10): e1002195. https://doi.org/10.1371/journal.pcbi.1002195

---

## License

This project is licensed under the MIT License. See `LICENSE` for the full text.
