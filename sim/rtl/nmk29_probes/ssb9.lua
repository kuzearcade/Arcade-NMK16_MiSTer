local mac = manager.machine
local m68 = mac.devices[":maincpu"].spaces["program"]
N=0; B9=0; EXACT=0; SEQ=0; C=nil
-- bucket 9 as a whole (0x12000-0x13FFF), the exact trapped word, and the
-- sequencer routine at 0x008876-0x008887
T1 = m68:install_read_tap(0x012000, 0x013FFF, "b9",  function(o,d,m) B9=B9+1; if o==0x13FF0 then EXACT=EXACT+1 end; return d end)
T2 = m68:install_read_tap(0x008876, 0x008887, "seq", function(o,d,m) SEQ=SEQ+1; return d end)
NOTIF = emu.add_machine_frame_notifier(function()
  N=N+1
  if N==2 then for pt,p in pairs(mac.ioport.ports) do for fn,f in pairs(p.fields) do
      if fn=="Coin 1" then C=f end end end end
  if N==900  then print(string.format("  MAME pre-coin : bucket9 reads=%d  0x13FF0 reads=%d  sequencer fetches=%d", B9, EXACT, SEQ)) end
  if N==960  then C:set_value(1) end
  if N==1000 then C:set_value(0) end
  if N==1600 then print(string.format("  MAME post-coin: bucket9 reads=%d  0x13FF0 reads=%d  sequencer fetches=%d", B9, EXACT, SEQ)); mac:exit() end
end)
