#!/usr/bin/env bash

set -euo pipefail

SCRIPT_NAME="$(basename "$0")"
STATE_DIR="${STATE_DIR:-/tmp/postgres-pool-exhaustion}"
RUN_ID_FILE="$STATE_DIR/run_id"
CLIENT_PIDS_FILE="$STATE_DIR/client_pids"
BACKEND_PIDS_FILE="$STATE_DIR/backend_pids"
META_FILE="$STATE_DIR/meta"
DEFAULT_CONNECTIONS="${DEFAULT_CONNECTIONS:-20}"
DEFAULT_HOLD_SECONDS="${DEFAULT_HOLD_SECONDS:-300}"
DEFAULT_START_DELAY="${DEFAULT_START_DELAY:-0.2}"

usage() {
  cat <<EOF
Usage:
  $SCRIPT_NAME start <connection-string> [connections] [hold-seconds]
  $SCRIPT_NAME status <connection-string>
  $SCRIPT_NAME monitor <connection-string>
  $SCRIPT_NAME cleanup <connection-string>

Examples:
  $SCRIPT_NAME start "host=10.60.2.4 port=5432 dbname=postgres user=labuser password=Lab@2024!" 40 180
  $SCRIPT_NAME status "host=10.60.2.4 port=5432 dbname=postgres user=labuser password=Lab@2024!"
  $SCRIPT_NAME cleanup "host=10.60.2.4 port=5432 dbname=postgres user=labuser password=Lab@2024!"

Notes:
  - Run this from the app server where psql can reach PostgreSQL 13.
  - The script opens many idle client sessions and keeps them alive with pg_sleep().
  - Cleanup kills only the client processes created by this script and can also terminate
    any leftover tagged backends on the server side.
EOF
}

require_psql() {
  if ! command -v psql >/dev/null 2>&1; then
    echo "psql is required but was not found in PATH." >&2
    exit 1
  fi
}

ensure_state_dir() {
  mkdir -p "$STATE_DIR"
}

load_run_id() {
  if [[ ! -f "$RUN_ID_FILE" ]]; then
    echo "No active run metadata found in $STATE_DIR" >&2
    exit 1
  fi
  RUN_ID="$(cat "$RUN_ID_FILE")"
  APP_NAME_PREFIX="fault_pool_${RUN_ID}"
}

write_meta() {
  local connection_count="$1"
  local hold_seconds="$2"
  cat >"$META_FILE" <<EOF
RUN_ID=$RUN_ID
APP_NAME_PREFIX=$APP_NAME_PREFIX
CONNECTION_COUNT=$connection_count
HOLD_SECONDS=$hold_seconds
STARTED_AT=$(date -u +%Y-%m-%dT%H:%M:%SZ)
EOF
}

print_preflight() {
  local conn_string="$1"
  echo "Preflight: checking server connection and available slots..."
  psql "$conn_string" -X -v ON_ERROR_STOP=1 -P pager=off <<'SQL'
SELECT current_database() AS database_name,
       current_user AS login_role,
       inet_server_addr() AS server_ip,
       inet_server_port() AS server_port,
       current_setting('max_connections') AS max_connections,
       current_setting('superuser_reserved_connections') AS reserved_connections;
SQL
}

start_fault() {
  local conn_string="$1"
  local connection_count="${2:-$DEFAULT_CONNECTIONS}"
  local hold_seconds="${3:-$DEFAULT_HOLD_SECONDS}"
  local start_delay="${START_DELAY_SECONDS:-$DEFAULT_START_DELAY}"

  if [[ -f "$RUN_ID_FILE" ]]; then
    echo "An active run already exists in $STATE_DIR. Run cleanup first." >&2
    exit 1
  fi

  ensure_state_dir
  RUN_ID="$(date +%Y%m%d%H%M%S)"
  APP_NAME_PREFIX="fault_pool_${RUN_ID}"
  : >"$CLIENT_PIDS_FILE"
  : >"$BACKEND_PIDS_FILE"
  write_meta "$connection_count" "$hold_seconds"

  print_preflight "$conn_string"

  echo "$RUN_ID" >"$RUN_ID_FILE"
  echo "Starting connection pool exhaustion test"
  echo "  run id: $RUN_ID"
  echo "  application_name prefix: $APP_NAME_PREFIX"
  echo "  connections to open: $connection_count"
  echo "  hold time per connection: ${hold_seconds}s"
  echo "  client state directory: $STATE_DIR"

  local client_pid
  local backend_pid
  local index
  for ((index = 1; index <= connection_count; index++)); do
    APP_NAME="${APP_NAME_PREFIX}_${index}"
    PSQLRC=/dev/null PGAPPNAME="$APP_NAME" \
      psql "$conn_string" -X -qAt -v ON_ERROR_STOP=1 \
      -c "SELECT pg_backend_pid(); SELECT pg_sleep(${hold_seconds});" \
      >"$STATE_DIR/${APP_NAME}.log" 2>&1 &
    client_pid=$!
    echo "$client_pid" >>"$CLIENT_PIDS_FILE"

    backend_pid=""
    for _ in 1 2 3 4 5; do
      backend_pid="$(psql "$conn_string" -X -qAt -v ON_ERROR_STOP=1 -c "SELECT pid FROM pg_stat_activity WHERE application_name = '$APP_NAME' LIMIT 1;" 2>/dev/null || true)"
      if [[ -n "$backend_pid" ]]; then
        echo "$backend_pid" >>"$BACKEND_PIDS_FILE"
        break
      fi
      sleep 1
    done

    echo "  opened $APP_NAME client_pid=$client_pid backend_pid=${backend_pid:-unknown}"
    sleep "$start_delay"
  done

  echo
  echo "Current tagged connections:"
  show_connections "$conn_string"
  echo
  echo "To stop quickly: $SCRIPT_NAME cleanup \"$conn_string\""
}

show_connections() {
  local conn_string="$1"

  if [[ -f "$RUN_ID_FILE" ]]; then
    load_run_id
  else
    echo "No active run metadata found. Showing matching connections requires an active run." >&2
    exit 1
  fi

  psql "$conn_string" -X -P pager=off -v ON_ERROR_STOP=1 <<SQL
SELECT pid,
       usename,
       application_name,
       client_addr,
       state,
       wait_event_type,
       wait_event,
       backend_start,
       now() - backend_start AS age,
       left(query, 80) AS query_sample
FROM pg_stat_activity
WHERE application_name LIKE '${APP_NAME_PREFIX}%'
ORDER BY backend_start;
SQL
}

monitor_fault() {
  local conn_string="$1"
  load_run_id

  echo "Connection summary for $APP_NAME_PREFIX"
  psql "$conn_string" -X -P pager=off -v ON_ERROR_STOP=1 <<SQL
SELECT application_name,
       state,
       count(*) AS connections
FROM pg_stat_activity
WHERE application_name LIKE '${APP_NAME_PREFIX}%'
GROUP BY application_name, state
ORDER BY application_name, state;

SELECT count(*) AS tagged_connections
FROM pg_stat_activity
WHERE application_name LIKE '${APP_NAME_PREFIX}%';

SELECT current_setting('max_connections') AS max_connections,
       current_setting('superuser_reserved_connections') AS reserved_connections,
       count(*) FILTER (WHERE backend_type = 'client backend') AS current_client_backends
FROM pg_stat_activity;
SQL
}

cleanup_fault() {
  local conn_string="$1"

  if [[ ! -f "$RUN_ID_FILE" ]]; then
    echo "No active run metadata found. Nothing to clean up."
    exit 0
  fi

  load_run_id
  echo "Stopping local client processes for $APP_NAME_PREFIX"

  if [[ -f "$CLIENT_PIDS_FILE" ]]; then
    while IFS= read -r pid; do
      if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
        kill "$pid" 2>/dev/null || true
      fi
    done <"$CLIENT_PIDS_FILE"
  fi

  echo "Terminating any leftover tagged backend sessions on PostgreSQL"
  psql "$conn_string" -X -P pager=off -v ON_ERROR_STOP=1 <<SQL
SELECT pid,
       application_name,
       pg_terminate_backend(pid) AS terminated
FROM pg_stat_activity
WHERE application_name LIKE '${APP_NAME_PREFIX}%'
  AND pid <> pg_backend_pid();
SQL

  rm -f "$RUN_ID_FILE" "$CLIENT_PIDS_FILE" "$BACKEND_PIDS_FILE" "$META_FILE"
  rm -f "$STATE_DIR"/*.log 2>/dev/null || true
  rmdir "$STATE_DIR" 2>/dev/null || true

  echo "Cleanup complete."
}

main() {
  require_psql

  if [[ $# -lt 2 ]]; then
    usage
    exit 1
  fi

  local command="$1"
  local conn_string="$2"

  case "$command" in
    start)
      start_fault "$conn_string" "${3:-}" "${4:-}"
      ;;
    status)
      show_connections "$conn_string"
      ;;
    monitor)
      monitor_fault "$conn_string"
      ;;
    cleanup)
      cleanup_fault "$conn_string"
      ;;
    *)
      usage
      exit 1
      ;;
  esac
}

main "$@"