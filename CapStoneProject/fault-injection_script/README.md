# PostgreSQL Connection Pool Exhaustion Lab

This folder contains a safe bash script to simulate connection pool exhaustion against PostgreSQL 13 from the app server.

## What It Does

The script opens many client connections from the app server, tags them with a unique `application_name`, and keeps them alive with `pg_sleep()` for a controlled amount of time.

It also captures evidence on demand so you can prove which sessions were injected, how many were active, and whether the server was close to `max_connections`.

This lets you test:
- app behavior when the database is close to `max_connections`
- connection pool timeouts or failures
- monitoring and alerting for session spikes

It does not modify schema or data.

## Files

- `postgres-connection-pool-exhaustion.sh`: start, inspect, collect evidence, monitor, and clean up the test

## Prerequisites

Run this from the app server.

Required on the app server:
- `psql` client installed
- network access to the PostgreSQL VM on port `5432`
- a test user allowed to connect to the target database

## Step-by-Step

### 1. Make the script executable

```bash
chmod +x postgres-connection-pool-exhaustion.sh
```

### 2. Prepare a connection string

Example:

```bash
CONN="host=10.60.2.4 port=5432 dbname=postgres user=labuser password=Lab@2024!"
```

You can also export `PGPASSWORD` and remove `password=...` from the string if you prefer.

### 3. Start the fault

Example with 40 held connections for 3 minutes:

```bash
./postgres-connection-pool-exhaustion.sh start "$CONN" 40 180
```

What happens:
- the script checks basic server settings first
- it opens 40 tagged sessions from the app server
- each session runs `pg_sleep(180)` to hold the connection open
- client PIDs are stored under `/tmp/postgres-pool-exhaustion` for quick cleanup
- the script prints the current matching sessions from `pg_stat_activity`

### 4. Collect evidence

List the tagged connections:

```bash
./postgres-connection-pool-exhaustion.sh status "$CONN"
```

Show a summary of current session counts versus server limits:

```bash
./postgres-connection-pool-exhaustion.sh monitor "$CONN"
```

Write a timestamped evidence log:

```bash
./postgres-connection-pool-exhaustion.sh evidence "$CONN"
```

Or write it to a specific file:

```bash
./postgres-connection-pool-exhaustion.sh evidence "$CONN" /tmp/postgres-pool-evidence.log
```

The evidence file includes:
- run metadata such as run ID, hold time, and requested connection count
- current PostgreSQL server connection limits
- the injected sessions from `pg_stat_activity`
- session counts by state
- local `psql` client PIDs that were started by the script

## How To Monitor Impact

### From PostgreSQL

Check total client backends and server limits:

```sql
SELECT current_setting('max_connections') AS max_connections,
       current_setting('superuser_reserved_connections') AS reserved_connections,
       count(*) FILTER (WHERE backend_type = 'client backend') AS current_client_backends
FROM pg_stat_activity;
```

Check only the injected sessions:

```sql
SELECT pid,
       usename,
       application_name,
       client_addr,
       state,
       now() - backend_start AS age
FROM pg_stat_activity
WHERE application_name LIKE 'fault_pool_%'
ORDER BY backend_start;
```

If you want a fast count by state:

```sql
SELECT state, count(*)
FROM pg_stat_activity
WHERE application_name LIKE 'fault_pool_%'
GROUP BY state;
```

### From The App Server

Watch whether new application connections begin to fail or time out.

You can also test a fresh direct login:

```bash
psql "$CONN" -c "select now();"
```

If `connection_count` is high enough relative to `max_connections`, that fresh login should slow down or fail.

For lab evidence from the app server, you can also capture the direct login result:

```bash
psql "$CONN" -c "select now();" > /tmp/postgres-direct-login-check.log 2>&1
```

## How To Stop Quickly

Immediate cleanup:

```bash
./postgres-connection-pool-exhaustion.sh cleanup "$CONN"
```

This is the primary rollback command. It is safe to run even if some held sessions have already ended.

What cleanup does:
- kills the local `psql` client processes started by the script
- terminates any leftover tagged backends using `pg_terminate_backend()`
- removes the local state files

## Safe Operating Notes

- Start below the server limit first, then increase gradually.
- Leave a safety margin for admin access. Do not aim for 100 percent of `max_connections` on the first run.
- Use short hold times such as `60` to `180` seconds in a lab.
- Run against a non-production environment only.
- If the application already uses a pooler such as PgBouncer, size the injected connection count so you stress the database without destabilizing the VM.

## Practical Lab Run

Example end-to-end run:

```bash
CONN="host=10.60.2.4 port=5432 dbname=postgres user=labuser"
export PGPASSWORD='your-password'

./postgres-connection-pool-exhaustion.sh start "$CONN" 20 120
./postgres-connection-pool-exhaustion.sh monitor "$CONN"
./postgres-connection-pool-exhaustion.sh evidence "$CONN"
./postgres-connection-pool-exhaustion.sh cleanup "$CONN"
```

## Practical Starting Point

Before the first run, check `max_connections`:

```bash
psql "$CONN" -c "show max_connections;"
```

Then start with something like:

```bash
./postgres-connection-pool-exhaustion.sh start "$CONN" 20 120
```

If the database is configured with a low limit, reduce the connection count. If the limit is high, increase gradually until your app shows the expected failure mode.