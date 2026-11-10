"""
Figures from experiments/results/summary.csv (written by run_experiments.jl), model v6.10.
    python experiments/plot_experiments.py
Requires pandas and matplotlib. Figures go to experiments/results/figures/.
For every experiment group: expected FFR profit, and the energy split BESS / IT / generators
over the whole event (sum of the hourly what-if events).
"""
import os
import sys
import pandas as pd
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt

HERE = os.path.dirname(os.path.abspath(__file__))
RES = sys.argv[1] if len(sys.argv) > 1 else os.path.join(HERE, "results")
FIG = os.path.join(RES, "figures")
os.makedirs(FIG, exist_ok=True)
df = pd.read_csv(os.path.join(RES, "summary.csv"))
for c in ["f_FFR_USD", "capacity_revenue_USD", "expected_event_cost_USD", "delta_C_DA_USD",
          "event_BESS_MWh", "event_IT_MWh", "event_GEN_MWh", "ffr_MW_h", "C0_USD"]:
    if c in df:
        df[c] = pd.to_numeric(df[c], errors="coerce")

C_BESS, C_IT, C_GEN = "#2a6f97", "#e09f3e", "#9e2a2b"
TITLES = {"E1": "Base case", "E2": "Qualified generators (share of base N_FFR)",
          "E3": "Generators take over the sustain stage", "E4": "UPS backup ride-through kept",
          "E5": "RRS price scenario", "E6": "Generator start time T_G", "E7": "Generator loading time",
          "E8": "Number of loading stages K_L", "E9": "Design margin below the ERCOT upper limits",
          "E10": "IT capping share in the sustain stage", "E11": "Fleet FFR limit R_mkt",
          "E12": "FFR offer cap F (share of facility load)", "E13": "UPS coverage U",
          "E14": "WAN wavelengths per site pair", "E15": "IT power ramp limit",
          "E16": "No-load inverter loss in the event", "E17": "Inverter loss: exact vs relaxed",
          "E18": "IT flexibility: site roles, migration, deadlines, capping share",
          "E19": "Reviewer repairs F1-F3 (ablation)"}

for g in sorted(df["group"].unique(), key=lambda s: int(s[1:])):
    d = df[df["group"] == g]
    fig, ax = plt.subplots(1, 2, figsize=(11, 3.8))
    x = list(range(len(d)))
    ax[0].bar(x, d["f_FFR_USD"], color="#555555")
    ax[0].set_xticks(x); ax[0].set_xticklabels(d["case"], rotation=30, ha="right")
    ax[0].set_ylabel("Expected FFR profit [USD/day]"); ax[0].grid(axis="y", alpha=0.3)
    b = d["event_BESS_MWh"].fillna(0); i = d["event_IT_MWh"].fillna(0); gg = d["event_GEN_MWh"].fillna(0)
    ax[1].bar(x, b, color=C_BESS, label="BESS")
    ax[1].bar(x, i, bottom=b, color=C_IT, label="IT capping")
    ax[1].bar(x, gg, bottom=b + i, color=C_GEN, label="generators")
    ax[1].set_xticks(x); ax[1].set_xticklabels(d["case"], rotation=30, ha="right")
    ax[1].set_ylabel("Event energy, sum over hourly what-if events [MWh]")
    ax[1].legend(frameon=False, fontsize=8); ax[1].grid(axis="y", alpha=0.3)
    fig.suptitle(TITLES.get(g, g))
    fig.tight_layout()
    fig.savefig(os.path.join(FIG, f"{g}.png"), dpi=160)
    plt.close(fig)
print("figures in", FIG)
