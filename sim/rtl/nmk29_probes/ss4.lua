local mac = manager.machine
local sp  = mac.devices[":maincpu"].spaces["program"]
N=0; C=nil; St=nil
local function snap(tag)
  local s = mac.screens:at(1)
  local px = s:pixels()
  local h=0
  for i=1,#px,997 do h = (h*31 + px:byte(i)) % 1000003 end
  print(string.format("  %s frame %d  screenhash %d", tag, N, h))
end
NOTIF = emu.add_machine_frame_notifier(function()
  N=N+1
  if N==2 then for pt,p in pairs(mac.ioport.ports) do for fn,f in pairs(p.fields) do
      if fn=="Coin 1" then C=f end; if fn=="1 Player Start" then St=f end end end end
  if N==400 then snap("attract ") end
  if N==420 then C:set_value(1) end
  if N==440 then C:set_value(0) end
  if N==500 then C:set_value(1) end
  if N==520 then C:set_value(0) end
  if N==600 then snap("aftercoin") end
  if N==620 then St:set_value(1) end
  if N==640 then St:set_value(0) end
  if N==900 then snap("afterstrt"); mac:exit() end
end)
