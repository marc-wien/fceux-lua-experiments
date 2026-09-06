--
--SUPER MARIO BROS (NTSC) Player State Logger for FCEUX 2.6.6
--
--Author: @marcofarfisa. Thanks to @TheNoSwearGuy.
--




--
--THIS SECTION IS ONE-TIME PREP
--


--TODO: Cross-check with https://datacrystal.tcrf.net/w/index.php?title=Super_Mario_Bros./RAM_map
--TODO: Cross-check with https://retrocomputing.stackexchange.com/questions/15404/understanding-mario-and-screen-position-in-nes-super-mario-bros

--RAM addresses (@TheNoSwearGuy)         --https://github.com/TheNoSwearGuy/smb.lua-and-smas-smb.lua/blob/main/Default/smb%20(FCEUX).lua#L52
local ram_SprObject_PageLoc     = 0x06D  --X position
local ram_SprObject_X_Position  = 0x086
local ram_SprObject_X_MoveForce = 0x400
local ram_Player_X_Speed        = 0x057  --X velocity
local ram_Player_X_MoveForce    = 0x705
local ram_FrictionAdderLow      = 0x702  --X acceleration

local ram_SprObject_Y_Position  = 0x0CE  --Y position
local ram_SprObject_YMF_Dummy   = 0x416
local ram_Player_Y_Speed        = 0x09F  --Y velocity
local ram_Player_Y_MoveForce    = 0x433
local ram_VerticalForce         = 0x709  --Y acceleration

--Additional RAM addresses (diagnostics)
local DIS_PLAYER_MOVINGDIR      = 0x045 --https://gist.github.com/1wErt3r/4048722#file-smbdis-asm-L279
local DIS_PLAYER_XSPEEDABSOLUTE = 0x700 --https://gist.github.com/1wErt3r/4048722#file-smbdis-asm-L381
local DIS_PLAYER_STATE          = 0x01D --https://gist.github.com/1wErt3r/4048722#file-smbdis-asm-L273
                                        --https://gist.github.com/1wErt3r/4048722#file-smbdis-asm-L5893 and -L14586     --usage hints
                                        --https://github.com/Kautenja/gym-super-mario-bros/blob/master/gym_super_mario_bros/smb_env.py#L306
local GYM_PLAYER_STATE          = 0x00E --https://github.com/Kautenja/gym-super-mario-bros/blob/master/gym_super_mario_bros/smb_env.py#L245
                                        --  _BUSY_STATES = [0x00, 0x01, 0x02, 0x03, 0x04, 0x05, 0x07]                   --usage hints
                                        --  0x08 : Normal
local GYM_STATUS_VALUE          = 0x756 --https://github.com/Kautenja/gym-super-mario-bros/blob/master/gym_super_mario_bros/smb_env.py#L235
                                        --  _STATUS_MAP = defaultdict(lambda: 'fireball', {0:'small', 1: 'tall'})       --usage hints

--Start CSV writer
local file = assert(io.open("my_data_log.csv", "w"), "Could not open CSV for writing!")

file:write("Frame,Input,Lag,Px,Vx,Ax,")
file:write("\n")

--Register "on-close" callback
emu.registerexit(function()
	file:close()
end)




--
--THIS SECTION DEFINES "HELPER" FUNCTIONS USED IN THE MAIN LOOP
--


--Joypad input helper function
local function get_input_string(input)
	local input_string = ""
	
	if input.A      then input_string = input_string .. "A" else input_string = input_string .. "." end
	if input.B      then input_string = input_string .. "B" else input_string = input_string .. "." end
	if input.select then input_string = input_string .. "S" else input_string = input_string .. "." end
	if input.start  then input_string = input_string .. "T" else input_string = input_string .. "." end
	if input.up     then input_string = input_string .. "U" else input_string = input_string .. "." end
	if input.down   then input_string = input_string .. "D" else input_string = input_string .. "." end
	if input.left   then input_string = input_string .. "L" else input_string = input_string .. "." end
	if input.right  then input_string = input_string .. "R" else input_string = input_string .. "." end
	
	return input_string
end

--X position helper function
local function get_xpos()
	local xpos1 = memory.readbyte(ram_SprObject_PageLoc)
	local xpos2 = memory.readbyte(ram_SprObject_X_Position)
	local xpos3 = memory.readbyte(ram_SprObject_X_MoveForce)
	
	local xpos = xpos1*256 + xpos2 + xpos3/256
	
	return xpos
end

--X velocity helper function
local function get_xvel()
	local xvel1 = memory.readbytesigned(ram_Player_X_Speed)
	local xvel2 = memory.readbyte(ram_Player_X_MoveForce)
	
	if xvel1 < 0 then  --Process subspeed byte to add to X velocity
		xvel2 = -AND(256 - xvel2, 0xFF)
	end
	
	local xvel = xvel1 + xvel2/256
	
	return xvel
end

--X acceleration helper function
local function get_xacc()
	local xacc1 = memory.readbyte(ram_FrictionAdderLow - 1)
	local xacc2 = memory.readbyte(ram_FrictionAdderLow)
	
	local xacc = xacc1 + xacc2/256
	
	return xacc
end




--
--THIS "MAIN LOOP" SECTION PROBES THE EMULATION STATE BEFORE EACH FRAME-ADVANCE
-- • This loop will execute during live play, movie playback, or manual frame-advance
-- • TODO: Consider if we want to structure for "registerafter" callback instead?
--


while true do
	
	--Frame count
	file:write(string.format("%d,", emu.framecount()))
	
	--Joypad inputs
	local input = joypad.getdown(1)
	local input_string = get_input_string(input)
	file:write(input_string)
	file:write(",")
	
	--Lag
	file:write(string.format("%d,", emu.lagged() and 1 or 0))
	
	--X position
	local xpos = get_xpos()
	file:write(string.format("%.11f,", xpos))
	
	--X velocity
	local xvel = get_xvel()
	file:write(string.format("%.11f,", xvel))
	
	--X acceleration
	local xacc = get_xacc()
	file:write(string.format("%.11f,", xacc))
	
	--End of CSV line
	file:write("\n")
	
	--Return control to emulator
	emu.frameadvance()
end
