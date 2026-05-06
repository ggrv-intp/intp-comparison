# V3.1 Makefile -- no compilation needed; bpftrace interprets scripts at runtime.
# Targets are validation and test helpers.

SCRIPTS := scripts/netp.bt scripts/nets.bt scripts/blk.bt scripts/cpu.bt scripts/llcmr.bt

BPFTRACE ?= bpftrace

.PHONY: all validate deps test test-scripts test-format clean help

all: validate

help:
	@echo "V3.1 bpftrace targets:"
	@echo "  make deps          check bpftrace, BTF, resctrl availability"
	@echo "  make validate      dry-run compile every .bt script (bpftrace -d ast)"
	@echo "  make test          run validation + output format tests"
	@echo "  make clean         remove temp files"

# Dry-run compilation check for each bpftrace script.
validate:
	@bash tests/validate-scripts.sh $(BPFTRACE) $(SCRIPTS)

# Verify tools and kernel features are present.
deps:
	@bash tests/check-btf.sh
	@command -v $(BPFTRACE) >/dev/null 2>&1 || { echo "bpftrace not installed"; exit 1; }
	@command -v python3 >/dev/null 2>&1 || { echo "python3 not installed"; exit 1; }
	@echo "Dependencies OK"

test: test-scripts test-format

test-scripts:
	@bash tests/validate-scripts.sh $(BPFTRACE) $(SCRIPTS)

test-format:
	@bash tests/test-output-format.sh

clean:
	@rm -rf /tmp/intp-bpftrace-* 2>/dev/null || true
	@[ -d /sys/fs/resctrl/mon_groups/intp-v3.1 ] && \
		rmdir /sys/fs/resctrl/mon_groups/intp-v3.1 2>/dev/null || true
	@echo "Cleaned temporary files and resctrl mon_groups"
