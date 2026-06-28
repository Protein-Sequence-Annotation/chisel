SHELL := /bin/sh

ROOT := $(abspath $(dir $(lastword $(MAKEFILE_LIST))))
BUILD := $(ROOT)/build
BIN := $(ROOT)/bin

-include $(ROOT)/build-config.mk
# Build targets need configure; install/test script targets do not.
ifndef IMPLDIR
ifeq ($(filter install-scripts install-external test-install config chisel_filter chisel_build chisel_dedup,$(MAKECMDGOALS)),)
$(error Run ./configure before make. It writes build-config.mk for your CPU (SSE or NEON).)
endif
endif

UNAME_S := $(shell uname -s 2>/dev/null || echo Unknown)
OS ?= $(UNAME_S)
# Darwin: avoid linking straight into bin/ (codesign/Gatekeeper); link to tmp under BUILD, codesign, then install.
IS_MACOS := $(if $(filter Darwin,$(UNAME_S)),1,)
EXE :=
ifeq ($(OS),Windows_NT)
  EXE := .exe
endif

CC ?= gcc
AR ?= ar
RANLIB ?= ranlib

CFLAGS := -O3 -pthread
CPPFLAGS := -DHAVE_CONFIG_H
INCLUDES := -I$(ROOT)/easel -I$(ROOT)/src -I$(ROOT)/src/$(IMPLDIR)
LDFLAGS :=
LDLIBS := -lpthread -lm

CHISEL_SRCS := \
	src/chisel_splitter.c \
	src/phmmer_filter.c \
	src/chisel_dev.c

# HMMER sources excluding impl_* (those come from configure via HMMER_IMPL_SRCS)
HMMER_BASE_SRCS := \
	src/errors.c src/logsum.c src/p7_alidisplay.c src/p7_bg.c src/p7_builder.c src/p7_domaindef.c \
	src/p7_hmm.c src/p7_pipeline.c src/p7_prior.c src/p7_profile.c src/p7_spensemble.c src/p7_tophits.c \
	src/p7_trace.c src/p7_scoredata.c src/fm_general.c src/fm_sse.c src/fm_ssv.c src/build.c src/evalues.c \
	src/eweight.c src/hmmer.c src/modelconfig.c src/modelstats.c src/seqmodel.c src/tracealign.c src/p7_gmx.c \
	src/p7_hit.c src/p7_hmmwindow.c src/fm_alphabet.c src/emit.c src/generic_decoding.c src/generic_fwdback.c \
	src/generic_optacc.c src/p7_domain.c

HMMER_SRCS := $(HMMER_BASE_SRCS) $(HMMER_IMPL_SRCS)

# Easel without SIMD variant (esl_sse.c / esl_neon.c added via EASEL_SIMD_SRC from configure)
EASEL_BASE_SRCS := \
	easel/easel.c easel/esl_alphabet.c easel/esl_cluster.c easel/esl_dirichlet.c easel/esl_dmatrix.c easel/esl_exponential.c \
	easel/esl_fileparser.c easel/esl_getopts.c easel/esl_gumbel.c easel/esl_hmm.c easel/esl_keyhash.c easel/esl_mem.c \
	easel/esl_minimizer.c easel/esl_mixdchlet.c easel/esl_msa.c easel/esl_msacluster.c easel/esl_msaweight.c \
	easel/esl_quicksort.c easel/esl_random.c easel/esl_rand64.c easel/esl_randomseq.c easel/esl_rootfinder.c \
	easel/esl_scorematrix.c easel/esl_sq.c easel/esl_sqio.c easel/esl_sqio_ascii.c easel/esl_sqio_ncbi.c easel/esl_ssi.c \
	easel/esl_stats.c easel/esl_stopwatch.c easel/esl_threads.c easel/esl_tree.c easel/esl_vectorops.c easel/esl_wuss.c \
	easel/esl_arr2.c easel/esl_arr3.c easel/esl_bitfield.c easel/esl_composition.c easel/esl_distance.c \
	easel/esl_graph.c easel/esl_matrixops.c easel/esl_msafile.c easel/esl_msafile_a2m.c easel/esl_msafile_afa.c \
	easel/esl_msafile_clustal.c easel/esl_msafile_phylip.c easel/esl_msafile_psiblast.c easel/esl_msafile_selex.c \
	easel/esl_msafile_stockholm.c easel/esl_ratematrix.c easel/esl_stack.c easel/esl_buffer.c

EASEL_SRCS := $(EASEL_BASE_SRCS) $(EASEL_SIMD_SRC)

CHISEL_OBJS := $(patsubst %.c,$(BUILD)/%.o,$(CHISEL_SRCS))
HMMER_OBJS := $(patsubst %.c,$(BUILD)/%.o,$(HMMER_SRCS))
EASEL_OBJS := $(patsubst %.c,$(BUILD)/%.o,$(EASEL_SRCS))

CONFIG_SCRIPT := $(ROOT)/install/gen_config.sh
CONFIG_OUT := $(ROOT)/install/chisel.config
TEST_CONFIG_OUT := $(ROOT)/install/test_filter.config

.PHONY: all libs clean distclean install-scripts install-external test-install config \
	chisel_splitter phmmer_filter chisel_filter chisel_build chisel_dedup

# Git clones often drop executable bits; restore before running install/test scripts.
INSTALL_SH := \
	$(ROOT)/configure \
	$(ROOT)/install/install_external.sh \
	$(ROOT)/install/fasta36_install.sh \
	$(ROOT)/install/test_installation.sh \
	$(ROOT)/install/gen_config.sh \
	$(ROOT)/install/linux/install_external_linux.sh \
	$(ROOT)/install/macos/install_external_macos.sh

install-scripts:
	chmod +x $(INSTALL_SH)

config: $(CONFIG_OUT) $(TEST_CONFIG_OUT)

$(CONFIG_OUT) $(TEST_CONFIG_OUT): $(ROOT)/install/chisel.config.in $(ROOT)/install/test_filter.config.in $(CONFIG_SCRIPT)
	bash "$(CONFIG_SCRIPT)" "$(ROOT)"

all: $(CONFIG_OUT) $(BIN)/chisel_splitter$(EXE) $(BIN)/phmmer_filter$(EXE) $(BIN)/chisel_filter $(BIN)/chisel_build $(BIN)/chisel_dedup

chisel_splitter: $(BIN)/chisel_splitter$(EXE)
phmmer_filter: $(BIN)/phmmer_filter$(EXE)
chisel_filter: $(BIN)/chisel_filter
chisel_build: $(BIN)/chisel_build
chisel_dedup: $(BIN)/chisel_dedup

libs: $(BUILD)/libhmmer_min.a $(BUILD)/libeasel_min.a

$(BUILD)/libhmmer_min.a: $(HMMER_OBJS)
	@mkdir -p $(dir $@)
	$(AR) rcs $@ $^
	$(RANLIB) $@

$(BUILD)/libeasel_min.a: $(EASEL_OBJS)
	@mkdir -p $(dir $@)
	$(AR) rcs $@ $^
	$(RANLIB) $@

ifeq ($(IS_MACOS),1)
$(BIN)/chisel_splitter$(EXE): $(BUILD)/src/chisel_splitter.o $(BUILD)/src/chisel_dev.o $(BUILD)/libhmmer_min.a $(BUILD)/libeasel_min.a
	@mkdir -p $(BIN) $(BUILD)
	@t=$$(mktemp "$(BUILD)/chisel_splitter.XXXXXX"); \
	$(CC) $(CFLAGS) $(LDFLAGS) -o "$$t" $^ $(LDLIBS) && \
	chmod +x "$$t" && \
	codesign --force --sign - "$$t" && \
	cp "$$t" $@ && chmod +x $@ && rm -f "$$t" || { st=$$?; rm -f "$$t"; exit $$st; }

$(BIN)/phmmer_filter$(EXE): $(BUILD)/src/phmmer_filter.o $(BUILD)/src/chisel_dev.o $(BUILD)/libhmmer_min.a $(BUILD)/libeasel_min.a
	@mkdir -p $(BIN) $(BUILD)
	@t=$$(mktemp "$(BUILD)/phmmer_filter.XXXXXX"); \
	$(CC) $(CFLAGS) $(LDFLAGS) -o "$$t" $^ $(LDLIBS) && \
	chmod +x "$$t" && \
	codesign --force --sign - "$$t" && \
	cp "$$t" $@ && chmod +x $@ && rm -f "$$t" || { st=$$?; rm -f "$$t"; exit $$st; }

$(BIN)/chisel_filter: $(ROOT)/src/chisel_filter.sh
	@mkdir -p $(BIN) $(BUILD)
	@t=$$(mktemp "$(BUILD)/chisel_filter.XXXXXX"); \
	cp $< "$$t" && chmod +x "$$t" && \
	cp "$$t" $@ && chmod +x $@ && rm -f "$$t" || { st=$$?; rm -f "$$t"; exit $$st; }

$(BIN)/chisel_build: $(ROOT)/src/chisel_build.sh
	@mkdir -p $(BIN) $(BUILD)
	@t=$$(mktemp "$(BUILD)/chisel_build.XXXXXX"); \
	cp $< "$$t" && chmod +x "$$t" && \
	cp "$$t" $@ && chmod +x $@ && rm -f "$$t" || { st=$$?; rm -f "$$t"; exit $$st; }

$(BIN)/chisel_dedup: $(ROOT)/src/chisel_dedup.sh
	@mkdir -p $(BIN) $(BUILD)
	@t=$$(mktemp "$(BUILD)/chisel_dedup.XXXXXX"); \
	cp $< "$$t" && chmod +x "$$t" && \
	cp "$$t" $@ && chmod +x $@ && rm -f "$$t" || { st=$$?; rm -f "$$t"; exit $$st; }
else
$(BIN)/chisel_splitter$(EXE): $(BUILD)/src/chisel_splitter.o $(BUILD)/src/chisel_dev.o $(BUILD)/libhmmer_min.a $(BUILD)/libeasel_min.a
	@mkdir -p $(dir $@)
	$(CC) $(CFLAGS) $(LDFLAGS) -o $@ $^ $(LDLIBS)

$(BIN)/phmmer_filter$(EXE): $(BUILD)/src/phmmer_filter.o $(BUILD)/src/chisel_dev.o $(BUILD)/libhmmer_min.a $(BUILD)/libeasel_min.a
	@mkdir -p $(dir $@)
	$(CC) $(CFLAGS) $(LDFLAGS) -o $@ $^ $(LDLIBS)

$(BIN)/chisel_filter: $(ROOT)/src/chisel_filter.sh
	@mkdir -p $(dir $@)
	cp $< $@
	chmod +x $@

$(BIN)/chisel_build: $(ROOT)/src/chisel_build.sh
	@mkdir -p $(dir $@)
	cp $< $@
	chmod +x $@

$(BIN)/chisel_dedup: $(ROOT)/src/chisel_dedup.sh
	@mkdir -p $(dir $@)
	cp $< $@
	chmod +x $@
endif

# SIMD intrinsics for impl_* and Easel vector math
$(BUILD)/src/$(IMPLDIR)/%.o: $(ROOT)/src/$(IMPLDIR)/%.c
	@mkdir -p $(dir $@)
	$(CC) $(CFLAGS) $(SIMD_CFLAGS) $(CPPFLAGS) $(INCLUDES) -c $< -o $@

$(BUILD)/easel/esl_neon.o: $(ROOT)/easel/esl_neon.c
	@mkdir -p $(dir $@)
	$(CC) $(CFLAGS) $(SIMD_CFLAGS) $(CPPFLAGS) $(INCLUDES) -c $< -o $@

$(BUILD)/easel/esl_sse.o: $(ROOT)/easel/esl_sse.c
	@mkdir -p $(dir $@)
	$(CC) $(CFLAGS) $(SIMD_CFLAGS) $(CPPFLAGS) $(INCLUDES) -c $< -o $@

$(BUILD)/%.o: $(ROOT)/%.c
	@mkdir -p $(dir $@)
	$(CC) $(CFLAGS) $(CPPFLAGS) $(INCLUDES) -c $< -o $@

install-external: install-scripts config
	"$(ROOT)/install/install_external.sh" "$(ROOT)"

ifeq ($(OS),Windows_NT)
test-install: install-scripts config
	powershell.exe -ExecutionPolicy Bypass -File "$(ROOT)/install/windows/test_installation_windows.ps1" -ChiselDir "$(ROOT)"
else
test-install: install-scripts config
	bash "$(ROOT)/install/test_installation.sh" "$(ROOT)"
endif

clean:
	rm -rf $(BUILD) $(BIN)

distclean: clean
	rm -f $(ROOT)/build-config.mk
