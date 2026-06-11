-- Create the otel database for OpenTelemetry data.
-- Tables (otel_logs, otel_metrics_*) are created automatically
-- by the OTel Collector clickhouse exporter (create_schema: true).
CREATE DATABASE IF NOT EXISTS otel;
