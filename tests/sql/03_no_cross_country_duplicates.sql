USE ROLE ACCOUNTADMIN;
USE WAREHOUSE skypoints_wh;
USE DATABASE skypoints;

SELECT member_id,
       COUNT(*) AS copies,
       LISTAGG(country_code, ',') AS countries
FROM skypoints.core.v_member_all
GROUP BY member_id
HAVING COUNT(*) > 1;