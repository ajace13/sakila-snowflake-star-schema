-- 03 Let Claude's read-only role see the SAKILA database (the same grants the agent setup gives it on the practice database).
-- Run in Snowsight as ACCOUNTADMIN, after sql/02_oltp_load_reconcile.sql and AGAIN after sql/04_dw_ddl.sql: schema DW is created by 04, and
-- "ALL SCHEMAS" covers only the schemas that exist when it runs (the first run left CLAUDE_RO without USAGE on SAKILA.DW). SELECT only: the agent still cannot write.
USE ROLE ACCOUNTADMIN;
GRANT USAGE ON DATABASE SAKILA TO ROLE CLAUDE_RO;
GRANT USAGE ON ALL SCHEMAS IN DATABASE SAKILA TO ROLE CLAUDE_RO;
GRANT USAGE ON FUTURE SCHEMAS IN DATABASE SAKILA TO ROLE CLAUDE_RO;
GRANT SELECT ON ALL TABLES IN DATABASE SAKILA TO ROLE CLAUDE_RO;
GRANT SELECT ON FUTURE TABLES IN DATABASE SAKILA TO ROLE CLAUDE_RO;

-- Check: CLAUDE_RO has USAGE on SAKILA.OLTP, SAKILA.DW and SAKILA.PUBLIC, SELECT on every table in OLTP and DW, and nothing else
SHOW GRANTS TO ROLE CLAUDE_RO;

-- Then make the agent user read-only in fact, not only by default role: it was also granted ACCOUNTADMIN, and with secondary roles = ALL
-- every role it holds is active in the session next to CLAUDE_RO. Run these two as ACCOUNTADMIN once the grants above are in place:
-- REVOKE ROLE ACCOUNTADMIN FROM USER CLAUDE_AGENT;
-- ALTER USER CLAUDE_AGENT SET DEFAULT_SECONDARY_ROLES = ();
-- Check from the agent's own connection:  snow sql -c claude -q "SELECT CURRENT_AVAILABLE_ROLES(), CURRENT_SECONDARY_ROLES()"
--   -> no ACCOUNTADMIN, SYSADMIN, SECURITYADMIN or USERADMIN; and  SELECT COUNT(*) FROM SAKILA.DW.FACT_PAYMENT  must still return 16044
