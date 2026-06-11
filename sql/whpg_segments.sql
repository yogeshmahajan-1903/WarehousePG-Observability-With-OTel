-- Get WHPG segment configuration details
-- Retrieves information about all segments in the WHPG cluster
-- excluding the coordinator/standby (content = -1)
SELECT
    content,
    role::text           AS role,
    preferred_role::text AS preferred_role,
    mode::text           AS mode,
    status::text         AS status,
    hostname,
    port::text           AS port,
    datadir,
    -- numeric columns used as OTel metric values (gauge 1/0)
    CASE WHEN status = 'u' THEN 1 ELSE 0 END AS is_up,
    CASE WHEN mode   = 's' THEN 1 ELSE 0 END AS is_in_sync,
    CASE WHEN role   = 'p' THEN 1 ELSE 0 END AS is_primary
FROM gp_segment_configuration
WHERE content >= 0
ORDER BY content ASC, role DESC
