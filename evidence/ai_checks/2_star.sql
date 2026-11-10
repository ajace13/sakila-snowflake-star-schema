SELECT s.store_id, COUNT(*) AS payments, SUM(p.amount) AS revenue
FROM SAKILA.DW.FACT_PAYMENT p
JOIN SAKILA.DW.DIM_STORE s ON s.store_key = p.store_key
GROUP BY s.store_id ORDER BY s.store_id
