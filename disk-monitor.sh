#!/usr/bin/env bash
set -euo pipefail

SCRIPT_NAME="$(basename "$0")"
APP_LOG_DIR="/var/log/app"
ARCHIVE_DIR="/var/log/app/archive"
ORIGINAL_DIR="${ARCHIVE_DIR}/originals"
MONITOR_LOG="/var/log/disk-monitor.log"
PID_FILE="/var/run/disk-monitor.pid"
LOCK_FILE="/var/run/disk-monitor.lock"
STATE_FILE="${ARCHIVE_DIR}/.disk-monitor.state"

CHECK_INTERVAL_SECONDS=300
USAGE_THRESHOLD=80
ALERT_THRESHOLD=90
LOG_AGE_DAYS=7
SPACE_MARGIN_BYTES=$((50 * 1024 * 1024))

DRY_RUN="false"
ACTION="run-once"

usage() {
  cat <<'EOF'
Usage: payment-monitor.sh [start|stop|status|run-once|rollback] [--dry-run]

Commands:
  start       Start daemon mode (checks every 5 minutes)
  stop        Stop daemon mode
  status      Show daemon status
  run-once    Run one monitor cycle one time
  rollback    Decompress and restore previously moved files

Options:
  --dry-run   Print actions only; do not compress, move, or write state
EOF
}

timestamp() {
  date '+%Y-%m-%d %H:%M:%S%z'
}

log_message() {
  local msg="$1"
  local line
  line="$(timestamp) ${msg}"

  if [[ "$DRY_RUN" == "true" ]]; then
    printf "%s\n" "$line"
    return 0
  fi

  printf "%s\n" "$line" | sudo tee -a "$MONITOR_LOG" >/dev/null
}

run_with_sudo() {
  if [[ "$DRY_RUN" == "true" ]]; then
    local cmd_text
    cmd_text="$(printf "%q " "$@")"
    cmd_text="${cmd_text% }"
    printf "[DRY-RUN] Would run: sudo %s\n" "$cmd_text"
    return 0
  fi

  sudo "$@"
}

parse_args() {
  local arg
  for arg in "$@"; do
    case "$arg" in
      start|stop|status|run-once|rollback)
        ACTION="$arg"
        ;;
      --dry-run)
        DRY_RUN="true"
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        printf "Unknown argument: %s\n" "$arg" >&2
        usage >&2
        exit 1
        ;;
    esac
  done
}

get_root_usage_percent() {
  df -P / | awk 'NR==2 {gsub("%","",$5); print $5}'
}

ensure_paths() {
  run_with_sudo mkdir -p "$APP_LOG_DIR" "$ARCHIVE_DIR" "$ORIGINAL_DIR"

  if [[ "$DRY_RUN" == "false" ]]; then
    run_with_sudo touch "$MONITOR_LOG"
  fi
}

monitor_is_running() {
  if [[ ! -f "$PID_FILE" ]]; then
    return 1
  fi

  local pid
  pid="$(sudo cat "$PID_FILE" 2>/dev/null || true)"
  [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null
}

ensure_not_running() {
  if monitor_is_running; then
    local pid
    pid="$(sudo cat "$PID_FILE")"
    printf "Monitor already running with PID %s\n" "$pid"
    log_message "Idempotency check: monitor already running with PID ${pid}; skipping action=${ACTION}"
    exit 0
  fi
}

candidate_files_stream() {
  sudo find "$APP_LOG_DIR" \
    -type f \
    -mtime +"$LOG_AGE_DAYS" \
    ! -path "${ARCHIVE_DIR}/*" \
    ! -name '*.gz' \
    -print0
}

sum_candidate_size_bytes() {
  local total=0
  local f size
  while IFS= read -r -d '' f; do
    size="$(sudo stat -c '%s' "$f")"
    total=$((total + size))
  done < <(candidate_files_stream)

  printf "%s\n" "$total"
}

verify_archive_space() {
  ensure_paths

  local needed_bytes
  local available_bytes
  local required_bytes

  needed_bytes="$(sum_candidate_size_bytes)"
  available_bytes="$(df -PB1 "$ARCHIVE_DIR" | awk 'NR==2 {print $4}')"
  required_bytes=$((needed_bytes + SPACE_MARGIN_BYTES))

  if (( available_bytes < required_bytes )); then
    log_message "Archive space check failed: available=${available_bytes} required=${required_bytes} needed=${needed_bytes}"
    return 1
  fi

  log_message "Archive space check passed: available=${available_bytes} required=${required_bytes}"
  return 0
}

record_state_line() {
  local archive_file="$1"
  local original_file="$2"
  local moved_original="$3"

  if [[ "$DRY_RUN" == "true" ]]; then
    return 0
  fi

  printf '%s|%s|%s|%s\n' "$archive_file" "$original_file" "$moved_original" "$(timestamp)" | sudo tee -a "$STATE_FILE" >/dev/null
}

compress_and_move() {
  local scanned=0
  local processed=0
  local now
  now="$(date '+%Y%m%d%H%M%S')"

  if ! verify_archive_space; then
    log_message "Skipping compression due to insufficient archive space"
    return 1
  fi

  local src_file base_name archive_file moved_original
  while IFS= read -r -d '' src_file; do
    scanned=$((scanned + 1))
    base_name="$(basename "$src_file")"
    archive_file="${ARCHIVE_DIR}/${base_name}.${now}.gz"
    moved_original="${ORIGINAL_DIR}/${base_name}.${now}.orig"

    if [[ "$DRY_RUN" == "true" ]]; then
      printf "[DRY-RUN] Would compress: %s -> %s\n" "$src_file" "$archive_file"
      printf "[DRY-RUN] Would move original: %s -> %s\n" "$src_file" "$moved_original"
      continue
    fi

    sudo gzip -c -- "$src_file" | sudo tee "$archive_file" >/dev/null
    run_with_sudo mv -- "$src_file" "$moved_original"
    record_state_line "$archive_file" "$src_file" "$moved_original"
    processed=$((processed + 1))
  done < <(candidate_files_stream)

  if [[ "$DRY_RUN" == "true" ]]; then
    log_message "Dry-run summary: scanned=${scanned}, would_process=${scanned}"
  else
    log_message "Run summary: scanned=${scanned}, processed=${processed}"
  fi
}

rollback() {
  log_message "Rollback started (dry-run=${DRY_RUN})"

  if [[ ! -f "$STATE_FILE" ]]; then
    log_message "Rollback skipped: state file not found at ${STATE_FILE}"
    printf "Rollback: no state file found\n"
    return 0
  fi

  local line archive_file original_file moved_original restored_count=0
  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    IFS='|' read -r archive_file original_file moved_original _ <<< "$line"

    if [[ "$DRY_RUN" == "true" ]]; then
      printf "[DRY-RUN] Would restore compressed file: %s -> %s\n" "$archive_file" "$original_file"
      continue
    fi

    run_with_sudo mkdir -p "$(dirname "$original_file")"
    sudo gzip -dc -- "$archive_file" | sudo tee "$original_file" >/dev/null
    restored_count=$((restored_count + 1))
  done < <(sudo tac "$STATE_FILE")

  if [[ "$DRY_RUN" == "true" ]]; then
    log_message "Rollback dry-run completed"
  else
    log_message "Rollback completed: restored=${restored_count}"
  fi
}

run_cycle() {
  local usage
  usage="$(get_root_usage_percent)"
  log_message "Disk usage check: / at ${usage}%"

  if (( usage > ALERT_THRESHOLD )); then
    printf "ALERT: root filesystem usage is critically high at %s%%\n" "$usage"
    log_message "Critical stdout alert emitted at usage=${usage}%"
  fi

  if (( usage > USAGE_THRESHOLD )); then
    log_message "Usage exceeded ${USAGE_THRESHOLD}%; searching and compressing old logs"
    compress_and_move || true
  else
    log_message "Usage below threshold; no log compression required"
  fi
}

daemon_loop() {
  trap 'cleanup_daemon; exit 0' INT TERM

  if [[ "$DRY_RUN" == "false" ]]; then
    printf '%s\n' "$$" | sudo tee "$PID_FILE" >/dev/null
  fi

  log_message "Daemon started (interval=${CHECK_INTERVAL_SECONDS}s, dry-run=${DRY_RUN})"

  while true; do
    run_cycle
    sleep "$CHECK_INTERVAL_SECONDS"
  done
}

cleanup_daemon() {
  if [[ "$DRY_RUN" == "false" ]]; then
    run_with_sudo rm -f "$PID_FILE"
  fi
}

start_daemon() {
  ensure_not_running

  if [[ "$DRY_RUN" == "true" ]]; then
    printf "[DRY-RUN] Would start daemon mode\n"
    log_message "Dry-run daemon start requested"
    return 0
  fi

  nohup "$0" internal-daemon-run >/dev/null 2>&1 &
  local bg_pid=$!
  printf '%s\n' "$bg_pid" | sudo tee "$PID_FILE" >/dev/null
  log_message "Daemon started with PID ${bg_pid}"
  printf "Daemon started with PID %s\n" "$bg_pid"
}

stop_daemon() {
  if ! monitor_is_running; then
    printf "Monitor is not running\n"
    log_message "Stop requested but monitor is not running"
    return 0
  fi

  local pid
  pid="$(sudo cat "$PID_FILE")"

  if [[ "$DRY_RUN" == "true" ]]; then
    printf "[DRY-RUN] Would stop PID %s\n" "$pid"
    log_message "Dry-run stop requested for PID ${pid}"
    return 0
  fi

  kill "$pid"
  run_with_sudo rm -f "$PID_FILE"
  log_message "Stop signal sent to PID ${pid}"
  printf "Stop signal sent to PID %s\n" "$pid"
}

status_daemon() {
  if monitor_is_running; then
    printf "Monitor is running with PID %s\n" "$(sudo cat "$PID_FILE")"
  else
    printf "Monitor is not running\n"
  fi
}

run_once() {
  ensure_not_running

  exec 9>"$LOCK_FILE"
  if ! flock -n 9; then
    printf "Another monitor invocation is in progress; exiting\n"
    log_message "Run-once skipped: another invocation holds lock"
    exit 0
  fi

  run_cycle
}

main() {
  parse_args "$@"
  ensure_paths

  case "$ACTION" in
    start)
      start_daemon
      ;;
    stop)
      stop_daemon
      ;;
    status)
      status_daemon
      ;;
    run-once)
      run_once
      ;;
    rollback)
      rollback
      ;;
    internal-daemon-run)
      daemon_loop
      ;;
    *)
      usage
      exit 1
      ;;
  esac
}

main "$@"
