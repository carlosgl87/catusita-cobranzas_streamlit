WITH params AS (
    SELECT
        %(id_cliente)s::text AS id_cliente,
        %(fecha_corte)s::date AS fecha_corte,
        %(deuda_actual)s::numeric AS deuda_actual,
        %(deuda_vencida)s::numeric AS deuda_vencida
),

/* =========================================================
   1. HISTÓRICO COMERCIAL DEL CLIENTE
   ========================================================= */
ventas_cliente AS (
    SELECT v.*
    FROM ventas_cobranzas v
    CROSS JOIN params p
    WHERE UPPER(v.id_cliente) = UPPER(p.id_cliente)
      AND v.fecha_emision::date <= p.fecha_corte
),

historial_comercial AS (
    SELECT
        MIN(fecha_emision::date) FILTER (
            WHERE COALESCE(monto_venta_original, 0) > 0
        ) AS primera_compra,

        ROUND(
            COALESCE(SUM(monto_venta_original) FILTER (
                WHERE fecha_emision::date > p.fecha_corte - INTERVAL '12 months'
                  AND COALESCE(monto_venta_original, 0) > 0
            ), 0)::numeric,
            2
        ) AS compras_12m,

        ROUND(
            COALESCE(SUM(monto_venta_original) FILTER (
                WHERE fecha_emision::date > p.fecha_corte - INTERVAL '24 months'
                  AND fecha_emision::date <= p.fecha_corte - INTERVAL '12 months'
                  AND COALESCE(monto_venta_original, 0) > 0
            ), 0)::numeric,
            2
        ) AS compras_12m_previos,

        COUNT(DISTINCT doc_sunat) FILTER (
            WHERE fecha_emision::date > p.fecha_corte - INTERVAL '12 months'
              AND COALESCE(monto_venta_original, 0) > 0
        ) AS operaciones_12m

    FROM ventas_cliente
    CROSS JOIN params p
    GROUP BY p.fecha_corte
),

operaciones_credito AS (
    SELECT
        COALESCE(NULLIF(TRIM(pedido::text), ''), doc_sunat) AS operacion,
        SUM(GREATEST(COALESCE(monto_venta_original, 0), 0)) AS monto
    FROM ventas_cliente
    CROSS JOIN params p
    WHERE fecha_emision::date > p.fecha_corte - INTERVAL '12 months'
      AND COALESCE(monto_venta_original, 0) > 0
      AND (
            fecha_vencimiento::date > fecha_emision::date
            OR n_canje IS NOT NULL
          )
    GROUP BY 1
),

mayor_operacion AS (
    SELECT ROUND(COALESCE(MAX(monto), 0)::numeric, 2) AS mayor_operacion_credito
    FROM operaciones_credito
),

/* =========================================================
   2. OBLIGACIONES NO CANJEADAS - ÚLTIMOS 12 MESES

   Regla de gracia:
   una obligación se considera "con atraso relevante" solo si
   estuvo impaga MÁS DE 7 días después de su vencimiento.
   ========================================================= */
facturas_credito_12m AS (
    SELECT
        CONCAT('DOC|', cia, '|', doc_sunat) AS obligacion_id,
        MAX(fecha_vencimiento::date) AS fecha_vencimiento,
        MAX(COALESCE(mora, 0))::numeric AS dias_atraso_registrados,
        BOOL_OR(LOWER(COALESCE(estado_pago, '')) <> 'pagado') AS sigue_pendiente
    FROM ventas_cliente
    CROSS JOIN params p
    WHERE fecha_vencimiento::date > p.fecha_corte - INTERVAL '12 months'
      AND fecha_vencimiento::date <= p.fecha_corte
      AND fecha_vencimiento::date > fecha_emision::date
      AND n_canje IS NULL
      AND COALESCE(monto_venta_original, 0) > 0
    GROUP BY cia, doc_sunat
),

obligaciones_facturas AS (
    SELECT
        obligacion_id,
        fecha_vencimiento,
        CASE
            WHEN sigue_pendiente
                THEN GREATEST((p.fecha_corte - fecha_vencimiento), 0)
            ELSE GREATEST(dias_atraso_registrados, 0)::integer
        END AS dias_atraso,
        CASE
            WHEN sigue_pendiente
                THEN GREATEST((p.fecha_corte - fecha_vencimiento), 0) > 7
            ELSE GREATEST(dias_atraso_registrados, 0) > 7
        END AS atraso_mayor_7_dias
    FROM facturas_credito_12m
    CROSS JOIN params p
),

/* =========================================================
   3. LETRAS INDIVIDUALES + PAGOS
   ========================================================= */
canjes_anulados AS (
    SELECT DISTINCT
        a."ciaAcronym" AS cia,
        a."exchangeNumber"::text AS exchange_number
    FROM master_cobranzas_letras_anuladas a
),

canjes_cliente AS (
    SELECT DISTINCT
        c."ciaAcronym" AS cia,
        c."exchangeNumber"::text AS exchange_number
    FROM master_cobranzas_documentos_venta_letras c
    CROSS JOIN params p
    WHERE UPPER(c."codeClient") = UPPER(p.id_cliente)
      AND NOT EXISTS (
          SELECT 1
          FROM canjes_anulados a
          WHERE a.cia = c."ciaAcronym"
            AND a.exchange_number = c."exchangeNumber"::text
      )
),

pagos_anulados AS (
    SELECT DISTINCT
        a."ciaAcronym" AS cia,
        a."docEntry"
    FROM master_cobranzas_pagos_anulados a
    CROSS JOIN params p
    WHERE UPPER(a."codeClient") = UPPER(p.id_cliente)
),

pagos_letras AS (
    SELECT
        d."ciaAcronym" AS cia,
        d."transDocId",
        d."transDocLine",
        MAX(
            NULLIF(BTRIM(d."dateAccounting"::text), '')::timestamp::date
        ) AS fecha_pago
    FROM master_cobranzas_pagos_detalle d
    CROSS JOIN params p
    LEFT JOIN pagos_anulados a
        ON a.cia = d."ciaAcronym"
       AND a."docEntry" = d."docEntry"
    WHERE UPPER(d."codeClient") = UPPER(p.id_cliente)
      AND a."docEntry" IS NULL
      AND NULLIF(BTRIM(d."dateAccounting"::text), '')::timestamp::date <= p.fecha_corte
    GROUP BY d."ciaAcronym", d."transDocId", d."transDocLine"
),

/* Todas las letras del cliente hasta la fecha de corte.
   Esto se usa para detectar protestos abiertos sin inferirlos
   desde el campo situation del nuevo API. */
letras_cliente AS (
    SELECT DISTINCT
        l."ciaAcronym" AS cia,
        l."exchangeNumber"::text AS exchange_number,
        l."transDocId",
        l."transDocLine",
        l."document" AS documento,
        NULLIF(BTRIM(l."dateExpiration"::text), '')::timestamp::date AS fecha_vencimiento,
        NULLIF(BTRIM(l."dateAccounting"::text), '')::timestamp::date AS fecha_emision,
        UPPER(COALESCE(l."state", '')) AS estado_letra,
        pl.fecha_pago
    FROM master_cobranzas_letras_generadas l
    INNER JOIN canjes_cliente c
        ON c.cia = l."ciaAcronym"
       AND c.exchange_number = l."exchangeNumber"::text
    CROSS JOIN params p
    LEFT JOIN pagos_letras pl
        ON pl.cia = l."ciaAcronym"
       AND pl."transDocId" = l."transDocId"
       AND pl."transDocLine" = l."transDocLine"
    WHERE UPPER(COALESCE(l."stateExchange", '')) = 'CONFIRMADO'
      AND NULLIF(BTRIM(l."dateAccounting"::text), '')::timestamp::date <= p.fecha_corte
),

letras_12m AS (
    SELECT l.*
    FROM letras_cliente l
    CROSS JOIN params p
    WHERE l.fecha_vencimiento > p.fecha_corte - INTERVAL '12 months'
      AND l.fecha_vencimiento <= p.fecha_corte
),

obligaciones_letras AS (
    SELECT
        CONCAT(
            'LT|', cia, '|', exchange_number, '|',
            COALESCE("transDocId"::text, ''), '|',
            COALESCE("transDocLine"::text, '')
        ) AS obligacion_id,
        fecha_vencimiento,
        CASE
            WHEN fecha_pago IS NULL
                THEN GREATEST((p.fecha_corte - fecha_vencimiento), 0)
            ELSE GREATEST((fecha_pago - fecha_vencimiento), 0)
        END::integer AS dias_atraso,
        CASE
            WHEN fecha_pago IS NULL
                THEN GREATEST((p.fecha_corte - fecha_vencimiento), 0) > 7
            ELSE GREATEST((fecha_pago - fecha_vencimiento), 0) > 7
        END AS atraso_mayor_7_dias
    FROM letras_12m
    CROSS JOIN params p
),

obligaciones_12m AS (
    SELECT * FROM obligaciones_facturas
    UNION ALL
    SELECT * FROM obligaciones_letras
),

metricas_obligaciones AS (
    SELECT
        COUNT(*)::integer AS obligaciones_12m,
        COUNT(*) FILTER (WHERE atraso_mayor_7_dias)::integer AS obligaciones_atrasadas_7d_12m,
        ROUND(
            CASE
                WHEN COUNT(*) > 0
                    THEN COUNT(*) FILTER (WHERE atraso_mayor_7_dias)::numeric / COUNT(*) * 100
                ELSE 0
            END,
            1
        ) AS pct_obligaciones_atrasadas_7d_12m,
        ROUND(COALESCE(AVG(dias_atraso), 0)::numeric, 1) AS dias_promedio_atraso_12m
    FROM obligaciones_12m
),

metricas_letras AS (
    SELECT
        COUNT(*)::integer AS letras_12m,
        COUNT(*) FILTER (
            WHERE estado_letra = 'P-PROTESTADA'
        )::integer AS letras_protestadas_12m
    FROM letras_12m
),

metricas_protestos_abiertos AS (
    SELECT
        COUNT(*) FILTER (
            WHERE estado_letra = 'P-PROTESTADA'
              AND fecha_pago IS NULL
        )::integer AS letras_protestadas_abiertas
    FROM letras_cliente
),

/* =========================================================
   4. NÚMERO DE LETRAS QUE YA MANEJÓ BIEN

   Se considera sano un canje pagado, sin protestos y con
   atraso promedio <= 7 días por letra (periodo de gracia).
   ========================================================= */
canjes_sanos AS (
    SELECT
        n_canje::text AS canje,
        MAX(COALESCE(n_letras, 0))::integer AS n_letras,
        MAX(COALESCE(n_letras_protestadas, 0))::integer AS n_protestadas,
        MAX(COALESCE(canje_mora, 0))::numeric AS mora_total,
        BOOL_AND(LOWER(COALESCE(estado_pago, '')) = 'pagado') AS pagado
    FROM ventas_cliente
    CROSS JOIN params p
    WHERE n_canje IS NOT NULL
      AND fecha_emision::date > p.fecha_corte - INTERVAL '12 months'
    GROUP BY n_canje::text
),

historial_letras_sano AS (
    SELECT
        COALESCE(
            MAX(n_letras) FILTER (
                WHERE pagado = TRUE
                  AND n_protestadas = 0
                  AND n_letras > 0
                  AND mora_total / NULLIF(n_letras, 0) <= 7
            ),
            0
        )::integer AS max_letras_canje_sano_12m
    FROM canjes_sanos
),

/* =========================================================
   5. EXPOSICIÓN HISTÓRICA Y LÍNEA ACTUAL
   ========================================================= */
cliente_modelo AS (
    SELECT
        COALESCE(max_monto_exposicion, 0)::numeric AS maxima_exposicion_12m
    FROM clientes_cobranzas c
    CROSS JOIN params p
    WHERE UPPER(c.id_cliente) = UPPER(p.id_cliente)
    LIMIT 1
),

linea_actual AS (
    SELECT COALESCE(cc."monto_credito", 0)::numeric AS linea_credito_actual
    FROM cliente_credito_cuenta cc
    CROSS JOIN params p
    WHERE UPPER(cc."codeClient") = UPPER(p.id_cliente)
      AND cc."created_at"::date <= p.fecha_corte
    ORDER BY cc."created_at" DESC
    LIMIT 1
),

/* =========================================================
   6. BASE + AJUSTES DE CAPACIDAD
   ========================================================= */
base AS (
    SELECT
        h.primera_compra,
        CASE
            WHEN h.primera_compra IS NULL THEN 0
            ELSE (
                DATE_PART('year', AGE(p.fecha_corte, h.primera_compra)) * 12
                + DATE_PART('month', AGE(p.fecha_corte, h.primera_compra))
            )::integer
        END AS antiguedad_meses,
        CASE
            WHEN h.primera_compra IS NULL THEN 0
            ELSE EXTRACT(YEAR FROM AGE(p.fecha_corte, h.primera_compra))::integer
        END AS antiguedad_anios,

        h.compras_12m,
        h.compras_12m_previos,
        CASE
            WHEN h.compras_12m_previos > 0
                THEN ROUND(((h.compras_12m / h.compras_12m_previos) - 1) * 100, 1)
            ELSE NULL
        END AS variacion_compras_pct,
        h.operaciones_12m,

        mo.mayor_operacion_credito,
        COALESCE(cm.maxima_exposicion_12m, 0) AS maxima_exposicion_12m,
        COALESCE(la.linea_credito_actual, 0) AS linea_credito_actual,

        p.deuda_actual,
        p.deuda_vencida,

        o.obligaciones_12m,
        o.obligaciones_atrasadas_7d_12m,
        o.pct_obligaciones_atrasadas_7d_12m,
        o.dias_promedio_atraso_12m,

        ml.letras_12m,
        ml.letras_protestadas_12m,
        pa.letras_protestadas_abiertas,

        hs.max_letras_canje_sano_12m

    FROM params p
    CROSS JOIN historial_comercial h
    CROSS JOIN mayor_operacion mo
    CROSS JOIN metricas_obligaciones o
    CROSS JOIN metricas_letras ml
    CROSS JOIN metricas_protestos_abiertos pa
    CROSS JOIN historial_letras_sano hs
    LEFT JOIN cliente_modelo cm ON TRUE
    LEFT JOIN linea_actual la ON TRUE
),

ajustes AS (
    SELECT
        b.*,

        /* Base principal: máxima exposición demostrada.
           Si no existe, usamos una referencia conservadora. */
        CASE
            WHEN b.maxima_exposicion_12m > 0 THEN b.maxima_exposicion_12m
            ELSE GREATEST(
                COALESCE(b.linea_credito_actual, 0),
                COALESCE(b.mayor_operacion_credito, 0),
                0
            )
        END AS capacidad_base,

        CASE
            WHEN b.antiguedad_meses < 6 THEN -0.20
            WHEN b.antiguedad_meses < 12 THEN -0.10
            WHEN b.antiguedad_meses < 24 THEN 0.00
            WHEN b.antiguedad_meses <= 60 THEN 0.05
            ELSE 0.10
        END AS ajuste_antiguedad,

        CASE
            WHEN b.compras_12m_previos <= 0 THEN 0.00
            WHEN b.variacion_compras_pct > 20 THEN 0.10
            WHEN b.variacion_compras_pct < -40 THEN -0.20
            WHEN b.variacion_compras_pct < -20 THEN -0.10
            ELSE 0.00
        END AS ajuste_compras,

        /* Cumplimiento: ya incorpora 7 días de gracia. */
        CASE
            WHEN b.pct_obligaciones_atrasadas_7d_12m = 0 THEN 0.10
            WHEN b.pct_obligaciones_atrasadas_7d_12m <= 10 THEN 0.05
            WHEN b.pct_obligaciones_atrasadas_7d_12m <= 25 THEN -0.05
            WHEN b.pct_obligaciones_atrasadas_7d_12m <= 50 THEN -0.15
            ELSE -0.30
        END AS ajuste_vencidas,

        /* Hasta 7 días de atraso promedio se considera dentro de tolerancia. */
        CASE
            WHEN b.dias_promedio_atraso_12m <= 7 THEN 0.05
            WHEN b.dias_promedio_atraso_12m <= 15 THEN 0.00
            WHEN b.dias_promedio_atraso_12m <= 30 THEN -0.10
            ELSE -0.20
        END AS ajuste_atraso,

        /* Protestos: usamos número, no porcentaje.
           Cualquier protesto abierto se bloquea más adelante. */
        CASE
            WHEN b.letras_12m = 0 THEN 0.00
            WHEN b.letras_protestadas_12m = 0 THEN 0.05
            WHEN b.letras_protestadas_12m = 1 THEN -0.05
            WHEN b.letras_protestadas_12m = 2 THEN -0.10
            ELSE -0.20
        END AS ajuste_protestos

    FROM base b
),

ajuste_total AS (
    SELECT
        a.*,
        (
            ajuste_antiguedad
            + ajuste_compras
            + ajuste_vencidas
            + ajuste_atraso
            + ajuste_protestos
        ) AS ajuste_total_bruto
    FROM ajustes a
),

ajuste_controlado AS (
    SELECT
        a.*,
        CASE
            /* Con menos de 5 obligaciones no permitimos subir la base,
               aunque sí permitimos reducirla por mal comportamiento. */
            WHEN a.obligaciones_12m < 5
                THEN GREATEST(LEAST(a.ajuste_total_bruto, 0.00), -0.50)
            ELSE GREATEST(LEAST(a.ajuste_total_bruto, 0.50), -0.50)
        END AS ajuste_total_aplicado
    FROM ajuste_total a
),

capacidad AS (
    SELECT
        a.*,
        CASE
            WHEN a.letras_protestadas_abiertas > 0 THEN 0::numeric
            ELSE a.capacidad_base * (1 + a.ajuste_total_aplicado)
        END AS capacidad_calculada
    FROM ajuste_controlado a
)

SELECT
    primera_compra,
    antiguedad_meses,
    antiguedad_anios,

    compras_12m,
    compras_12m_previos,
    variacion_compras_pct,
    operaciones_12m,

    mayor_operacion_credito,
    ROUND(maxima_exposicion_12m, 2) AS maxima_exposicion_12m,
    ROUND(linea_credito_actual, 2) AS linea_credito_actual,

    ROUND(deuda_actual, 2) AS deuda_actual,
    ROUND(deuda_vencida, 2) AS deuda_vencida,

    obligaciones_12m,
    obligaciones_atrasadas_7d_12m,
    pct_obligaciones_atrasadas_7d_12m,
    dias_promedio_atraso_12m,

    letras_12m,
    letras_protestadas_abiertas,
    letras_protestadas_12m,
    max_letras_canje_sano_12m,

    ROUND(capacidad_base, 2) AS capacidad_base,
    ROUND(ajuste_antiguedad * 100, 1) AS ajuste_antiguedad_pct,
    ROUND(ajuste_compras * 100, 1) AS ajuste_compras_pct,
    ROUND(ajuste_vencidas * 100, 1) AS ajuste_vencidas_pct,
    ROUND(ajuste_atraso * 100, 1) AS ajuste_atraso_pct,
    ROUND(ajuste_protestos * 100, 1) AS ajuste_protestos_pct,
    ROUND(ajuste_total_aplicado * 100, 1) AS ajuste_total_pct,

    CASE
        WHEN letras_protestadas_abiertas > 0 THEN 0
        WHEN capacidad_calculada <= 0 THEN 0
        WHEN capacidad_calculada < 500 THEN ROUND(capacidad_calculada, 2)
        ELSE FLOOR(capacidad_calculada / 500.0) * 500
    END AS capacidad_sugerida,

    ROUND(
        CASE
            WHEN capacidad_calculada > 0
                THEN GREATEST(deuda_actual, 0) / capacidad_calculada * 100
            ELSE 0
        END,
        1
    ) AS pct_capacidad_utilizada,

    CASE
        WHEN obligaciones_12m < 5 THEN TRUE
        ELSE FALSE
    END AS poca_historia_crediticia

FROM capacidad;
