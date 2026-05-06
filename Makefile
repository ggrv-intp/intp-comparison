# IntP root Makefile — orchestrates per-variant builds.
#
# Compileable variants:
#   v1.1-stap-helper   — C helper for V1 stap module
#   v2-c-stable-abi    — hybrid procfs/perf_event_open/resctrl backends
#   v3-ebpf-libbpf     — libbpf+CO-RE BPF program (needs clang, libbpf-dev)
#
# Validate-only variants (no compile, runtime interpreters):
#   v3.1-bpftrace      — bpftrace .bt scripts (deps + parse check)
#   v0-stap-classic    — original SystemTap script (parse check only)
#   v0.1-stap-k68      — kernel-6.8 SystemTap port (parse check only)
#   v1-stap-native     — native stap module (parse check only)
#
# Common targets:
#   make all       build every compileable variant + validate the rest
#   make clean     clean every variant tree
#   make smoke     quick 5s sanity invocation per variant (needs sudo)
#   make help      this message
#
# Per-variant targets (build/clean/smoke individually):
#   make v1.1 v2 v3 v3.1
#   make clean-v1.1 clean-v2 clean-v3 clean-v3.1
#   make smoke-v1.1 smoke-v2 smoke-v3 smoke-v3.1
#

ROOT := $(abspath $(dir $(lastword $(MAKEFILE_LIST))))

V11_DIR := $(ROOT)/v1.1-stap-helper
V2_DIR  := $(ROOT)/v2-c-stable-abi
V3_DIR  := $(ROOT)/v3-ebpf-libbpf
V31_DIR := $(ROOT)/v3.1-bpftrace
V0_STP  := $(ROOT)/v0-stap-classic/INTPCERRADO.STP
V01_STP := $(ROOT)/v0.1-stap-k68/intp-6.8.stp
V1_STP  := $(ROOT)/v1-stap-native/intp-resctrl.stp

.PHONY: all clean smoke help \
        v1.1 v2 v3 v3.1 \
        clean-v1.1 clean-v2 clean-v3 clean-v3.1 \
        smoke-v1.1 smoke-v2 smoke-v3 smoke-v3.1 \
        validate-v0 validate-v0.1 validate-v1

all: v1.1 v2 v3 v3.1 validate-v0 validate-v0.1 validate-v1
	@echo "[intp] all variants built/validated"

# ---- compileable variants ----------------------------------------------------

v1.1:
	$(MAKE) -C $(V11_DIR) all

v2:
	$(MAKE) -C $(V2_DIR) all

v3:
	$(MAKE) -C $(V3_DIR) all

# ---- runtime-interpreted variants -------------------------------------------

v3.1:
	$(MAKE) -C $(V31_DIR) deps validate

validate-v0:
	@command -v stap >/dev/null 2>&1 || { echo "[v0] skip: stap not installed"; exit 0; }
	@test -f $(V0_STP) && stap -p1 $(V0_STP) >/dev/null && echo "[v0] parse OK"

validate-v0.1:
	@command -v stap >/dev/null 2>&1 || { echo "[v0.1] skip: stap not installed"; exit 0; }
	@test -f $(V01_STP) && stap -p1 $(V01_STP) >/dev/null && echo "[v0.1] parse OK"

validate-v1:
	@command -v stap >/dev/null 2>&1 || { echo "[v1] skip: stap not installed"; exit 0; }
	@test -f $(V1_STP) && stap -p1 $(V1_STP) >/dev/null && echo "[v1] parse OK"

# ---- clean ------------------------------------------------------------------

clean: clean-v1.1 clean-v2 clean-v3 clean-v3.1

clean-v1.1:
	-$(MAKE) -C $(V11_DIR) clean

clean-v2:
	-$(MAKE) -C $(V2_DIR) clean

clean-v3:
	-$(MAKE) -C $(V3_DIR) clean

clean-v3.1:
	-$(MAKE) -C $(V31_DIR) clean

# ---- smoke (5s runtime sanity) ----------------------------------------------
# All require sudo for perf/BPF/stap. v0/v0.1/v1 are excluded — they need
# kernel-tied stap modules that compile per-host and can't be one-shot here.

smoke: smoke-v2 smoke-v3 smoke-v3.1
	@echo "[intp] smoke OK"

smoke-v1.1: v1.1
	@echo "[v1.1] smoke not applicable (helper, not standalone profiler)"

smoke-v2: v2
	@$(V2_DIR)/intp-hybrid --interval 1 --duration 5 >/dev/null && echo "[v2] smoke OK"

smoke-v3: v3
	@$(V3_DIR)/intp-ebpf --interval 1 --duration 5 >/dev/null && echo "[v3] smoke OK"

smoke-v3.1:
	@$(V31_DIR)/run-intp-bpftrace.sh --interval 1 --duration 5 >/dev/null \
		&& echo "[v3.1] smoke OK"

# ---- help -------------------------------------------------------------------

help:
	@sed -n '1,/^$$/p' $(firstword $(MAKEFILE_LIST))
