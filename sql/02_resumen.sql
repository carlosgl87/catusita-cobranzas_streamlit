
WITH params AS (
    SELECT
        %(id_cliente)s::text AS id_cliente,
        %(fecha_corte)s::date AS fecha_corte,
        EXTRACT(YEAR FROM %(fecha_corte)s::date)::int AS anio_actual
),

/* =========================================================
   DOCUMENTOS ANULADOS
   ========================================================= */

documentos_anulados AS (
    SELECT DISTINCT
        "ciaAcronym",
        "transDocId",
        "transDocLine"
    FROM master_cobranzas_documentos_venta_anuladas
),

/* =========================================================
   DOCUMENTOS DEL CLIENTE
   ========================================================= */

docs AS (
    SELECT
        v."ciaAcronym",
        v."transDocId",
        v."transDocLine",
        COALESCE(
            NULLIF(UPPER(BTRIM(v."typeDocAcronym")), ''),
            UPPER(
                SPLIT_PART(
                    REGEXP_REPLACE(COALESCE(v."document",''), '\s+', '', 'g'),
                    '/',
                    1
                )
            )
        ) AS tipo_documento,
        v."document",
        v."dateAccounting" AS fecha_emision,
        v."dateExpiration" AS fecha_vencimiento,
        UPPER(v."currency") AS moneda,
        v."amount"::numeric AS amount,
        v."codeClient"

    FROM master_cobranzas_documentos_venta v
    CROSS JOIN params p

    WHERE UPPER(v."codeClient") = UPPER(p.id_cliente)

      /* Solo movimientos contables hasta la fecha del reporte */
      AND v."dateAccounting"::date <= p.fecha_corte

      /* Excluir documentos anulados */
      AND NOT EXISTS (
          SELECT 1
          FROM documentos_anulados a
          WHERE a."ciaAcronym" = v."ciaAcronym"
            AND a."transDocId" = v."transDocId"
            AND a."transDocLine" = v."transDocLine"
      )
),

/* =========================================================
   COMPRAS / DEVOLUCIONES / CONTADO
   ========================================================= */

ventas_resumen AS (
    SELECT
        EXTRACT(YEAR FROM fecha_emision)::int AS anio,

        /* COMPRAS SOLES */
        COUNT(*) FILTER (
            WHERE tipo_documento IN ('FA','BV')
              AND moneda IN ('SOL','PEN')
        ) AS compras_op_sol,

        COALESCE(
            SUM(amount) FILTER (
                WHERE tipo_documento IN ('FA','BV')
                  AND moneda IN ('SOL','PEN')
            ),
            0
        ) AS compras_sol,

        /* COMPRAS USD */
        COUNT(*) FILTER (
            WHERE tipo_documento IN ('FA','BV')
              AND moneda = 'USD'
        ) AS compras_op_usd,

        COALESCE(
            SUM(amount) FILTER (
                WHERE tipo_documento IN ('FA','BV')
                  AND moneda = 'USD'
            ),
            0
        ) AS compras_usd,

        /* DEVOLUCIONES SOLES */
        COUNT(*) FILTER (
            WHERE tipo_documento = 'NA'
              AND moneda IN ('SOL','PEN')
        ) AS devoluciones_op_sol,

        ABS(
            COALESCE(
                SUM(amount) FILTER (
                    WHERE tipo_documento = 'NA'
                      AND moneda IN ('SOL','PEN')
                ),
                0
            )
        ) AS devoluciones_sol,

        /* DEVOLUCIONES USD */
        COUNT(*) FILTER (
            WHERE tipo_documento = 'NA'
              AND moneda = 'USD'
        ) AS devoluciones_op_usd,

        ABS(
            COALESCE(
                SUM(amount) FILTER (
                    WHERE tipo_documento = 'NA'
                      AND moneda = 'USD'
                ),
                0
            )
        ) AS devoluciones_usd,

        /* CONTADO SOLES */
        COUNT(*) FILTER (
            WHERE tipo_documento IN ('FA','BV')
              AND fecha_emision::date = fecha_vencimiento::date
              AND moneda IN ('SOL','PEN')
        ) AS contado_op_sol,

        COALESCE(
            SUM(amount) FILTER (
                WHERE tipo_documento IN ('FA','BV')
                  AND fecha_emision::date = fecha_vencimiento::date
                  AND moneda IN ('SOL','PEN')
            ),
            0
        ) AS contado_sol,

        /* CONTADO USD */
        COUNT(*) FILTER (
            WHERE tipo_documento IN ('FA','BV')
              AND fecha_emision::date = fecha_vencimiento::date
              AND moneda = 'USD'
        ) AS contado_op_usd,

        COALESCE(
            SUM(amount) FILTER (
                WHERE tipo_documento IN ('FA','BV')
                  AND fecha_emision::date = fecha_vencimiento::date
                  AND moneda = 'USD'
            ),
            0
        ) AS contado_usd

    FROM docs
    GROUP BY 1
),

/* =========================================================
   CANJES DEL CLIENTE
   ========================================================= */

canjes AS (
    SELECT DISTINCT
        c."ciaAcronym" AS cia,
        c."exchangeNumber"::text AS exchange_number

    FROM master_cobranzas_documentos_venta_letras c
    CROSS JOIN params p

    WHERE UPPER(c."codeClient") = UPPER(p.id_cliente)

      AND NOT EXISTS (
          SELECT 1
          FROM master_cobranzas_letras_anuladas a
          WHERE a."ciaAcronym" = c."ciaAcronym"
            AND a."exchangeNumber"::text =
                c."exchangeNumber"::text
      )
),

/* =========================================================
   LETRAS
   ========================================================= */

letras AS (
    SELECT DISTINCT
        l."ciaAcronym",
        l."exchangeNumber"::text,
        l."document",

        NULLIF(
            BTRIM(l."dateAccounting"::text),
            ''
        )::timestamp AS fecha_emision,

        UPPER(l."currency") AS moneda,

        l."amount"::numeric AS amount,

        l."state"

    FROM master_cobranzas_letras_generadas l

    INNER JOIN canjes c
        ON c.cia = l."ciaAcronym"
       AND c.exchange_number = l."exchangeNumber"::text

    CROSS JOIN params p

    WHERE UPPER(l."stateExchange") = 'CONFIRMADO'

      AND NULLIF(
            BTRIM(l."dateAccounting"::text),
            ''
          )::timestamp::date <= p.fecha_corte
),

/* =========================================================
   RESUMEN DE LETRAS
   ========================================================= */

letras_resumen AS (
    SELECT
        EXTRACT(YEAR FROM fecha_emision)::int AS anio,

        /* LETRAS ACEPTADAS SOLES */
        COUNT(*) FILTER (
            WHERE moneda IN ('SOL','PEN')
        ) AS letras_aceptadas_op_sol,

        COALESCE(
            SUM(amount) FILTER (
                WHERE moneda IN ('SOL','PEN')
            ),
            0
        ) AS letras_aceptadas_sol,

        /* LETRAS ACEPTADAS USD */
        COUNT(*) FILTER (
            WHERE moneda = 'USD'
        ) AS letras_aceptadas_op_usd,

        COALESCE(
            SUM(amount) FILTER (
                WHERE moneda = 'USD'
            ),
            0
        ) AS letras_aceptadas_usd,

        /* PROTESTADAS SOLES */
        COUNT(*) FILTER (
            WHERE moneda IN ('SOL','PEN')
              AND UPPER("state") = 'P-PROTESTADA'
        ) AS letras_protestadas_op_sol,

        COALESCE(
            SUM(amount) FILTER (
                WHERE moneda IN ('SOL','PEN')
                  AND UPPER("state") = 'P-PROTESTADA'
            ),
            0
        ) AS letras_protestadas_sol,

        /* PROTESTADAS USD */
        COUNT(*) FILTER (
            WHERE moneda = 'USD'
              AND UPPER("state") = 'P-PROTESTADA'
        ) AS letras_protestadas_op_usd,

        COALESCE(
            SUM(amount) FILTER (
                WHERE moneda = 'USD'
                  AND UPPER("state") = 'P-PROTESTADA'
            ),
            0
        ) AS letras_protestadas_usd

    FROM letras
    GROUP BY 1
),

/* =========================================================
   AÑOS DISPONIBLES
   ========================================================= */

anios AS (
    SELECT anio FROM ventas_resumen
    UNION
    SELECT anio FROM letras_resumen
)

/* =========================================================
   RESULTADO
   ========================================================= */

SELECT
    a.anio,

    COALESCE(v.compras_op_sol,0)
        AS compras_op_sol,

    ROUND(COALESCE(v.compras_sol,0),2)
        AS compras_sol,

    COALESCE(v.compras_op_usd,0)
        AS compras_op_usd,

    ROUND(COALESCE(v.compras_usd,0),2)
        AS compras_usd,


    COALESCE(v.devoluciones_op_sol,0)
        AS devoluciones_op_sol,

    ROUND(COALESCE(v.devoluciones_sol,0),2)
        AS devoluciones_sol,

    COALESCE(v.devoluciones_op_usd,0)
        AS devoluciones_op_usd,

    ROUND(COALESCE(v.devoluciones_usd,0),2)
        AS devoluciones_usd,


    COALESCE(l.letras_aceptadas_op_sol,0)
        AS letras_aceptadas_op_sol,

    ROUND(COALESCE(l.letras_aceptadas_sol,0),2)
        AS letras_aceptadas_sol,

    COALESCE(l.letras_aceptadas_op_usd,0)
        AS letras_aceptadas_op_usd,

    ROUND(COALESCE(l.letras_aceptadas_usd,0),2)
        AS letras_aceptadas_usd,


    COALESCE(l.letras_protestadas_op_sol,0)
        AS letras_protestadas_op_sol,

    ROUND(COALESCE(l.letras_protestadas_sol,0),2)
        AS letras_protestadas_sol,

    COALESCE(l.letras_protestadas_op_usd,0)
        AS letras_protestadas_op_usd,

    ROUND(COALESCE(l.letras_protestadas_usd,0),2)
        AS letras_protestadas_usd,


    COALESCE(v.contado_op_sol,0)
        AS contado_op_sol,

    ROUND(COALESCE(v.contado_sol,0),2)
        AS contado_sol,

    COALESCE(v.contado_op_usd,0)
        AS contado_op_usd,

    ROUND(COALESCE(v.contado_usd,0),2)
        AS contado_usd

FROM anios a

LEFT JOIN ventas_resumen v
    ON v.anio = a.anio

LEFT JOIN letras_resumen l
    ON l.anio = a.anio

CROSS JOIN params p

WHERE a.anio IN (
    p.anio_actual,
    p.anio_actual - 1
)

ORDER BY a.anio DESC;