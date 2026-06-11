-- Database size for all databases in the WHPG cluster
SELECT
    sodddatname,
    sodddatsize
FROM gp_toolkit.gp_size_of_database;
