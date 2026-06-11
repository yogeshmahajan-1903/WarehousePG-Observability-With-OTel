# WHPG Observability with OpenTelemetry and ClickHouse

Observability stack for WHPG clusters using the OpenTelemetry Collector and ClickHouse.

## Architecture

```
WHPG Cluster Node(s)
  └─ otelcol-contrib (native process, no Docker)
       ├─ filelog receiver     → /whpgdata/master/whpgsne-1/pg_log/*.csv
       ├─ hostmetrics receiver → CPU, memory, disk, network
       ├─ postgresql receiver  → localhost:5432 (WHPG_ENDPOINT)
       └─ TCP :9000 ───────────────────────────────────────┐
                                                           ▼
                                               Observability Host (Docker)
                                               ├─ ClickHouse  :8123 / :9000
                                               └─ ch-ui       :3488  (web UI)
```

---

## Quick Setup

Two machines are involved:

| Machine | Script | Purpose |
|---------|--------|---------|
| Observability host (your workstation / separate server) | `manage.sh` | Starts ClickHouse + ch-ui via Docker |
| Each WHPG cluster node | `otelcol-container.sh` | Installs and runs the OTel Collector |

---

### A — Start ClickHouse on the Observability Host

```bash
# Clone the repo (once)
git clone https://github.com/OWNER/REPO.git
cd warehouse-pg-observability-otelcollector

./manage.sh start        # pulls Docker images and starts ClickHouse + ch-ui
./manage.sh health       # verify ClickHouse is responding
```

**ch-ui** is available at **http://localhost:3488**

---

### B — Deploy the OTel Collector on each WHPG Cluster Node

Run the following **on each WHPG node** as `gpadmin`. No repo clone needed — curl the script directly:

```bash
curl -fsSL https://raw.githubusercontent.com/yogeshmahajan-1903/WarehousePG-Observability-With-OTel/refs/heads/main/otelcol-container.sh \
    -o ~/otelcol-container.sh
chmod +x ~/otelcol-container.sh
```

#### 1. Deploy (one-time per node)

```bash
~/otelcol-container.sh deploy
```

`deploy` will interactively:
1. Source `/usr/local/greenplum-db/greenplum_path.sh` to load the Greenplum environment
2. Prompt for WHPG connection details and **validate the connection** (exits on failure)
3. Auto-detect `PG_LOG_DIR` by querying `gp_segment_configuration` for this node's `datadir`
4. Prompt for ClickHouse connection details and **validate the connection** (exits on failure)
5. Download and install `otelcol-contrib` binary
6. Create `/var/lib/otelcol/file_storage` and `/etc/otelcol` directories
7. Download `otel-collector-whpg-node.yaml` from GitHub into `/etc/otelcol/`
8. Write all connection details to `/etc/otelcol/otelcol.env`

#### 2. Manage the collector

```bash
~/otelcol-container.sh start      # start the collector
~/otelcol-container.sh status     # show PID and health check
~/otelcol-container.sh restart    # restart after a config change
~/otelcol-container.sh stop       # stop the collector
```

Logs: `~/otel.log`

#### 3. Re-deploy after a config update

```bash
~/otelcol-container.sh deploy     # re-runs all steps; overwrites config and otelcol.env
~/otelcol-container.sh restart
```

---

### C — Verify data is flowing

```bash
# On the observability host
./manage.sh stats           # row counts in otel_logs and otel_metrics
./manage.sh query-logs 20   # last 20 log entries
./manage.sh health          # ClickHouse ping
```

---

## Part 1 — Observability Host (ClickHouse via Docker)

Run this on a separate machine or your workstation.

### Configure password (optional)

The default password is `otelpassword`. To use a different one:

```bash
echo "CLICKHOUSE_PASSWORD=your_password" > .env
```

### Start the stack

```bash
docker-compose up -d
```

### Verify

```bash
curl http://localhost:8123/ping
# Expected: Ok.

curl "http://localhost:8123/?user=default&password=otelpassword&query=SHOW+DATABASES"
```

**ch-ui** (ClickHouse web UI) is available at **http://localhost:3488**

### Stop / Reset

```bash
docker-compose down        # stop, keep data
docker-compose down -v     # stop and delete all data
```

---

## Part 2 — WHPG Cluster Node Setup

Repeat these steps on **each WHPG cluster node**. Runs as `gpadmin`, no Docker or systemd required.

### Step 1 — Install otelcol-contrib

```bash
curl -L -O https://github.com/open-telemetry/opentelemetry-collector-releases/releases/download/v0.153.0/otelcol-contrib_0.153.0_linux_amd64.tar.gz
tar -xf otelcol-contrib_0.153.0_linux_amd64.tar.gz
sudo mv otelcol-contrib /usr/local/bin/
otelcol-contrib --version
```

### Step 2 — Create directories

```bash
sudo mkdir -p /var/lib/otelcol/file_storage
sudo mkdir -p /etc/otelcol
sudo chown -R gpadmin:gpadmin /var/lib/otelcol
```

### Step 3 — Copy the OTel Collector config

```bash
sudo cp otel-collector-whpg-node.yaml /etc/otelcol/otel-collector-whpg-node.yaml
```

Key settings in [otel-collector-whpg-node.yaml](otel-collector-whpg-node.yaml):
- **Log path**: `${env:PG_LOG_DIR}/*.csv` and `*.log` — set `PG_LOG_DIR` in `otelcol.env`
- **Log format**: 30-field WHPG CSV, multiline, severity + timestamp parsed
- **Metrics**: host CPU, memory, disk, network every 60s
- **Prometheus scrape endpoint**: `:8888/metrics`

### Step 4 — Create the environment file

> **Shortcut:** `./otelcol-container.sh deploy` performs Steps 1–4 automatically. It validates the WHPG connection first, queries `gp_segment_configuration` for `PG_LOG_DIR`, then installs the binary, creates directories, downloads the config from GitHub, and writes `otelcol.env`.


```bash
sudo tee /etc/otelcol/otelcol.env > /dev/null << 'EOF'
# ClickHouse backend
CLICKHOUSE_HOST=<clickhouse-host-ip>
CLICKHOUSE_TCP_PORT=9000
CLICKHOUSE_HTTP_PORT=8123
CLICKHOUSE_USERNAME=default
CLICKHOUSE_ENDPOINT=tcp://<clickhouse-host-ip>:9000?dial_timeout=10s
CLICKHOUSE_PASSWORD=otelpassword

# WHPG connection (used by the postgresql receiver)
WHPG_HOST=localhost
WHPG_PORT=5432
WHPG_DB=postgres
WHPG_ENDPOINT=localhost:5432
WHPG_USERNAME=gpadmin
WHPG_PASSWORD=<whpg-password>

# Path to the pg_log directory for this node (no trailing slash)
PG_LOG_DIR=/whpgdata/master/whpgsne-1/pg_log
EOF
```

If the WHPG node is a container on the same Mac as ClickHouse (Docker Desktop):
```
CLICKHOUSE_ENDPOINT=tcp://host.docker.internal:9000?dial_timeout=10s
```

> **WHPG receiver note:** The OTel `postgresql` receiver connects with
> `WHPG_ENDPOINT` (`host:port`), `WHPG_USERNAME`, and `WHPG_PASSWORD`.
> The user must have the `pg_monitor` role (or superuser) to collect all metrics:
> ```sql
> GRANT pg_monitor TO <username>;
> ```
> Leave `databases: []` in the config to collect metrics for all databases,
> or list specific ones.

### Step 5 — Copy the process management script

```bash
cp otelcol-container.sh /home/gpadmin/otelcol-container.sh
chmod +x /home/gpadmin/otelcol-container.sh
```

### Step 6 — Start the collector

```bash
cd /home/gpadmin
./otelcol-container.sh start
tail -f /home/gpadmin/otel.log
```

---

## Managing the Collector

All commands run as `gpadmin` from `/home/gpadmin/`.

| Command | Description |
|---------|-------------|
| `./otelcol-container.sh start` | Start the collector |
| `./otelcol-container.sh stop` | Stop the collector |
| `./otelcol-container.sh restart` | Restart (e.g. after config change) |
| `./otelcol-container.sh status` | Show PID and health check |

Logs: `/home/gpadmin/otel.log`

### Apply a config change

```bash
sudo cp otel-collector-whpg-node.yaml /etc/otelcol/otel-collector-whpg-node.yaml
./otelcol-container.sh restart
```

### Force re-read of existing log files

The collector resumes from checkpointed offsets. To re-read all existing log files:

```bash
./otelcol-container.sh stop
sudo rm -rf /var/lib/otelcol/file_storage/*
./otelcol-container.sh start
```

---

## Verification

### Collector health
```bash
curl -s http://localhost:13133
```

### Prometheus metrics endpoint
```bash
curl -s http://localhost:8888/metrics | head -20
```

### Check data in ClickHouse
```bash
# Log count
curl -s "http://<clickhouse-host>:8123/?user=default&password=otelpassword&query=SELECT+count(*)+FROM+otel.otel_logs"

# Metrics count
curl -s "http://<clickhouse-host>:8123/?user=default&password=otelpassword&query=SELECT+count(*)+FROM+otel.otel_metrics"

# Recent logs
curl -s "http://<clickhouse-host>:8123/?user=default&password=otelpassword&query=SELECT+timestamp,severity,message+FROM+otel.otel_logs+ORDER+BY+timestamp+DESC+LIMIT+10+FORMAT+PrettyCompact"
```

---

## Troubleshooting

### Permission denied on file_storage
```bash
sudo chown -R gpadmin:gpadmin /var/lib/otelcol
./otelcol-container.sh restart
```

### No logs — table is empty
The collector may have checkpointed files at the end. Clear and restart:
```bash
./otelcol-container.sh stop
sudo rm -rf /var/lib/otelcol/file_storage/*
./otelcol-container.sh start
```

### Authentication failed connecting to ClickHouse
Ensure the password in `/etc/otelcol/otelcol.env` matches `CLICKHOUSE_PASSWORD` in docker-compose `.env`.

If ClickHouse was previously running with a different password, recreate the volume:
```bash
docker-compose down -v && docker-compose up -d
```

### Cannot reach ClickHouse
```bash
curl -s http://<clickhouse-host>:8123/ping
# Expected: Ok.
```

If using Docker Desktop on Mac from a container:
```bash
curl -s http://host.docker.internal:8123/ping
```

### Env vars not loaded
```bash
cat /etc/otelcol/otelcol.env
```
Must contain `CLICKHOUSE_ENDPOINT`, `CLICKHOUSE_PASSWORD`, `WHPG_ENDPOINT`, `WHPG_USERNAME`, `WHPG_PASSWORD`, and `PG_LOG_DIR`.

---

## Log Processing Details

**Log path:** `/whpgdata/master/whpgsne-1/pg_log/*.csv`

**WHPG CSV fields (30 columns):**
`log_time, log_user, log_database, log_pid, thread_id, connection_from, session_id, session_start, vxid, txid, command_tag, log_segment, slice_id, dtx_id, local_txid, subtxid, log_severity, sql_state, log_message, detail, hint, internal_query, internal_query_pos, context, log_query, query_pos, location, file_name, file_line, stack_trace`

**Severity mapping:**

| WHPG | OTel |
|------|------|
| DEBUG1–DEBUG5 | debug |
| INFO, LOG, NOTICE | info |
| WARNING | warn |
| ERROR, FATAL | error |
| PANIC | fatal |

---

## Ports Reference

| Port | Host | Purpose |
|------|------|---------|
| 8123 | ClickHouse host | HTTP interface |
| 9000 | ClickHouse host | Native TCP (used by OTel exporter) |
| 3488 | ClickHouse host | ch-ui web interface |
| 13133 | WHPG node | OTel Collector health check |
| 9187 | WHPG node | Prometheus metrics scrape endpoint |
| 1777 | WHPG node | pprof (debug) |

---

## References

- [otelcol-contrib releases](https://github.com/open-telemetry/opentelemetry-collector-releases/releases)
- [OpenTelemetry Collector Contrib](https://github.com/open-telemetry/opentelemetry-collector-contrib)
- [ClickHouse Documentation](https://clickhouse.com/docs/)
# WarehousePG-Observability-With-OTel
