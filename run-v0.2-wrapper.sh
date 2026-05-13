#!/bin/bash
exec sudo \
    INTP_HELPER_IMC_PMU_TYPE_FIRST=73 \
    INTP_HELPER_IMC_PMU_TYPE_LAST=80 \
    bash bench/run-intp-bench.sh "$@"
