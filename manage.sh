#!/bin/bash

# Helper script for managing the WHPG Observability Stack

set -e

COMPOSE_FILE="docker-compose.yml"
PROJECT_NAME="whpg-observability"

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

function print_header() {
    echo -e "${BLUE}=== $1 ===${NC}"
}

function print_success() {
    echo -e "${GREEN}✓ $1${NC}"
}

function print_error() {
    echo -e "${RED}✗ $1${NC}"
}

function print_info() {
    echo -e "${YELLOW}ℹ $1${NC}"
}

function check_prerequisites() {
    print_header "Checking prerequisites"

    if ! command -v docker &> /dev/null; then
        print_error "Docker is not installed"
        exit 1
    fi
    print_success "Docker is installed"

    if ! command -v docker-compose &> /dev/null; then
        print_error "Docker Compose is not installed"
        exit 1
    fi
    print_success "Docker Compose is installed"

    if [ -f ".env" ]; then
        print_info "Using .env for ClickHouse password override"
    else
        print_info "No .env found — using default ClickHouse password (otelpassword)"
    fi
}

function start_stack() {
    print_header "Starting the stack"
    docker-compose up -d
    print_success "Stack started"

    print_info "Waiting for services to be healthy..."
    sleep 10

    # Check ClickHouse
    if docker-compose exec -T clickhouse curl -s http://localhost:8123/ping > /dev/null 2>&1; then
        print_success "ClickHouse is healthy"
    else
        print_error "ClickHouse health check failed"
    fi
}

function stop_stack() {
    print_header "Stopping the stack"
    docker-compose stop
    print_success "Stack stopped"
}

function restart_stack() {
    print_header "Restarting the stack"
    docker-compose restart
    print_success "Stack restarted"
}

function view_logs() {
    local service=$1
    if [ -z "$service" ]; then
        print_header "Viewing all logs"
        docker-compose logs -f
    else
        print_header "Viewing logs for $service"
        docker-compose logs -f "$service"
    fi
}

function status() {
    print_header "Stack status"
    docker-compose ps
}

function check_health() {
    print_header "Checking service health"

    print_info "ClickHouse:"
    curl -s http://localhost:8123/ping && echo "" && print_success "ClickHouse responding" || print_error "ClickHouse not responding"
}

function query_logs() {
    local limit=${1:-100}
    print_header "Querying recent logs (limit: $limit)"
    docker-compose exec -T clickhouse clickhouse-client \
        --query "SELECT timestamp, hostname, database, severity, message FROM otel.otel_logs ORDER BY timestamp DESC LIMIT $limit FORMAT PrettyCompact"
}

function query_metrics() {
    local limit=${1:-50}
    print_header "Querying recent metrics (limit: $limit)"
    docker-compose exec -T clickhouse clickhouse-client \
        --query "SELECT timestamp, hostname, metric_name, metric_value FROM otel.otel_metrics ORDER BY timestamp DESC LIMIT $limit FORMAT PrettyCompact"
}

function stats() {
    print_header "Database Statistics"
    
    docker-compose exec -T clickhouse clickhouse-client \
        --query "SELECT 'Logs' as table_name, COUNT(*) as row_count FROM otel.otel_logs UNION ALL SELECT 'Metrics' as table_name, COUNT(*) as row_count FROM otel.otel_metrics FORMAT PrettyCompact"
}

function clean_volumes() {
    print_header "Cleaning volumes"
    print_error "WARNING: This will delete all data!"
    read -p "Are you sure? (yes/no): " response

    if [ "$response" = "yes" ]; then
        docker-compose down -v
        print_success "Volumes cleaned"
    else
        print_info "Operation cancelled"
    fi
}

function clean_all() {
    print_header "Full Clean — containers, images, volumes, networks"
    print_error "WARNING: This will destroy ALL stack data and remove Docker images!"
    print_error "You will need to run './manage.sh start' to rebuild from scratch."
    read -p "Type 'yes' to confirm: " response

    if [ "$response" = "yes" ]; then
        print_info "Stopping and removing containers, volumes, and networks ..."
        docker-compose down -v --remove-orphans

        print_info "Removing images used by this stack ..."
        docker-compose images -q | xargs -r docker rmi -f

        print_success "Full clean complete — stack is completely removed"
    else
        print_info "Operation cancelled"
    fi
}

function logs_count_by_severity() {
    print_header "Log count by severity"
    docker-compose exec -T clickhouse clickhouse-client \
        --query "SELECT severity, COUNT(*) as count FROM otel.otel_logs WHERE timestamp > now() - INTERVAL 1 HOUR GROUP BY severity ORDER BY count DESC FORMAT PrettyCompact"
}

function cpu_metrics() {
    print_header "CPU metrics (last hour)"
    docker-compose exec -T clickhouse clickhouse-client \
        --query "SELECT timestamp, hostname, cpu_usage_percent, memory_usage_percent FROM otel.otel_system_metrics WHERE metric_type='cpu' AND timestamp > now() - INTERVAL 1 HOUR ORDER BY timestamp DESC LIMIT 20 FORMAT PrettyCompact"
}

function show_help() {
    cat << EOF
${BLUE}WHPG Observability Stack Manager${NC}

Usage: ./manage.sh [COMMAND] [OPTIONS]

Commands:
    start               Start all services
    stop                Stop all services
    restart             Restart all services
    status              Show service status
    logs [service]      View logs (all or specific service)
    health              Check service health
    query-logs [limit]  Query recent logs from ClickHouse
    query-metrics [limit] Query recent metrics from ClickHouse
    stats               Show database statistics
    severity-stats      Show log count by severity
    cpu-metrics         Show CPU and memory metrics
    clean-volumes       Delete all data volumes (DESTRUCTIVE)
    clean               Remove containers, volumes, networks, and images (DESTRUCTIVE)
    help                Show this help message

Examples:
    ./manage.sh start
    ./manage.sh logs clickhouse
    ./manage.sh query-logs 50
    ./manage.sh severity-stats
    ./manage.sh health

EOF
}

# Main script logic
case "${1:-help}" in
    start)
        check_prerequisites
        start_stack
        ;;
    stop)
        stop_stack
        ;;
    restart)
        restart_stack
        ;;
    status)
        status
        ;;
    logs)
        view_logs "$2"
        ;;
    health)
        check_health
        ;;
    query-logs)
        query_logs "$2"
        ;;
    query-metrics)
        query_metrics "$2"
        ;;
    stats)
        stats
        ;;
    severity-stats)
        logs_count_by_severity
        ;;
    cpu-metrics)
        cpu_metrics
        ;;
    clean-volumes)
        clean_volumes
        ;;
    clean)
        clean_all
        ;;
    help)
        show_help
        ;;
    *)
        print_error "Unknown command: $1"
        show_help
        exit 1
        ;;
esac
