ALTER SESSION SET USE_CACHED_RESULT = FALSE;
USE WAREHOUSE CLASS_WH;
ALTER SESSION SET QUERY_TAG = 'P4_WARMUP';
SELECT SUM(payment_date_key), SUM(customer_key), SUM(amount) FROM SAKILA.DW.FACT_PAYMENT;
SELECT SUM(customer_key), SUM(customer_id) FROM SAKILA.DW.DIM_CUSTOMER;
ALTER SESSION SET QUERY_TAG = 'P4_BEFORE';
SELECT SUM(p.amount) AS revenue, COUNT(*) AS payments, COUNT(DISTINCT c.customer_id) AS paying_customers, ROUND(AVG(p.amount), 2) AS average_payment FROM SAKILA.DW.FACT_PAYMENT p JOIN SAKILA.DW.DIM_CUSTOMER c ON c.customer_key = p.customer_key WHERE p.payment_date_key BETWEEN 20050524 AND 20060214;
ALTER SESSION SET QUERY_TAG = 'P4_AFTER';
SELECT SUM(p.amount) AS revenue, COUNT(*) AS payments, COUNT(DISTINCT c.customer_id) AS paying_customers, ROUND(AVG(p.amount), 2) AS average_payment FROM SAKILA.DW.FACT_PAYMENT p JOIN SAKILA.DW.DIM_CUSTOMER c ON c.customer_key = p.customer_key;
ALTER SESSION SET QUERY_TAG = 'P4_BEFORE';
SELECT SUM(p.amount) AS revenue, COUNT(*) AS payments, COUNT(DISTINCT c.customer_id) AS paying_customers, ROUND(AVG(p.amount), 2) AS average_payment FROM SAKILA.DW.FACT_PAYMENT p JOIN SAKILA.DW.DIM_CUSTOMER c ON c.customer_key = p.customer_key WHERE p.payment_date_key BETWEEN 20050524 AND 20060214;
ALTER SESSION SET QUERY_TAG = 'P4_AFTER';
SELECT SUM(p.amount) AS revenue, COUNT(*) AS payments, COUNT(DISTINCT c.customer_id) AS paying_customers, ROUND(AVG(p.amount), 2) AS average_payment FROM SAKILA.DW.FACT_PAYMENT p JOIN SAKILA.DW.DIM_CUSTOMER c ON c.customer_key = p.customer_key;
ALTER SESSION SET QUERY_TAG = 'P4_BEFORE';
SELECT SUM(p.amount) AS revenue, COUNT(*) AS payments, COUNT(DISTINCT c.customer_id) AS paying_customers, ROUND(AVG(p.amount), 2) AS average_payment FROM SAKILA.DW.FACT_PAYMENT p JOIN SAKILA.DW.DIM_CUSTOMER c ON c.customer_key = p.customer_key WHERE p.payment_date_key BETWEEN 20050524 AND 20060214;
ALTER SESSION SET QUERY_TAG = 'P4_AFTER';
SELECT SUM(p.amount) AS revenue, COUNT(*) AS payments, COUNT(DISTINCT c.customer_id) AS paying_customers, ROUND(AVG(p.amount), 2) AS average_payment FROM SAKILA.DW.FACT_PAYMENT p JOIN SAKILA.DW.DIM_CUSTOMER c ON c.customer_key = p.customer_key;
ALTER SESSION SET QUERY_TAG = '';
SELECT TO_CHAR(start_time, 'HH24:MI:SS.FF3') AS started, query_tag, query_id, total_elapsed_time AS elapsed_ms, compilation_time AS compile_ms, execution_time AS exec_ms, queued_provisioning_time AS provisioning_ms, bytes_scanned, rows_produced FROM TABLE(INFORMATION_SCHEMA.QUERY_HISTORY_BY_SESSION(RESULT_LIMIT => 100)) WHERE query_tag IN ('P4_WARMUP', 'P4_BEFORE', 'P4_AFTER') AND query_type = 'SELECT' ORDER BY start_time
