USE ROLE ACCOUNTADMIN;
USE WAREHOUSE skypoints_wh;
USE DATABASE skypoints;

LIST @skypoints.raw.member_stage;

COPY INTO skypoints.raw.member_feed_raw (
  record_type, member_name, member_id, enrollment_date, last_flight_date,
  tier_code, agent_name, state, country, dob, is_active,
  _source_file, _file_row_number, _feed_date
)
FROM (
  SELECT $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12,
         METADATA$FILENAME,
         METADATA$FILE_ROW_NUMBER,
         TO_DATE(REGEXP_SUBSTR(METADATA$FILENAME, '[0-9]{8}'), 'YYYYMMDD')
  FROM @skypoints.raw.member_stage
)
FILE_FORMAT = (FORMAT_NAME = skypoints.raw.ff_member_pipe)
ON_ERROR = CONTINUE;

SELECT record_type, COUNT(*) AS n
FROM skypoints.raw.member_feed_raw
GROUP BY record_type;