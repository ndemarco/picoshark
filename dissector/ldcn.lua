-- PicoShark LDCN Dissector for Wireshark
-- Decodes captures from the PicoShark RS-485 sniffer (DLT_USER0 = 147)
--
-- Installation:
--   Linux:   ~/.local/lib/wireshark/plugins/ldcn.lua
--   Windows: %APPDATA%\Wireshark\plugins\ldcn.lua
--   macOS:   ~/.local/lib/wireshark/plugins/ldcn.lua
--
-- After installing: Wireshark → Analyze → Reload Lua Plugins (Ctrl+Shift+L)

local ldcn = Proto("ldcn", "LDCN – Logosol Distributed Control Network")

-- ── Field definitions ─────────────────────────────────────────────────────────

local f_channel     = ProtoField.uint8 ("ldcn.channel",       "Channel",         base.DEC)
local f_flags       = ProtoField.uint8 ("ldcn.flags",         "Flags",           base.HEX)
local f_flag_bcksum = ProtoField.bool  ("ldcn.flags.bad_cksum","Bad Checksum")
local f_flag_invcnt = ProtoField.bool  ("ldcn.flags.inv_count","Invalid Count")
local f_flag_trunc  = ProtoField.bool  ("ldcn.flags.truncated","Truncated")
local f_flag_frame  = ProtoField.bool  ("ldcn.flags.framing",  "Framing Error")
local f_header      = ProtoField.uint8 ("ldcn.header",        "Header",          base.HEX)
local f_address     = ProtoField.uint8 ("ldcn.address",       "Address",         base.HEX)
local f_addr_type   = ProtoField.string("ldcn.address.type",  "Address Type")
local f_command     = ProtoField.uint8 ("ldcn.command",       "Command Byte",    base.HEX)
local f_cmd_name    = ProtoField.string("ldcn.command.name",  "Command")
local f_data_count  = ProtoField.uint8 ("ldcn.data_count",    "Data Count",      base.DEC)
local f_data        = ProtoField.bytes ("ldcn.data",          "Data")
local f_brd         = ProtoField.uint8 ("ldcn.brd",           "Baud Rate Div",   base.HEX)
local f_checksum    = ProtoField.uint8 ("ldcn.checksum",      "Checksum",        base.HEX)
local f_cksum_ok    = ProtoField.bool  ("ldcn.checksum.valid","Checksum Valid")
local f_cksum_exp   = ProtoField.uint8 ("ldcn.checksum.expected","Expected",     base.HEX)

ldcn.fields = {
    f_channel, f_flags, f_flag_bcksum, f_flag_invcnt, f_flag_trunc, f_flag_frame,
    f_header, f_address, f_addr_type, f_command, f_cmd_name, f_data_count,
    f_data, f_brd, f_checksum, f_cksum_ok, f_cksum_exp,
}

-- ── Command lookup ────────────────────────────────────────────────────────────

local CMD_NAMES = {
    [0x1] = "Set Address",
    [0x2] = "Define Status",
    [0x3] = "Read Status",
    [0x4] = "Set PWM",
    [0x5] = "Synch Output",
    [0x6] = "Set Outputs",
    [0x7] = "Set Synch Output",
    [0x8] = "Set Timer Mode",
    [0xA] = "Set Baud Rate",
    [0xC] = "Synch Input",
    [0xE] = "NoOp",
    [0xF] = "Hard Reset",
}

-- BRD byte → baud rate (LDCN protocol values)
local BRD_BAUD = {
    [0x81] =    9600,
    [0x3F] =   19200,
    [0x14] =   57600,
    [0x0A] =  115200,
    [0x27] =  125000,
    [0x0F] =  312500,
    [0x07] =  625000,
    [0x03] = 1250000,
}

-- ── Dissector function ────────────────────────────────────────────────────────

function ldcn.dissector(buf, pinfo, tree)
    local len = buf:len()
    if len < 2 then return end   -- Need at least channel + flags

    pinfo.cols.protocol:set("LDCN")

    local root = tree:add(ldcn, buf(), "LDCN Packet")

    -- Byte 0: channel
    local channel = buf(0,1):uint()
    root:add(f_channel, buf(0,1))

    -- Byte 1: flags
    local flags = buf(1,1):uint()
    local ft = root:add(f_flags, buf(1,1))
    ft:add(f_flag_bcksum, buf(1,1), bit.band(flags, 0x01) ~= 0)
    ft:add(f_flag_invcnt, buf(1,1), bit.band(flags, 0x02) ~= 0)
    ft:add(f_flag_trunc,  buf(1,1), bit.band(flags, 0x04) ~= 0)
    ft:add(f_flag_frame,  buf(1,1), bit.band(flags, 0x08) ~= 0)

    if len < 5 then
        root:add_proto_expert_info(ldcn.experts.too_short)
        return
    end

    -- Byte 2: LDCN header (always 0xAA)
    root:add(f_header, buf(2,1))

    -- Byte 3: address
    local addr = buf(3,1):uint()
    local at = root:add(f_address, buf(3,1))
    if addr == 0x00 then
        at:add(f_addr_type, buf(3,1), "Default (initialisation)")
    elseif addr == 0xFF then
        at:add(f_addr_type, buf(3,1), "Broadcast")
    elseif addr >= 0x80 then
        at:add(f_addr_type, buf(3,1), "Group")
    else
        at:add(f_addr_type, buf(3,1), "Individual")
    end

    -- Byte 4: command
    local cmd_byte  = buf(4,1):uint()
    local cmd_val   = bit.band(cmd_byte, 0x0F)
    local data_cnt  = bit.rshift(cmd_byte, 4)
    local cmd_name  = CMD_NAMES[cmd_val] or string.format("Unknown (0x%X)", cmd_val)

    local ct = root:add(f_command, buf(4,1),
                        string.format("0x%02X  (%s, %d data bytes)", cmd_byte, cmd_name, data_cnt))
    ct:add(f_cmd_name,   buf(4,1), cmd_name)
    ct:add(f_data_count, buf(4,1), data_cnt)

    -- Data bytes
    local data_end = 5 + data_cnt
    if data_cnt > 0 then
        if len < data_end then
            root:add_proto_expert_info(ldcn.experts.truncated)
            return
        end
        local db = root:add(f_data, buf(5, data_cnt))

        -- Special decode: Set Baud Rate
        if cmd_val == 0xA and data_cnt == 1 then
            local brd  = buf(5,1):uint()
            local baud = BRD_BAUD[brd] or "unknown"
            db:add(f_brd, buf(5,1),
                   string.format("BRD=0x%02X → %s baud", brd, tostring(baud)))
        end
    end

    -- Checksum
    if len < data_end + 1 then
        root:add_proto_expert_info(ldcn.experts.truncated)
        return
    end

    local cksum_rx   = buf(data_end, 1):uint()
    local cksum_calc = addr + cmd_byte
    for i = 0, data_cnt - 1 do
        cksum_calc = cksum_calc + buf(5 + i, 1):uint()
    end
    cksum_calc = bit.band(cksum_calc, 0xFF)

    local ckt = root:add(f_checksum, buf(data_end, 1))
    local ok  = (cksum_calc == cksum_rx)
    ckt:add(f_cksum_ok, buf(data_end, 1), ok)
    if not ok then
        ckt:add(f_cksum_exp, buf(data_end, 1), cksum_calc)
        ckt:add_proto_expert_info(ldcn.experts.bad_checksum)
    end

    -- Info column summary
    local addr_str = string.format("0x%02X", addr)
    if addr == 0xFF then addr_str = "broadcast" end
    pinfo.cols.info:set(string.format("CH%d  %-16s  addr=%s%s",
        channel, cmd_name, addr_str,
        (flags ~= 0) and "  [ERR]" or ""))
end

-- ── Expert info ───────────────────────────────────────────────────────────────

ldcn.experts = {
    too_short    = ProtoExpert.new("ldcn.expert.too_short",    "Packet too short",
                                   expert.group.MALFORMED, expert.severity.ERROR),
    truncated    = ProtoExpert.new("ldcn.expert.truncated",    "Data truncated",
                                   expert.group.MALFORMED, expert.severity.ERROR),
    bad_checksum = ProtoExpert.new("ldcn.expert.bad_checksum", "Bad checksum",
                                   expert.group.CHECKSUM,  expert.severity.WARN),
}

-- ── Registration ──────────────────────────────────────────────────────────────

-- DLT_USER0 = wtap link type 147
local wtap_table = DissectorTable.get("wtap_encap")
wtap_table:add(wtap.USER0, ldcn)
