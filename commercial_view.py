import pandas as pd
import streamlit as st


SEGMENT_ORDER = {
    "🔥 Alta oportunidad": 0,
    "📈 Oportunidad de crecimiento": 1,
    "🌱 Desarrollar relación": 2,
    "⛔ No activar": 3,
}


SEGMENT_META = {
    "🔥 Alta oportunidad": {
        "description": "Clientes consolidados con alta línea disponible para activar comercialmente.",
    },
    "📈 Oportunidad de crecimiento": {
        "description": "Clientes consolidados con capacidad disponible para ampliar ticket o hacer cross-sell.",
    },
    "🌱 Desarrollar relación": {
        "description": "Clientes con capacidad disponible, pero todavía con poca historia crediticia.",
    },
    "⛔ No activar": {
        "description": "Clientes que no conviene activar en campañas de crédito en este momento.",
    },
}


def _safe_number(series):
    return pd.to_numeric(series, errors="coerce").fillna(0.0)


def _prepare_portfolio(df):
    data = df.copy()
    if data.empty:
        return data, {"p40": 0.0, "p75": 0.0}

    numeric_columns = [
        "linea_credito_sugerida",
        "linea_utilizada",
        "linea_disponible",
        "pct_utilizacion",
        "letras_protestadas_abiertas",
        "compras_12m",
        "compras_12m_previos",
        "variacion_compras_pct",
        "operaciones_12m",
    ]
    for column in numeric_columns:
        if column in data.columns:
            data[column] = _safe_number(data[column])

    if "poca_historia_crediticia" in data.columns:
        data["poca_historia_crediticia"] = (
            data["poca_historia_crediticia"].fillna(False).astype(bool)
        )
    else:
        data["poca_historia_crediticia"] = False

    data["vendedor_nombre"] = data.get(
        "vendedor_nombre",
        pd.Series(index=data.index, dtype="object"),
    ).fillna("Sin vendedor")
    data["zona"] = data.get(
        "zona",
        pd.Series(index=data.index, dtype="object"),
    ).fillna("Sin zona")
    data["nombre_cliente"] = data.get(
        "nombre_cliente",
        pd.Series(index=data.index, dtype="object"),
    ).fillna(data["id_cliente"])

    if "dias_sin_compra" in data.columns:
        data["dias_sin_compra"] = pd.to_numeric(
            data["dias_sin_compra"], errors="coerce"
        )

    sugerida = data["linea_credito_sugerida"].clip(lower=0)
    disponible = data["linea_disponible"]
    denominador = sugerida.where(sugerida > 0)
    data["pct_linea_libre"] = (
        (disponible.clip(lower=0) / denominador) * 100
    ).fillna(0).clip(upper=999)

    # Los percentiles se calculan sobre toda la cartera elegible, no sobre el
    # vendedor filtrado. Así un cliente mantiene el mismo segmento al cambiar
    # de filtro.
    elegibles = data[
        (data["linea_disponible"] > 0)
        & (data["linea_credito_sugerida"] > 0)
        & (data["letras_protestadas_abiertas"] <= 0)
    ]["linea_disponible"]

    if elegibles.empty:
        p40 = p75 = 0.0
    else:
        p40 = float(elegibles.quantile(0.40))
        p75 = float(elegibles.quantile(0.75))

    def profile(row):
        if (
            row["letras_protestadas_abiertas"] > 0
            or row["linea_credito_sugerida"] <= 0
        ):
            return "Restringido"
        if row["poca_historia_crediticia"]:
            return "En desarrollo"
        return "Consolidado"

    def capacity(row):
        amount = row["linea_disponible"]
        if amount <= 0:
            return "Sin capacidad"
        if amount >= p75:
            return "Alta"
        if amount >= p40:
            return "Media"
        return "Baja"

    def segment(row):
        if (
            row["linea_disponible"] <= 0
            or row["linea_credito_sugerida"] <= 0
            or row["letras_protestadas_abiertas"] > 0
        ):
            return "⛔ No activar"
        if row["poca_historia_crediticia"]:
            return "🌱 Desarrollar relación"
        if row["linea_disponible"] >= p75:
            return "🔥 Alta oportunidad"
        return "📈 Oportunidad de crecimiento"

    def action(row):
        segment_name = row["segmento"]
        days = row.get("dias_sin_compra", None)
        inactive = pd.notna(days) and float(days) >= 45

        if segment_name == "⛔ No activar":
            return "No activar campaña de crédito"
        if segment_name == "🌱 Desarrollar relación":
            return "Venta controlada para generar historia"
        if segment_name == "🔥 Alta oportunidad":
            if inactive:
                return "Reactivación prioritaria"
            return "Campaña prioritaria / ampliar pedido"
        if inactive:
            return "Reactivación / cross-sell"
        return "Cross-sell / mayor ticket"

    data["perfil_crediticio"] = data.apply(profile, axis=1)
    data["nivel_capacidad"] = data.apply(capacity, axis=1)
    data["segmento"] = data.apply(segment, axis=1)
    data["accion_sugerida"] = data.apply(action, axis=1)
    data["segment_rank"] = data["segmento"].map(SEGMENT_ORDER).fillna(99)

    return data, {"p40": p40, "p75": p75}


def _format_money(value, decimals=0):
    try:
        return f"US$ {float(value):,.{decimals}f}"
    except Exception:
        return "US$ 0"


def _format_days(value):
    if value is None or pd.isna(value):
        return "Sin dato"
    try:
        return f"{int(value)} días"
    except Exception:
        return "Sin dato"


@st.cache_data(ttl=300, show_spinner=False)
def _load_portfolio(_run_query):
    return _run_query("05_oportunidades_comerciales.sql", {})


def _table_from_segment(segment_df, show_seller):
    ranked = segment_df.sort_values(
        ["linea_disponible", "compras_12m"],
        ascending=[False, False],
    ).copy()

    columns = ["nombre_cliente", "id_cliente"]
    if show_seller:
        columns.append("vendedor_nombre")
    columns += [
        "zona",
        "linea_credito_sugerida",
        "linea_utilizada",
        "linea_disponible",
        "pct_linea_libre",
        "compras_12m",
        "dias_sin_compra",
        "accion_sugerida",
    ]
    columns = [column for column in columns if column in ranked.columns]

    return ranked[columns].rename(
        columns={
            "nombre_cliente": "Cliente",
            "id_cliente": "Código",
            "vendedor_nombre": "Vendedor",
            "zona": "Zona",
            "linea_credito_sugerida": "Línea sugerida",
            "linea_utilizada": "Utilizada",
            "linea_disponible": "Disponible",
            "pct_linea_libre": "% libre",
            "compras_12m": "Compras 12m",
            "dias_sin_compra": "Días sin compra",
            "accion_sugerida": "Acción sugerida",
        }
    )


def _render_segment_table(segment_name, segment_df, show_seller, collapsed=False):
    amount = segment_df["linea_disponible"].clip(lower=0).sum()
    title = (
        f"{segment_name} · {len(segment_df):,} clientes · "
        f"{_format_money(amount)} disponibles"
    )

    def render_content():
        st.caption(SEGMENT_META[segment_name]["description"])
        if segment_df.empty:
            st.info("No hay clientes en este segmento para los filtros seleccionados.")
            return

        table = _table_from_segment(segment_df, show_seller=show_seller)
        st.dataframe(
            table,
            use_container_width=True,
            hide_index=True,
            height=min(520, 38 + max(len(table), 1) * 35),
            column_config={
                "Línea sugerida": st.column_config.NumberColumn(format="US$ %.2f"),
                "Utilizada": st.column_config.NumberColumn(format="US$ %.2f"),
                "Disponible": st.column_config.NumberColumn(format="US$ %.2f"),
                "% libre": st.column_config.NumberColumn(format="%.1f%%"),
                "Compras 12m": st.column_config.NumberColumn(format="US$ %.2f"),
                "Días sin compra": st.column_config.NumberColumn(format="%d"),
            },
        )

    if collapsed:
        with st.expander(title, expanded=False):
            render_content()
    else:
        st.markdown(f"### {title}")
        render_content()


def _render_client_detail(client_row):
    name = str(client_row.get("nombre_cliente", client_row.get("id_cliente", "Cliente")))
    code = str(client_row.get("id_cliente", ""))
    seller = str(client_row.get("vendedor_nombre", "Sin vendedor"))
    zone = str(client_row.get("zona", "Sin zona"))
    segment = str(client_row.get("segmento", ""))
    profile = str(client_row.get("perfil_crediticio", ""))
    capacity = str(client_row.get("nivel_capacidad", ""))

    st.markdown(f"### {name}")
    st.caption(f"Código {code} · Vendedor: {seller} · Zona: {zone}")

    m1, m2, m3, m4 = st.columns(4)
    m1.metric("Línea sugerida", _format_money(client_row.get("linea_credito_sugerida", 0)))
    m2.metric("Utilizada", _format_money(client_row.get("linea_utilizada", 0)))
    m3.metric(
        "Disponible",
        _format_money(max(float(client_row.get("linea_disponible", 0)), 0)),
    )
    m4.metric("% libre", f"{float(client_row.get('pct_linea_libre', 0)):.1f}%")

    with st.container(border=True):
        c1, c2, c3 = st.columns([1.05, 1, 1.2])
        with c1:
            st.markdown("**Segmento**")
            st.markdown(segment)
            st.caption(f"Perfil: {profile} · Capacidad: {capacity}")
        with c2:
            st.markdown("**Comportamiento comercial**")
            st.write(
                f"Compras últimos 12m: **{_format_money(client_row.get('compras_12m', 0))}**"
            )
            st.write(
                f"Días sin compra: **{_format_days(client_row.get('dias_sin_compra'))}**"
            )
        with c3:
            st.markdown("**Acción sugerida**")
            st.write(str(client_row.get("accion_sugerida", "-")))


def render_commercial_view(run_query):
    st.markdown("## Oportunidades comerciales por crédito")
    st.caption(
        "Prioriza campañas comerciales usando la línea de crédito disponible, "
        "el perfil crediticio y el comportamiento reciente de compra."
    )

    try:
        with st.spinner("Cargando cartera comercial..."):
            raw = _load_portfolio(run_query)
    except Exception as exc:
        st.error("No se pudo cargar analytics_cartera_credito_diaria.")
        st.exception(exc)
        return

    if raw.empty:
        st.info("No hay registros disponibles en analytics_cartera_credito_diaria.")
        return

    data, thresholds = _prepare_portfolio(raw)
    fecha = data["fecha_calculo"].max() if "fecha_calculo" in data.columns else None
    if pd.notna(fecha):
        fecha_text = pd.to_datetime(fecha).strftime("%d/%m/%Y")
        st.caption(f"Corte de cartera: {fecha_text}")

    with st.container(border=True):
        f1, f2 = st.columns([1.15, 2.0])
        vendedores = ["Todos"] + sorted(
            data["vendedor_nombre"].dropna().astype(str).unique().tolist()
        )
        with f1:
            vendedor = st.selectbox("Vendedor", vendedores)
        with f2:
            buscar = st.text_input(
                "Buscar cliente",
                placeholder="Nombre o código",
            )

    filtered = data.copy()
    if vendedor != "Todos":
        filtered = filtered[filtered["vendedor_nombre"] == vendedor]
    if buscar.strip():
        needle = buscar.strip().casefold()
        filtered = filtered[
            filtered["nombre_cliente"]
            .astype(str)
            .str.casefold()
            .str.contains(needle, regex=False)
            | filtered["id_cliente"]
            .astype(str)
            .str.casefold()
            .str.contains(needle, regex=False)
        ]

    positive_available = filtered["linea_disponible"].clip(lower=0)
    high = filtered[filtered["segmento"] == "🔥 Alta oportunidad"]

    c1, c2, c3, c4 = st.columns(4)
    c1.metric("Línea disponible total", _format_money(positive_available.sum()))
    c2.metric("Clientes con línea", int((filtered["linea_disponible"] > 0).sum()))
    c3.metric("Clientes alta oportunidad", f"{len(high):,}")
    c4.metric(
        "Línea alta oportunidad",
        _format_money(high["linea_disponible"].clip(lower=0).sum()),
    )

    st.caption(
        "Umbrales dinámicos de capacidad sobre la cartera elegible: "
        f"media desde {_format_money(thresholds['p40'])} y "
        f"alta desde {_format_money(thresholds['p75'])}."
    )

    if filtered.empty:
        st.warning("No hay clientes que coincidan con los filtros seleccionados.")
        return

    if buscar.strip() and len(filtered) == 1:
        _render_client_detail(filtered.iloc[0])
        return

    left, right = st.columns([1.45, 1], gap="large")

    with left:
        st.markdown("### Top oportunidades de la cartera")
        top = filtered[
            filtered["segmento"].isin(
                ["🔥 Alta oportunidad", "📈 Oportunidad de crecimiento"]
            )
        ].sort_values(
            ["segment_rank", "linea_disponible", "compras_12m"],
            ascending=[True, False, False],
        ).head(8)

        if top.empty:
            st.info("No hay oportunidades activables para los filtros seleccionados.")
        else:
            top_table = top[
                [
                    "nombre_cliente",
                    "segmento",
                    "linea_disponible",
                    "dias_sin_compra",
                    "accion_sugerida",
                ]
            ].rename(
                columns={
                    "nombre_cliente": "Cliente",
                    "segmento": "Segmento",
                    "linea_disponible": "Disponible",
                    "dias_sin_compra": "Días sin compra",
                    "accion_sugerida": "Acción sugerida",
                }
            )
            st.dataframe(
                top_table,
                use_container_width=True,
                hide_index=True,
                height=min(360, 38 + len(top_table) * 35),
                column_config={
                    "Disponible": st.column_config.NumberColumn(format="US$ %.0f"),
                    "Días sin compra": st.column_config.NumberColumn(format="%d"),
                },
            )

    with right:
        st.markdown("### Segmentación de cartera")
        segment_summary = (
            filtered.groupby("segmento", as_index=False)
            .agg(
                Clientes=("id_cliente", "count"),
                Linea_disponible=(
                    "linea_disponible",
                    lambda x: x.clip(lower=0).sum(),
                ),
            )
        )
        segment_summary["orden"] = (
            segment_summary["segmento"].map(SEGMENT_ORDER).fillna(99)
        )
        segment_summary = segment_summary.sort_values("orden")
        st.dataframe(
            segment_summary[["segmento", "Clientes", "Linea_disponible"]].rename(
                columns={
                    "segmento": "Segmento",
                    "Linea_disponible": "Línea disponible",
                }
            ),
            use_container_width=True,
            hide_index=True,
            column_config={
                "Línea disponible": st.column_config.NumberColumn(format="US$ %.0f"),
            },
        )

    st.divider()
    st.markdown("## Clientes para campaña")
    st.caption(
        "La cartera se separa por segmento para que cada grupo tenga una acción comercial clara."
    )

    show_seller = vendedor == "Todos"
    for segment_name in SEGMENT_ORDER:
        segment_df = filtered[filtered["segmento"] == segment_name].copy()
        collapsed = segment_name in ["🌱 Desarrollar relación", "⛔ No activar"]
        _render_segment_table(
            segment_name,
            segment_df,
            show_seller=show_seller,
            collapsed=collapsed,
        )

    export_columns = [
        "segmento",
        "nombre_cliente",
        "id_cliente",
        "vendedor_nombre",
        "zona",
        "linea_credito_sugerida",
        "linea_utilizada",
        "linea_disponible",
        "pct_linea_libre",
        "perfil_crediticio",
        "nivel_capacidad",
        "compras_12m",
        "dias_sin_compra",
        "accion_sugerida",
    ]
    export_columns = [column for column in export_columns if column in filtered.columns]
    csv = filtered[export_columns].to_csv(index=False).encode("utf-8-sig")
    st.download_button(
        "Descargar cartera filtrada",
        data=csv,
        file_name="oportunidades_comerciales_credito.csv",
        mime="text/csv",
    )

    with st.expander("Cómo se construye la segmentación"):
        st.markdown(
            """
- **Alta oportunidad:** cliente sin protestos abiertos, con historia suficiente y línea disponible en el cuartil superior de la cartera elegible.
- **Oportunidad de crecimiento:** cliente consolidado con línea disponible positiva por debajo del cuartil superior.
- **Desarrollar relación:** tiene capacidad disponible, pero todavía cuenta con poca historia crediticia. No se considera un cliente malo.
- **No activar:** no tiene línea disponible, su línea sugerida es cero o tiene protestos abiertos.

La capacidad **Alta / Media / Baja** se calcula con percentiles de toda la cartera elegible (P75 y P40), no con montos arbitrarios. El historial de compras y los días sin compra orientan la acción comercial, pero no cambian por ahora la regla crediticia.
            """
        )
