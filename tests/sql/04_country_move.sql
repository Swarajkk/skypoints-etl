USE ROLE ACCOUNTADMIN;
USE WAREHOUSE skypoints_wh;
USE DATABASE skypoints;

SELECT 'ravi_still_in_india' AS failure
FROM skypoints.core.table_india
WHERE member_id = '223458'

UNION ALL
SELECT 'ravi_missing_in_australia'
FROM (SELECT 1 AS x)
WHERE NOT EXISTS (
  SELECT 1 FROM skypoints.core.table_australia WHERE member_id = '223458')

UNION ALL
SELECT 'ravi_flight_date_not_updated'
FROM (SELECT 1 AS x)
WHERE NOT EXISTS (
  SELECT 1 FROM skypoints.core.table_australia
  WHERE member_id = '223458' AND last_flight_date = '2024-01-10'::DATE)

UNION ALL
SELECT 'routing_not_updated'
FROM (SELECT 1 AS x)
WHERE NOT EXISTS (
  SELECT 1 FROM skypoints.core.member_current
  WHERE member_id = '223458' AND country_code = 'AUS' AND target_table = 'TABLE_AUSTRALIA');