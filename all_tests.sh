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
MASTER_DEFAULT_LIB="$LIBS_DIR/jemalloc-5.2.1/libjemalloc.so.2"

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

# Mode & sysbench duration: enforce 8hs for "long". Optionally allow
# a custom duration via "--custom-time <seconds>".
MODE="quick"              # quick=20s, long=28800s (8h)
SB_TIME=20

while [[ $# -gt 0 ]]; do
  case "$1" in
    quick)
      MODE="quick"
      SB_TIME=20
      shift
      ;;
    long)
      MODE="long"
      SB_TIME=28800
      shift
      ;;
    --custom-time)
      MODE="custom"
      if [[ -n "${2:-}" && "${2}" =~ ^[0-9]+$ ]]; then
        SB_TIME="${2}"
        shift 2
      else
        echo "Error: --custom-time requires a numeric argument" >&2
        exit 1
      fi
      ;;
    *)
      echo "Usage: $0 [quick|long|--custom-time <seconds>]" >&2
      exit 1
      ;;
  esac
done

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
  "--threads=10"
  "--report-interval=5"
  "--time=$SB_TIME"
)

# ─── HELPERS ───────────────────────────────────────────────────────────────────

ensure_dirs() {
  mkdir -p "$OUTPUT_ROOT"
}

restart_sandbox() {
  cd "$SANDBOX_DIR"
  CUSTOM_MALLOC="$CUSTOM_MALLOC_MASTER" ./"$SANDBOX_NAME"/master/restart
  CUSTOM_MALLOC="$CUSTOM_MALLOC" ./"$SANDBOX_NAME"/node1/restart
}

configure_master() {
  cd "$SANDBOX_DIR"
  ./"$SANDBOX_NAME"/master/use -e "SET GLOBAL binlog_group_commit_sync_delay=5000"
}

wait_for_replica() {
  cd "$SANDBOX_DIR"
  while true; do
    LAG=$(./"$SANDBOX_NAME"/node1/use -sN -e "SHOW REPLICA STATUS\\G" | \
      awk -F': ' '/Seconds_Behind/{print $2}' | tr -d '\r')
    LAG=${LAG:-0}
    [[ "$LAG" -eq 0 ]] && break
    sleep 5
    echo "waiting for replica to catch up (lag: $LAG seconds)..."
  done
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
  } > "$out/allocator_check_replica.log"
}

check_allocator_master() {
  local out="$1"
  local SBOX="$SANDBOX_DIR/$SANDBOX_NAME"
  local PID
  PID=$("$SBOX"/master/metadata pid)
  {
    echo "mysqld PID = $PID"
    echo -n "LD_PRELOAD: "
    tr '\0' '\n' < "/proc/$PID/environ" | grep '^LD_PRELOAD=' || echo "<none>"
    echo "Mapped allocator libs:"
    grep -E 'glibc|malloc|jemalloc|tcmalloc' /proc/$PID/maps \
      | awk '{print $6}' | sort -u
  } > "$out/allocator_check_master.log"
}

start_pidstat() {
  local out="$1"
  cd "$SANDBOX_DIR"
  local PID_NODE PID_MASTER
  PID_NODE=$("$SANDBOX_NAME"/node1/metadata pid)
  PID_MASTER=$("$SANDBOX_NAME"/master/metadata pid)
  pidstat -r -p "$PID_NODE" "$RSS_INTERVAL" > "$out/replica_pidstat.log" &
  PIDSTAT1=$!
  pidstat -r -p "$PID_MASTER" "$RSS_INTERVAL" > "$out/master_pidstat.log" &
  PIDSTAT2=$!
}

stop_all_monitors() {
  touch /tmp/exit-percona-monitor
  kill "$PIDSTAT1" "$PIDSTAT2" &>/dev/null || true
  wait "$METRICS_PID" "$PIDSTAT1" "$PIDSTAT2" &>/dev/null || true
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
      echo "$TS" >> "$out/global_status.log"
      ./"$SANDBOX_NAME"/node1/use -e "SHOW GLOBAL STATUS" \
        >> "$out/global_status.log"
      sleep "$METRIC_INTERVAL"
    done
  ) &
  METRICS_PID=$!
}

run_sysbench() {
  local out="$1"
  sysbench "${SB_OPTS[@]}" /usr/share/sysbench/oltp_insert.lua run \
    | tee "$out/sysbench.log"
}

# ─── MAIN EXECUTION ────────────────────────────────────────────────────────────

ensure_dirs
configure_master

for idx in "${!ALLOC_NAMES[@]}"; do
  name="${ALLOC_NAMES[$idx]}"
  lib="${ALLOC_LIBS[$idx]}"

  echo
  echo "===== Testing allocator: $name  (MODE=$MODE) ====="
  export CUSTOM_MALLOC="$lib"
  if [[ "$name" == "jemalloc-5.3.0" ]]; then
    CUSTOM_MALLOC_MASTER="$lib"
  else
    CUSTOM_MALLOC_MASTER="$MASTER_DEFAULT_LIB"
  fi
  echo "→ CUSTOM_MALLOC=$CUSTOM_MALLOC"

  OUTDIR="$OUTPUT_ROOT/${name}_$(date +%Y%m%d_%H%M%S)"
  mkdir -p "$OUTDIR"

  # 1) restart mysqld under this allocator
  restart_sandbox

  # 2) verify preload & mapping
  check_allocator "$OUTDIR"
  check_allocator_master "$OUTDIR"

  # 3) launch pidstat monitors
  start_pidstat "$OUTDIR"

  # 4) launch RocksDB metrics thread
  collect_rocksdb_metrics "$OUTDIR"

  # 5) run sysbench workload
  run_sysbench "$OUTDIR"

  # 6) stop all monitors/metrics
  stop_all_monitors
  wait_for_replica

  # 7) pidstat logs are already in $OUTDIR

  echo "→ Logs for $name in $OUTDIR"
done

echo
echo "All allocators tested ($MODE mode)."
echo "Results: $OUTPUT_ROOT"
echo "Overall log: $LOGFILE"
