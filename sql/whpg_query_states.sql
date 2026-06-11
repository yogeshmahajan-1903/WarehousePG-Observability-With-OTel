-- Query state counts from pg_stat_activity (excludes the collector's own connection)
SELECT
    count(*)                                                                                    AS total,
    count(*) FILTER (WHERE state = 'active')                                                   AS active_count,
    count(*) FILTER (WHERE state = 'idle')                                                     AS idle_count,
    count(*) FILTER (WHERE state = 'idle in transaction')                                      AS idle_in_transaction_count,
    count(*) FILTER (WHERE state = 'idle in transaction (aborted)')                            AS idle_in_transaction_aborted_count,
    count(*) FILTER (WHERE state = 'fastpath function call')                                   AS fastpath_function_call_count,
    count(*) FILTER (WHERE state = 'disabled')                                                 AS disabled_count,
    count(*) FILTER (WHERE waiting = 't')                                                      AS count_blocked_query,
    count(*) FILTER (WHERE state = 'active' AND NOW() - query_start > INTERVAL '120 seconds') AS count_long_run_query_120sec,
    count(*) FILTER (WHERE state = 'active' AND waiting_reason IS NOT NULL)                   AS count_query_in_wait
FROM pg_catalog.pg_stat_activity
WHERE pid != pg_catalog.pg_backend_pid();
