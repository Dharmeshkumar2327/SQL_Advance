#!/usr/bin/env python3
"""Render the static charts used in README.md from dashboard/data/*.csv (needs matplotlib)."""
from pathlib import Path

import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
import pandas as pd

ROOT = Path(__file__).resolve().parents[1]
DATA, OUT = ROOT / "dashboard" / "data", ROOT / "docs" / "images"
OUT.mkdir(parents=True, exist_ok=True)

BLUE, ORANGE, MUTED = "#2a78d6", "#eb6834", "#c3c2b7"
INK, INK_2, GRID, SURFACE = "#0b0b0b", "#52514e", "#e7e6e2", "#fcfcfb"
plt.rcParams.update({
    "figure.facecolor": SURFACE, "axes.facecolor": SURFACE, "axes.edgecolor": GRID,
    "axes.labelcolor": INK_2, "xtick.color": INK_2, "ytick.color": INK_2, "text.color": INK,
    "font.size": 11, "axes.spines.top": False, "axes.spines.right": False,
    "axes.titleweight": "bold", "axes.titlesize": 13, "axes.titlelocation": "left",
})


def save(fig, name):
    fig.tight_layout()
    fig.savefig(OUT / name, dpi=160)
    plt.close(fig)
    print("wrote", OUT / name)


# 1. recall per planted pattern (caught vs missed, stacked)
cv = pd.read_csv(DATA / "pattern_coverage.csv").sort_values("recall")
missed = cv.planted_txns - cv.caught_txns
fig, ax = plt.subplots(figsize=(9, 4.2))
ax.barh(cv.fraud_pattern, cv.caught_txns, color=BLUE, label="Caught", height=0.6)
ax.barh(cv.fraud_pattern, missed, left=cv.caught_txns, color=MUTED, label="Missed", height=0.6,
        edgecolor=SURFACE, linewidth=2)
for y, (tot, rec) in enumerate(zip(cv.planted_txns, cv.recall)):
    ax.text(tot + 15, y, f"{rec:.0%}", va="center", color=INK_2)
ax.set_xlabel("Planted fraud transactions")
ax.set_title("Recall by fraud pattern")
ax.grid(axis="x", color=GRID)
ax.set_axisbelow(True)
ax.legend(frameon=False, loc="lower right")
save(fig, "recall_by_pattern.png")

# 2. precision / recall vs threshold
c = pd.read_csv(DATA / "threshold_curve.csv")
fig, ax = plt.subplots(figsize=(9, 3.8))
ax.plot(c.threshold, c.precision, color=BLUE, lw=2, marker="o", ms=5, label="Precision")
ax.plot(c.threshold, c.recall, color=ORANGE, lw=2, marker="o", ms=5, label="Recall")
ax.axvline(25, color=INK_2, lw=1, ls="--")
ax.text(26, 0.6, "production\nthreshold = 25", color=INK_2)
ax.set_ylim(0, 1.05)
ax.yaxis.set_major_formatter(plt.FuncFormatter(lambda v, _: f"{v:.0%}"))
ax.set_xlabel("Alert if risk score ≥")
ax.set_title("Precision–recall trade-off by alert threshold")
ax.grid(axis="y", color=GRID)
ax.legend(frameon=False)
save(fig, "threshold_curve.png")

# 3. alerts per 1,000 txns, day x hour
h = pd.read_csv(DATA / "hourly_risk_heatmap.csv")
order = h.drop_duplicates("iso_dow").sort_values("iso_dow").day_name.tolist()
m = h.pivot_table(index="day_name", columns="hour_of_day", values="alerts_per_1000").reindex(order)
fig, ax = plt.subplots(figsize=(10, 3.4))
im = ax.imshow(m.values, cmap="Blues", aspect="auto")
ax.set_yticks(range(len(order)), order)
ax.set_xticks(range(0, 24, 2), [f"{x:02d}" for x in range(0, 24, 2)])
ax.set_xlabel("Hour of day")
ax.set_title("Alerts per 1,000 transactions — the 1am–4am window lights up")
for s in ax.spines.values():
    s.set_visible(False)
cb = fig.colorbar(im, ax=ax, fraction=0.025, pad=0.01)
cb.outline.set_visible(False)
save(fig, "risk_heatmap.png")
