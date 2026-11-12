-- MAME autoboot script (tools/mame_ref.sh): type MAME_TEXT_<n> at frame MAME_AT_<n> (natural keyboard),
-- snapshot at every frame listed in SNAPF (comma separated), then exit after the last.
local n = 0
local snaps, last = {}, 0
for f in (os.getenv("SNAPF") or "400"):gmatch("%d+") do
  snaps[tonumber(f)] = true
  if tonumber(f) > last then last = tonumber(f) end
end
local posts = {}
for i = 1, 9 do
  local f = os.getenv("MAME_AT_" .. i)
  if f then posts[tonumber(f)] = (os.getenv("MAME_TEXT_" .. i) or ""):gsub("\\n", "\n") end
end
-- MAME_SWAP=FRAME:FILE puts FILE in floppy drive 1 at FRAME (as cscp_cmp.sh SWAP=)
local swap_at, swap_file = (os.getenv("MAME_SWAP") or ""):match("^(%d+):(.+)$")
swap_at = tonumber(swap_at)
emu.register_frame_done(function()
  n = n + 1
  if swap_at and n == swap_at then
    for tag, img in pairs(manager.machine.images) do
      if img.instance_name == "floppydisk1" then img:unload(); img:load(swap_file) end
    end
  end
  if posts[n] then manager.machine.natkeyboard:post(posts[n]) end
  if snaps[n] then manager.machine.video:snapshot() end
  if n == last + 2 then manager.machine:exit() end
end)
