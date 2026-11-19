"""
UPI Fraud Detection Engine - Streamlit dashboard.

Reads the CSVs exported by sql/50_export/01_export_dashboard_data.sql,
so it runs without a database connection (works on Streamlit Community Cloud).

    streamlit run dashboard/app.py
"""
from __future__ import annotations

import json
from pathlib import Path

import pandas as pd
import plotly.express as px
import plotly.graph_objects as go
import streamlit as st

DATA = Path(__file__).parent / "data"

# Palette: validated categorical slots + fixed status colours (see README > Design)
BLUE, ORANGE, AQUA, VIOLET = "#2a78d6", "#eb6834", "#1baf7a", "#6250d6"
STATUS = {"LOW": "#0ca30c", "MEDIUM": "#fab219", "HIGH": "#ec835a", "CRITICAL": "#d03b3b"}
SEQ_BLUE = ["#cde2fb", "#9ec5f4", "#6da7ec", "#3987e5", "#256abf", "#184f95", "#0d366b"]
INK, INK_2, GRID = "#0b0b0b", "#52514e", "#e7e6e2"
BAND_ORDER = ["LOW", "MEDIUM", "HIGH", "CRITICAL"]

st.set_page_config(page_title="UPI Fraud Detection Engine", page_icon="🛡️", layout="wide")


# --------------------------------------------------------------------------
# data
# --------------------------------------------------------------------------
@st.cache_data
def load(name: str) -> pd.DataFrame:
    return pd.read_csv(DATA / f"{name}.csv")


def style(fig: go.Figure, height: int = 360, legend: bool = True) -> go.Figure:
    """Shared, recessive chart styling: thin grid, muted axes, horizontal legend on top."""
    fig.update_layout(
        height=height,
        margin=dict(l=10, r=10, t=40, b=10),
        plot_bgcolor="#fcfcfb",
        paper_bgcolor="rgba(0,0,0,0)",
        font=dict(color=INK, size=13),
        showlegend=legend,
        legend=dict(orientation="h", yanchor="bottom", y=1.02, xanchor="left", x=0, title=None),
        hoverlabel=dict(bgcolor="white", font_color=INK),
    )
    fig.update_xaxes(showgrid=False, linecolor=GRID, tickfont=dict(color=INK_2), title_font=dict(color=INK_2))
    fig.update_yaxes(gridcolor=GRID, zeroline=False, tickfont=dict(color=INK_2), title_font=dict(color=INK_2))
    return fig


def inr(x: float) -> str:
    """Format rupees in lakh / crore, the way Indian teams read money."""
    if x >= 1e7:
        return f"₹{x / 1e7:,.2f} Cr"
    if x >= 1e5:
        return f"₹{x / 1e5:,.2f} L"
    return f"₹{x:,.0f}"


kpi = load("kpi_summary").iloc[0]
metrics = load("overall_metrics").iloc[0]
daily = load("daily_alert_trend")
bands = load("risk_band_summary")
coverage = load("pattern_coverage")
rule_perf = load("rule_performance")
rule_cfg = load("rule_config")
curve = load("threshold_curve")
overlap = load("rule_overlap")
heat = load("hourly_risk_heatmap")
city = load("city_risk")
channel = load("channel_risk")
edges = load("mule_network_edges")
queue = load("alert_queue")
accounts = load("top_risky_accounts")

# --------------------------------------------------------------------------
# header
# --------------------------------------------------------------------------
st.title("🛡️ UPI Fraud Detection Engine")
st.caption(
    "8 fraud rules written in pure PostgreSQL, run over "
    f"{int(kpi.total_txns):,} synthetic UPI transactions (Jul–Sep 2026). "
    "Accuracy is measured against planted ground-truth fraud."
)

c = st.columns(6)
c[0].metric("Transactions scanned", f"{int(kpi.total_txns):,}")
c[1].metric("Alerts raised", f"{int(kpi.alerted_txns):,}", f"{metrics.alerts_per_1000_txns} per 1,000 txns",
            delta_color="off")
c[2].metric("Precision", f"{kpi.precision:.1%}", help="Of all alerts, how many were real fraud")
c[3].metric("Recall", f"{kpi.recall:.1%}", help="Of all planted fraud, how much was caught")
c[4].metric("Fraud value caught", f"{kpi.pct_fraud_amount_caught:.1f}%",
            f"{inr(metrics.fraud_amount_caught)} of {inr(metrics.fraud_amount)}", delta_color="off")
c[5].metric("Mule chains found", f"{int(kpi.mule_chains)}", f"{int(kpi.suspected_mules)} mule accounts",
            delta_color="off")

tab_overview, tab_rules, tab_hotspots, tab_mules, tab_cases = st.tabs(
    ["📊 Overview", "⚙️ Rule performance", "🗺️ Hotspots", "🕸️ Mule network", "🔎 Investigator"]
)

# --------------------------------------------------------------------------
# overview
# --------------------------------------------------------------------------
with tab_overview:
    left, right = st.columns([2, 1])
    with left:
        st.subheader("Alerts per day")
        d = daily.melt(id_vars="txn_date", value_vars=["alerts", "critical_alerts"],
                       var_name="series", value_name="count")
        d["series"] = d["series"].map({"alerts": "All alerts", "critical_alerts": "Critical (blocked)"})
        fig = px.line(d, x="txn_date", y="count", color="series",
                      color_discrete_map={"All alerts": BLUE, "Critical (blocked)": STATUS["CRITICAL"]},
                      labels={"txn_date": "", "count": "Alerts"})
        fig.update_traces(line_width=2)
        fig.update_layout(hovermode="x unified")
        st.plotly_chart(style(fig), width="stretch")
    with right:
        st.subheader("Alerts by risk band")
        b = bands.copy()
        b["label"] = b["risk_band"] + " → " + b["action"]
        fig = px.bar(b, x="txns", y="label", orientation="h", color="risk_band",
                     color_discrete_map=STATUS, text="txns",
                     labels={"txns": "Transactions", "label": ""},
                     hover_data={"amount": ":,.0f", "risk_band": False})
        fig.update_traces(textposition="outside", cliponaxis=False, marker_line_width=0)
        fig.update_yaxes(categoryorder="array", categoryarray=list(b["label"]))
        st.plotly_chart(style(fig, legend=False), width="stretch")

    st.subheader("How much of each fraud pattern was caught?")
    cv = coverage.sort_values("recall")
    cv["missed_txns"] = cv["planted_txns"] - cv["caught_txns"]
    m = cv.melt(id_vars="fraud_pattern", value_vars=["caught_txns", "missed_txns"],
                var_name="outcome", value_name="txns")
    m["outcome"] = m["outcome"].map({"caught_txns": "Caught", "missed_txns": "Missed"})
    fig = px.bar(m, x="txns", y="fraud_pattern", color="outcome", orientation="h",
                 color_discrete_map={"Caught": BLUE, "Missed": "#c3c2b7"},
                 labels={"txns": "Planted fraud transactions", "fraud_pattern": ""})
    fig.update_traces(marker_line_color="#fcfcfb", marker_line_width=2)
    fig.update_yaxes(categoryorder="array", categoryarray=list(cv["fraud_pattern"]))
    for _, r in cv.iterrows():
        fig.add_annotation(x=r.planted_txns, y=r.fraud_pattern, text=f"{r.recall:.0%}",
                           showarrow=False, xanchor="left", xshift=6, font=dict(color=INK_2))
    st.plotly_chart(style(fig, height=380), width="stretch")
    st.caption("Misses are intentional: the generator plants 'evasive' fraud (slow mule chains, "
               "low-and-slow takeovers, structuring spread over two days) that stays under the thresholds.")

# --------------------------------------------------------------------------
# rule performance
# --------------------------------------------------------------------------
with tab_rules:
    st.subheader("Per-rule scorecard")
    rp = rule_perf.merge(rule_cfg[["rule_code", "description", "params"]], on="rule_code", how="left")
    st.dataframe(
        rp[["rule_code", "rule_name", "severity_points", "alerts", "true_positives", "false_positives",
            "precision", "recall_on_target", "params"]],
        width="stretch", hide_index=True,
        column_config={
            "precision": st.column_config.ProgressColumn("Precision", format="%.2f", min_value=0, max_value=1),
            "recall_on_target": st.column_config.ProgressColumn("Recall (own pattern)", format="%.2f",
                                                                min_value=0, max_value=1),
            "params": st.column_config.TextColumn("Thresholds (fraud.rule_config)"),
        },
    )

    left, right = st.columns(2)
    with left:
        st.subheader("Precision vs recall by rule")
        fig = px.scatter(rule_perf, x="recall_on_target", y="precision", text="rule_code",
                         size="alerts", size_max=40, hover_name="rule_name",
                         labels={"recall_on_target": "Recall on target pattern", "precision": "Precision"})
        fig.update_traces(marker=dict(color=BLUE, opacity=0.75, line=dict(color="#fcfcfb", width=2)),
                          textposition="top center")
        fig.update_xaxes(range=[0.6, 1.05], tickformat=".0%")
        fig.update_yaxes(range=[0.5, 1.08], tickformat=".0%")
        st.plotly_chart(style(fig, legend=False), width="stretch")
    with right:
        st.subheader("Choosing the alert threshold")
        cm = curve.melt(id_vars="threshold", value_vars=["precision", "recall"],
                        var_name="metric", value_name="value")
        fig = px.line(cm, x="threshold", y="value", color="metric", markers=True,
                      color_discrete_map={"precision": BLUE, "recall": ORANGE},
                      labels={"threshold": "Alert if risk score ≥", "value": ""})
        fig.update_traces(line_width=2, marker_size=8)
        fig.update_yaxes(tickformat=".0%", range=[0, 1.05])
        fig.update_layout(hovermode="x unified")
        st.plotly_chart(style(fig), width="stretch")
        st.caption(f"Production threshold = {int(metrics.alert_threshold)} (MEDIUM band). "
                   "Raising it buys precision but recall collapses because most fraud trips one rule.")

    st.subheader("Rules that agree (same transaction)")
    if len(overlap):
        codes = sorted(set(overlap.rule_a) | set(overlap.rule_b))
        mat = pd.DataFrame(0, index=codes, columns=codes)
        for _, r in overlap.iterrows():
            mat.loc[r.rule_a, r.rule_b] = r.shared_txns
            mat.loc[r.rule_b, r.rule_a] = r.shared_txns
        fig = px.imshow(mat, text_auto=True, color_continuous_scale=SEQ_BLUE, aspect="auto",
                        labels=dict(color="Shared txns"))
        fig.update_xaxes(side="top")
        st.plotly_chart(style(fig, height=380, legend=False), width="stretch")

# --------------------------------------------------------------------------
# hotspots
# --------------------------------------------------------------------------
with tab_hotspots:
    st.subheader("When does fraud happen? Alerts per 1,000 transactions")
    hm = heat.pivot_table(index="day_name", columns="hour_of_day", values="alerts_per_1000", aggfunc="sum")
    order = heat.drop_duplicates("iso_dow").sort_values("iso_dow")["day_name"].tolist()
    hm = hm.reindex(order)
    fig = px.imshow(hm, color_continuous_scale=SEQ_BLUE, aspect="auto",
                    labels=dict(x="Hour of day", y="", color="Alerts / 1,000"))
    fig.update_traces(xgap=2, ygap=2,
                      hovertemplate="%{y} %{x}:00<br>%{z:.1f} alerts per 1,000 txns<extra></extra>")
    st.plotly_chart(style(fig, height=330, legend=False), width="stretch")
    st.caption("The 1am–4am band lights up: little genuine traffic, so odd-hour anomalies and takeovers stand out.")

    left, right = st.columns(2)
    with left:
        st.subheader("Cities by alert value")
        cc = city.sort_values("alerted_value").tail(12)
        fig = px.bar(cc, x="alerted_value", y="city", orientation="h",
                     hover_data={"alerts": True, "alerts_per_1000": True, "state": True},
                     labels={"alerted_value": "Alerted value (₹)", "city": ""})
        fig.update_traces(marker_color=BLUE, marker_line_width=0)
        st.plotly_chart(style(fig, height=420, legend=False), width="stretch")
    with right:
        st.subheader("Channels by alert rate")
        ch = channel.copy()
        ch["channel_type"] = ch["channel"] + " · " + ch["txn_type"]
        ch = ch.sort_values("alerts_per_1000")
        fig = px.bar(ch, x="alerts_per_1000", y="channel_type", orientation="h", text="alerts_per_1000",
                     hover_data={"txns": ":,", "alerts": True, "avg_alerted_amount": ":,.0f"},
                     labels={"alerts_per_1000": "Alerts per 1,000 txns", "channel_type": ""})
        fig.update_traces(marker_color=BLUE, marker_line_width=0, textposition="outside", cliponaxis=False)
        st.plotly_chart(style(fig, height=420, legend=False), width="stretch")

# --------------------------------------------------------------------------
# mule network
# --------------------------------------------------------------------------
with tab_mules:
    chains = (edges.groupby("chain_id")
                   .agg(start=("txn_ts", "min"), hops=("chain_txns", "first"),
                        root_amount=("amount", "first"), retained=("pct_amount_retained", "first"),
                        victim=("payer_vpa", "first"), cash_out=("payee_vpa", "last"))
                   .reset_index())
    left, right = st.columns([1, 2])
    with left:
        st.subheader(f"{len(chains)} chains detected by the recursive CTE")
        st.dataframe(chains.sort_values("root_amount", ascending=False), hide_index=True, height=430,
                     width="stretch",
                     column_config={"root_amount": st.column_config.NumberColumn("Stolen (₹)", format="%d"),
                                    "retained": st.column_config.NumberColumn("% reaching last hop",
                                                                              format="%.1f")})
    with right:
        default = int(chains.sort_values("hops", ascending=False).iloc[0].chain_id)
        pick = st.selectbox("Trace a chain", chains["chain_id"].tolist(),
                            index=chains["chain_id"].tolist().index(default))
        e = edges[edges.chain_id == pick].sort_values("hop_no")
        nodes = list(dict.fromkeys(list(e.payer_vpa) + list(e.payee_vpa)))
        idx = {n: i for i, n in enumerate(nodes)}
        node_color = [ORANGE if i == 0 else (VIOLET if n == e.payee_vpa.iloc[-1] else BLUE)
                      for i, n in enumerate(nodes)]
        fig = go.Figure(go.Sankey(
            node=dict(label=nodes, color=node_color, pad=18, thickness=14, line=dict(width=0)),
            link=dict(source=[idx[s] for s in e.payer_vpa], target=[idx[t] for t in e.payee_vpa],
                      value=e.amount, color="rgba(42,120,214,0.25)",
                      customdata=e.txn_ts,
                      hovertemplate="₹%{value:,.0f}<br>%{customdata}<extra></extra>"),
        ))
        st.plotly_chart(style(fig, height=380, legend=False), width="stretch")
        st.caption("🟠 victim  ·  🔵 mule accounts  ·  🟣 cash-out (gift cards / crypto). "
                   "Each hop forwards 96–99% of what it received, within minutes.")
        st.dataframe(e[["hop_no", "txn_ts", "payer_vpa", "payee_vpa", "amount"]], hide_index=True,
                     width="stretch")

# --------------------------------------------------------------------------
# investigator
# --------------------------------------------------------------------------
with tab_cases:
    st.subheader("Alert queue (HIGH / CRITICAL or multi-rule)")
    f1, f2 = st.columns(2)
    band_pick = f1.multiselect("Risk band", [b for b in BAND_ORDER if b in queue.risk_band.unique()],
                               default=[b for b in BAND_ORDER if b in queue.risk_band.unique()])
    all_rules = sorted({r for x in queue.rules_fired for r in x.split(" + ")})
    rule_pick = f2.multiselect("Contains rule", all_rules)
    q = queue[queue.risk_band.isin(band_pick)]
    if rule_pick:
        q = q[q.rules_fired.apply(lambda x: all(r in x.split(" + ") for r in rule_pick))]
    st.dataframe(
        q[["txn_id", "txn_ts", "risk_score", "risk_band", "action", "amount", "payer_vpa", "payee_vpa",
           "txn_city", "reasons"]],
        width="stretch", hide_index=True, height=320,
        column_config={"risk_score": st.column_config.ProgressColumn("Score", min_value=0, max_value=100,
                                                                     format="%d")},
    )
    if len(q):
        txn = st.selectbox("Why was this flagged?", q["txn_id"].tolist())
        st.json(json.loads(q.loc[q.txn_id == txn, "evidence"].iloc[0]))

    st.subheader("Top risky accounts")
    tier = st.radio("Investigation tier", ["All"] + sorted(accounts.investigation_tier.unique()), horizontal=True)
    a = accounts if tier == "All" else accounts[accounts.investigation_tier == tier]
    st.dataframe(
        a[["risk_rank", "vpa", "account_type", "home_city", "kyc_level", "alerted_txns", "alerted_amount",
           "rules", "is_suspected_mule", "account_risk_score", "investigation_tier"]].head(200),
        width="stretch", hide_index=True,
    )
    st.caption("Deep-dive any account in SQL:  "
               "`psql -d upi_fraud -v account_id=<id> -f sql/60_analyst_toolkit/02_investigate_account.sql`")

st.divider()
st.caption("Built by Dharmesh Kumar · data is 100% synthetic · "
           "[GitHub](https://github.com/Dharmeshkumar2327) · "
           "[LinkedIn](https://www.linkedin.com/in/dharmesh-kumar-293a89235)")
