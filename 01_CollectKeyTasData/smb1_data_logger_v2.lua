--
--SUPER MARIO BROS (NTSC) Player State Logger for FCEUX 2.6.6
--
--Author: @marcofarfisa. Thanks to @TheNoSwearGuy and @silverslither.
--
--Additional discussion: https://www.speedrun.com/smb1/forums/lxh6c
--



--
--THIS SECTION IS ONE-TIME PREP
--


--RAM addresses (@TheNoSwearGuy)         --https://github.com/TheNoSwearGuy/smb.lua-and-smas-smb.lua/blob/main/Default/smb%20(FCEUX).lua#L52
local ram_SprObject_PageLoc     = 0x06D  --X position
local ram_SprObject_X_Position  = 0x086
local ram_SprObject_X_MoveForce = 0x400
local ram_Player_X_Speed        = 0x057  --X velocity
local ram_Player_X_MoveForce    = 0x705
local ram_FrictionAdderHigh     = 0x701  --X acceleration
local ram_FrictionAdderLow      = 0x702

local ram_SprObject_Y_Position  = 0x0CE  --Y position
local ram_SprObject_YMF_Dummy   = 0x416
local ram_Player_Y_Speed        = 0x09F  --Y velocity
local ram_Player_Y_MoveForce    = 0x433
local ram_VerticalForce         = 0x709  --Y acceleration

--Additional RAM addresses (diagnostics)
local DIS_PLAYER_Y_HIGHPOS      = 0x0B5  --https://www.speedrun.com/smb1/forums/n59i1
local DIS_PLAYER_MOVINGDIR      = 0x045  --https://gist.github.com/1wErt3r/4048722#file-smbdis-asm-L279
local DIS_PLAYER_XSPEEDABSOLUTE = 0x700  --https://gist.github.com/1wErt3r/4048722#file-smbdis-asm-L381
local DIS_PLAYER_STATE          = 0x01D  --https://gist.github.com/1wErt3r/4048722#file-smbdis-asm-L273
                                         --https://gist.github.com/1wErt3r/4048722#file-smbdis-asm-L5893 and -L14586     --usage hints
                                         --https://github.com/Kautenja/gym-super-mario-bros/blob/master/gym_super_mario_bros/smb_env.py#L306
local GYM_GAMEENGINESUBROUTINE  = 0x00E  --https://github.com/Kautenja/gym-super-mario-bros/blob/master/gym_super_mario_bros/smb_env.py#L245
                                         --  _BUSY_STATES = [0x00, 0x01, 0x02, 0x03, 0x04, 0x05, 0x07]                   --usage hints
                                         --  0x08 : Normal
local GYM_PLAYERSTATUS          = 0x756  --https://github.com/Kautenja/gym-super-mario-bros/blob/master/gym_super_mario_bros/smb_env.py#L235
                                         --  _STATUS_MAP = defaultdict(lambda: 'fireball', {0:'small', 1: 'tall'})       --usage hints

--Other resources for cross-checks:
--  - https://simplistic6502.github.io/smb1_tll/smbpedia_movement.html
--  - https://datacrystal.tcrf.net/w/index.php?title=Super_Mario_Bros./RAM_map
--  - https://web.archive.org/web/20140406030423/http://s276.photobucket.com/user/jdaster64/media/smb_playerphysics.png.html
--  -  -or- https://web.archive.org/web/20130807122227im_/http://i276.photobucket.com/albums/kk21/jdaster64/smb_playerphysics.png
--  - https://www.speedrun.com/smb1/guides/elaz6


--Start CSV writer
local file = assert(io.open("my_data_log.csv", "w"), "Could not open CSV for writing!")

file:write("Frame,LagCount,LagFrame,Input,XPos,XPosSmooth,XVel,XVelSmooth,XAcc,YPos,YVel,YVelSmooth,YAcc,")
file:write("MoveDirByte,XSpeedByte,YPageByte,PlayerState,PlayerControl,PlayerStatus,")
file:write("\n")


--Register "on-close" callback
emu.registerexit(function()
	file:close()
end)





--
--THIS SECTION DEFINES "HELPER" FUNCTIONS USED IN THE MAIN LOOP
--


--Joypad string helper function
local function get_joypad_string(buttons_down)
	local joy_str = ""
	
	if buttons_down.A      then joy_str = joy_str .. "A" else joy_str = joy_str .. "." end
	if buttons_down.B      then joy_str = joy_str .. "B" else joy_str = joy_str .. "." end
	if buttons_down.select then joy_str = joy_str .. "S" else joy_str = joy_str .. "." end
	if buttons_down.start  then joy_str = joy_str .. "T" else joy_str = joy_str .. "." end
	if buttons_down.up     then joy_str = joy_str .. "U" else joy_str = joy_str .. "." end
	if buttons_down.down   then joy_str = joy_str .. "D" else joy_str = joy_str .. "." end
	if buttons_down.left   then joy_str = joy_str .. "L" else joy_str = joy_str .. "." end
	if buttons_down.right  then joy_str = joy_str .. "R" else joy_str = joy_str .. "." end
	
	return joy_str
end


-- X PHYSICS --


--X position (actual)
local function get_xpos()
	local xpos1 = memory.readbyte(ram_SprObject_PageLoc)
	local xpos2 = memory.readbyte(ram_SprObject_X_Position)
	
	local xpos = xpos1*256 + xpos2
	
	return xpos
end


--X position smooth (includes accumulators; for visualization)
local function get_xpos_smooth()
	local xpos1 = memory.readbyte(ram_SprObject_PageLoc)
	local xpos2 = memory.readbyte(ram_SprObject_X_Position)
	local xpos3 = memory.readbyte(ram_SprObject_X_MoveForce)
	
	local xpos = xpos1*256 + xpos2 + xpos3/256
	
	return xpos
end


--X velocity, scaled (actual)
local function get_xvel()
	local xvel = memory.readbytesigned(ram_Player_X_Speed)
	
	return xvel
end


--X velocity smooth, scaled (includes accumulators; for visualization)
local function get_xvel_smooth()
	local xvel1 = memory.readbytesigned(ram_Player_X_Speed)
	local xvel2 = memory.readbyte(ram_Player_X_MoveForce)
	
	--This logic is wrong for this application, per https://claude.ai/share/91733d95-12e5-46f5-b120-e794083eb3ab
	--if xvel1 < 0 then  --Process subspeed byte to add to X velocity
	--	xvel2 = -AND(256 - xvel2, 0xFF)
	--end
	
	local xvel = xvel1 + xvel2/256
	
	if xvel > 40 then  --Apply hardcoded "hard cap" on max possible speed
		xvel = 40
	elseif xvel < -40 then
		xvel = -40
	end
	
	return xvel
end


--X acceleration, scaled
local function get_xacc()
	local xacc1 = memory.readbyte(ram_FrictionAdderHigh)
	local xacc2 = memory.readbyte(ram_FrictionAdderLow)
	
	local xacc = xacc1 + xacc2/256
	
	return xacc
end


-- Y PHYSICS --


--Y position (actual)
local function get_ypos()
	local ypos1 = memory.readbyte(ram_SprObject_Y_Position)
	local ypos2 = memory.readbyte(ram_SprObject_YMF_Dummy)
	
	local ypos = ypos1 + ypos2/256
	
	return ypos
end


--Y velocity, scaled (actual)
local function get_yvel()
	local yvel = memory.readbytesigned(ram_Player_Y_Speed)
	
	return yvel
end


--Y velocity smooth, scaled (includes accumulators; for visualization)
local function get_yvel_smooth()
	local yvel1 = memory.readbytesigned(ram_Player_Y_Speed)
	local yvel2 = memory.readbyte(ram_Player_Y_MoveForce)
	
	--This logic is wrong for this application, per https://claude.ai/share/91733d95-12e5-46f5-b120-e794083eb3ab
	--if yvel1 < 0 then  --Process subspeed byte to add to Y velocity
	--	yvel2 = -AND(256 - yvel2, 0xFF)
	--end
	
	local yvel = yvel1 + yvel2/256
	
	return yvel
end


--Y acceleration, scaled
local function get_yacc()
	local yacc = memory.readbyte(ram_VerticalForce)
	
	return yacc
end





--
--THIS "MAIN LOOP" SECTION PROBES THE EMULATION STATE BEFORE EACH FRAME-ADVANCE
-- • This loop will execute during live play, movie playback, or manual frame-advance
-- • TODO: Consider if we want to structure for "registerafter" callback instead?
--


while true do
	
	
	-- LAST FRAME --
	
	
	--Frame count
	file:write(string.format("%d,", emu.framecount()))
	
	--Lag count
	file:write(string.format("%d,", emu.lagcount()))
	
	--Lagged
	file:write(string.format("%d,", emu.lagged() and 1 or 0))
	
	--Joypad inputs
	local buttons_down = joypad.getdown(1)
	file:write(get_joypad_string(buttons_down))
	file:write(",")
	
	-- X DATA --
	
	--X position
	local xpos = get_xpos()
	file:write(string.format("%.9f,", xpos))
    
	local xpos_smooth = get_xpos_smooth()
	file:write(string.format("%.9f,", xpos_smooth))
	
	--X velocity
	local xvel = get_xvel()
	file:write(string.format("%.9f,", xvel))
	
	local xvel_smooth = get_xvel_smooth()
	file:write(string.format("%.9f,", xvel_smooth))
	
	--X acceleration
	local xacc = get_xacc()
	file:write(string.format("%.9f,", xacc))
	
	-- Y DATA --
	
	--Y position
	local ypos = get_ypos()
	file:write(string.format("%.9f,", ypos))
	
	--Y velocity
	local yvel = get_yvel()
	file:write(string.format("%.9f,", yvel))
	
	local yvel_smooth = get_yvel_smooth()
	file:write(string.format("%.9f,", yvel_smooth))
	
	--Y acceleration
	local yacc = get_yacc()
	file:write(string.format("%.9f,", yacc))
	
	-- DIAGNOSTICS --
	
	file:write(string.format("%d,", memory.readbyte(DIS_PLAYER_MOVINGDIR)))
	file:write(string.format("%d,", memory.readbyte(DIS_PLAYER_XSPEEDABSOLUTE)))
	file:write(string.format("%d,", memory.readbyte(DIS_PLAYER_Y_HIGHPOS)))
	file:write(string.format("%d,", memory.readbyte(DIS_PLAYER_STATE)))
	file:write(string.format("%d,", memory.readbyte(GYM_GAMEENGINESUBROUTINE)))
	file:write(string.format("%d,", memory.readbyte(GYM_PLAYERSTATUS)))
	
	
	--End of CSV line
	file:write("\n")
	
	
	-- NEXT FRAME --
	
	
	--NOTE: Can programatically set next joypad inputs here
	
	--Return control to emulator
	emu.frameadvance()
	
end
