#
# SUPER MARIO BROS (NTSC) Player State Post-Processor for FCEUX 2.6.6
#
# Author: @marcofarfisa
#

import pandas as pd
import matplotlib.pyplot as plt

# Load CSVs
TAS = pd.read_csv("data_log_v1_HappyLeeTAS.csv")
RTA = pd.read_csv("data_log_v1_MaruRTA.csv")
B_L = pd.read_csv("data_log_v1_HoldRightAndB.csv")
SLO = pd.read_csv("data_log_v1_HoldRightWalking.csv")


# Filter table
TAS = TAS.iloc[180:]  # Get rid of long beginning
RTA = RTA.iloc[180:]
B_L = B_L.iloc[180:]
SLO = SLO.iloc[180:]

TAS = TAS.loc[TAS.Px > 0]  # Wait for x position to take on a meaningful value
RTA = RTA.loc[RTA.Px > 0]
B_L = B_L.loc[B_L.Px > 0]
SLO = SLO.loc[SLO.Px > 0]

TAS = TAS.loc[TAS.Frame <= 256]  # Stop after maximum speed reached (242+ frames)
RTA = RTA.loc[RTA.Frame <= 256]
B_L = B_L.loc[B_L.Frame <= 256]
SLO = SLO.loc[SLO.Frame <= 256]

# Check for assumed alignment
assert (
    (TAS.iloc[0].Frame == RTA.iloc[0].Frame)
    and (TAS.iloc[0].Frame == B_L.iloc[0].Frame)
    and (TAS.iloc[0].Frame == SLO.iloc[0].Frame)
)

# Calculate and scale empirical derivative of x position
RTA["VxEmp"] = RTA.Px.diff() * 16
TAS["VxEmp"] = TAS.Px.diff() * 16
B_L["VxEmp"] = B_L.Px.diff() * 16
SLO["VxEmp"] = SLO.Px.diff() * 16


# Plot
plt.figure(dpi=300)

plt.plot(SLO.Frame, SLO.Px, label="X Pos: Walking", color="black", linestyle="--")
plt.plot(B_L.Frame, B_L.Px, label="X Pos: Running", color="black")
plt.plot(RTA.Frame, RTA.Px, label="X Pos: Fast Accel (RTA)", color="tab:orange")
plt.plot(TAS.Frame, TAS.Px, label="X Pos: Fast Accel (L+R)", color="tab:green")

plt.plot(
    SLO.Frame,
    SLO.Vx.clip(upper=SLO.VxEmp.max()),
    label="X Vel (x16): Walking",
    color="black",
    linestyle=":",
)
plt.plot(
    B_L.Frame,
    B_L.Vx.clip(upper=B_L.VxEmp.max()),
    label="X Vel (x16): Running",
    color="black",
    marker=".",
    markersize=4,
)
plt.plot(
    RTA.Frame,
    RTA.Vx.clip(upper=RTA.VxEmp.max()),
    label="X Vel (x16): Fast Accel (RTA)",
    color="tab:orange",
    marker=".",
    markersize=4,
)
plt.plot(
    TAS.Frame,
    TAS.Vx.clip(upper=TAS.VxEmp.max()),
    label="X Vel (x16): Fast Accel (L+R)",
    color="tab:green",
    marker=".",
    markersize=4,
)


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


# Print key values

ACC_QUERY_FRAME = 212

WalkingAccel = (
    SLO.loc[SLO.Frame == ACC_QUERY_FRAME].Vx.iloc[0] / 16
    - SLO.loc[SLO.Frame == ACC_QUERY_FRAME - 1].Vx.iloc[0] / 16
)
print()
print("WalkingAccel X Acc (Hold Right):")
print(WalkingAccel)
print("  = {} / 4096".format(WalkingAccel * 4096))

RunningAccel = (
    B_L.loc[B_L.Frame == ACC_QUERY_FRAME].Vx.iloc[0] / 16
    - B_L.loc[B_L.Frame == ACC_QUERY_FRAME - 1].Vx.iloc[0] / 16
)
print()
print("RunningAccel X Acc (Hold Right+B):")
print(RunningAccel)
print("  = {} / 4096".format(RunningAccel * 4096))

FirstFastAccelJumpAccTAS = (
    TAS.loc[TAS.Frame == ACC_QUERY_FRAME].Vx.iloc[0] / 16
    - TAS.loc[TAS.Frame == ACC_QUERY_FRAME - 1].Vx.iloc[0] / 16
)
print()
print("FirstFastAccelJump X Acc (L+R):")
print(FirstFastAccelJumpAccTAS)
print("  = {} / 4096".format(FirstFastAccelJumpAccTAS * 4096))

FirstFastAccelJumpAccRTA = (
    RTA.loc[RTA.Frame == ACC_QUERY_FRAME].Vx.iloc[0] / 16
    - RTA.loc[RTA.Frame == ACC_QUERY_FRAME - 1].Vx.iloc[0] / 16
)
print()
print("FirstFastAccelJump X Acc (RTA):")
print(FirstFastAccelJumpAccRTA)
print("  = {} / 4096".format(FirstFastAccelJumpAccRTA * 4096))


ACC_QUERY_FRAME = 225

SecondFastAccelJumpAccTAS = (
    TAS.loc[TAS.Frame == ACC_QUERY_FRAME].Vx.iloc[0] / 16
    - TAS.loc[TAS.Frame == ACC_QUERY_FRAME - 1].Vx.iloc[0] / 16
)
print()
print("SecondFastAccelJump X Acc (L+R):")
print(SecondFastAccelJumpAccTAS)
print("  = {} / 4096".format(SecondFastAccelJumpAccTAS * 4096))

SecondFastAccelJumpAccRTA = (
    RTA.loc[RTA.Frame == ACC_QUERY_FRAME].Vx.iloc[0] / 16
    - RTA.loc[RTA.Frame == ACC_QUERY_FRAME - 1].Vx.iloc[0] / 16
)
print()
print("SecondFastAccelJump X Acc (RTA):")
print(SecondFastAccelJumpAccRTA)
print("  = {} / 4096".format(SecondFastAccelJumpAccRTA * 4096))
