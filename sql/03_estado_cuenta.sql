WITH params AS (
    SELECT
        %(id_cliente)s::text AS id_cliente,
        %(fecha_corte)s::date AS fecha_corte,
        DATE '2023-01-01' AS fecha_inicio_movimientos,
        0.01::numeric AS tolerancia_abs
),

/* =========================================================
   1. CLIENTE
   ========================================================= */
cliente AS (
    SELECT
        c."codeClient",
        c."codeSeller"
    FROM master_cobranzas_clientes c
    CROSS JOIN params p
    WHERE UPPER(c."codeClient") = UPPER(p.id_cliente)
    LIMIT 1
),

/* =========================================================
   2. DOCUMENTOS ANULADOS
   ========================================================= */
documentos_anulados AS (
    SELECT DISTINCT
        a."ciaAcronym" AS cia,
        a."transDocId",
        a."transDocLine"
    FROM master_cobranzas_documentos_venta_anuladas a
    CROSS JOIN params p
    WHERE UPPER(a."codeClient") = UPPER(p.id_cliente)
),

/* =========================================================
   3. DOCUMENTOS RAW DEL CLIENTE

   DISTINCT ON elimina duplicados transaccionales como
   NC/F080-0006057, que vimos repetido con distinto seller.
   ========================================================= */
documentos AS (
    SELECT DISTINCT ON (
        v."ciaAcronym",
        v."transDocId",
        v."transDocLine"
    )
        v."ciaAcronym" AS cia,
        v."transDocId",
        v."transDocLine",
        v."transDocType",
        v."docEntryDoc",

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

        REGEXP_REPLACE(
            v."document",
            '\s+',
            '',
            'g'
        ) AS documento,

        REGEXP_REPLACE(
            COALESCE(v."reference",''),
            '\s+',
            '',
            'g'
        ) AS referencia,

        v."dateAccounting"::date AS fecha_emision,
        v."dateExpiration"::date AS fecha_vencimiento,

        UPPER(v."currency") AS moneda,
        v."amount"::numeric AS importe,

        v."codeSeller" AS vendedor,
        v."orderSales" AS pedido,

        REGEXP_REPLACE(
            UPPER(v."document"),
            '[^A-Z0-9]',
            '',
            'g'
        ) AS documento_norm,

        REGEXP_REPLACE(
            UPPER(COALESCE(v."reference",'')),
            '[^A-Z0-9]',
            '',
            'g'
        ) AS referencia_norm

    FROM master_cobranzas_documentos_venta v
    CROSS JOIN params p

    WHERE UPPER(v."codeClient") = UPPER(p.id_cliente)

      AND v."dateAccounting"::date
          BETWEEN p.fecha_inicio_movimientos
              AND p.fecha_corte

      AND NOT EXISTS (
          SELECT 1
          FROM documentos_anulados a
          WHERE a.cia = v."ciaAcronym"
            AND a."transDocId" = v."transDocId"
            AND a."transDocLine" = v."transDocLine"
      )

    ORDER BY
        v."ciaAcronym",
        v."transDocId",
        v."transDocLine",
        v."codeSeller"
),

/* =========================================================
   4. PAGOS ANULADOS
   ========================================================= */
pagos_anulados AS (
    SELECT DISTINCT
        a."ciaAcronym" AS cia,
        a."docEntry"
    FROM master_cobranzas_pagos_anulados a
    CROSS JOIN params p
    WHERE UPPER(a."codeClient") = UPPER(p.id_cliente)
),

/* =========================================================
   5. PAGOS DEL CLIENTE

   V2:
   Conservamos ambos importes del pago.
   La moneda que manda es la del DOCUMENTO destino, no la
   moneda del header/pago.
   ========================================================= */
pagos_cliente AS (
    SELECT
        d."ciaAcronym" AS cia,
        d."transDocId",
        d."transDocLine",
        d."docEntry",

        COALESCE(
            NULLIF(BTRIM(d."amountApplied"), '')::numeric,
            0
        ) AS monto_local,

        COALESCE(
            NULLIF(BTRIM(d."amountAppliedFC"), '')::numeric,
            0
        ) AS monto_fc

    FROM master_cobranzas_pagos_detalle d
    CROSS JOIN params p

    WHERE UPPER(d."codeClient") = UPPER(p.id_cliente)

      AND (
            NULLIF(
                BTRIM(d."dateAccounting"),
                ''
            )::timestamp::date <= p.fecha_corte

            OR NULLIF(
                BTRIM(d."dateAccounting"),
                ''
            ) IS NULL
      )
),

/* =========================================================
   6. PAGOS VÁLIDOS AGRUPADOS POR DOCUMENTO

   Clave correcta:
   cia + transDocId + transDocLine
   ========================================================= */
pagos AS (
    SELECT
        pc.cia,
        pc."transDocId",
        pc."transDocLine",

        SUM(pc.monto_local) AS monto_local,
        SUM(pc.monto_fc)    AS monto_fc

    FROM pagos_cliente pc

    LEFT JOIN pagos_anulados pa
        ON pa.cia = pc.cia
       AND pa."docEntry" = pc."docEntry"

    WHERE pa."docEntry" IS NULL

    GROUP BY
        pc.cia,
        pc."transDocId",
        pc."transDocLine"
),

/* =========================================================
   7. FACTURAS BASE
   ========================================================= */
facturas_base AS (
    SELECT
        d.*,

        CASE
            WHEN d.moneda = 'USD'
                THEN COALESCE(p.monto_fc, 0)
            ELSE COALESCE(p.monto_local, 0)
        END AS monto_pagado,

        GREATEST(
            d.importe
            - CASE
                WHEN d.moneda = 'USD'
                    THEN COALESCE(p.monto_fc, 0)
                ELSE COALESCE(p.monto_local, 0)
              END,
            0
        ) AS saldo_antes_notas

    FROM documentos d

    LEFT JOIN pagos p
        ON p.cia = d.cia
       AND p."transDocId" = d."transDocId"
       AND p."transDocLine" = d."transDocLine"

    WHERE d.tipo_documento IN ('FA','BV')
      AND d.importe > 0
),

/* =========================================================
   8. NOTAS NEGATIVAS QUE PARTICIPAN EN CUENTA CORRIENTE

   Series observadas/validadas en los 17 casos:
   - F007
   - F027
   - F070

   Solo notas negativas. El saldo abierto exacto de algunas
   NA sigue dependiendo de reconciliaciones no visibles en el
   extracto RAW actual.
   ========================================================= */
notas_base AS (
    SELECT
        d.cia,
        d."transDocId",
        d."transDocLine",
        d."docEntryDoc",

        d.documento,
        d.referencia,
        d.referencia_norm,

        d.fecha_emision,
        d.fecha_vencimiento,

        d.moneda,
        d.importe,
        ABS(d.importe) AS importe_abs,

        d.vendedor

    FROM documentos d

    WHERE d.tipo_documento = 'NA'
      AND d.importe < 0

      AND (
           UPPER(d.documento) LIKE 'NA/F007-%%'
        OR UPPER(d.documento) LIKE 'NA/F027-%%'
        OR UPPER(d.documento) LIKE 'NA/F070-%%'
      )
),

/* =========================================================
   9. APLICACIONES DIRECTAS DE LA PROPIA NOTA

   Ejemplo Racing:
   NA/F007-0010904 = -420
   aplicado directamente = 420
   disponible = 0
   ========================================================= */
notas_disponibles AS (
    SELECT
        n.*,

        CASE
            WHEN n.moneda = 'USD'
                THEN COALESCE(p.monto_fc, 0)
            ELSE COALESCE(p.monto_local, 0)
        END AS aplicado_directo,

        GREATEST(
            n.importe_abs
            - CASE
                WHEN n.moneda = 'USD'
                    THEN COALESCE(p.monto_fc, 0)
                ELSE COALESCE(p.monto_local, 0)
              END,
            0
        ) AS monto_disponible

    FROM notas_base n

    LEFT JOIN pagos p
        ON p.cia = n.cia
       AND p."transDocId" = n."transDocId"
       AND p."transDocLine" = n."transDocLine"
),

/* =========================================================
   10. ASIGNACIÓN SECUENCIAL DE NA A SU FACTURA

   Una factura puede tener más de una nota.
   ========================================================= */
notas_asignacion AS (
    SELECT
        n.*,

        f.documento AS factura_documento,
        f.saldo_antes_notas,

        COALESCE(
            SUM(n.monto_disponible)
            OVER (
                PARTITION BY
                    n.cia,
                    n.referencia_norm,
                    n.moneda

                ORDER BY
                    n.fecha_emision,
                    n."transDocId",
                    n."transDocLine"

                ROWS BETWEEN
                    UNBOUNDED PRECEDING
                    AND 1 PRECEDING
            ),
            0
        ) AS notas_previas

    FROM notas_disponibles n

    INNER JOIN facturas_base f
        ON f.cia = n.cia
       AND f.documento_norm = n.referencia_norm
       AND f.moneda = n.moneda
),

/* =========================================================
   11. CÁLCULO DE CONSUMO Y CRÉDITO ABIERTO POR NA
   ========================================================= */
notas_calculadas AS (
    SELECT
        n.*,

        GREATEST(
            n.saldo_antes_notas
            - n.notas_previas,
            0
        ) AS deuda_disponible,

        LEAST(
            n.monto_disponible,
            GREATEST(
                n.saldo_antes_notas
                - n.notas_previas,
                0
            )
        ) AS nota_consumida_factura,

        GREATEST(
            n.monto_disponible
            -
            GREATEST(
                n.saldo_antes_notas
                - n.notas_previas,
                0
            ),
            0
        ) AS credito_abierto

    FROM notas_asignacion n
),

/* =========================================================
   12. TOTAL DE NOTAS DISPONIBLES POR FACTURA

   Solo usamos el monto que no fue aplicado directamente
   a otro documento.
   ========================================================= */
notas_por_factura AS (
    SELECT
        cia,
        referencia_norm,
        moneda,

        SUM(monto_disponible)
            AS notas_disponibles

    FROM notas_disponibles

    GROUP BY
        cia,
        referencia_norm,
        moneda
),

/* =========================================================
   13. FACTURA DESPUÉS DE PAGOS + NA DISPONIBLES
   ========================================================= */
facturas_calculadas AS (
    SELECT
        f.*,

        COALESCE(
            n.notas_disponibles,
            0
        ) AS monto_notas,

        GREATEST(
            f.saldo_antes_notas
            - COALESCE(n.notas_disponibles,0),
            0
        ) AS saldo_final

    FROM facturas_base f

    LEFT JOIN notas_por_factura n
        ON n.cia = f.cia
       AND n.referencia_norm =
           f.documento_norm
       AND n.moneda = f.moneda
),

/* =========================================================
   14. CANJES ANULADOS
   ========================================================= */
canjes_anulados AS (
    SELECT DISTINCT
        a."ciaAcronym" AS cia,
        a."exchangeNumber"::text
            AS exchange_number

    FROM master_cobranzas_letras_anuladas a
),

/* =========================================================
   15. RELACIÓN FACTURA -> CANJE
   ========================================================= */
canjes_base AS (
    SELECT DISTINCT
        c."ciaAcronym" AS cia,

        c."exchangeNumber"::text
            AS exchange_number,

        c."transBaseDocId",
        c."transBaseDocLine"

    FROM master_cobranzas_documentos_venta_letras c
    CROSS JOIN params p

    WHERE UPPER(c."codeClient") = UPPER(p.id_cliente)

      AND (
            NULLIF(
                BTRIM(c."dateAccounting"::text),
                ''
            )::timestamp::date <= p.fecha_corte

            OR NULLIF(
                BTRIM(c."dateAccounting"::text),
                ''
            ) IS NULL
      )

      AND NOT EXISTS (
          SELECT 1
          FROM canjes_anulados ca
          WHERE ca.cia = c."ciaAcronym"
            AND ca.exchange_number =
                c."exchangeNumber"::text
      )
),

canjes_unicos AS (
    SELECT DISTINCT
        cia,
        exchange_number
    FROM canjes_base
),

/* =========================================================
   16. LETRAS GENERADAS CONFIRMADAS
   ========================================================= */
letras_base AS (
    SELECT DISTINCT
        l."ciaAcronym" AS cia,

        l."exchangeNumber"::text
            AS exchange_number,

        l."transDocId",
        l."transDocLine",

        REGEXP_REPLACE(
            l."document",
            '^LT-',
            'LT/'
        ) AS documento,

        REGEXP_REPLACE(
            REGEXP_REPLACE(
                UPPER(l."document"),
                '^LT[-/ ]*',
                ''
            ),
            '[^A-Z0-9]',
            '',
            'g'
        ) AS letra_norm,

        NULLIF(
            BTRIM(l."dateAccounting"::text),
            ''
        )::timestamp::date
            AS fecha_documento,

        NULLIF(
            BTRIM(l."dateExpiration"::text),
            ''
        )::timestamp::date
            AS fecha_vencimiento,

        UPPER(l."currency") AS moneda,

        l."amount"::numeric AS importe,

        l."state",
        l."situation"

    FROM master_cobranzas_letras_generadas l

    INNER JOIN canjes_unicos c
        ON c.cia = l."ciaAcronym"
       AND c.exchange_number =
           l."exchangeNumber"::text

    CROSS JOIN params p

    WHERE UPPER(l."stateExchange") = 'CONFIRMADO'

      AND NULLIF(
            BTRIM(l."dateAccounting"::text),
            ''
          )::timestamp::date
          <= p.fecha_corte
),

/* =========================================================
   17. CANJES QUE REALMENTE TIENEN LETRAS CONFIRMADAS

   Se usan para excluir la factura.
   ========================================================= */
canjes_activos AS (
    SELECT DISTINCT
        cb.cia,
        cb.exchange_number,
        cb."transBaseDocId",
        cb."transBaseDocLine"

    FROM canjes_base cb

    INNER JOIN (
        SELECT DISTINCT
            cia,
            exchange_number
        FROM letras_base
    ) l
        ON l.cia = cb.cia
       AND l.exchange_number =
           cb.exchange_number
),

/* =========================================================
   18. FACTURA ORIGEN + VENDEDOR DEL CANJE

   El vendedor de la letra sale del documento origen,
   no del maestro actual del cliente.
   ========================================================= */
origen_canje_candidates AS (
    SELECT
        ca.cia,
        ca.exchange_number,

        REGEXP_REPLACE(
            v."document",
            '\s+',
            '',
            'g'
        ) AS documento_origen,

        REPLACE(
            REGEXP_REPLACE(
                v."document",
                '\s+',
                '',
                'g'
            ),
            '/',
            '-'
        ) AS doc_ref,

        v."codeSeller" AS vendedor

    FROM canjes_activos ca

    INNER JOIN master_cobranzas_documentos_venta v
        ON v."ciaAcronym" = ca.cia
       AND v."transDocId" =
           ca."transBaseDocId"
       AND v."transDocLine" =
           ca."transBaseDocLine"

    WHERE UPPER(v."typeDocAcronym")
          IN ('FA','BV')
),

origen_canje AS (
    SELECT DISTINCT ON (
        cia,
        exchange_number
    )
        cia,
        exchange_number,
        doc_ref,
        vendedor

    FROM origen_canje_candidates

    ORDER BY
        cia,
        exchange_number,
        documento_origen
),

/* =========================================================
   19. FACTURAS ABIERTAS

   Regla V2:
   factura - pagos - NA disponibles.

   IMPORTANTE: un canje no elimina automáticamente la factura.
   Si el canje/pagos cubrieron solo parte del documento, se
   conserva el saldo residual.
   ========================================================= */
facturas AS (
    SELECT
        f.cia,

        CASE
            WHEN f.cia = 'RJ'
                THEN 'REPUESTOS JAPONESES S.A.'
            WHEN f.cia = 'IC'
                THEN 'IMPORTACIONES CATUSITA S.A.'
            WHEN f.cia = 'TG'
                THEN 'CATUSITA TIRE GROUP S.A.'
            WHEN f.cia = 'FC'
                THEN 'FC DIESEL S.A.'
            ELSE f.cia
        END AS empresa,

        1 AS orden_tipo,

        'FACTURA'::text AS tipo,

        f.documento,

        /* DocRef real del documento: OV/2026-xxxxxx */
        NULLIF(
            REGEXP_REPLACE(
                COALESCE(f.referencia,''),
                '\s+',
                '',
                'g'
            ),
            ''
        ) AS doc_ref,

        f.fecha_emision AS fecha_documento,

        f.fecha_vencimiento,

        f.moneda,

        f.importe,

        f.saldo_final AS saldo,

        'CA'::text AS st,

        NULL::text AS banco,

        CASE
            WHEN f.fecha_vencimiento < p.fecha_corte
                THEN 'VENCIDO'
            ELSE 'POR VENCER'
        END AS estado,

        NULL::text AS numero_unico,

        f.vendedor::text AS vendedor

    FROM facturas_calculadas f
    CROSS JOIN params p

    WHERE f.saldo_final > p.tolerancia_abs
),

/* =========================================================
   20. NA ABIERTAS

   Solo el excedente que ya no pudo consumirse
   contra la factura de referencia.
   ========================================================= */
notas_abiertas AS (
    SELECT
        n.cia,

        CASE
            WHEN n.cia = 'RJ'
                THEN 'REPUESTOS JAPONESES S.A.'
            WHEN n.cia = 'IC'
                THEN 'IMPORTACIONES CATUSITA S.A.'
            WHEN n.cia = 'TG'
                THEN 'CATUSITA TIRE GROUP S.A.'
            WHEN n.cia = 'FC'
                THEN 'FC DIESEL S.A.'
            ELSE n.cia
        END AS empresa,

        2 AS orden_tipo,

        'NOTA CREDITO'::text AS tipo,

        n.documento,

        n.referencia AS doc_ref,

        n.fecha_emision
            AS fecha_documento,

        n.fecha_vencimiento,

        n.moneda,

        /* Importe original */
        n.importe,

        /* Saldo todavía disponible a favor */
        -n.credito_abierto AS saldo,

        'CA'::text AS st,

        NULL::text AS banco,

        CASE
            WHEN n.fecha_vencimiento
                 < p.fecha_corte
            THEN 'VENCIDO'

            ELSE 'POR VENCER'
        END AS estado,

        NULL::text AS numero_unico,

        n.vendedor::text AS vendedor

    FROM notas_calculadas n
    CROSS JOIN params p

    WHERE n.credito_abierto
          > p.tolerancia_abs
),

/* =========================================================
   21. LETRAS + PAGOS
   ========================================================= */
letras_calculadas AS (
    SELECT
        l.*,

        CASE
            WHEN l.moneda = 'USD'
                THEN COALESCE(p.monto_fc, 0)
            ELSE COALESCE(p.monto_local, 0)
        END AS monto_pagado,

        o.doc_ref,
        o.vendedor

    FROM letras_base l

    LEFT JOIN pagos p
        ON p.cia = l.cia
       AND p."transDocId" =
           l."transDocId"
       AND p."transDocLine" =
           l."transDocLine"

    LEFT JOIN origen_canje o
        ON o.cia = l.cia
       AND o.exchange_number =
           l.exchange_number
),

/* =========================================================
   22. LETRAS ABIERTAS
   ========================================================= */
letras_abiertas_base AS (
    SELECT
        l.*
    FROM letras_calculadas l
    CROSS JOIN params p

    WHERE ABS(l.monto_pagado)
          < p.tolerancia_abs
),

letras AS (
    SELECT
        l.cia,

        CASE
            WHEN l.cia = 'RJ'
                THEN 'REPUESTOS JAPONESES S.A.'
            WHEN l.cia = 'IC'
                THEN 'IMPORTACIONES CATUSITA S.A.'
            WHEN l.cia = 'TG'
                THEN 'CATUSITA TIRE GROUP S.A.'
            WHEN l.cia = 'FC'
                THEN 'FC DIESEL S.A.'
            ELSE l.cia
        END AS empresa,

        3 AS orden_tipo,

        'LETRA'::text AS tipo,

        l.documento,

        l.doc_ref,

        l.fecha_documento,
        l.fecha_vencimiento,

        l.moneda,

        l.importe,
        l.importe AS saldo,

        CASE
            WHEN UPPER(l."state")
                 = 'P-PROTESTADA'
            THEN 'PR'

            WHEN UPPER(l."state")
                 = 'O-DEPOSITADA'
            THEN 'CO'

            WHEN UPPER(l."state")
                 = 'C-CONFIRMADA'
            THEN 'CA'

            ELSE 'CA'
        END AS st,

        NULL::text AS banco,

        CASE
            WHEN l.fecha_vencimiento
                 < p.fecha_corte
            THEN 'VENCIDO'

            ELSE 'POR VENCER'
        END AS estado,

        NULL::text AS numero_unico,

        COALESCE(
            l.vendedor,
            c."codeSeller"
        )::text AS vendedor

    FROM letras_abiertas_base l

    CROSS JOIN params p
    CROSS JOIN cliente c
),

/* =========================================================
   23. NC F080

   Ajuste positivo relacionado a una letra.
   ========================================================= */
nc_f080_base AS (
    SELECT
        d.cia,
        d."transDocId",
        d."transDocLine",

        d.documento,
        d.referencia,

        d.fecha_emision,
        d.fecha_vencimiento,

        d.moneda,
        d.importe,

        REGEXP_REPLACE(
            REGEXP_REPLACE(
                UPPER(d.referencia),
                '^(LE|LT)[/ -]*',
                ''
            ),
            '[^A-Z0-9]',
            '',
            'g'
        ) AS letra_ref_norm

    FROM documentos d

    WHERE d.tipo_documento = 'NC'
      AND UPPER(d.documento)
          LIKE 'NC/F080-%%'
      AND d.importe > 0
),

/* =========================================================
   24. NC F080 SOLO SI SU LETRA SIGUE ABIERTA

   Esto elimina F080 históricos que ya no pertenecen
   al estado de cuenta.
   ========================================================= */
nc_f080 AS (
    SELECT
        n.cia,

        CASE
            WHEN n.cia = 'RJ'
                THEN 'REPUESTOS JAPONESES S.A.'
            WHEN n.cia = 'IC'
                THEN 'IMPORTACIONES CATUSITA S.A.'
            WHEN n.cia = 'TG'
                THEN 'CATUSITA TIRE GROUP S.A.'
            WHEN n.cia = 'FC'
                THEN 'FC DIESEL S.A.'
            ELSE n.cia
        END AS empresa,

        4 AS orden_tipo,

        'NC F080'::text AS tipo,

        n.documento,

        n.referencia AS doc_ref,

        n.fecha_emision
            AS fecha_documento,

        n.fecha_vencimiento,

        n.moneda,

        n.importe,
        n.importe AS saldo,

        'CA'::text AS st,

        NULL::text AS banco,

        CASE
            WHEN n.fecha_vencimiento
                 < p.fecha_corte
            THEN 'VENCIDO'

            ELSE 'POR VENCER'
        END AS estado,

        NULL::text AS numero_unico,

        COALESCE(
            l.vendedor,
            c."codeSeller"
        )::text AS vendedor

    FROM nc_f080_base n

    INNER JOIN letras_abiertas_base l
        ON l.cia = n.cia
       AND l.letra_norm =
           n.letra_ref_norm

    CROSS JOIN params p
    CROSS JOIN cliente c
),

/* =========================================================
   AT / ANTICIPOS

   V2 NO incorpora AT al resultado final.

   Motivo: en el snapshot existen múltiples headers Estandar
   sin detalle que NO aparecen como AT abierto en el reporte
   oficial. La combinación cabecera + detalle no permite
   distinguirlos con seguridad. Incluir "header sin detalle"
   genera falsos positivos.

   Se mantiene AT como gap explícito hasta identificar la
   fuente/regla de saldo abierto del anticipo.
   ========================================================= */

/* =========================================================
   25. ESTADO DE CUENTA CONSOLIDADO
   ========================================================= */
estado_cuenta AS (

    SELECT *
    FROM facturas

    UNION ALL

    SELECT *
    FROM notas_abiertas

    UNION ALL

    SELECT *
    FROM letras

    UNION ALL

    SELECT *
    FROM nc_f080
)

/* =========================================================
   26. RESULTADO FINAL
   ========================================================= */

SELECT
    empresa,
    tipo,
    documento,
    doc_ref,

    fecha_documento,
    fecha_vencimiento,

    moneda,

    ROUND(importe,2)
        AS importe,

    ROUND(saldo,2)
        AS saldo,

    st,
    banco,
    estado,
    numero_unico,
    vendedor

FROM estado_cuenta

ORDER BY
    empresa,
    orden_tipo,
    fecha_vencimiento,
    documento;