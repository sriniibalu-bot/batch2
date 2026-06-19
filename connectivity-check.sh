#!/usr/bin/env bash
set -uo pipefail

LOG_FILE="/var/log/connectivity-check.log"
DRY_RUN="false"
CRITICAL_ONLY="false"

PASSED="0"
FAILED="0"
SKIPPED="0"
CRITICAL_FAILED="0"

timestamp() {
  date "+%Y-%m-%d %H:%M:%S%z"
}

log_message() {
  local message="$1"
  local line
  line="$(timestamp) ${message}"
  printf "%s\n" "$line" | tee -a "$LOG_FILE" >/dev/null
}

create_log_file() {
  local log_dir
  log_dir="$(dirname "$LOG_FILE")"

  if ! sudo mkdir -p "$log_dir"; then
    printf "[FAIL] Unable to create log directory: %s\n" "$log_dir" >&2
    exit 1
  fi

  if ! sudo touch "$LOG_FILE"; then
    printf "[FAIL] Unable to create log file: %s\n" "$LOG_FILE" >&2
    exit 1
  fi

  if ! sudo chown "$USER:$USER" "$LOG_FILE"; then
    printf "[FAIL] Unable to set log file ownership: %s\n" "$LOG_FILE" >&2
    exit 1
  fi
}

record_pass() {
  local check_name="$1"
  PASSED="$((PASSED + 1))"
  log_message "[PASS] ${check_name}"
  printf "[PASS] %s\n" "$check_name"
}

record_fail() {
  local check_name="$1"
  local is_critical="$2"
  FAILED="$((FAILED + 1))"
  if [[ "$is_critical" == "true" ]]; then
    CRITICAL_FAILED="$((CRITICAL_FAILED + 1))"
  fi
  log_message "[FAIL] ${check_name}"
  printf "[FAIL] %s\n" "$check_name"
}

record_skip() {
  local check_name="$1"
  local reason="$2"
  SKIPPED="$((SKIPPED + 1))"
  log_message "[SKIP] ${check_name} (${reason})"
  printf "[SKIP] %s (%s)\n" "$check_name" "$reason"
}

run_check() {
  local check_name="$1"
  local is_critical="$2"
  shift 2

  if [[ "$CRITICAL_ONLY" == "true" && "$is_critical" != "true" ]]; then
    record_skip "$check_name" "non-critical skipped by --critical-only"
    return
  fi

  if [[ "$DRY_RUN" == "true" ]]; then
    local cmd_text
    cmd_text="$(printf "%q " "$@")"
    cmd_text="${cmd_text% }"
    record_skip "$check_name" "dry-run: $cmd_text"
    return
  fi

  if "$@" >/dev/null 2>&1; then
    record_pass "$check_name"
  else
    record_fail "$check_name" "$is_critical"
  fi
}

parse_args() {
  local arg

  for arg in "$@"; do
    case "$arg" in
      --dry-run)
        DRY_RUN="true"
        ;;
      --critical-only)
        CRITICAL_ONLY="true"
        ;;
      *)
        printf "Unknown argument: %s\n" "$arg" >&2
        printf "Usage: %s [--dry-run] [--critical-only]\n" "$0" >&2
        exit 1
        ;;
    esac
  done
}

main() {
  parse_args "$@"
  create_log_file

  log_message "Starting connectivity checks (dry-run=${DRY_RUN}, critical-only=${CRITICAL_ONLY})"

  # 1) Critical ping checks
  run_check "Ping gateway 10.0.0.1" "true" timeout 5 ping -c 3 -W 5 "10.0.0.1"
  run_check "Ping self 10.0.0.4" "true" timeout 5 ping -c 3 -W 5 "10.0.0.4"
  run_check "Ping internet 8.8.8.8" "true" timeout 5 ping -c 3 -W 5 "8.8.8.8"

  # 2) Non-critical ping checks
  run_check "Ping app server 10.0.1.10" "false" timeout 5 ping -c 3 -W 5 "10.0.1.10"
  run_check "Ping DB server 10.0.2.10" "false" timeout 5 ping -c 3 -W 5 "10.0.2.10"

  # 3) Non-critical port checks
  run_check "Port check 10.0.2.10:5432 (PostgreSQL)" "false" timeout 5 nc -zv -w 5 "10.0.2.10" "5432"
  run_check "Port check 10.0.1.10:8080 (app health)" "false" timeout 5 nc -zv -w 5 "10.0.1.10" "8080"

  # 4) Critical DNS check
  run_check "DNS resolution google.com" "true" timeout 5 nslookup "google.com"

  # 5) Critical default route check
  run_check "Default route exists" "true" timeout 5 bash -c "ip route show | grep -q '^default'"

  # 6) tc qdisc check (required check, non-critical)
  run_check "No artificial latency on eth0 (no netem qdisc)" "false" timeout 5 bash -c "tc qdisc show dev eth0 | grep -q 'netem'; if [[ \$? -eq 0 ]]; then exit 1; else exit 0; fi"

  log_message "Summary: passed=${PASSED}, failed=${FAILED}, skipped=${SKIPPED}"
  printf "Summary: passed=%s, failed=%s, skipped=%s\n" "$PASSED" "$FAILED" "$SKIPPED"

  if [[ "$CRITICAL_FAILED" -gt 0 ]]; then
    log_message "Exit code: 1 (critical check failure)"
    exit 1
  fi

  log_message "Exit code: 0 (no critical check failures)"
  exit 0
}

main "$@"
