#
# SUPER MARIO BROS (NTSC) Player State Post-Processor for FCEUX 2.6.6
#
# Author: @marcofarfisa
#

import pandas as pd
import matplotlib.pyplot as plt

# Load CSVs
TAS = pd.read_csv("data_log_v1_HappyLee8-4.csv")


# Filter table
TAS = TAS.loc[TAS.Px > 0]  # Wait for x position to take on a meaningful value

TAS = TAS.loc[TAS.Frame <= 15290]  # Stop after maximum speed reached (15265+ frames)

# Calculate and scale empirical derivative of x position
TAS["VxEmp"] = TAS.Px.diff() * 16


# Plot
plt.figure(dpi=300)

plt.plot(
    TAS.Frame,
    TAS.Px,
    label="X Pos: TAS Accel (L+R)",
    color="tab:green",
    linewidth=1.2,
)

plt.plot(
    TAS.Frame,
    TAS.Vx.clip(upper=TAS.VxEmp.max()),
    label="X Vel (x16): TAS Accel (L+R)",
    color="tab:green",
    marker=".",
    linewidth=0.8,
    markersize=3,
)


# Format plot
plt.title("Start of 8-4, Initial Player Acceleration")
plt.xlabel("Frame #")
plt.ylabel("X Pos, Vel")
plt.legend()
plt.legend(fontsize=8)
plt.grid(color="#dfdfdf")

# Save
plt.savefig("Output_Plot_8-4.png")

plt.show()


# Print key values

ACC_QUERY_FRAME = 15235

FirstFastAccelJumpAccTAS = (
    TAS.loc[TAS.Frame == ACC_QUERY_FRAME].Vx.iloc[0] / 16
    - TAS.loc[TAS.Frame == ACC_QUERY_FRAME - 1].Vx.iloc[0] / 16
)
print()
print("FirstFastAccelJump X Acc (L+R):")
print(FirstFastAccelJumpAccTAS)
print("  = {} / 4096".format(FirstFastAccelJumpAccTAS * 4096))


ACC_QUERY_FRAME = 15259

SecondFastAccelJumpAccTAS = (
    TAS.loc[TAS.Frame == ACC_QUERY_FRAME].Vx.iloc[0] / 16
    - TAS.loc[TAS.Frame == ACC_QUERY_FRAME - 1].Vx.iloc[0] / 16
)
print()
print("SecondFastAccelJump X Acc (L+R):")
print(SecondFastAccelJumpAccTAS)
print("  = {} / 4096".format(SecondFastAccelJumpAccTAS * 4096))
