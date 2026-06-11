-- Per-user connection/query count from pg_stat_activity (excludes the collector's own connection)
SELECT
    COALESCE(usename, 'system') AS usename,
    count(*) AS count
FROM pg_catalog.pg_stat_activity
WHERE pid != pg_catalog.pg_backend_pid()
GROUP BY usename;
