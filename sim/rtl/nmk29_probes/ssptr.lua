-- What does MAME put in the object-script pointer at 0x0B5A38, and who writes it?
local mac = manager.machine
local m68 = mac.devices[":maincpu"].spaces["program"]
N=0; WR=0; LASTPC=0; C=nil; VALS={}
T = m68:install_write_tap(0x0B5A38, 0x0B5A3B, "ptr", function(o,d,m)
    WR = WR + 1
    LASTPC = mac.devices[":maincpu"].state["PC"].value
    return d
end)
NOTIF = emu.add_machine_frame_notifier(function()
  N=N+1
  if N==2 then for pt,p in pairs(mac.ioport.ports) do for fn,f in pairs(p.fields) do
      if fn=="Coin 1" then C=f end end end end
  local function dump(tag)
    local hi = m68:read_u16(0x0B5A38); local lo = m68:read_u16(0x0B5A3A)
    print(string.format("  MAME %-11s ptr=%04X%04X  writes=%d  lastWritePC=%06X", tag, hi, lo, WR, LASTPC))
  end
  if N==900  then dump("pre-coin") end
  if N==960  then C:set_value(1) end
  if N==1000 then C:set_value(0) end
  if N==1300 then dump("post-coin") end
  if N==1800 then dump("later"); mac:exit() end
end)
