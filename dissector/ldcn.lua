-- PicoShark LDCN Dissector for Wireshark
-- Decodes captures from the PicoShark RS-485 sniffer (DLT_USER0 = 147)
--
-- Installation (copy ldcn.lua, ldcn_core.lua and optionally ldcn_usb.lua):
--   Linux:   ~/.local/lib/wireshark/plugins/
--   Windows: %APPDATA%\Wireshark\plugins\
--   macOS:   ~/.local/lib/wireshark/plugins/
--
-- After installing: Wireshark -> Analyze -> Reload Lua Plugins (Ctrl+Shift+L)
--
-- Frame layout from the Pico: [channel][flags][0xAA][addr][cmd][data...][cksum]

local function load_core()
    if _G.LDCN_CORE then return _G.LDCN_CORE end
    local src = debug.getinfo(1, "S").source or ""
    local dir = src:match("^@(.*[/\\])") or ""
    return dofile(dir .. "ldcn_core.lua")
end

local core = load_core()
local ldcn = core.proto
local F, E, B = core.F, core.E, core.bit

local function pico_dissector(buf, pinfo, tree)
    local len = buf:len()
    if len < 2 then return end   -- Need at least channel + flags

    pinfo.cols.protocol:set("LDCN")

    local root = tree:add(ldcn, buf(), "LDCN Packet")

    local channel = buf(0, 1):uint()
    root:add(F.channel, buf(0, 1))

    local flags = buf(1, 1):uint()
    local ft = root:add(F.flags, buf(1, 1))
    ft:add(F.flag_bcksum, buf(1, 1), B.band(flags, 0x01) ~= 0)
    ft:add(F.flag_invcnt, buf(1, 1), B.band(flags, 0x02) ~= 0)
    ft:add(F.flag_trunc,  buf(1, 1), B.band(flags, 0x04) ~= 0)
    ft:add(F.flag_frame,  buf(1, 1), B.band(flags, 0x08) ~= 0)

    if len < 5 then
        root:add_proto_expert_info(E.too_short)
        return
    end

    -- Device type for the command-set choice comes from the address preference
    local addr = buf(3, 1):uint()
    local devtype = core.devtype(nil, addr)
    local info = core.decode_command(buf(2):tvb(), root, { devtype = devtype })

    pinfo.cols.info:set(string.format("CH%d  %s%s", channel,
        info.summary or "LDCN", (flags ~= 0) and "  [ERR]" or ""))
end

ldcn.dissector = pico_dissector

-- DLT_USER0 = wtap link type 147
DissectorTable.get("wtap_encap"):add(wtap.USER0, ldcn)
