SELECT c.store_id, COUNT(*) AS payments, SUM(p.amount) AS revenue
FROM SAKILA.OLTP.payment p
JOIN SAKILA.OLTP.customer c ON c.customer_id = p.customer_id
GROUP BY c.store_id ORDER BY c.store_id
