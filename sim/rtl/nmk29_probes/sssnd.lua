local mac = manager.machine
local m68 = mac.devices[":maincpu"].spaces["program"]
local z80 = mac.devices[":audiocpu"].spaces["program"]
N=0; SLW=0; OKIW=0; LRD=0; C=nil
TAP1 = m68:install_write_tap(0x0C001E, 0x0C001F, "slw", function(o,d,m) SLW=SLW+1; return d end)
TAP2 = z80:install_write_tap(0x9800, 0x9800, "okiw", function(o,d,m) OKIW=OKIW+1; return d end)
TAP3 = z80:install_write_tap(0x9000, 0x9000, "bank", function(o,d,m) return d end)
NOTIF = emu.add_machine_frame_notifier(function()
  N=N+1
  if N==2 then for pt,p in pairs(mac.ioport.ports) do for fn,f in pairs(p.fields) do
      if fn=="Coin 1" then C=f end end end end
  if N==1200 then print(string.format("  MAME @frame1200 (attract): soundlatchWr=%d okiWr=%d", SLW, OKIW)) end
  if N==1260 then C:set_value(1) end
  if N==1320 then C:set_value(0) end
  if N==1500 then C:set_value(1) end
  if N==1560 then C:set_value(0) end
  if N==2000 then
    print(string.format("  MAME @frame2000 (after 2 coins): soundlatchWr=%d okiWr=%d", SLW, OKIW))
    mac:exit()
  end
end)
