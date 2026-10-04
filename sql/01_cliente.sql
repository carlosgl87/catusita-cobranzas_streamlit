WITH params AS (
    SELECT
        %(id_cliente)s::text AS id_cliente,
        %(fecha_corte)s::date AS fecha_corte
),

ultimo_vendedor AS (
    SELECT DISTINCT ON (v."codeClient")
        v."codeClient",
        v."codeSeller"
    FROM master_cobranzas_documentos_venta v
    CROSS JOIN params p
    WHERE UPPER(v."codeClient") = UPPER(p.id_cliente)
      AND v."dateAccounting"::date <= p.fecha_corte
      AND COALESCE(
            NULLIF(UPPER(BTRIM(v."typeDocAcronym")), ''),
            UPPER(SPLIT_PART(REGEXP_REPLACE(COALESCE(v."document",''), '\s+', '', 'g'), '/', 1))
          ) IN ('FA','BV')
    ORDER BY
        v."codeClient",
        v."dateAccounting"::date DESC,
        v."transDocId" DESC,
        v."transDocLine" DESC
),

cliente AS (
    SELECT DISTINCT ON (c."codeClient")
        c.*
    FROM master_cobranzas_clientes c
    CROSS JOIN params p
    LEFT JOIN ultimo_vendedor uv
        ON uv."codeClient" = c."codeClient"
    WHERE UPPER(c."codeClient") = UPPER(p.id_cliente)
    ORDER BY
        c."codeClient",
        CASE WHEN c."codeSeller" = uv."codeSeller" THEN 0 ELSE 1 END,
        c."codeSeller" DESC
)

SELECT *
FROM cliente;
