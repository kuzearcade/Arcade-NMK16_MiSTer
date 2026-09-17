-- Same measurement as the hardware overlay: which 8 KB regions of the 256 KB
-- program ROM the 68000 touches, in ~1.7 s windows (100 frames at ~60 Hz).
local mac = manager.machine
local m68 = mac.devices[":maincpu"].spaces["program"]
N=0; VIS=0; C=nil
TAP = m68:install_read_tap(0x000000, 0x03FFFF, "rom", function(o,d,m)
    local b = (o >> 13) & 31
    VIS = VIS | (1 << b)
    return d
end)
local function show(tag)
  local s = ""
  for i=31,0,-1 do s = s .. (((VIS >> i) & 1) == 1 and "1" or ".") end
  print(string.format("  %-14s bucket31..0 = %s   (0x%08X)", tag, s, VIS))
  VIS = 0
end
NOTIF = emu.add_machine_frame_notifier(function()
  N=N+1
  if N==2 then for pt,p in pairs(mac.ioport.ports) do for fn,f in pairs(p.fields) do
      if fn=="Coin 1" then C=f end end end end
  if N==400  then show("attract-1") end
  if N==500  then show("attract-2") end
  if N==560  then C:set_value(1) end
  if N==600  then C:set_value(0) end
  if N==700  then show("after-coin") end
  if N==800  then show("after-coin2"); mac:exit() end
end)
