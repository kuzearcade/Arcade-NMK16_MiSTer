local mac = manager.machine
local m68 = mac.devices[":maincpu"].spaces["program"]
N=0; TAB=0; CODE=0; C=nil
T1 = m68:install_read_tap(0x00E354, 0x00E367, "tab", function(o,d,m) TAB=TAB+1; return d end)
T2 = m68:install_read_tap(0x007D42, 0x007D59, "code", function(o,d,m) CODE=CODE+1; return d end)
NOTIF = emu.add_machine_frame_notifier(function()
  N=N+1
  if N==2 then for pt,p in pairs(mac.ioport.ports) do for fn,f in pairs(p.fields) do
      if fn=="Coin 1" then C=f end end end end
  if N==300  then print(string.format("  MAME frame300  coinage-table reads=%d  routine fetches=%d", TAB, CODE)) end
  if N==900  then print(string.format("  MAME frame900  coinage-table reads=%d  routine fetches=%d", TAB, CODE)) end
  if N==960  then C:set_value(1) end
  if N==1000 then C:set_value(0) end
  if N==1400 then print(string.format("  MAME frame1400 (after coin) reads=%d  fetches=%d", TAB, CODE)); mac:exit() end
end)
