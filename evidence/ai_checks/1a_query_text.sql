SELECT SUM(p.amount) AS revenue, COUNT(*) AS payments, COUNT(DISTINCT c.customer_id) AS paying_customers,
       ROUND(AVG(p.amount), 2) AS average_payment
FROM SAKILA.DW.FACT_PAYMENT p
JOIN SAKILA.DW.DIM_CUSTOMER c ON c.customer_key = p.customer_key   -- DIM_CUSTOMER is Type 2: count customer_id, not customer_key
WHERE p.payment_date_key BETWEEN 20050527 AND 20050825
