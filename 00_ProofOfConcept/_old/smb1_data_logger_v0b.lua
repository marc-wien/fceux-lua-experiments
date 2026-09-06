--Author: @marcofarfisa. Thanks to @TheNoSwearGuy.


--
--THIS SECTION IS ONE-TIME PREP.
--

--RAM addresses
local ram_Player_State          = 0x001D
local ram_SprObject_PageLoc     = 0x06D  --X position
local ram_SprObject_X_Position  = 0x086
local ram_SprObject_X_MoveForce = 0x400
local ram_Player_X_Speed        = 0x057  --X velocity
local ram_Player_X_MoveForce    = 0x705
local ram_SprObject_Y_Position  = 0x0CE  --Y position
local ram_SprObject_YMF_Dummy   = 0x416
local ram_Player_Y_Speed        = 0x09F  --Y velocity
local ram_Player_Y_MoveForce    = 0x433
local ram_FrictionAdderLow      = 0x702  --X acceleration
local ram_VerticalForce         = 0x709  --Y acceleration

--Start CSV writer
local file = io.open("my_data_log.csv", "w")

file:write(string.format("Frame,Input,Px,Vx,Ax,"))
file:write(string.format("\n"))

emu.registerexit(function()
	file:close()
end)


--
--THIS SECTION PROBES THE EMULATION STATE BEFORE EACH FRAME-ADVANCE.
-- • This loop will execute during live play, movie playback, or manual frame-advance
-- • TODO: Consider if we want to structure for "registerafter" callback instead?
--

while true do
	
	--Frame count
	file:write(string.format("%d,", emu.framecount()))
	
	--Joypad inputs
	local input = joypad.getdown(1)
	for pressed_button_name in pairs(input) do
		file:write(pressed_button_name)
	end 
	file:write(string.format(","))
	
	--X position
	local xpos1 = memory.readbyte(ram_SprObject_PageLoc)
	local xpos2 = memory.readbyte(ram_SprObject_X_Position)
	local xpos3 = memory.readbyte(ram_SprObject_X_MoveForce)
	
	local xpos = xpos1*256 + xpos2 + xpos3/256
	
	file:write(string.format("%.11f,", xpos))
	
	--X velocity
	local xvel1 = memory.readbytesigned(ram_Player_X_Speed)
	local xvel2 = memory.readbyte(ram_Player_X_MoveForce)
	
	if xvel1 < 0 then  --Process subspeed byte to add to X velocity
		xvel2 = -AND(256 - xvel2, 0xFF)
	end
	
	local xvel = xvel1 + xvel2/256
	
	file:write(string.format("%.11f,", xvel))
	
	--X acceleration
	local xacc1 = memory.readbyte(ram_FrictionAdderLow - 1)
	local xacc2 = memory.readbyte(ram_FrictionAdderLow)
	
	local xacc = xacc1 + xacc2/256
	
	file:write(string.format("%.11f,", xacc))
	
	--End of CSV line
	file:write(string.format("\n"))
	
	--Return control to emulator
	emu.frameadvance()
end