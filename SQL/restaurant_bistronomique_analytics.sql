
-- 1. Vue d'ensemble financière: CA, Volume et Panier moyen par couvert
    -- Obtenir les KPIs globaux du restaurant (chiffre d'affaires net, nombre total de commandes, couverts servis et panier moyen)

WITH order_summary AS (
    SELECT
        s.order_code,
        EXTRACT(YEAR FROM MAX(s.datetime:: TIMESTAMP)) AS year,
        MAX(s.order_pax) AS order_pax,
        SUM(s.product_quantity) AS total_quantity,
        ROUND(SUM(s.product_price_net):: NUMERIC, 2) AS total_revenue
    FROM fact_sales s
    GROUP BY s.order_code
)
SELECT
    COALESCE(year::TEXT, 'TOTAL') AS year,
    COUNT(*) AS total_orders,
    SUM(os.order_pax) AS total_pax,
    SUM(os.total_quantity) AS total_quantity,
    ROUND(SUM(os.total_revenue)::NUMERIC, 2) AS total_revenue,
    ROUND((SUM(os.total_revenue) / NULLIF(SUM(os.order_pax), 0))::NUMERIC, 2) AS average_price
FROM order_summary os
GROUP BY ROLLUP(year)
ORDER BY year ASC NULLS LAST;

-- 2. Top 10 des produits les plus générateurs de Chiffre d'Affaires
    -- Identifier les locomotives du menu par catégorie et par volume de vente.

WITH ranked_products AS (
    SELECT
        p.product_cat,
        p.product_name,
        SUM(s.product_quantity) AS total_quantity_sold,
        ROUND(SUM(s.product_price_net)::NUMERIC, 2) AS total_revenue,
        (SELECT SUM(product_price_net)::NUMERIC AS global_revenue FROM fact_sales) AS global_revenue,
        ROW_NUMBER() OVER (ORDER BY SUM(s.product_price_net) DESC) AS product_rank
    FROM fact_sales s
    JOIN dim_products p ON s.product_id = p.product_id
    GROUP BY p.product_cat, p.product_name
    ORDER BY total_revenue DESC
    LIMIT 10
)

SELECT
    CASE 
        WHEN GROUPING(rp.product_cat) = 1 THEN '--- TOTAL TOP 10 ---'
        ELSE MAX(rp.product_rank)::TEXT 
    END AS rank,
    COALESCE(rp.product_cat, '') AS product_cat,
    COALESCE(rp.product_name, '') AS product_name,
    SUM(rp.total_quantity_sold) AS total_quantity_sold,
    SUM(rp.total_revenue) AS total_revenue,
    ROUND((SUM(rp.total_revenue) / MAX(rp.global_revenue) * 100)::NUMERIC, 2) AS percentage_of_total_revenue
FROM ranked_products rp
GROUP BY GROUPING SETS ((rp.product_cat, rp.product_name), ())
ORDER BY GROUPING(rp.product_cat) ASC, total_revenue DESC;

-- 3. Performance de la Brigade
    -- Classer les serveurs selon le chiffre d'affaires généré au sein de leur propre équipe.

WITH order_summary AS (
    SELECT
        s.order_code,
        s.employee_id,
        MAX(s.order_pax) AS order_pax,
        ROUND(SUM(s.product_price_net):: NUMERIC, 2) AS order_revenue
    FROM fact_sales s
    GROUP BY s.order_code, s.employee_id
),

employee_ranked AS (
    SELECT
        e.employee_team,
        RANK() OVER(PARTITION BY e.employee_team ORDER BY SUM(os.order_revenue) DESC) AS rank_in_team,
        e.employee_name,
        ROUND(SUM(os.order_revenue)::NUMERIC, 2) AS revenue_generated,
        SUM(os.order_pax) AS total_pax_served,
        COUNT(DISTINCT os.order_code) AS total_orders_handled
    FROM order_summary os
    JOIN dim_employees e ON os.employee_id = e.employee_id
    GROUP BY e.employee_team, e.employee_name
)

SELECT
    CASE
        WHEN GROUPING(er.employee_team) = 1 THEN 'TOTAL GENERAL'
        ELSE er.employee_team::TEXT
    END AS employee_team,
    
    CASE 
        WHEN GROUPING(er.employee_team) = 1 THEN '-'
        WHEN GROUPING(er.employee_name) = 1 THEN 'SOUS-TOTAL'
        ELSE MAX(er.rank_in_team)::TEXT
    END AS rank_in_team,
    
    CASE
        WHEN GROUPING(er.employee_team) = 1 THEN '-'
        WHEN GROUPING(er.employee_name) = 1 THEN '-'
        ELSE er.employee_name
    END AS employee_name,

    ROUND(SUM(er.revenue_generated)::NUMERIC, 2) AS revenue_generated,
    SUM(er.total_pax_served) AS total_pax_served,
    SUM(er.total_orders_handled) AS total_orders_handled
FROM employee_ranked er
GROUP BY ROLLUP(er.employee_team, er.employee_name)
ORDER BY 
    GROUPING(er.employee_team) ASC,  
    er.employee_team ASC,            
    GROUPING(er.employee_name) ASC,  
    revenue_generated DESC;

-- 4. Analyse de la fréquentation par Service (Midi vs Soir)
    -- Comparer la répartition de l'activité commerciale entre les services de midi et du soir.

WITH order_summary AS (
    SELECT
        s.service_id,
        s.order_code,
        MAX(s.order_pax) AS order_pax,
        ROUND(SUM(s.product_price_net):: NUMERIC, 2) AS order_revenue
    FROM fact_sales s
    GROUP BY s.order_code, s.service_id
)
SELECT
    CASE
        WHEN GROUPING(srv.service_name) = 1 THEN 'TOTAL GENERAL'
        ELSE srv.service_name::TEXT
    END AS service_name,
    COUNT(DISTINCT os.order_code) AS total_orders,
    SUM(os.order_pax) AS total_pax,
    ROUND(SUM(os.order_revenue)::NUMERIC, 2) AS total_revenue,
    ROUND((SUM(os.order_revenue) / NULLIF(COUNT(DISTINCT os.order_code), 0))::NUMERIC, 2) AS revenue_per_order,
    ROUND((SUM(os.order_revenue) / NULLIF(SUM(os.order_pax), 0))::NUMERIC, 2) AS average_price_per_pax
FROM order_summary os
JOIN dim_services srv ON os.service_id = srv.service_id
GROUP BY ROLLUP(srv.service_name)
ORDER BY 
    GROUPING(srv.service_name) NULLS LAST,
    total_revenue DESC NULLS LAST;

-- 5. Suivi de l'impact COVID et Saisonnalité Mensuelle
    -- Mesurer l'évolution du chiffre d'affaires mois par mois pour visualiser les creux liés au COVID ou à la saisonnalité d'hiver.

WITH orders AS (
    SELECT
        s.order_code,
        TO_CHAR(MAX(s.datetime::TIMESTAMP), 'YYYY-MM') AS year_month,
        TO_CHAR(MAX(s.datetime::TIMESTAMP), 'YYYY') AS year_val,
        MAX(s.order_pax) AS total_pax,
        SUM(product_price_net) AS order_revenue
    FROM fact_sales s
    GROUP BY s.order_code
)
SELECT

    CASE 
        WHEN GROUPING(o.year_val) = 1 AND GROUPING(o.year_month) = 1 THEN 'TOTAL GENERAL'
        WHEN GROUPING(o.year_month) = 1 THEN 'TOTAL ' || o.year_val::TEXT
        ELSE o.year_month
    END AS year_month,
    
    COUNT(DISTINCT o.order_code) AS total_orders,
    SUM(o.total_pax) AS total_pax,
    ROUND(SUM(o.order_revenue)::NUMERIC, 2) AS revenue,
    ROUND((SUM(o.order_revenue) / NULLIF(SUM(o.total_pax), 0))::NUMERIC, 2) AS average_price_monthly

FROM orders o
GROUP BY ROLLUP(o.year_val, o.year_month)
ORDER BY 
    GROUPING(o.year_val) ASC,
    o.year_val ASC NULLS LAST,
    GROUPING(o.year_month) ASC,
    o.year_month ASC NULLS LAST;

-- 6. Rentabilité des Tables et des Zones (Salle, Terrasse, VIP)
    -- Identifier quelle zone du restaurant génère le plus de chiffre d'affaires et accueille le plus de couverts.

WITH orders_table AS (
    SELECT
        s.order_code,
        s.table_id,
        MAX(s.order_pax) AS total_pax,
        ROUND(SUM(s.product_price_net)::NUMERIC, 2) AS total_revenue
    FROM fact_sales s
    GROUP BY s.order_code, s.table_id
)
SELECT
    COALESCE(t.table_zone, 'TOTAL GENERAL') AS table_zone,
    COUNT(*) AS total_orders,
    SUM(ot.total_pax) AS total_pax,
    ROUND(SUM(ot.total_revenue)::NUMERIC, 0) AS total_revenue,
    ROUND((SUM(ot.total_revenue) / NULLIF(SUM(ot.total_pax), 0))::NUMERIC, 2) AS revenue_per_pax
FROM orders_table ot
JOIN dim_tables t ON ot.table_id = t.table_id
GROUP BY ROLLUP(t.table_zone)
ORDER BY 
    GROUPING(t.table_zone) ASC,
    total_revenue DESC;

-- 7. Analyse des Pertes et Mouvements de Stock par Ingrédient
    -- Croiser la table de faits des stocks avec les ingrédients pour identifier les volumes perdus ou gaspillés.

SELECT
    COALESCE(i.ingredient_name, 'TOTAL GENERAL') AS ingredient_name,
    COALESCE(i.ingredient_unit, '-') AS ingredient_unit,
    COALESCE(sm.stock_movements_type, '-') AS stock_movements_type,
    ROUND((SUM(ABS(sm.stock_movements_quantity)))::NUMERIC, 2) AS total_quantity_wasted,
    ROUND(SUM(ABS(sm.stock_movements_quantity) * i.ingredient_unit_cost)::NUMERIC, 2) AS total_cost_food
FROM fact_stock_movements sm
JOIN dim_ingredients i ON sm.ingredient_id = i.ingredient_id
WHERE sm.stock_movements_type IN ('Perte')
GROUP BY GROUPING SETS (
    (i.ingredient_name, i.ingredient_unit, sm.stock_movements_type, i.ingredient_unit_cost),
    ()
)
ORDER BY
    CASE WHEN i.ingredient_name IS NULL THEN 1 ELSE 0 END ASC,
    total_cost_food DESC;

-- 8. Impact des Promotions sur le Volume de Vente
    -- Analyser le comportement d'achat des clients selon qu'ils ont bénéficié d'une promotion ou non.

WITH order_summary AS (
    SELECT
        s.order_code,
        s.promotion_id,
        MAX(s.order_pax) AS order_pax,
        ROUND(SUM(s.product_price_net)::NUMERIC, 2) AS order_revenue,
        SUM(s.product_quantity) AS product_quantity
    FROM fact_sales s
    GROUP BY s.order_code, s.promotion_id
)

SELECT
    CASE
        WHEN GROUPING(p.promotion_name) = 1 THEN 'TOTAL'
        WHEN p.promotion_name IS NULL THEN 'No Promotion'
        ELSE p.promotion_name
    END AS promotion_applied,
    COUNT(DISTINCT os.order_code) AS total_orders,
    SUM(os.product_quantity) AS total_quantity,
    SUM(os.order_pax) AS total_pax,
    ROUND(SUM(os.order_revenue)::NUMERIC, 2) AS total_revenue,
    ROUND((SUM(os.order_revenue) / NULLIF(SUM(os.order_pax), 0))::NUMERIC, 2) AS average_price_per_pax
FROM order_summary os
LEFT JOIN dim_promotions p ON os.promotion_id = p.promotion_id
GROUP BY ROLLUP(p.promotion_name)
ORDER BY
    GROUPING(p.promotion_name) ASC,
    p.promotion_name ASC NULLS LAST,
    total_revenue DESC;

-- 9. Top 10 des Meilleurs Clients (Loyauté & Valeur Client)
    -- Identifier les clients les plus fidèles ou ceux qui rapportent le plus de chiffre d'affaires cumulé.

WITH top10_customers AS (
    SELECT 
        c.customer_name,
        c.customer_type,
        COUNT(DISTINCT s.order_code) AS total_visits,
        ROUND(SUM(s.product_price_net)::NUMERIC, 2) AS total_spent,
        ROUND((SUM(s.product_price_net) / COUNT(DISTINCT s.order_code))::NUMERIC, 2) AS average_price_per_order
    FROM fact_sales s
    JOIN dim_customers c ON s.customer_id = c.customer_id
    GROUP BY c.customer_name, c.customer_type
    ORDER BY total_spent DESC
    LIMIT 10
)

SELECT 
    customer_name,
    customer_type,
    total_visits,
    total_spent,
    average_price_per_order
FROM top10_customers

UNION ALL

SELECT 
    '--- TOTAL TOP 10 ---' AS customer_name,
    '-' AS customer_type,
    SUM(total_visits) AS total_visits,
    SUM(total_spent) AS total_spent,
    ROUND((SUM(total_spent) / NULLIF(SUM(total_visits), 0))::NUMERIC, 2) AS average_price_per_order
FROM top10_customers;

-- 10. Analyse de la Complexité des Recettes (Ingrédients par Produit)
    -- Utiliser la table de pont (bridge_recipes) pour lister les produits et compter précisément de combien d'ingrédients se compose chaque plat.

SELECT
    p.product_name,
    p.product_cat,
    COUNT(r.ingredient_id) AS total_ingredients_needed,
    SUM(r.recipe_quantity) AS total_quantity_ingredients_used,
    MAX(p.product_price) AS product_price,
    ROUND((SUM(r.recipe_quantity * i.ingredient_unit_cost))::NUMERIC, 2) AS food_cost,
    ROUND((MAX(p.product_price) - SUM(r.recipe_quantity * i.ingredient_unit_cost))::NUMERIC, 2) AS product_margin
FROM dim_products p
JOIN bridge_recipes r ON p.product_id = r.product_id
JOIN dim_ingredients i ON r.ingredient_id = i.ingredient_id
GROUP BY p.product_name, p.product_cat
ORDER BY product_margin DESC;