#!/usr/bin/env bash
# VCS backend for the HBL2 matrix trace replay (tl-test-new DPI Guest Mode).
#
# Usage:
#   vcs/run_vcs.sh build      compile simv (no coverage instrumentation)
#   vcs/run_vcs.sh run        compile if needed, replay the trace in run/tltest.ini
#   vcs/run_vcs.sh coverage   coverage-instrumented compile + run + urg report
#
# Modeled on CUTE-Test/vcs/run_vcs.sh. The VCS Q-2020.03 launcher scripts carry
# a '#!/bin/sh -h' shebang that dash rejects, and default to the 32-bit
# binaries; both are worked around by invoking them through bash with -full64.
set -euo pipefail

project_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
rtl_dir_default="$project_root/../HBL2/build"
rtl_dir=${HBL2_RTL_DIR:-$rtl_dir_default}
vcs_build_root=${HBL2_VCS_BUILD_DIR:-$project_root/build_vcs}
run_root="$project_root/run/vcs_run"
tb_file="$project_root/vcs/vcs_tb.sv"
coverage_hier="$project_root/vcs/hbl2_coverage.hier"
dpi_lib="$project_root/main/build/libtltest_dpi.so"
mode=${1:-run}

export VCS_HOME=${VCS_HOME:-/nfs/tools/synopsys/vcs/Q-2020.03-SP2}
export LM_LICENSE_FILE=${LM_LICENSE_FILE:-28000@eda01}
vcs_cpp=${HBL2_VCS_CPP:-/usr/bin/g++}
vcs_jobs=${HBL2_VCS_JOBS:-16}

vcs() { bash "$VCS_HOME/bin/vcs" -full64 "$@"; }
# urg's wrapper invokes ${VCS_HOME}/bin/vcs -location directly, so the
# dash-rejected '#!/bin/sh -h' shebang (see the header comment) breaks it
# from the inside — wrapping urg in bash is not enough. Patch a build-dir
# copy: bash shebang plus routing the internal vcs -location / vcsMsgReport
# calls through bash. -full64 is forced to skip the vdb auto-detect branch.
urg() {
  mkdir -p "$vcs_build_root/tool"
  sed -e '1s|^#!.*$|#!/usr/bin/env bash|' \
      -e 's|\${VCS_HOME}/bin/vcs -location|bash ${VCS_HOME}/bin/vcs -location|g' \
      -e 's|ERR_MSG_REPORT=${BASE_STRING}/bin/vcsMsgReport|ERR_MSG_REPORT="bash ${BASE_STRING}/bin/vcsMsgReport"|' \
      "$VCS_HOME/bin/urg" > "$vcs_build_root/tool/urg"
  chmod +x "$vcs_build_root/tool/urg"
  bash "$vcs_build_root/tool/urg" -full64 "$@"
}

require_dpi_lib() {
  if [[ ! -f "$dpi_lib" ]]; then
    echo "error: $dpi_lib is missing; run 'make tltest-build-dpi-coupledL2' first" >&2
    exit 2
  fi
}

require_rtl() {
  if [[ ! -f "$rtl_dir/TestTop.sv" || ! -f "$rtl_dir/filelist.f" ]]; then
    echo "error: generated RTL is missing at $rtl_dir; run 'make coupledL2-verilog-test-top-matrix' first" >&2
    exit 2
  fi
}

# Blackbox / behavioral models that live next to the generated RTL but are not
# referenced by filelist.f (array*_ext.v, L2MPWriter.v, TLLogWriter.v,
# ClockGate.sv, ...). VCS resolves nothing on its own, so every one of them must
# be on the command line — the Verilator flow gets them implicitly from its
# build/*.*v glob. mem_ext.v is excluded here: its flat 4GB array exceeds the
# VCS elaboration limit and vcs/mem_ext_sparse.v provides the same interface.
collect_ext_models() {
  local dir=$1
  local f
  (
    cd "$dir" || exit 1
    for f in *.sv *.v; do
      [[ -e "$f" ]] || continue
      [[ "$f" == "mem_ext.v" ]] && continue
      grep -qx "$f" filelist.f || printf '%s\n' "$f"
    done
  )
}

# compile_simv BUILD_DIR COVERAGE(on|off) COMPILE_RTL_DIR
compile_simv() {
  local build_dir=$1
  local coverage=$2
  local compile_rtl_dir=$3
  local simv_path

  mkdir -p "$build_dir"
  simv_path=$(cd "$build_dir" && pwd)/simv
  # VCS does not track C++ header dependencies in its -Mdir cache.
  rm -rf "$build_dir/csrc"

  mapfile -t ext_models < <(collect_ext_models "$compile_rtl_dir")

  # chisel_db.cpp composes its INSERT statements with %#lx (0x-prefixed hex),
  # which SQLite only accepts as an integer literal from 3.8.6 on. The simv
  # link resolves libsqlite3 to the ancient copy bundled inside VCS_HOME, which
  # rejects the 0x tokens. Patch a build-dir copy to decimal %lu so the stored
  # integers are identical on any SQLite version.
  sed 's/%#lx/%lu/g' "$compile_rtl_dir/chisel_db.cpp" > "$build_dir/chisel_db.cpp"

  local -a command=(
    -cpp "$vcs_cpp" -CFLAGS "-std=c++11 -I$compile_rtl_dir"
    -sverilog -timescale=1ns/1ps
    +vcs+initreg+random
    -debug_access+all
    -j "$vcs_jobs"
  )
  if [[ "$coverage" == on ]]; then
    command+=(-cm line+cond+fsm+tgl -cm_hier "$coverage_hier"
              -cm_dir "$build_dir/template.vdb")
  fi
  command+=(-f filelist.f "${ext_models[@]}"
            "$project_root/vcs/mem_ext_sparse.v"
            "$build_dir/chisel_db.cpp" "$compile_rtl_dir/constantin.cpp" \
            "$compile_rtl_dir/perfCCT.cpp"
            "$tb_file" +incdir+"$project_root/main/DPI"
            -top tltest_vcs_tb -Mdir="$build_dir/csrc" -o "$simv_path"
            -LDFLAGS "-lsqlite3 -ldl"
            -l "$build_dir/compile.log")

  echo "VCS compile in $compile_rtl_dir -> $simv_path"
  (cd "$compile_rtl_dir" && vcs "${command[@]}")
}

# run_simv SIMV COVERAGE_DIR(empty for plain runs)
run_simv() {
  local simv=$1
  local coverage_dir=$2
  local log_file="$run_root/simv.log"

  require_dpi_lib
  rm -rf "$run_root"
  mkdir -p "$run_root"
  # TileLinkSystemInitialize() reads tltest.ini from the working directory;
  # the trace path inside is absolute so a copied ini keeps working.
  cp "$project_root/run/tltest.ini" "$run_root/tltest.ini"
  printf '#!SV_LIBRARIES\n%s\n' "${dpi_lib%.so}" > "$run_root/bootstrap_lib_files"

  # Match the Verilator zero-initialization semantics: registers and memory
  # arrays start at 0 instead of X (chosen at runtime; the compile only
  # enables the mechanism — +vcs+initreg covers both).
  local -a run_args=(-sv_liblist bootstrap_lib_files +vcs+initreg+0)
  # Extra runtime plusargs (e.g. "+vcd_start=40500 +vcd_stop=42000"), split
  # on spaces so callers can hand whole plusarg groups through the env.
  if [[ -n "${HBL2_VCS_RUN_ARGS:-}" ]]; then
    read -r -a extra_args <<< "$HBL2_VCS_RUN_ARGS"
    run_args+=("${extra_args[@]}")
  fi
  if [[ -n "$coverage_dir" ]]; then
    run_args+=(-cm line+cond+fsm+tgl -cm_dir "$coverage_dir" -cm_name matrix_trace)
  fi

  echo "VCS run in $run_root (log: $log_file)"
  (cd "$run_root" && "$simv" "${run_args[@]}") > "$log_file" 2>&1 || {
    tail -n 80 "$log_file" >&2
    echo "error: VCS exited unsuccessfully; see $log_file" >&2
    exit 1
  }

  # This VCS version reports $fatal with a zero process exit status, so the
  # simulator log is the authoritative result.
  if grep -q 'Fatal:' "$log_file"; then
    tail -n 80 "$log_file" >&2
    echo "error: VCS test failed; see $log_file" >&2
    exit 1
  fi
  if ! grep -q 'FINISHED' "$log_file"; then
    tail -n 80 "$log_file" >&2
    echo "error: replay did not reach FINISHED; see $log_file" >&2
    exit 1
  fi
  grep -m1 'FINISHED' "$log_file" || true
}

case "$mode" in
  build)
    require_rtl
    compile_simv "$vcs_build_root/test" off "$rtl_dir"
    ;;
  run)
    require_rtl
    compile_simv "$vcs_build_root/test" off "$rtl_dir"
    run_simv "$(cd "$vcs_build_root/test" && pwd)/simv" ""
    ;;
  coverage)
    require_rtl
    build_dir="$vcs_build_root/coverage"
    rm -rf "$build_dir"
    coverage_rtl_dir="$build_dir/rtl"
    bash "$project_root/vcs/prepare_coverage_rtl.sh" "$rtl_dir" "$coverage_rtl_dir"
    compile_simv "$build_dir" on "$coverage_rtl_dir"
    coverage_vdb="$build_dir/vdb/matrix_trace.vdb"
    mkdir -p "$build_dir/vdb"
    cp -r "$build_dir/template.vdb" "$coverage_vdb"
    run_simv "$(cd "$build_dir" && pwd)/simv" "$coverage_vdb"
    urg -dir "$coverage_vdb" -hier "$coverage_hier" -report "$build_dir/report"
    echo "VCS coverage report: $build_dir/report/dashboard.html"
    ;;
  *)
    echo "usage: $0 {build|run|coverage}" >&2
    exit 2
    ;;
esac
