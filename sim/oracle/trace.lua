-- NMK16 MiSTerFPGA project — MAME oracle tracer.
--
-- Loaded via `mame <game> -autoboot_script sim/oracle/trace.lua`. Uses MAME's
-- non-intrusive bus-tap API (space:install_read_tap/install_write_tap) to
-- log every CPU bus transaction in a configured address range, plus a
-- per-frame screen checksum (register_frame_done + screen:pixel) and
-- optional per-frame CPU register snapshots, to a plain-text trace file
-- that sim/compare/oracle_diff.py parses. See docs/sim-harness.md for the
-- full trace format grammar and rationale (no JSON/external Lua libs used,
-- so this has zero dependency on MAME's plugin system).
--
-- Configuration is via environment variables (autoboot scripts get no CLI
-- args of their own):
--   NMKTRACE_OUT         output file path (required)
--   NMKTRACE_CPU         bus-trace CPU device tag, e.g. ":maincpu" (optional;
--                         omit to skip bus tracing entirely)
--   NMKTRACE_SPACE       address space name (default "program")
--   NMKTRACE_ADDR_START  hex string, default "0"
--   NMKTRACE_ADDR_END    hex string, default "ffffff"
--   NMKTRACE_SCREEN      screen device tag (default ":screen")
--   NMKTRACE_CLOCK_HZ    master clock for cycle-count timestamps (default 8000000)
--   NMKTRACE_MAX_FRAMES  stop and exit MAME after N frames (default: unlimited,
--                         rely on -seconds_to_run instead)
--   NMKTRACE_REGS        comma-separated register names to snapshot every
--                         frame, e.g. "PC,SP" (optional)
--   NMKTRACE_PC_PERIOD   if set (cycle count), also samples PC via
--                         emu.register_periodic, throttled to at most once
--                         per this many cycles. Emits 'R <cycle> PCFINE
--                         <value>' lines. Requires NMKTRACE_CPU to be set.
--                         CAVEAT, found the hard way: for this driver,
--                         register_periodic's underlying callback did not
--                         fire any more often than once per real frame
--                         (~177920 cycles) regardless of how small a period
--                         was requested — it is NOT a reliable way to get
--                         sub-frame PC resolution for this game. For
--                         genuine fine-grained control-flow debugging, use
--                         MAME's own debugger instead (`-debug -debuglog`,
--                         `wpset`/`bpset`/`trace` commands, output read
--                         from debug.log) — see docs/tier1-bjtwin.md's
--                         "Sprite rendering verification" section for a
--                         worked example that proved decisive where this
--                         env var did not.
--   NMKTRACE_ITEM_INDEX  if set, dumps the full contents of a MAME
--                         save-state item (emu.item(index):read(...)) once
--                         per frame — for verifying host-memory state that
--                         is never a CPU bus transaction and so is
--                         invisible to both the bus tap above and
--                         sim/oracle/debug_capture.py's debugger
--                         watchpoints (nmk16.cpp's sprite_dma() is exactly
--                         this: a straight C++ array copy from a scanline
--                         timer callback, not a 68000 bus write). Find the
--                         index for a given driver-private variable with
--                         `for name,idx in pairs(manager.machine.devices[":"].items)
--                         do print(name,idx) end` in a throwaway
--                         -autoboot_script — root-device (driver_device)
--                         members registered via save_item/save_pointer
--                         show up there as "0/<member name>". Emits
--                         'I <cycle> <frame> <hex bytes...>' lines (u16
--                         entries, little-endian byte pairs, one 'I' line
--                         per frame — NMKTRACE_ITEM_LABEL is cosmetic only,
--                         not part of the line format, just echoed to
--                         stdout at startup for a sanity check).
--   NMKTRACE_ITEM_LABEL  cosmetic label for the above (optional)

local out_path = os.getenv("NMKTRACE_OUT")
if not out_path then
	print("[nmktrace] NMKTRACE_OUT not set, tracer disabled")
	return
end

local cpu_tag        = os.getenv("NMKTRACE_CPU")
local space_name     = os.getenv("NMKTRACE_SPACE") or "program"
local addr_start     = tonumber(os.getenv("NMKTRACE_ADDR_START") or "0", 16)
local addr_end       = tonumber(os.getenv("NMKTRACE_ADDR_END") or "ffffff", 16)
local screen_tag     = os.getenv("NMKTRACE_SCREEN") or ":screen"
local clock_hz       = tonumber(os.getenv("NMKTRACE_CLOCK_HZ") or "8000000")
local max_frames     = tonumber(os.getenv("NMKTRACE_MAX_FRAMES") or "0")
local reg_list_raw   = os.getenv("NMKTRACE_REGS")
local pc_period      = tonumber(os.getenv("NMKTRACE_PC_PERIOD") or "0")
local item_index     = tonumber(os.getenv("NMKTRACE_ITEM_INDEX") or "")
local item_label     = os.getenv("NMKTRACE_ITEM_LABEL") or "item"

local reg_names = {}
if reg_list_raw then
	for name in string.gmatch(reg_list_raw, "[^,]+") do
		reg_names[#reg_names + 1] = name
	end
end

local out = assert(io.open(out_path, "w"))
local out_closed = false -- register_periodic/frame_done can still fire briefly
                          -- after out:close() below; guard writes on this.

-- ---------------------------------------------------------------------
-- Pure-Lua CRC32 (IEEE 802.3 / zlib polynomial), so frame checksums are
-- directly reproducible with Python's zlib.crc32 on the comparison side
-- without depending on any MAME plugin library being present.
-- ---------------------------------------------------------------------
local crc32_table = {}
for i = 0, 255 do
	local c = i
	for _ = 1, 8 do
		if (c & 1) ~= 0 then
			c = 0xEDB88320 ~ (c >> 1)
		else
			c = c >> 1
		end
	end
	crc32_table[i] = c
end

local function crc32_update(crc, byte)
	return crc32_table[(crc ~ byte) & 0xFF] ~ (crc >> 8)
end

-- ---------------------------------------------------------------------
-- Header
-- ---------------------------------------------------------------------
out:write(string.format("# nmktrace v1 game=%s clock_hz=%d cpu=%s space=%s addr=%x-%x screen=%s\n",
	emu.romname(), clock_hz, cpu_tag or "-", space_name, addr_start, addr_end, screen_tag))
out:flush()

local function cycle_ts()
	return math.floor(manager.machine.time:as_double() * clock_hz)
end

-- ---------------------------------------------------------------------
-- Bus tracing
-- ---------------------------------------------------------------------
if cpu_tag then
	local ok, cpu = pcall(function() return manager.machine.devices[cpu_tag] end)
	if ok and cpu then
		local space = cpu.spaces[space_name]
		if space then
			space:install_read_tap(addr_start, addr_end, "nmktrace_r", function(offset, data, mem_mask)
				out:write(string.format("B %d r %x %x %x\n", cycle_ts(), offset, data, mem_mask))
				return nil -- don't alter the read
			end)
			space:install_write_tap(addr_start, addr_end, "nmktrace_w", function(offset, data, mem_mask)
				out:write(string.format("B %d w %x %x %x\n", cycle_ts(), offset, data, mem_mask))
				return nil -- don't alter the write
			end)
			print(string.format("[nmktrace] bus tracing %s:%s [%x-%x]", cpu_tag, space_name, addr_start, addr_end))
		else
			print(string.format("[nmktrace] WARNING: space '%s' not found on %s, bus tracing disabled", space_name, cpu_tag))
		end
	else
		print(string.format("[nmktrace] WARNING: cpu device '%s' not found, bus tracing disabled", cpu_tag))
	end
end

-- ---------------------------------------------------------------------
-- Optional save-item dump (see NMKTRACE_ITEM_INDEX above)
-- ---------------------------------------------------------------------
local save_item_obj = nil
if item_index then
	save_item_obj = emu.item(item_index)
	if save_item_obj.count == 0 then
		print(string.format("[nmktrace] WARNING: item index %d ('%s') has zero count, bad index?", item_index, item_label))
		save_item_obj = nil
	else
		print(string.format("[nmktrace] dumping item %d ('%s') per frame: size=%d count=%d",
			item_index, item_label, save_item_obj.size, save_item_obj.count))
	end
end

-- ---------------------------------------------------------------------
-- Per-frame screen checksum + optional register snapshot
-- ---------------------------------------------------------------------
local frame_count = 0

emu.register_frame_done(function()
	local screen = manager.machine.screens[screen_tag]
	if not screen then
		return
	end

	local w = screen.width
	local h = screen.height
	local crc = 0xFFFFFFFF
	for y = 0, h - 1 do
		for x = 0, w - 1 do
			local px = screen:pixel(x, y)
			crc = crc32_update(crc, px & 0xFF)
			crc = crc32_update(crc, (px >> 8) & 0xFF)
			crc = crc32_update(crc, (px >> 16) & 0xFF)
		end
	end
	crc = (crc ~ 0xFFFFFFFF) & 0xFFFFFFFF

	out:write(string.format("F %d %d %08x\n", cycle_ts(), frame_count, crc))

	if #reg_names > 0 and cpu_tag then
		local cpu = manager.machine.devices[cpu_tag]
		if cpu then
			for _, name in ipairs(reg_names) do
				local entry = cpu.state[name]
				if entry then
					out:write(string.format("R %d %s %x\n", cycle_ts(), name, entry.value))
				end
			end
		end
	end

	if save_item_obj then
		local parts = {}
		for i = 0, save_item_obj.count - 1 do
			parts[#parts + 1] = string.format("%04x", save_item_obj:read(i) & 0xFFFF)
		end
		out:write(string.format("I %d %d %s\n", cycle_ts(), frame_count, table.concat(parts, "")))
	end

	out:flush()
	frame_count = frame_count + 1

	if max_frames > 0 and frame_count >= max_frames then
		print(string.format("[nmktrace] reached NMKTRACE_MAX_FRAMES=%d, exiting", max_frames))
		out_closed = true
		out:close()
		manager.machine:exit()
	end
end)

-- ---------------------------------------------------------------------
-- Fine-grained PC sampling (optional, see NMKTRACE_PC_PERIOD above)
-- ---------------------------------------------------------------------
if pc_period > 0 and cpu_tag then
	local cpu = manager.machine.devices[cpu_tag]
	if cpu then
		local pc_state = cpu.state["PC"]
		local last_sample_cycle = -pc_period
		emu.register_periodic(function()
			if out_closed then return end
			local now = cycle_ts()
			if now - last_sample_cycle >= pc_period then
				last_sample_cycle = now
				out:write(string.format("R %d PCFINE %x\n", now, pc_state.value))
				out:flush()
			end
		end)
		print(string.format("[nmktrace] fine PC sampling every >=%d cycles", pc_period))
	end
end

-- No Lua-exposed machine-exit/stop notifier exists in this MAME build (only
-- register_prestart/frame_done/sound_update/periodic are bound) — the trace
-- file is flushed after every frame instead, so a run ended externally
-- (Ctrl+C, -seconds_to_run, window close) never loses buffered data; it
-- just lacks the "# nmktrace end" trailer line the MAX_FRAMES path writes.

print(string.format("[nmktrace] tracing to %s (clock_hz=%d)", out_path, clock_hz))
