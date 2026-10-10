WITH corte AS (
    SELECT MAX(fecha_calculo)::date AS fecha_calculo
    FROM analytics_cartera_credito_diaria
    WHERE estado_calculo = 'ok'
),

cartera AS (
    SELECT
        a.fecha_calculo,
        a.id_cliente,
        a.nombre_cliente,
        a.vendedor_codigo,
        a.vendedor_nombre,
        a.zona,
        a.linea_credito_sugerida,
        a.linea_utilizada,
        a.linea_disponible,
        a.pct_utilizacion,
        a.letras_protestadas_abiertas,
        a.poca_historia_crediticia,
        a.estado_calculo
    FROM analytics_cartera_credito_diaria a
    INNER JOIN corte c
        ON a.fecha_calculo::date = c.fecha_calculo
    WHERE a.estado_calculo = 'ok'
),

ventas AS (
    SELECT
        UPPER(v.id_cliente) AS id_cliente,
        MAX(v.fecha_emision::date) FILTER (
            WHERE COALESCE(v.monto_venta_original, 0) > 0
        ) AS ultima_compra,
        ROUND(
            COALESCE(SUM(v.monto_venta_original) FILTER (
                WHERE v.fecha_emision::date > c.fecha_calculo - INTERVAL '12 months'
                  AND COALESCE(v.monto_venta_original, 0) > 0
            ), 0)::numeric,
            2
        ) AS compras_12m,
        ROUND(
            COALESCE(SUM(v.monto_venta_original) FILTER (
                WHERE v.fecha_emision::date > c.fecha_calculo - INTERVAL '24 months'
                  AND v.fecha_emision::date <= c.fecha_calculo - INTERVAL '12 months'
                  AND COALESCE(v.monto_venta_original, 0) > 0
            ), 0)::numeric,
            2
        ) AS compras_12m_previos,
        COUNT(DISTINCT v.doc_sunat) FILTER (
            WHERE v.fecha_emision::date > c.fecha_calculo - INTERVAL '12 months'
              AND COALESCE(v.monto_venta_original, 0) > 0
        )::integer AS operaciones_12m
    FROM ventas_cobranzas v
    INNER JOIN cartera ca
        ON UPPER(ca.id_cliente) = UPPER(v.id_cliente)
    CROSS JOIN corte c
    WHERE v.fecha_emision::date <= c.fecha_calculo
    GROUP BY UPPER(v.id_cliente), c.fecha_calculo
)

SELECT
    ca.*,
    ve.ultima_compra,
    CASE
        WHEN ve.ultima_compra IS NULL THEN NULL
        ELSE (ca.fecha_calculo::date - ve.ultima_compra)::integer
    END AS dias_sin_compra,
    COALESCE(ve.compras_12m, 0) AS compras_12m,
    COALESCE(ve.compras_12m_previos, 0) AS compras_12m_previos,
    COALESCE(ve.operaciones_12m, 0) AS operaciones_12m,
    CASE
        WHEN COALESCE(ve.compras_12m_previos, 0) > 0
            THEN ROUND(((ve.compras_12m / ve.compras_12m_previos) - 1) * 100, 1)
        ELSE NULL
    END AS variacion_compras_pct
FROM cartera ca
LEFT JOIN ventas ve
    ON ve.id_cliente = UPPER(ca.id_cliente)
ORDER BY
    GREATEST(COALESCE(ca.linea_disponible, 0), 0) DESC,
    ca.vendedor_nombre,
    ca.nombre_cliente;
