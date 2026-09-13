#
# SUPER MARIO BROS (NTSC) Player State Post-Processor for FCEUX 2.6.6
#
# Author: @marcofarfisa
#
import pandas as pd
import matplotlib.pyplot as plt

# Load CSVs
TAS = pd.read_csv("data/TAS_HL.csv")
RTA = pd.read_csv("data/RTA_Maru.csv")
B_L = pd.read_csv("data/BL_RunRight.csv")  # Can change "Right" to "Left"
SLO = pd.read_csv("data/BL_WalkRight.csv")  # Can change "Right" to "Left"


# Filter table
TAS = TAS.iloc[180:]  # Get rid of long beginning
RTA = RTA.iloc[180:]
B_L = B_L.iloc[180:]
SLO = SLO.iloc[180:]

TAS = TAS.loc[TAS.XPosSmooth > 0]  # Wait for x position to take on a meaningful value
RTA = RTA.loc[RTA.XPosSmooth > 0]
B_L = B_L.loc[B_L.XPosSmooth > 0]
SLO = SLO.loc[SLO.XPosSmooth > 0]

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
TAS["XVelEmpiricalSmooth"] = TAS.XPosSmooth.diff() * 16
RTA["XVelEmpiricalSmooth"] = RTA.XPosSmooth.diff() * 16
B_L["XVelEmpiricalSmooth"] = B_L.XPosSmooth.diff() * 16
SLO["XVelEmpiricalSmooth"] = SLO.XPosSmooth.diff() * 16


# Handle jump state for plots (assumes values are 0 or 1)
assert (TAS.PlayerState < 2).all() and (RTA.PlayerState < 2).all()

TAS["InAir"] = TAS.PlayerState
TAS.loc[TAS.InAir == 0, "InAir"] = float("nan")

RTA["InAir"] = RTA.PlayerState
RTA.loc[RTA.InAir == 0, "InAir"] = float("nan")


# Handle inputs for RTA
RTA["APress"] = RTA.Input.str.contains("A").astype(float)
RTA["BPress"] = RTA.Input.str.contains("B").astype(float)
RTA["LPress"] = RTA.Input.str.contains("L").astype(float)
RTA["RPress"] = RTA.Input.str.contains("R").astype(float)

RTA.loc[RTA.APress == 0, "APress"] = float("nan")
RTA.loc[RTA.BPress == 0, "BPress"] = float("nan")
RTA.loc[RTA.LPress == 0, "LPress"] = float("nan")
RTA.loc[RTA.RPress == 0, "RPress"] = float("nan")

TAS["APress"] = TAS.Input.str.contains("A").astype(float)
TAS["BPress"] = TAS.Input.str.contains("B").astype(float)
TAS["LPress"] = TAS.Input.str.contains("L").astype(float)
TAS["RPress"] = TAS.Input.str.contains("R").astype(float)

TAS.loc[TAS.APress == 0, "APress"] = float("nan")
TAS.loc[TAS.BPress == 0, "BPress"] = float("nan")
TAS.loc[TAS.LPress == 0, "LPress"] = float("nan")
TAS.loc[TAS.RPress == 0, "RPress"] = float("nan")


# Plot
plt.figure(dpi=600)


# Reference lines
plt.plot([0, 300], [0, 0], color="dimgray", linewidth=0.75)

# # https://gist.github.com/1wErt3r/4048722#file-smbdis-asm-L6144
# plt.plot([0, 300], [25, 25], color="lightgray", linestyle="--", linewidth=0.5)


# Position
plt.plot(
    SLO.Frame,
    SLO.XPosSmooth,
    label="X Pos: Walking",
    color="black",
    linestyle="--",
    linewidth=1.2,
)
plt.plot(
    B_L.Frame,
    B_L.XPosSmooth,
    label="X Pos: Running",
    color="black",
    linewidth=1.2,
)
plt.plot(
    RTA.Frame,
    RTA.XPosSmooth,
    label="X Pos: Fast Accel (RTA)",
    color="tab:orange",
    linewidth=1.2,
)
plt.plot(
    TAS.Frame,
    TAS.XPosSmooth,
    label="X Pos: Fast Accel (L+R)",
    color="tab:green",
    linewidth=1.2,
)


# Velocity
plt.plot(
    SLO.Frame,
    SLO.XVelSmooth.clip(upper=SLO.XVelEmpiricalSmooth.max()),
    label="X Vel (x16): Walking",
    color="black",
    linestyle=":",
    linewidth=1.1,
)
plt.plot(
    B_L.Frame,
    B_L.XVelSmooth,
    label="X Vel (x16): Running",
    color="black",
    marker=".",
    linewidth=0.8,
    markersize=3,
)
plt.plot(
    RTA.Frame,
    RTA.XVelSmooth,
    label="X Vel (x16): Fast Accel (RTA)",
    color="tab:orange",
    marker=".",
    linewidth=0.8,
    markersize=3,
)
plt.plot(
    TAS.Frame,
    TAS.XVelSmooth,
    label="X Vel (x16): Fast Accel (L+R)",
    color="tab:green",
    marker=".",
    linewidth=0.8,
    markersize=3,
)


# Player State
plt.plot(
    TAS.Frame,
    TAS.InAir - 9,
    label="Is In Air: Fast Accel (L+R)",
    color="tab:green",
    marker="s",
    linewidth=0.8,
    markersize=3,
)
plt.plot(
    RTA.Frame,
    RTA.InAir - 15,
    label="Is In Air: Fast Accel (RTA)",
    color="tab:orange",
    marker="s",
    linewidth=0.8,
    markersize=3,
)


# Button Presses
plt.text(193.25, -22.2, "Input:", fontsize=5)


# Button Presses TAS
plt.plot(
    TAS.Frame,
    TAS.APress - 20 - 0,
    color="tab:green",
    marker=".",
    linestyle="none",
    markersize=1,
)
plt.plot(
    TAS.Frame,
    TAS.BPress - 20 - 1,
    color="tab:green",
    marker=".",
    linestyle="none",
    markersize=0.5,
)
plt.plot(
    TAS.Frame,
    TAS.RPress - 20 - 2,
    color="tab:green",
    marker=">",
    linestyle="none",
    markersize=0.5,
)
plt.plot(
    TAS.Frame,
    TAS.LPress - 20 - 3,
    color="tab:green",
    marker="<",
    linestyle="none",
    markersize=0.5,
)


# Button Presses RTA
plt.plot(
    RTA.Frame,
    RTA.APress - 26 - 0,
    color="tab:orange",
    marker=".",
    linestyle="none",
    markersize=1,
)
plt.plot(
    RTA.Frame,
    RTA.BPress - 26 - 1,
    color="tab:orange",
    marker=".",
    linestyle="none",
    markersize=0.5,
)
plt.plot(
    RTA.Frame,
    RTA.RPress - 26 - 2,
    color="tab:orange",
    marker=">",
    linestyle="none",
    markersize=0.5,
)
plt.plot(
    RTA.Frame,
    RTA.LPress - 26 - 3,
    color="tab:orange",
    marker="<",
    linestyle="none",
    markersize=0.5,
)


# Format plot
plt.title("Start of 1-1, Initial Player Accelerations (For Smooth Visual Only)")
plt.xlabel("Frame #")
plt.ylabel("X Value")
plt.legend()
plt.legend(fontsize=7)
plt.grid(color="#dfdfdf")

plt.xlim((193, 258))
plt.ylim((-30, 160))
plt.yticks(range(0, 180, 20))


# Save
plt.savefig("Output_Plot_Smooth.png")

plt.show()


# Print key values

ACC_QUERY_FRAME = 212

WalkingAccel = (
    SLO.loc[SLO.Frame == ACC_QUERY_FRAME].XVelSmooth.iloc[0] / 16
    - SLO.loc[SLO.Frame == ACC_QUERY_FRAME - 1].XVelSmooth.iloc[0] / 16
)
print()
print("WalkingAccel X Acc (Hold Right):")
print(WalkingAccel)
print("  = {} / 4096".format(WalkingAccel * 4096))

RunningAccel = (
    B_L.loc[B_L.Frame == ACC_QUERY_FRAME].XVelSmooth.iloc[0] / 16
    - B_L.loc[B_L.Frame == ACC_QUERY_FRAME - 1].XVelSmooth.iloc[0] / 16
)
print()
print("RunningAccel X Acc (Hold Right+B):")
print(RunningAccel)
print("  = {} / 4096".format(RunningAccel * 4096))

FirstFastAccelJumpAccTAS = (
    TAS.loc[TAS.Frame == ACC_QUERY_FRAME].XVelSmooth.iloc[0] / 16
    - TAS.loc[TAS.Frame == ACC_QUERY_FRAME - 1].XVelSmooth.iloc[0] / 16
)
print()
print("FirstFastAccelJump X Acc (L+R):")
print(FirstFastAccelJumpAccTAS)
print("  = {} / 4096".format(FirstFastAccelJumpAccTAS * 4096))

FirstFastAccelJumpAccRTA = (
    RTA.loc[RTA.Frame == ACC_QUERY_FRAME].XVelSmooth.iloc[0] / 16
    - RTA.loc[RTA.Frame == ACC_QUERY_FRAME - 1].XVelSmooth.iloc[0] / 16
)
print()
print("FirstFastAccelJump X Acc (RTA):")
print(FirstFastAccelJumpAccRTA)
print("  = {} / 4096".format(FirstFastAccelJumpAccRTA * 4096))


ACC_QUERY_FRAME = 225

SecondFastAccelJumpAccTAS = (
    TAS.loc[TAS.Frame == ACC_QUERY_FRAME].XVelSmooth.iloc[0] / 16
    - TAS.loc[TAS.Frame == ACC_QUERY_FRAME - 1].XVelSmooth.iloc[0] / 16
)
print()
print("SecondFastAccelJump X Acc (L+R):")
print(SecondFastAccelJumpAccTAS)
print("  = {} / 4096".format(SecondFastAccelJumpAccTAS * 4096))

SecondFastAccelJumpAccRTA = (
    RTA.loc[RTA.Frame == ACC_QUERY_FRAME].XVelSmooth.iloc[0] / 16
    - RTA.loc[RTA.Frame == ACC_QUERY_FRAME - 1].XVelSmooth.iloc[0] / 16
)
print()
print("SecondFastAccelJump X Acc (RTA):")
print(SecondFastAccelJumpAccRTA)
print("  = {} / 4096".format(SecondFastAccelJumpAccRTA * 4096))
