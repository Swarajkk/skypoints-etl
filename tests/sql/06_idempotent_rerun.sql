USE ROLE ACCOUNTADMIN;
USE WAREHOUSE skypoints_wh;
USE DATABASE skypoints;

SET before_members = (SELECT COUNT(*) FROM skypoints.core.v_member_all);
SET before_routing = (SELECT COUNT(*) FROM skypoints.core.member_current);

CALL skypoints.core.sp_split_members('2024-01-16'::DATE);
CALL skypoints.core.sp_refresh_member_all();

SELECT 'member_count_changed' AS failure, $before_members AS before_cnt, COUNT(*) AS after_cnt
FROM skypoints.core.v_member_all
HAVING COUNT(*) <> $before_members

UNION ALL
SELECT 'routing_count_changed', $before_routing, COUNT(*)
FROM skypoints.core.member_current
HAVING COUNT(*) <> $before_routing;