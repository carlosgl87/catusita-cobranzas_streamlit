import json
import os
from datetime import datetime
from pathlib import Path
from zoneinfo import ZoneInfo

import pandas as pd
import psycopg2
import requests
import streamlit as st
from dotenv import load_dotenv

from commercial_view import render_commercial_view


# ==========================================================
# CONFIGURACIÓN GENERAL
# ==========================================================

load_dotenv(override=True)

LIMA_TZ = ZoneInfo("America/Lima")
HOY_LIMA = datetime.now(LIMA_TZ).date()

st.set_page_config(
    page_title="Catusita · Evaluación de crédito",
    page_icon="💳",
    layout="wide",
    initial_sidebar_state="collapsed",
)

st.markdown(
    """
    <style>
        .block-container {
            padding-top: 1.2rem;
            padding-bottom: 2.5rem;
            max-width: 1550px;
        }
        [data-testid="stSidebar"] {
            display: none;
        }
        [data-testid="collapsedControl"] {
            display: none;
        }
        .client-label {
            color: #5f6b7a;
            font-size: .85rem;
            margin-bottom: .15rem;
        }
        .client-value {
            font-size: 1.18rem;
            font-weight: 700;
            color: #111827;
        }
        .credit-card-title {
            font-size: 1.05rem;
            font-weight: 800;
            margin-bottom: .1rem;
        }
        .credit-card-subtitle {
            color: #6b7280;
            font-size: .82rem;
            margin-bottom: .75rem;
        }
        .metric-line {
            display:flex;
            justify-content:space-between;
            gap:1rem;
            padding:.42rem 0;
            border-bottom:1px solid #edf0f4;
            font-size:.91rem;
        }
        .metric-line:last-child { border-bottom:none; }
        .metric-name { color:#465268; }
        .metric-value { color:#111827; font-weight:700; white-space:nowrap; }
        .suggested-box {
            border:1px solid #d9efe2;
            background:#f3fbf6;
            border-radius:.65rem;
            padding:.9rem 1rem;
            margin:.35rem 0 .85rem 0;
        }
        .suggested-label { color:#536174; font-size:.8rem; }
        .suggested-value { color:#079455; font-size:1.75rem; font-weight:800; }
        .risk-pill {
            display:inline-block;
            border-radius:999px;
            padding:.22rem .62rem;
            font-weight:700;
            font-size:.78rem;
            background:#eef7f0;
            color:#16794b;
        }
        .factor-good { color:#1d6f42; margin:.22rem 0; font-size:.88rem; }
        .factor-warn { color:#9a6700; margin:.22rem 0; font-size:.88rem; }
        .small-note { color:#6b7280; font-size:.77rem; }
        div[data-testid="stMetricValue"] { font-size: 1.55rem; }
        div[data-testid="stDataFrame"] { border-radius: .6rem; overflow: hidden; }
    </style>
    """,
    unsafe_allow_html=True,
)


# ==========================================================
# CONEXIÓN A POSTGRESQL / SQL
# ==========================================================

BASE_DIR = Path(__file__).resolve().parent
SQL_DIR = BASE_DIR / "sql"


def get_connection():
    return psycopg2.connect(
        host=os.getenv("DB_HOST"),
        port=os.getenv("DB_PORT", "5432"),
        dbname=os.getenv("DB_NAME"),
        user=os.getenv("DB_USER"),
        password=os.getenv("DB_PASSWORD"),
        sslmode=os.getenv("DB_SSLMODE", "require"),
        connect_timeout=15,
    )


def load_sql(filename):
    path = SQL_DIR / filename
    if not path.exists():
        raise FileNotFoundError(f"No se encontró el archivo SQL: {path}")
    return path.read_text(encoding="utf-8")


def run_query(filename, params):
    conn = get_connection()
    try:
        return pd.read_sql_query(load_sql(filename), conn, params=params)
    finally:
        conn.close()


# ==========================================================
# API CATUSITA
# ==========================================================

API_BASE_URL = os.getenv(
    "CATUSITA_API_BASE_URL",
    "http://api.catusita.com:8084",
).rstrip("/")


def get_catusita_token():
    static_token = os.getenv("CATUSITA_BEARER_TOKEN", "").strip()
    if static_token:
        return static_token

    api_user = os.getenv("API_USER", "").strip()
    api_pass = os.getenv("API_PASS", "").strip()

    if not api_user or not api_pass:
        raise RuntimeError(
            "Faltan API_USER y API_PASS (o CATUSITA_BEARER_TOKEN) en el .env."
        )

    response = requests.post(
        f"{API_BASE_URL}/api/accounts/login",
        json={"userCode": api_user, "password": api_pass},
        timeout=30,
    )
    response.raise_for_status()

    payload = response.json()
    try:
        return payload["data"]["userToken"]
    except (KeyError, TypeError) as exc:
        raise RuntimeError("El login no devolvió data.userToken.") from exc


def fetch_account_statement(customer_code):
    token = get_catusita_token()
    response = requests.get(
        f"{API_BASE_URL}/api/customer-account-statements/{customer_code}",
        headers={
            "Authorization": f"Bearer {token}",
            "Accept": "application/json, text/plain, */*",
        },
        timeout=60,
    )
    response.raise_for_status()

    payload = response.json()
    if isinstance(payload, dict):
        payload = payload.get("data", payload)

    if payload is None:
        payload = []
    if not isinstance(payload, list):
        raise RuntimeError("El API de estado de cuenta no devolvió una lista de documentos.")

    return pd.DataFrame(payload)


def normalize_statement_api(df):
    if df.empty:
        return pd.DataFrame(
            columns=[
                "empresa", "tipo", "documento", "doc_ref",
                "fecha_documento", "fecha_vencimiento", "moneda",
                "importe", "saldo", "saldo_usd", "st", "banco",
                "cuenta", "estado", "vendedor", "order",
            ]
        )

    out = pd.DataFrame()
    out["empresa"] = df.get("companyName", "")
    out["documento"] = df.get("documentNumber", "")
    out["doc_ref"] = df.get("reference", "")
    out["fecha_documento"] = df.get("issueDate")
    out["fecha_vencimiento"] = df.get("dueDate")
    out["moneda"] = df.get("currency", "")
    out["importe"] = pd.to_numeric(df.get("amount", 0), errors="coerce").fillna(0)
    out["saldo"] = pd.to_numeric(df.get("balance", 0), errors="coerce").fillna(0)

    if "balanceUsd" in df.columns:
        out["saldo_usd"] = pd.to_numeric(df["balanceUsd"], errors="coerce").fillna(0)
    else:
        out["saldo_usd"] = out["saldo"].where(
            out["moneda"].astype(str).str.upper().eq("USD"),
            0,
        )

    out["st"] = df.get("situation", "")
    out["banco"] = df.get("bank", "")
    out["cuenta"] = df.get("account", "")
    out["estado"] = df.get("status", "")
    out["vendedor"] = df.get("salesPersonCode", "")
    out["order"] = pd.to_numeric(df.get("order", 0), errors="coerce").fillna(0)

    document_type = df.get("documentType", pd.Series([""] * len(df), index=df.index)).astype(str).str.upper()
    document_number = out["documento"].astype(str).str.upper()

    out["tipo"] = document_type
    out.loc[document_type.eq("LT"), "tipo"] = "LETRA"
    out.loc[document_type.eq("NA"), "tipo"] = "NOTA CRÉDITO"
    out.loc[document_type.eq("NC") & document_number.str.startswith("NC/F080"), "tipo"] = "NC F080"

    out = out.sort_values(
        ["empresa", "order", "fecha_vencimiento", "documento"],
        kind="stable",
    ).reset_index(drop=True)

    return out


def calculate_api_metrics(df_estado):
    """Métricas que sí vienen explícitamente del nuevo API de estado de cuenta.

    Importante: no inferimos protestos desde ``situation``/``st`` porque el
    contrato del API no documenta que, por ejemplo, ``PR`` signifique
    "protestada". Los protestos se calculan con las tablas históricas de letras.
    """
    if df_estado.empty:
        return {
            "deuda_actual": 0.0,
            "deuda_vencida": 0.0,
            "obligaciones_abiertas": 0,
            "obligaciones_vencidas": 0,
        }

    saldo_usd = pd.to_numeric(df_estado["saldo_usd"], errors="coerce").fillna(0)
    estado = df_estado["estado"].astype(str).str.upper().str.strip()

    deuda_actual = float(saldo_usd.sum())
    deuda_vencida = float(saldo_usd[(estado.eq("VENCIDO")) & (saldo_usd > 0)].sum())

    positivas = saldo_usd > 0.005
    vencidas_positivas = positivas & estado.eq("VENCIDO")

    return {
        "deuda_actual": round(deuda_actual, 2),
        "deuda_vencida": round(max(deuda_vencida, 0.0), 2),
        "obligaciones_abiertas": int(positivas.sum()),
        "obligaciones_vencidas": int(vencidas_positivas.sum()),
    }


# ==========================================================
# HELPERS
# ==========================================================


def get_column_case_insensitive(df, candidates):
    if df.empty:
        return None
    cols = {str(col).lower(): col for col in df.columns}
    for candidate in candidates:
        if candidate.lower() in cols:
            return cols[candidate.lower()]
    return None


def get_client_value(df, candidates, default="-"):
    col = get_column_case_insensitive(df, candidates)
    if col is None:
        return default
    value = df.iloc[0][col]
    if pd.isna(value):
        return default
    value = str(value).strip()
    return value if value else default


def get_summary_value(df, anio, columna, default=0):
    if df.empty or "anio" not in df.columns or columna not in df.columns:
        return default
    fila = df[pd.to_numeric(df["anio"], errors="coerce") == anio]
    if fila.empty:
        return default
    value = fila.iloc[0][columna]
    if pd.isna(value):
        return default
    try:
        return float(value)
    except Exception:
        return default


def clean_text_value(value):
    if value is None or pd.isna(value) or str(value).lower() == "none":
        return ""
    return value


def format_estado_dataframe(df):
    output = df.copy()
    for col in ["fecha_documento", "fecha_vencimiento"]:
        if col in output.columns:
            output[col] = pd.to_datetime(output[col], errors="coerce").dt.strftime("%d/%m/%Y")
    for col in output.columns:
        if output[col].dtype == "object":
            output[col] = output[col].apply(clean_text_value)
    return output


def credit_value(row, column, default=0):
    if row is None or column not in row.index or pd.isna(row[column]):
        return default
    return row[column]


def usd(value):
    try:
        return f"US$ {float(value):,.2f}"
    except Exception:
        return "US$ 0.00"


def pct(value):
    try:
        return f"{float(value):,.1f}%"
    except Exception:
        return "0.0%"


def metric_html(name, value, alert=False):
    value_color = "#d92d20" if alert else "#111827"
    return (
        '<div class="metric-line">'
        f'<span class="metric-name">{name}</span>'
        f'<span class="metric-value" style="color:{value_color}">{value}</span>'
        "</div>"
    )


def signed_pct(value):
    try:
        value = float(value)
        return f"{value:+.0f}%"
    except Exception:
        return "0%"


def build_capacity_factors(row):
    """Devuelve los ajustes que explican el monto sugerido."""
    factors = []

    factor_specs = [
        ("Antigüedad de la relación", "ajuste_antiguedad_pct"),
        ("Evolución de compras", "ajuste_compras_pct"),
        ("Cumplimiento de obligaciones", "ajuste_vencidas_pct"),
        ("Días de atraso", "ajuste_atraso_pct"),
        ("Historial de protestos", "ajuste_protestos_pct"),
    ]

    for label, field in factor_specs:
        value = float(credit_value(row, field, 0))
        factors.append((label, value))

    return factors


def evaluate_operation(row, monto_solicitado, numero_letras):
    deuda = float(credit_value(row, "deuda_actual", 0))
    capacidad = float(credit_value(row, "capacidad_sugerida", 0))
    protestadas_abiertas = int(credit_value(row, "letras_protestadas_abiertas", 0))
    pct_atrasadas_7d = float(credit_value(row, "pct_obligaciones_atrasadas_7d_12m", 0))
    max_letras_sanas = int(credit_value(row, "max_letras_canje_sano_12m", 0))

    exposicion_resultante = deuda + monto_solicitado
    exceso = max(exposicion_resultante - capacidad, 0)
    monto_por_letra = monto_solicitado / numero_letras if numero_letras else 0

    if protestadas_abiertas > 0:
        resultado = "NO RECOMENDADO"
        detail = "El cliente tiene letras protestadas abiertas. La capacidad sugerida se bloquea en US$ 0."
        tone = "error"
    elif capacidad <= 0:
        resultado = "NO RECOMENDADO"
        detail = "No hay capacidad disponible para una nueva operación en este momento."
        tone = "error"
    elif exposicion_resultante <= capacidad:
        if max_letras_sanas <= 0:
            resultado = "REVISIÓN"
            detail = "El monto está dentro de la capacidad, pero no hay suficiente historial de canjes sanos para validar el número de letras."
            tone = "warning"
        elif numero_letras <= max_letras_sanas:
            resultado = "APROBADO"
            detail = "El monto está dentro de la capacidad sugerida y el número de letras ya fue manejado satisfactoriamente por el cliente."
            tone = "success"
        else:
            resultado = "REVISIÓN"
            detail = f"El monto está dentro de capacidad, pero solicita {numero_letras} letras y el máximo historial sano es {max_letras_sanas}."
            tone = "warning"
    elif (
        exposicion_resultante <= capacidad * 1.10
        and pct_atrasadas_7d <= 10
        and protestadas_abiertas == 0
    ):
        resultado = "REVISIÓN"
        detail = "La exposición queda hasta 10% sobre la capacidad sugerida, pero el historial reciente permite una revisión manual."
        tone = "warning"
    else:
        resultado = "NO RECOMENDADO"
        detail = "La exposición resultante supera la capacidad sugerida en un nivel que no se recomienda aprobar automáticamente."
        tone = "error"

    return {
        "resultado": resultado,
        "detail": detail,
        "tone": tone,
        "deuda": deuda,
        "monto": monto_solicitado,
        "numero_letras": numero_letras,
        "monto_por_letra": monto_por_letra,
        "max_letras_sanas": max_letras_sanas,
        "exposicion_resultante": exposicion_resultante,
        "capacidad": capacidad,
        "exceso": exceso,
    }


# ==========================================================
# NAVEGACIÓN
# ==========================================================

vista_principal = st.radio(
    "Vista",
    ["Evaluación de cliente", "Oportunidades comerciales"],
    horizontal=True,
    label_visibility="collapsed",
    key="vista_principal",
)

if vista_principal == "Oportunidades comerciales":
    render_commercial_view(run_query)
    st.stop()


# ==========================================================
# FORMULARIO DE CONSULTA
# ==========================================================

st.markdown("## Cliente · Crédito y cobranza")
st.caption(
    "Mockup funcional: estado de cuenta actual desde el API de Catusita + histórico y analítica desde PostgreSQL."
)

with st.form("form_consulta", border=True):
    col1, col2, col3 = st.columns([2.2, 1, 0.8])
    with col1:
        cliente_input = st.text_input(
            "Código de cliente",
            value=st.session_state.get("cliente_consultado", "C14479"),
            placeholder="Ej. C14479",
        )
    with col2:
        fecha_corte_input = st.date_input(
            "Fecha de corte / histórico",
            value=st.session_state.get("fecha_corte", HOY_LIMA),
            format="DD/MM/YYYY",
        )
    with col3:
        st.write("")
        st.write("")
        consultar = st.form_submit_button(
            "Consultar",
            use_container_width=True,
            type="primary",
        )

if consultar:
    cliente = cliente_input.strip().upper()
    if not cliente:
        st.warning("Ingresa un código de cliente.")
        st.stop()

    try:
        with st.spinner(f"Consultando {cliente}..."):
            params_base = {
                "id_cliente": cliente,
                "fecha_corte": fecha_corte_input,
            }
            df_cliente = run_query("01_cliente.sql", params_base)
            df_resumen = run_query("02_resumen.sql", params_base)

            df_api_raw = fetch_account_statement(cliente)
            df_estado = normalize_statement_api(df_api_raw)
            api_metrics = calculate_api_metrics(df_estado)

            params_credito = {
                **params_base,
                "deuda_actual": api_metrics["deuda_actual"],
                "deuda_vencida": api_metrics["deuda_vencida"],
            }
            df_credito = run_query("04_credito.sql", params_credito)

        st.session_state["consulta_data"] = {
            "cliente": cliente,
            "fecha_corte": fecha_corte_input,
            "df_cliente": df_cliente,
            "df_resumen": df_resumen,
            "df_estado": df_estado,
            "api_metrics": api_metrics,
            "df_credito": df_credito,
        }
        st.session_state["cliente_consultado"] = cliente
        st.session_state["fecha_corte"] = fecha_corte_input
        st.session_state.pop("evaluacion_resultado", None)

    except Exception as exc:
        st.error("No se pudo completar la consulta.")
        st.exception(exc)
        st.stop()


# ==========================================================
# RENDER
# ==========================================================

consulta = st.session_state.get("consulta_data")
if not consulta:
    st.info("Consulta un cliente para ver el mockup.")
    st.stop()

cliente = consulta["cliente"]
fecha_corte = consulta["fecha_corte"]
df_cliente = consulta["df_cliente"]
df_resumen = consulta["df_resumen"]
df_estado = consulta["df_estado"]
api_metrics = consulta["api_metrics"]
df_credito = consulta["df_credito"]

if df_cliente.empty:
    st.error(f"No se encontró el cliente {cliente} en el maestro local.")
    st.stop()

if fecha_corte != HOY_LIMA:
    st.warning(
        "El resumen histórico usa la fecha seleccionada, pero el nuevo API de estado de cuenta devuelve el saldo actual. "
        "Para una evaluación de crédito consistente, usa la fecha de hoy."
    )

razon_social = get_client_value(
    df_cliente,
    ["nameClient", "clientName", "razonSocial", "businessName", "name"],
    cliente,
)
ruc = get_client_value(
    df_cliente,
    ["ruc", "RUC", "taxId", "taxNumber", "documentNumber", "numberDocument", "rucClient"],
)
vendedor_actual = get_client_value(df_cliente, ["codeSeller", "sellerCode"])
direccion = get_client_value(df_cliente, ["address", "addressClient", "direccion"], "")
telefono = get_client_value(df_cliente, ["phone", "telephone", "telefono"], "")
correo = get_client_value(df_cliente, ["email", "mail", "correo"], "")

credit_row = df_credito.iloc[0] if not df_credito.empty else None
linea_actual = credit_value(credit_row, "linea_credito_actual", 0)

# ----------------------------------------------------------
# Cabecera cliente
# ----------------------------------------------------------

st.divider()
st.markdown(f"# {cliente} - {razon_social}")

head_cols = st.columns([1.15, 1.15, 1.15, 1.15])
for col, label, value in [
    (head_cols[0], "RUC", ruc),
    (head_cols[1], "Vendedor actual", vendedor_actual),
    (head_cols[2], "Línea de crédito", usd(linea_actual)),
    (head_cols[3], "Fecha de corte", fecha_corte.strftime("%d/%m/%Y")),
]:
    with col:
        st.markdown(f'<div class="client-label">{label}</div>', unsafe_allow_html=True)
        st.markdown(f'<div class="client-value">{value}</div>', unsafe_allow_html=True)

info_parts = []
if direccion:
    info_parts.append(f"**Dirección:** {direccion}")
if telefono:
    info_parts.append(f"**Teléfono:** {telefono}")
if correo:
    info_parts.append(f"**Correo:** {correo}")
if info_parts:
    st.markdown("  \n".join(info_parts))

# ----------------------------------------------------------
# Resumen histórico
# ----------------------------------------------------------

st.divider()
st.subheader("Resumen")

anios_disponibles = []
if not df_resumen.empty and "anio" in df_resumen.columns:
    anios_disponibles = (
        pd.to_numeric(df_resumen["anio"], errors="coerce")
        .dropna()
        .astype(int)
        .sort_values(ascending=False)
        .unique()
        .tolist()
    )
anios = anios_disponibles[:2] or [fecha_corte.year, fecha_corte.year - 1]

conceptos = [
    ("Compras", "compras"),
    ("Contado", "contado"),
    ("Devoluciones", "devoluciones"),
    ("Lt. Aceptadas", "letras_aceptadas"),
    ("Lt. Protestadas", "letras_protestadas"),
]

resumen_visual = []
for nombre, prefijo in conceptos:
    fila = {"Concepto": nombre}
    for anio in anios:
        op_sol = get_summary_value(df_resumen, anio, f"{prefijo}_op_sol")
        op_usd = get_summary_value(df_resumen, anio, f"{prefijo}_op_usd")
        fila[f"{anio} #Op"] = int(op_sol + op_usd)
        fila[f"{anio} S/"] = get_summary_value(df_resumen, anio, f"{prefijo}_sol")
        fila[f"{anio} US$"] = get_summary_value(df_resumen, anio, f"{prefijo}_usd")
    resumen_visual.append(fila)

df_resumen_visual = pd.DataFrame(resumen_visual)
column_config_resumen = {
    "Concepto": st.column_config.TextColumn("Concepto"),
}
for anio in anios:
    column_config_resumen[f"{anio} #Op"] = st.column_config.NumberColumn(f"{anio} #Op", format="%d")
    column_config_resumen[f"{anio} S/"] = st.column_config.NumberColumn(f"{anio} S/", format="%.2f")
    column_config_resumen[f"{anio} US$"] = st.column_config.NumberColumn(f"{anio} US$", format="%.2f")

st.dataframe(
    df_resumen_visual,
    use_container_width=True,
    hide_index=True,
    column_config=column_config_resumen,
)

# ----------------------------------------------------------
# Estado de cuenta desde API
# ----------------------------------------------------------

st.divider()
st.subheader("Estado de cuenta")
st.caption("Fuente: nuevo API customer-account-statements de Catusita (saldo actual).")

if df_estado.empty:
    st.success("El API no devuelve documentos abiertos para este cliente.")
else:
    saldo_usd = float(
        pd.to_numeric(df_estado.loc[df_estado["moneda"].astype(str).str.upper().eq("USD"), "saldo"], errors="coerce")
        .fillna(0)
        .sum()
    )
    saldo_sol = float(
        pd.to_numeric(
            df_estado.loc[df_estado["moneda"].astype(str).str.upper().isin(["SOL", "PEN"]), "saldo"],
            errors="coerce",
        )
        .fillna(0)
        .sum()
    )

    total1, total2, total3 = st.columns([1, 1, 2])
    total1.metric("Saldo total USD", f"US$ {saldo_usd:,.2f}")
    total2.metric("Saldo total S/", f"S/ {saldo_sol:,.2f}")
    total3.metric("Saldo normalizado USD", usd(api_metrics["deuda_actual"]))

    df_estado_visual = format_estado_dataframe(df_estado)
    columnas = [
        "tipo", "documento", "doc_ref", "fecha_documento", "fecha_vencimiento",
        "moneda", "importe", "saldo", "st", "banco", "cuenta", "estado", "vendedor",
    ]
    nombres = {
        "tipo": "Tipo",
        "documento": "Documento",
        "doc_ref": "DocRef",
        "fecha_documento": "F.Doc.",
        "fecha_vencimiento": "F.Vcto.",
        "moneda": "Mnd",
        "importe": "Importe",
        "saldo": "Saldo",
        "st": "St",
        "banco": "Banco",
        "cuenta": "Cuenta",
        "estado": "Estado",
        "vendedor": "Vend.",
    }

    for empresa in df_estado_visual["empresa"].dropna().unique().tolist():
        st.markdown(f"### {empresa}")
        df_empresa_original = df_estado_visual[df_estado_visual["empresa"] == empresa].copy()
        columnas_existentes = [c for c in columnas if c in df_empresa_original.columns]
        df_empresa = df_empresa_original[columnas_existentes].rename(columns=nombres)

        config_estado = {}
        for monetary_col in ["Importe", "Saldo"]:
            if monetary_col in df_empresa.columns:
                config_estado[monetary_col] = st.column_config.NumberColumn(monetary_col, format="%.2f")

        row_height = 35
        table_height = 38 + len(df_empresa) * row_height + 5
        st.dataframe(
            df_empresa,
            use_container_width=True,
            hide_index=True,
            height=table_height,
            row_height=row_height,
            column_config=config_estado,
        )

        subtotal_usd = pd.to_numeric(
            df_empresa_original.loc[df_empresa_original["moneda"].astype(str).str.upper().eq("USD"), "saldo"],
            errors="coerce",
        ).fillna(0).sum()
        subtotal_sol = pd.to_numeric(
            df_empresa_original.loc[
                df_empresa_original["moneda"].astype(str).str.upper().isin(["SOL", "PEN"]), "saldo"
            ],
            errors="coerce",
        ).fillna(0).sum()

        subtotal_text = []
        if abs(subtotal_usd) > 0.001:
            subtotal_text.append(f"**Subtotal USD:** US$ {subtotal_usd:,.2f}")
        if abs(subtotal_sol) > 0.001:
            subtotal_text.append(f"**Subtotal S/:** S/ {subtotal_sol:,.2f}")
        if subtotal_text:
            st.markdown(" &nbsp;&nbsp; · &nbsp;&nbsp; ".join(subtotal_text), unsafe_allow_html=True)
        st.write("")

# ----------------------------------------------------------
# NUEVOS CUADROS DEL MOCKUP
# ----------------------------------------------------------

st.divider()
st.markdown("## Evaluación de crédito")

if credit_row is None:
    st.warning("No se pudieron calcular las métricas históricas de crédito para este cliente.")
    st.stop()

card1, card2, card3 = st.columns([1.08, 1.08, 1.02], gap="medium")

# Card 1
with card1:
    with st.container(border=True):
        st.markdown('<div class="credit-card-title" style="color:#175cd3">◉ Análisis de crédito – Catu</div>', unsafe_allow_html=True)
        st.markdown('<div class="credit-card-subtitle">Comportamiento histórico y situación actual</div>', unsafe_allow_html=True)

        deuda_vencida = float(credit_value(credit_row, "deuda_vencida", 0))
        protestadas_abiertas = int(credit_value(credit_row, "letras_protestadas_abiertas", 0))
        letras_protestadas_12m = int(credit_value(credit_row, "letras_protestadas_12m", 0))
        variacion_compras = credit_value(credit_row, "variacion_compras_pct", None)

        if variacion_compras is None or pd.isna(variacion_compras):
            variacion_texto = "Sin base comparable"
        else:
            variacion_texto = signed_pct(variacion_compras)

        metrics_html = "".join(
            [
                metric_html("Máxima exposición últimos 12m", usd(credit_value(credit_row, "maxima_exposicion_12m", 0))),
                metric_html("Mayor operación individual a crédito", usd(credit_value(credit_row, "mayor_operacion_credito", 0))),
                metric_html("Compras últimos 12m", usd(credit_value(credit_row, "compras_12m", 0))),
                metric_html("Variación compras vs. 12m previos", variacion_texto),
                metric_html("Deuda abierta actual", usd(credit_value(credit_row, "deuda_actual", 0))),
                metric_html("Deuda vencida actual", usd(deuda_vencida), alert=deuda_vencida > 0),
                metric_html("% obligaciones con atraso > 7 días (12m)", pct(credit_value(credit_row, "pct_obligaciones_atrasadas_7d_12m", 0))),
                metric_html("Días promedio de atraso (12m)", f"{float(credit_value(credit_row, 'dias_promedio_atraso_12m', 0)):.1f} días"),
                metric_html("Letras protestadas abiertas", str(protestadas_abiertas), alert=protestadas_abiertas > 0),
                metric_html("Letras protestadas (12m)", str(letras_protestadas_12m), alert=letras_protestadas_12m > 0),
                metric_html("Cliente desde", f"{credit_value(credit_row, 'primera_compra', '-')} ({int(credit_value(credit_row, 'antiguedad_anios', 0))} años)"),
            ]
        )
        st.markdown(metrics_html, unsafe_allow_html=True)

# Card 2
with card2:
    with st.container(border=True):
        st.markdown('<div class="credit-card-title" style="color:#079455">♟ Capacidad de crédito sugerida</div>', unsafe_allow_html=True)
        st.markdown('<div class="credit-card-subtitle">Base histórica ajustada por comportamiento real</div>', unsafe_allow_html=True)

        capacidad = float(credit_value(credit_row, "capacidad_sugerida", 0))
        base_capacidad = float(credit_value(credit_row, "capacidad_base", 0))
        ajuste_total = float(credit_value(credit_row, "ajuste_total_pct", 0))
        protestadas_abiertas = int(credit_value(credit_row, "letras_protestadas_abiertas", 0))

        st.markdown(
            f"""
            <div class="suggested-box">
                <div class="suggested-label">Monto sugerido</div>
                <div class="suggested-value">{usd(capacidad)}</div>
            </div>
            """,
            unsafe_allow_html=True,
        )

        st.markdown(
            metric_html("Base: máxima exposición demostrada", usd(base_capacidad))
            + metric_html("Ajuste total aplicado", signed_pct(ajuste_total), alert=ajuste_total < 0),
            unsafe_allow_html=True,
        )

        if protestadas_abiertas > 0:
            st.error("Hay letras protestadas abiertas según el histórico de letras: la regla bloquea la capacidad sugerida en US$ 0.")
        else:
            uso = float(credit_value(credit_row, "pct_capacidad_utilizada", 0))
            st.progress(min(max(uso / 100, 0.0), 1.0))
            st.caption(f"Uso actual de la capacidad sugerida: {pct(uso)}")

        st.markdown("**Cómo se ajustó la base**")
        for label, value in build_capacity_factors(credit_row):
            css_class = "factor-good" if value > 0 else "factor-warn" if value < 0 else "small-note"
            symbol = "+" if value > 0 else "−" if value < 0 else "•"
            display_value = signed_pct(value)
            st.markdown(
                f'<div class="{css_class}">{symbol} {label}: <b>{display_value}</b></div>',
                unsafe_allow_html=True,
            )

        if bool(credit_value(credit_row, "poca_historia_crediticia", False)):
            st.info("Hay menos de 5 obligaciones observadas en 12 meses: el sistema puede reducir la base, pero no aumentarla.")

# Card 3
with card3:
    with st.container(border=True):
        st.markdown('<div class="credit-card-title" style="color:#6938ef">▣ Evaluar nueva operación</div>', unsafe_allow_html=True)
        st.markdown('<div class="credit-card-subtitle">Simula monto y número de letras</div>', unsafe_allow_html=True)

        with st.form("form_evaluacion"):
            monto_solicitado = st.number_input(
                "Monto solicitado (US$)",
                min_value=0.0,
                value=8000.0,
                step=500.0,
                format="%.2f",
            )
            numero_letras = st.number_input(
                "Número de letras",
                min_value=1,
                max_value=24,
                value=4,
                step=1,
            )
            st.caption(f"Monto aproximado por letra: {usd(monto_solicitado / numero_letras if numero_letras else 0)}")

            evaluar = st.form_submit_button(
                "✦ Evaluar operación",
                type="primary",
                use_container_width=True,
            )

        if evaluar:
            st.session_state["evaluacion_resultado"] = evaluate_operation(
                credit_row,
                monto_solicitado,
                int(numero_letras),
            )

        result = st.session_state.get("evaluacion_resultado")
        if result:
            message = f"**{result['resultado']}**  \n{result['detail']}"
            if result["tone"] == "success":
                st.success(message)
            elif result["tone"] == "warning":
                st.warning(message)
            else:
                st.error(message)

            historial_letras = (
                str(result["max_letras_sanas"])
                if result["max_letras_sanas"] > 0
                else "Sin historial sano suficiente"
            )

            result_table = pd.DataFrame(
                [
                    ["Deuda actual", usd(result["deuda"])],
                    ["Nueva operación", usd(result["monto"])],
                    ["Número de letras", str(result["numero_letras"])],
                    ["Monto por letra", usd(result["monto_por_letra"])],
                    ["Máx. letras manejadas sanamente", historial_letras],
                    ["Exposición resultante", usd(result["exposicion_resultante"])],
                    ["Capacidad sugerida", usd(result["capacidad"])],
                    ["Sobre capacidad sugerida", usd(result["exceso"])],
                ],
                columns=["Concepto", "Valor"],
            )
            st.dataframe(result_table, use_container_width=True, hide_index=True)

st.caption(
    "Mockup: la capacidad parte de la máxima exposición demostrada y aplica ajustes por antigüedad, evolución de compras, cumplimiento con 7 días de gracia, atraso y número de protestos. Los protestos abiertos se toman del histórico de letras, no se infieren del API de estado de cuenta."
)
