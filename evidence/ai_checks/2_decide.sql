SELECT i.store_id AS copy_store, c.store_id AS home_store, COUNT(*) AS payments, SUM(p.amount) AS revenue
FROM SAKILA.OLTP.payment p
JOIN SAKILA.OLTP.rental r ON r.rental_id = p.rental_id
JOIN SAKILA.OLTP.inventory i ON i.inventory_id = r.inventory_id
JOIN SAKILA.OLTP.customer c ON c.customer_id = p.customer_id
GROUP BY i.store_id, c.store_id ORDER BY i.store_id, c.store_id
