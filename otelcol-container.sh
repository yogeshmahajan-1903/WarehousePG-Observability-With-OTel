#!/bin/bash
# Manage otelcol-contrib on a WHPG cluster node (no systemd)

BINARY=/usr/local/bin/otelcol-contrib
CONFIG=/etc/otelcol/otel-collector-whpg-node.yaml
LOGFILE=/home/gpadmin/otel.log
PIDFILE=/tmp/otelcol.pid
ENV_FILE=/etc/otelcol/otelcol.env

# ── Deploy settings — update OTELCOL_CONFIG_URL before first run ──────────────
OTELCOL_VERSION="0.153.0"
OTELCOL_ARCHIVE="otelcol-contrib_${OTELCOL_VERSION}_linux_amd64.tar.gz"
OTELCOL_DOWNLOAD_URL="https://github.com/open-telemetry/opentelemetry-collector-releases/releases/download/v${OTELCOL_VERSION}/${OTELCOL_ARCHIVE}"
# Set this to the raw GitHub URL of otel-collector-whpg-node.yaml in your fork
OTELCOL_CONFIG_URL="https://raw.githubusercontent.com/yogeshmahajan-1903/WarehousePG-Observability-With-OTel/refs/heads/main/otel-collector-whpg-node.yaml"

# ── Helpers ───────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
ok()   { echo -e "${GREEN}✓ $*${NC}"; }
err()  { echo -e "${RED}✗ $*${NC}"; }
info() { echo -e "${YELLOW}ℹ $*${NC}"; }

deploy() {
    echo -e "\n${GREEN}=== WHPG OTel Collector — Node Deployment ===${NC}\n"

    # ── Source Greenplum environment (provides psql and sets GPHOME/PATH) ─────
    GP_PATH="/usr/local/greenplum-db/greenplum_path.sh"
    if [ -f "$GP_PATH" ]; then
        # shellcheck disable=SC1090
        source "$GP_PATH"
        ok "Sourced ${GP_PATH}"
    else
        err "Greenplum environment not found at ${GP_PATH}"
        err "Install Greenplum or update GP_PATH in this script."
        exit 1
    fi

    # ── Validate WHPG connection first ────────────────────────────────────────
    info "Step 0 — Validate WHPG connection"

    read -p "  WHPG host [localhost]: " _host
    WHPG_HOST="${_host:-localhost}"

    read -p "  WHPG port [5432]: " _port
    WHPG_PORT="${_port:-5432}"

    read -p "  WHPG database [postgres]: " _db
    WHPG_DB="${_db:-postgres}"

    read -p "  WHPG username [gpadmin]: " _user
    WHPG_USERNAME="${_user:-gpadmin}"

    read -s -p "  WHPG password: " WHPG_PASSWORD
    echo ""

    # Assemble endpoint for the OTel postgresql receiver (host:port)
    WHPG_ENDPOINT="${WHPG_HOST}:${WHPG_PORT}"

    info "Connecting to WHPG at ${WHPG_HOST}:${WHPG_PORT} db=${WHPG_DB} as ${WHPG_USERNAME} ..."
    if ! PGPASSWORD="$WHPG_PASSWORD" psql -h "$WHPG_HOST" -p "$WHPG_PORT" -U "$WHPG_USERNAME" \
            -d "$WHPG_DB" -c "SELECT 1" > /dev/null 2>&1; then
        err "Cannot connect to WHPG at ${WHPG_HOST}:${WHPG_PORT}."
        err "Check credentials, network, and that pg_hba.conf allows this host."
        exit 1
    fi
    ok "WHPG connection OK"

    # Resolve PG_LOG_DIR via gp_segment_configuration for this machine's hostname
    THIS_HOSTNAME=$(hostname)
    info "Querying datadir for hostname '${THIS_HOSTNAME}' from gp_segment_configuration ..."
    DATADIR=$(PGPASSWORD="$WHPG_PASSWORD" psql -h "$WHPG_HOST" -p "$WHPG_PORT" -U "$WHPG_USERNAME" \
        -d "$WHPG_DB" -t -A \
        -c "SELECT datadir FROM gp_segment_configuration WHERE hostname = '${THIS_HOSTNAME}' LIMIT 1" 2>/dev/null)

    if [ -z "$DATADIR" ]; then
        err "No row found in gp_segment_configuration for hostname '${THIS_HOSTNAME}'."
        read -p "  Enter PG_LOG_DIR manually (full path, no trailing slash): " PG_LOG_DIR
        [ -z "$PG_LOG_DIR" ] && { err "PG_LOG_DIR is required. Aborting."; exit 1; }
    else
        PG_LOG_DIR="${DATADIR}/pg_log"
        ok "PG_LOG_DIR resolved to: ${PG_LOG_DIR}"
    fi

    # ── ClickHouse connection details ─────────────────────────────────────────
    info "Step 0b — Validate ClickHouse connection"
    read -p "  ClickHouse host [host.docker.internal]: " _ch_host
    CH_HOST="${_ch_host:-host.docker.internal}"

    read -p "  ClickHouse TCP port [9000]: " _ch_tcp
    CH_TCP_PORT="${_ch_tcp:-9000}"

    read -p "  ClickHouse HTTP port [8123]: " _ch_http
    CH_HTTP_PORT="${_ch_http:-8123}"

    read -p "  ClickHouse username [default]: " _ch_user
    CH_USERNAME="${_ch_user:-default}"

    read -s -p "  ClickHouse password [otelpassword]: " _ch_pw
    echo ""
    CLICKHOUSE_PASSWORD="${_ch_pw:-otelpassword}"

    # Assemble TCP endpoint for the OTel exporter
    CLICKHOUSE_ENDPOINT="tcp://${CH_HOST}:${CH_TCP_PORT}?dial_timeout=10s"

    info "Connecting to ClickHouse at ${CH_HOST}:${CH_HTTP_PORT} as ${CH_USERNAME} ..."
    CH_RESPONSE=$(curl -s -w "\n%{http_code}" \
        -u "${CH_USERNAME}:${CLICKHOUSE_PASSWORD}" \
        "http://${CH_HOST}:${CH_HTTP_PORT}/?query=SELECT+1")
    CH_STATUS=$(echo "$CH_RESPONSE" | tail -1)
    CH_BODY=$(echo "$CH_RESPONSE" | head -1)

    if [ "$CH_STATUS" != "200" ]; then
        err "Cannot connect to ClickHouse at ${CH_HOST}:${CH_HTTP_PORT} (HTTP ${CH_STATUS:-unreachable})."
        [ -n "$CH_BODY" ] && err "ClickHouse response: ${CH_BODY}"
        echo ""
        case "$CH_STATUS" in
            401) echo -e "  ${YELLOW}Hint: Wrong password. Check CLICKHOUSE_PASSWORD in the observability host .env file.${NC}"
                 echo -e "  ${YELLOW}      If ClickHouse was started with a different password, run: ./manage.sh clean && ./manage.sh start${NC}" ;;
            000) echo -e "  ${YELLOW}Hint: Host unreachable. Verify ClickHouse is running and ${CH_HOST}:${CH_HTTP_PORT} is reachable from this node.${NC}" ;;
            *)   echo -e "  ${YELLOW}Hint: Check ClickHouse logs on the observability host: ./manage.sh logs clickhouse${NC}" ;;
        esac
        exit 1
    fi
    ok "ClickHouse connection OK"

    # ── Step 1: Install otelcol-contrib ──────────────────────────────────────
    info "Step 1 — Installing otelcol-contrib v${OTELCOL_VERSION}"
    if command -v otelcol-contrib > /dev/null 2>&1; then
        info "otelcol-contrib already installed at $(command -v otelcol-contrib) — skipping download"
    else
        info "Downloading ${OTELCOL_ARCHIVE} ..."
        curl -L -O "$OTELCOL_DOWNLOAD_URL"
        tar -xf "$OTELCOL_ARCHIVE"
        sudo mv otelcol-contrib /usr/local/bin/
        rm -f "$OTELCOL_ARCHIVE"
        ok "otelcol-contrib installed to /usr/local/bin/"
    fi

    # ── Step 2: Create directories ────────────────────────────────────────────
    info "Step 2 — Creating directories"
    sudo mkdir -p /var/lib/otelcol/file_storage
    sudo mkdir -p /etc/otelcol/sql
    sudo chown -R gpadmin:gpadmin /var/lib/otelcol
    ok "Directories ready"

    # ── Step 3: Download collector config + SQL files from GitHub ─────────────
    info "Step 3 — Fetching OTel Collector config from GitHub"
    if [ "$OTELCOL_CONFIG_URL" = "https://raw.githubusercontent.com/OWNER/REPO/main/otel-collector-whpg-node.yaml" ]; then
        err "OTELCOL_CONFIG_URL is still the placeholder value in otelcol-container.sh."
        err "Edit the script and set OTELCOL_CONFIG_URL to the raw GitHub URL of your config."
        exit 1
    fi
    sudo curl -fsSL "$OTELCOL_CONFIG_URL" -o "$CONFIG"
    ok "Config written to ${CONFIG}"

    # Derive the repo raw base URL from OTELCOL_CONFIG_URL
    # e.g. https://raw.githubusercontent.com/OWNER/REPO/main/otel-collector-whpg-node.yaml
    #   → https://raw.githubusercontent.com/OWNER/REPO/main
    REPO_RAW_BASE="${OTELCOL_CONFIG_URL%/*}"

    info "Step 3b — Fetching SQL/YAML query files from GitHub (${REPO_RAW_BASE}/sql/)"
    # Add new query files here — both the .sql (query) and .yaml (metric definitions)
    SQL_FILES=(
        whpg_segments.sql
        whpg_db_metrics.yaml
        whpg_db_size.sql
        whpg_query_states.sql
        whpg_per_user_query_count.sql
    )
    for sql_file in "${SQL_FILES[@]}"; do
        sudo curl -fsSL "${REPO_RAW_BASE}/sql/${sql_file}" -o "/etc/otelcol/sql/${sql_file}"
        ok "  sql/${sql_file}"
    done

    # ── Step 4: Write otelcol.env ─────────────────────────────────────────────
    info "Step 4 — Writing ${ENV_FILE}"
    sudo tee "$ENV_FILE" > /dev/null << EOF
# ClickHouse backend
CLICKHOUSE_HOST=${CH_HOST}
CLICKHOUSE_TCP_PORT=${CH_TCP_PORT}
CLICKHOUSE_HTTP_PORT=${CH_HTTP_PORT}
CLICKHOUSE_USERNAME=${CH_USERNAME}
CLICKHOUSE_ENDPOINT=${CLICKHOUSE_ENDPOINT}
CLICKHOUSE_PASSWORD=${CLICKHOUSE_PASSWORD}

# WHPG connection (postgresql receiver)
WHPG_HOST=${WHPG_HOST}
WHPG_PORT=${WHPG_PORT}
WHPG_DB=${WHPG_DB}
WHPG_ENDPOINT=${WHPG_ENDPOINT}
WHPG_USERNAME=${WHPG_USERNAME}
WHPG_PASSWORD=${WHPG_PASSWORD}

# pg_log directory for this node (resolved from gp_segment_configuration)
PG_LOG_DIR=${PG_LOG_DIR}
EOF
    ok "${ENV_FILE} written"

    echo ""
    ok "Deployment complete. FOllow the next steps to start the collector and verify it's running:"
    echo ""
    echo -e "  ${YELLOW}Next steps:${NC}"
    echo -e "    Start collector :  $0 start"
    echo -e "    Collector log   :  ${LOGFILE}"
    echo -e "    Tail log        :  tail -f ${LOGFILE}"
    echo -e "    Health check    :  $0 status"
}

load_env() {
    if [ -f "$ENV_FILE" ]; then
        # Export only non-comment, non-empty lines; handle values with spaces safely
        set -a
        # shellcheck disable=SC1090
        source <(grep -v '^\s*#' "$ENV_FILE" | grep -v '^\s*$')
        set +a
    else
        err "Env file not found: $ENV_FILE"
        err "Run $0 deploy first, or create the file manually."
        exit 1
    fi
}

# ── Commands ──────────────────────────────────────────────────────────────────
start() {
    if [ -f "$PIDFILE" ] && kill -0 "$(cat "$PIDFILE")" 2>/dev/null; then
        info "otelcol already running (pid $(cat "$PIDFILE"))"
        exit 0
    fi
    load_env
    nohup "$BINARY" --config "$CONFIG" >> "$LOGFILE" 2>&1 &
    echo $! > "$PIDFILE"
    ok "otelcol started (pid $!), log: $LOGFILE"
}

stop() {
    if [ ! -f "$PIDFILE" ]; then
        info "otelcol not running"
        exit 0
    fi
    PID=$(cat "$PIDFILE")
    if kill "$PID" 2>/dev/null; then
        rm -f "$PIDFILE"
        ok "otelcol stopped (pid $PID)"
    else
        err "Failed to stop otelcol (pid $PID) — removing stale pidfile"
        rm -f "$PIDFILE"
        exit 1
    fi
}

status() {
    if [ -f "$PIDFILE" ] && kill -0 "$(cat "$PIDFILE")" 2>/dev/null; then
        ok "otelcol running (pid $(cat "$PIDFILE"))"
        HEALTH=$(curl -s -o /dev/null -w "%{http_code}" http://localhost:13133 2>/dev/null)
        if [ "$HEALTH" = "200" ]; then
            ok "Health check: OK (HTTP 200)"
        else
            err "Health check: HTTP ${HEALTH:-unreachable}"
        fi
    else
        err "otelcol not running"
    fi
}

# ── Dispatch ──────────────────────────────────────────────────────────────────
case "${1:-help}" in
    deploy)  deploy ;;
    start)   start  ;;
    stop)    stop   ;;
    restart) stop; sleep 1; start ;;
    status)  status ;;
    *)
        echo "Usage: $0 {deploy|start|stop|restart|status}"
        exit 1
        ;;
esac
