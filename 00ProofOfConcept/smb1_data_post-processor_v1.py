#
# SUPER MARIO BROS (NTSC) Player State Post-Processor for FCEUX 2.6.6
#
# Author: @marcofarfisa
#

import pandas as pd
import matplotlib.pyplot as plt


# Load CSVs
TAS = pd.read_csv(r"data_log_v1_HappyLeeTAS.csv")
RTA = pd.read_csv(r"data_log_v1_MaruRTA.csv")
B_L = pd.read_csv(r"data_log_v1_HoldRightAndB.csv")


# Filter table
TAS = TAS.iloc[180:]
RTA = RTA.iloc[180:]
B_L = B_L.iloc[180:]

TAS = TAS.loc[TAS.Px > 0]
RTA = RTA.loc[RTA.Px > 0]
B_L = B_L.loc[B_L.Px > 0]

TAS = TAS.loc[TAS.Frame <= 256]
RTA = RTA.loc[RTA.Frame <= 256]
B_L = B_L.loc[B_L.Frame <= 256]

assert (RTA.iloc[0].Frame == TAS.iloc[0].Frame) and (RTA.iloc[0].Frame == B_L.iloc[0].Frame)

RTA["VxEmp"] = RTA.Px.diff() * 16
TAS["VxEmp"] = TAS.Px.diff() * 16
B_L["VxEmp"] = B_L.Px.diff() * 16


# Plot
plt.figure(dpi=300)

plt.plot(B_L.Frame, B_L.Px, label="X Pos: Hold Right+B", color="black")
plt.plot(RTA.Frame, RTA.Px, label="X Pos: TAS (RTA)", color="tab:orange")
plt.plot(TAS.Frame, TAS.Px, label="X Pos: TAS (L+R)", color="tab:green")

plt.plot(B_L.Frame, B_L.Vx.clip(upper=40), label="X Vel (Scaled): Hold Right+B", color="black", marker='.', markersize=4)
plt.plot(RTA.Frame, RTA.Vx.clip(upper=40), label="X Vel (Scaled): TAS (RTA)", color="tab:orange", marker='.', markersize=4)
plt.plot(TAS.Frame, TAS.Vx.clip(upper=40), label="X Vel (Scaled): TAS (L+R)", color="tab:green", marker='.', markersize=4)

# plt.plot(TAS.Frame, TAS.Ax * 10 - 25, label="X Acc: TAS", color='tab:green', linestyle=':')
# plt.plot(RTA.Frame, RTA.Ax * 10 - 25, label="X Acc: RTA", color='tab:orange', linestyle=':')
# plt.plot(B_L.Frame, B_L.Ax * 10 - 25, label="X Acc: Baseline", color='tab:blue', linestyle=':')


# Format plot
plt.title("Start of 1-1, Initial Player Acceleration")
plt.xlabel("Frame #")
plt.ylabel("X Pos/Vel")
plt.legend()
plt.legend(fontsize=8)
plt.grid()

# Save
plt.savefig("data_comparison_v1.png")

plt.show()
