#!/usr/bin/env bash
set -euo pipefail

# ─── GLOBAL LOGGING ─────────────────────────────────────────────────────────────
# Capture all output (stdout + stderr) into all_tests.log alongside console
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOGFILE="$SCRIPT_DIR/all_tests.log"
exec > >(tee -a "$LOGFILE") 2>&1

# ─── USER CONFIGURATION ────────────────────────────────────────────────────────

SANDBOX_NAME="rsandbox_ps8_0_29"
SANDBOX_DIR="$HOME/sandboxes"
LIBS_DIR="$HOME/opt/mysql/ps8.0.29/lib"
OUTPUT_ROOT="$SANDBOX_DIR/results"

# Exact list of allocators (in desired order) and their .so paths:
ALLOC_NAMES=(
  "glibc-2.34"
  "glibc-2.34-fewer-arenas"
  "jemalloc-5.2.1"
  "jemalloc-5.2.1-fewer-arenas"
  "jemalloc-5.3.0"
  "tcmalloc-2.9.1"
)
ALLOC_LIBS=(
  "$LIBS_DIR/glibc-2.34/libc.so.6"
  "$LIBS_DIR/glibc-2.34-fewer-arenas/libc.so.6"
  "$LIBS_DIR/jemalloc-5.2.1/libjemalloc.so.2"
  "$LIBS_DIR/jemalloc-5.2.1-fewer-arenas/libjemalloc.so.2"
  "$LIBS_DIR/jemalloc-5.3.0/libjemalloc.so"
  "$LIBS_DIR/tcmalloc-2.9.1/libtcmalloc.so"
)

# Sampling intervals
RSS_INTERVAL=5           # seconds
METRIC_INTERVAL=30       # seconds

# Mode & sysbench duration: enforce 150 minutes for "long"
MODE="${1:-quick}"       # quick=20s, long=9000s (150m)
if [[ "$MODE" == "long" ]]; then
  SB_TIME=9000
else
  SB_TIME=20
fi

# Sysbench parameters
SB_OPTS=(
  "--mysql-host=localhost"
  "--mysql-socket=/tmp/mysql_sandbox21930.sock"
  "--mysql-db=db3"
  "--mysql-user=root"
  "--mysql-password=msandbox"
  "--db-driver=mysql"
  "--rand-type=uniform"
  "--table-size=20000000"
  "--tables=14"
  "--threads=16"
  "--report-interval=5"
  "--time=$SB_TIME"
)

# ─── HELPERS ───────────────────────────────────────────────────────────────────

ensure_dirs() {
  mkdir -p "$OUTPUT_ROOT"
}

restart_sandbox() {
  cd "$SANDBOX_DIR"
  ./"$SANDBOX_NAME"/node1/restart
}

check_allocator() {
  local out="$1"
  local SBOX="$SANDBOX_DIR/$SANDBOX_NAME"
  local PID
  PID=$("$SBOX"/node1/metadata pid)
  {
    echo "mysqld PID = $PID"
    echo -n "LD_PRELOAD: "
    tr '\0' '\n' < "/proc/$PID/environ" | grep '^LD_PRELOAD=' || echo "<none>"
    echo "Mapped allocator libs:"
    grep -E 'glibc|malloc|jemalloc|tcmalloc' /proc/$PID/maps \
      | awk '{print $6}' | sort -u
  } > "$out/allocator_check.log"
}

start_rss_monitors() {
  cd "$SANDBOX_DIR"
  rm -f /tmp/exit-percona-monitor
  ./rss-mon.sh "$SANDBOX_NAME/node1" "$RSS_INTERVAL" &
  RSS1=$!
  ./rss-mon.sh "$SANDBOX_NAME/master" "$RSS_INTERVAL" &
  RSS2=$!
}

stop_all_monitors() {
  touch /tmp/exit-percona-monitor
  wait "$RSS1" "$RSS2" "$METRICS_PID" &>/dev/null || true
}

collect_rocksdb_metrics() {
  local out="$1"
  (
    cd "$SANDBOX_DIR"
    rm -f /tmp/exit-percona-monitor
    while true; do
      [[ -f /tmp/exit-percona-monitor ]] && break
      TS=$(date +"%FT%T")
      echo "$TS" >> "$out/rocksdb_status.log"
      ./"$SANDBOX_NAME"/node1/use -e "SHOW ENGINE ROCKSDB STATUS\\G" \
        >> "$out/rocksdb_status.log"
      echo "$TS" >> "$out/rocksdb_perf_context.log"
      ./"$SANDBOX_NAME"/node1/use -e "SELECT * FROM INFORMATION_SCHEMA.ROCKSDB_PERF_CONTEXT_GLOBAL" \
        >> "$out/rocksdb_perf_context.log"
      sleep "$METRIC_INTERVAL"
    done
  ) &
  METRICS_PID=$!
}

run_sysbench() {
  local out="$1"
  sysbench "${SB_OPTS[@]}" /usr/share/sysbench/oltp_write_only.lua run \
    | tee "$out/sysbench.log"
}

# ─── MAIN EXECUTION ────────────────────────────────────────────────────────────

ensure_dirs

for idx in "${!ALLOC_NAMES[@]}"; do
  name="${ALLOC_NAMES[$idx]}"
  lib="${ALLOC_LIBS[$idx]}"

  echo
  echo "===== Testing allocator: $name  (MODE=$MODE) ====="
  export CUSTOM_MALLOC="$lib"
  echo "→ CUSTOM_MALLOC=$CUSTOM_MALLOC"

  OUTDIR="$OUTPUT_ROOT/${name}_$(date +%Y%m%d_%H%M%S)"
  mkdir -p "$OUTDIR"

  # 1) restart mysqld under this allocator
  restart_sandbox

  # 2) verify preload & mapping
  check_allocator "$OUTDIR"

  # 3) launch RSS monitors
  start_rss_monitors

  # 4) launch RocksDB metrics thread
  collect_rocksdb_metrics "$OUTDIR"

  # 5) run sysbench workload
  run_sysbench "$OUTDIR"

  # 6) stop all monitors/metrics
  stop_all_monitors

  # 7) collect RSS logs
  mv "$SANDBOX_NAME/node1_rss.log"  "$OUTDIR/node1_rss.log"
  mv "$SANDBOX_NAME/master_rss.log" "$OUTDIR/master_rss.log"

  echo "→ Logs for $name in $OUTDIR"
done

echo
echo "All allocators tested ($MODE mode)."
echo "Results: $OUTPUT_ROOT"
echo "Overall log: $LOGFILE"
