-- LDCN core: shared protocol tables, field definitions, command/status
-- decoders and the request/reply state model used by both front-ends:
--
--   ldcn.lua      PicoShark RS-485 sniffer captures (DLT_USER0 = 147)
--   ldcn_usb.lua  USBPcap captures of an FTDI USB-to-RS485 converter
--
-- This file is loaded by the front-ends with dofile(); Wireshark also loads
-- it directly as a plugin.  The global guard makes both paths share one
-- Proto so field names are registered exactly once.

if _G.LDCN_CORE then return _G.LDCN_CORE end

local core = {}
_G.LDCN_CORE = core

-- ── Bit-op compatibility (Wireshark ships Lua 5.1/5.2 with `bit`, 5.4 may not) ──

local B = bit32 or bit
if not (B and B.band and B.bor and B.rshift and B.lshift) then
    B = {
        band   = load("return function(a, b) return a & b end")(),
        bor    = load("return function(a, b) return a | b end")(),
        rshift = load("return function(a, n) return a >> n end")(),
        lshift = load("return function(a, n) return a << n end")(),
    }
end
core.bit = B

local function bitset(value, b) return B.band(value, B.lshift(1, b)) ~= 0 end
core.bitset = bitset

-- ── Protocol ────────────────────────────────────────────────────────────────

local proto = Proto("ldcn", "LDCN - Logosol Distributed Control Network")
core.proto = proto

proto.prefs.devtypes = Pref.string("Device types by address", "",
    "Comma-separated addr:type pairs, e.g. \"1:servo,2:servo,10:io,11:sk2310\". " ..
    "Types: servo (LS-231SE), io (LS-773), sk2310 (SK-2310g2). " ..
    "Addresses in decimal or 0x hex. Unlisted addresses default to servo " ..
    "unless a Device ID reply identifies them.")

-- ── Fields ──────────────────────────────────────────────────────────────────

local F = {}
core.F = F

-- PicoShark capture envelope
F.channel        = ProtoField.uint8 ("ldcn.channel",            "Channel",             base.DEC)
F.flags          = ProtoField.uint8 ("ldcn.flags",              "Flags",               base.HEX)
F.flag_bcksum    = ProtoField.bool  ("ldcn.flags.bad_cksum",    "Bad Checksum")
F.flag_invcnt    = ProtoField.bool  ("ldcn.flags.inv_count",    "Invalid Count")
F.flag_trunc     = ProtoField.bool  ("ldcn.flags.truncated",    "Truncated")
F.flag_frame     = ProtoField.bool  ("ldcn.flags.framing",      "Framing Error")

-- Common
F.direction      = ProtoField.string("ldcn.direction",          "Direction")
F.devtype        = ProtoField.string("ldcn.devtype",            "Device Type")
F.header         = ProtoField.uint8 ("ldcn.header",             "Header",              base.HEX)
F.address        = ProtoField.uint8 ("ldcn.address",            "Address",             base.HEX)
F.addr_type      = ProtoField.string("ldcn.address.type",       "Address Type")
F.command        = ProtoField.uint8 ("ldcn.command",            "Command Byte",        base.HEX)
F.cmd            = ProtoField.uint8 ("ldcn.cmd",                "Command Value",       base.DEC)
F.cmd_name       = ProtoField.string("ldcn.command.name",       "Command")
F.data_count     = ProtoField.uint8 ("ldcn.data_count",         "Data Count",          base.DEC)
F.data           = ProtoField.bytes ("ldcn.data",               "Data")
F.checksum       = ProtoField.uint8 ("ldcn.checksum",           "Checksum",            base.HEX)
F.cksum_ok       = ProtoField.bool  ("ldcn.checksum.valid",     "Checksum Valid")
F.cksum_exp      = ProtoField.uint8 ("ldcn.checksum.expected",  "Expected",            base.HEX)
F.response_in    = ProtoField.framenum("ldcn.response_in",      "Response in frame")
F.response_to    = ProtoField.framenum("ldcn.response_to",      "Response to frame")
F.reassembled_from = ProtoField.framenum("ldcn.reassembled_from", "Reassembled from frame")
F.reassembled_in = ProtoField.framenum("ldcn.reassembled_in",   "Reassembled in frame")
F.segment        = ProtoField.bytes ("ldcn.segment",            "LDCN segment")
F.unmatched      = ProtoField.bytes ("ldcn.unmatched",          "Unmatched bytes")
F.predicted_len  = ProtoField.uint8 ("ldcn.predicted_len",      "Predicted reply length", base.DEC)

-- Command parameters
F.set_addr_ind   = ProtoField.uint8 ("ldcn.set_address.individual", "Individual Address", base.HEX)
F.set_addr_grp   = ProtoField.uint8 ("ldcn.set_address.group",  "Group Address",       base.HEX)
F.set_addr_lead  = ProtoField.bool  ("ldcn.set_address.leader", "Group Leader")
F.status_items   = ProtoField.uint16("ldcn.status_items",       "Status Items Bitmap", base.HEX)
F.brd            = ProtoField.uint8 ("ldcn.brd",                "Baud Rate Divisor",   base.HEX)
F.traj_ctrl      = ProtoField.uint8 ("ldcn.traj.control",       "Trajectory Control",  base.HEX)
F.traj_pos       = ProtoField.int32 ("ldcn.traj.position",      "Position",            base.DEC)
F.traj_vel       = ProtoField.uint32("ldcn.traj.velocity",      "Velocity",            base.DEC)
F.traj_acc       = ProtoField.uint32("ldcn.traj.acceleration",  "Acceleration",        base.DEC)
F.traj_pwm       = ProtoField.uint8 ("ldcn.traj.pwm",           "PWM",                 base.DEC)
F.gain_kp        = ProtoField.uint16("ldcn.gain.kp",            "KP (proportional)",   base.DEC)
F.gain_kd        = ProtoField.uint16("ldcn.gain.kd",            "KD (derivative)",     base.DEC)
F.gain_ki        = ProtoField.uint16("ldcn.gain.ki",            "KI (integral)",       base.DEC)
F.gain_il        = ProtoField.uint16("ldcn.gain.il",            "IL (integration limit)", base.DEC)
F.gain_ol        = ProtoField.uint8 ("ldcn.gain.ol",            "OL (output limit)",   base.DEC)
F.gain_cl        = ProtoField.uint8 ("ldcn.gain.cl",            "CL (current limit)",  base.DEC)
F.gain_el        = ProtoField.uint16("ldcn.gain.el",            "EL (position error limit)", base.DEC)
F.gain_sr        = ProtoField.uint8 ("ldcn.gain.sr",            "SR (servo rate divisor)", base.DEC)
F.gain_dc        = ProtoField.uint8 ("ldcn.gain.dc",            "DC (deadband compensation)", base.DEC)
F.stop_ctrl      = ProtoField.uint8 ("ldcn.stop.control",       "Stop Control",        base.HEX)
F.io_ctrl        = ProtoField.uint8 ("ldcn.io_control",         "I/O Control",         base.HEX)
F.home_ctrl      = ProtoField.uint8 ("ldcn.home.control",       "Home Mode Control",   base.HEX)
F.path_point     = ProtoField.int32 ("ldcn.path.point",         "Path Point",          base.DEC)
F.ext_sub        = ProtoField.uint8 ("ldcn.ext.subcommand",     "Extended Subcommand", base.HEX)
F.ext_name       = ProtoField.string("ldcn.ext.name",           "Extended Command")
F.ext_value      = ProtoField.uint16("ldcn.ext.value",          "Extended Value",      base.DEC)
F.pwm1           = ProtoField.uint8 ("ldcn.pwm1",               "PWM 1",               base.DEC)
F.pwm2           = ProtoField.uint8 ("ldcn.pwm2",               "PWM 2",               base.DEC)
F.out0           = ProtoField.uint8 ("ldcn.outputs.byte0",      "Outputs Byte 0",      base.HEX)
F.out1           = ProtoField.uint8 ("ldcn.outputs.byte1",      "Outputs Byte 1",      base.HEX)
F.timer_mode     = ProtoField.uint8 ("ldcn.timer_mode",         "Timer Mode",          base.HEX)

-- Status packet
F.status         = ProtoField.uint8 ("ldcn.status",             "Status Byte",         base.HEX)
F.st_move_done   = ProtoField.bool  ("ldcn.status.move_done",   "Move Done")
F.st_cksum_err   = ProtoField.bool  ("ldcn.status.cksum_error", "Checksum Error")
F.st_cur_limit   = ProtoField.bool  ("ldcn.status.current_limit","Current Limit")
F.st_power_on    = ProtoField.bool  ("ldcn.status.power_on",    "Power On")
F.st_pos_error   = ProtoField.bool  ("ldcn.status.pos_error",   "Position Error")
F.st_limit1      = ProtoField.bool  ("ldcn.status.limit1",      "Limit 1 / Home")
F.st_limit2      = ProtoField.bool  ("ldcn.status.limit2",      "Limit 2")
F.st_home_prog   = ProtoField.bool  ("ldcn.status.home_in_progress", "Home In Progress")
F.position       = ProtoField.int32 ("ldcn.position",           "Position",            base.DEC)
F.ad             = ProtoField.uint8 ("ldcn.ad",                 "A/D Value",           base.DEC)
F.velocity       = ProtoField.int16 ("ldcn.velocity",           "Velocity",            base.DEC)
F.aux            = ProtoField.uint8 ("ldcn.aux",                "Auxiliary Status",    base.HEX)
F.home_pos       = ProtoField.int32 ("ldcn.home_position",      "Home Position",       base.DEC)
F.device_id      = ProtoField.uint8 ("ldcn.device_id",          "Device ID",           base.DEC)
F.version        = ProtoField.uint8 ("ldcn.version",            "Firmware Version",    base.DEC)
F.pos_error      = ProtoField.int16 ("ldcn.pos_error",          "Position Error",      base.DEC)
F.path_points    = ProtoField.uint8 ("ldcn.path_points",        "Free Path Points",    base.DEC)
F.digital_in     = ProtoField.uint16("ldcn.digital_inputs",     "Digital Inputs",      base.HEX)
F.analog_in      = ProtoField.uint16("ldcn.analog_inputs",      "Analog Inputs",       base.HEX)
F.watchdog       = ProtoField.uint16("ldcn.watchdog",           "Watchdog",            base.HEX)
F.in0            = ProtoField.uint8 ("ldcn.inputs.byte0",       "Inputs Byte 0",       base.HEX)
F.in1            = ProtoField.uint8 ("ldcn.inputs.byte1",       "Inputs Byte 1",       base.HEX)
F.analog0        = ProtoField.uint8 ("ldcn.analog0",            "Analog 0",            base.DEC)
F.analog1        = ProtoField.uint8 ("ldcn.analog1",            "Analog 1",            base.DEC)
F.analog2        = ProtoField.uint8 ("ldcn.analog2",            "Analog 2",            base.DEC)
F.counter        = ProtoField.uint32("ldcn.counter",            "Counter",             base.DEC)
F.sync_in        = ProtoField.uint16("ldcn.sync_inputs",        "Synchronised Inputs", base.HEX)
F.sync_counter   = ProtoField.uint32("ldcn.sync_counter",       "Synchronised Counter",base.DEC)
F.item_unknown   = ProtoField.bytes ("ldcn.item.unknown",       "Unknown Status Item")

-- SK-2310g2 inputs byte 1
local DIAG_NAMES = {
    [0x00] = "Power-off delay",
    [0x01] = "Initializing",
    [0x02] = "Control voltage shorted",
    [0x03] = "Output shorted",
    [0x04] = "Control voltage low",
    [0x05] = "Home/test switch malfunction",
    [0x06] = "Power-up home error",
    [0x07] = "Power-up test mode error",
    [0x08] = "System locked",
    [0x09] = "Watchdog stop",
    [0x0A] = "Safety link error",
    [0x0B] = "Cover open stop: spindle not stopped",
    [0x0C] = "Cover open stop: not at home",
    [0x0D] = "Cover open stop: test mode no ack",
    [0x0E] = "Cover contact fault",
    [0x0F] = "Limit switch stop",
    [0x10] = "Emergency stop",
    [0x11] = "E-stop contact malfunction or monitor loop open",
    [0x12] = "Busy / power button short / monitor loop open",
    [0x13] = "Motor PSU undervoltage",
    [0x14] = "Covers state: ready to power",
    [0x15] = "Covers state: ready to power",
    [0x16] = "Covers state: ready to power",
    [0x17] = "Covers state: ready to power",
    [0x18] = "Covers state: test mode",
    [0x19] = "Covers state: test mode",
    [0x1A] = "Covers state: test mode",
    [0x1B] = "Covers state: test mode",
    [0x1C] = "Covers state: at home, spindle stopped",
    [0x1D] = "Covers state: at home, spindle stopped",
    [0x1E] = "Covers state: at home, spindle stopped",
    [0x1F] = "Covers closed, power on",
}
core.DIAG_NAMES = DIAG_NAMES

F.diag           = ProtoField.uint8 ("ldcn.diag",               "SK-2310g2 Diagnostic Code", base.HEX, DIAG_NAMES)
F.diag_name      = ProtoField.string("ldcn.diag.name",          "Diagnostic")
F.sk_at_home     = ProtoField.bool  ("ldcn.sk.at_home",         "At Home")
F.sk_test_mode   = ProtoField.bool  ("ldcn.sk.test_mode",       "Test Mode")
F.sk_servo_fault = ProtoField.bool  ("ldcn.sk.servo_fault",     "Servo Fault")

do
    local list = {}
    for _, f in pairs(F) do list[#list + 1] = f end
    proto.fields = list
end

-- ── Expert info ─────────────────────────────────────────────────────────────

local E = {}
core.E = E
E.too_short    = ProtoExpert.new("ldcn.expert.too_short",    "Packet too short",
                                 expert.group.MALFORMED, expert.severity.ERROR)
E.truncated    = ProtoExpert.new("ldcn.expert.truncated",    "Data truncated",
                                 expert.group.MALFORMED, expert.severity.ERROR)
E.bad_checksum = ProtoExpert.new("ldcn.expert.bad_checksum", "Bad checksum",
                                 expert.group.CHECKSUM,  expert.severity.WARN)
E.unexpected   = ProtoExpert.new("ldcn.unexpected",
                                 "Reply does not match predicted length (undocumented status item?)",
                                 expert.group.PROTOCOL,  expert.severity.WARN)
E.unframed     = ProtoExpert.new("ldcn.unframed",            "Bytes could not be framed",
                                 expert.group.PROTOCOL,  expert.severity.WARN)
E.no_reply     = ProtoExpert.new("ldcn.no_reply",            "No reply observed for this command",
                                 expert.group.SEQUENCE,  expert.severity.NOTE)
E.unknown_item = ProtoExpert.new("ldcn.unknown_item",
                                 "Status item with unknown size requested",
                                 expert.group.UNDECODED, expert.severity.WARN)
E.bad_header   = ProtoExpert.new("ldcn.expert.bad_header",   "Header byte is not 0xAA",
                                 expert.group.MALFORMED, expert.severity.WARN)
proto.experts = { E.too_short, E.truncated, E.bad_checksum, E.unexpected, E.unframed,
                  E.no_reply, E.unknown_item, E.bad_header }

-- ── Tables ──────────────────────────────────────────────────────────────────

core.DEVTYPES = { servo = "servo", io = "io", sk2310 = "sk2310" }

local DEVTYPE_ALIASES = {
    servo = "servo", ["ls231"] = "servo", ["ls-231"] = "servo", ["ls231se"] = "servo",
    ["ls-231se"] = "servo", picservo = "servo",
    io = "io", ["ls773"] = "io", ["ls-773"] = "io", picio = "io",
    sk2310 = "sk2310", ["sk2310g2"] = "sk2310", ["sk-2310g2"] = "sk2310", ["sk-2310"] = "sk2310",
}

local function is_io_family(devtype) return devtype == "io" or devtype == "sk2310" end
core.is_io_family = is_io_family

local SERVO_CMDS = {
    [0x0] = "Reset Position",   [0x1] = "Set Address",       [0x2] = "Define Status",
    [0x3] = "Read Status",      [0x4] = "Load Trajectory",   [0x5] = "Start Motion",
    [0x6] = "Set Gain",         [0x7] = "Stop Motor",        [0x8] = "I/O Control",
    [0x9] = "Set Home Mode",    [0xA] = "Set Baud Rate",     [0xB] = "Clear Bits",
    [0xC] = "Save As Home",     [0xD] = "Add Path Points",   [0xE] = "NOP / Extended",
    [0xF] = "Hard Reset",
}

local IO_CMDS = {
    [0x1] = "Set Address",      [0x2] = "Define Status",     [0x3] = "Read Status",
    [0x4] = "Set PWM",          [0x5] = "Synch Output",      [0x6] = "Set Outputs",
    [0x7] = "Set Synch Output", [0x8] = "Set Timer Mode",    [0xA] = "Set Baud Rate",
    [0xC] = "Synch Input",      [0xE] = "NOP",               [0xF] = "Hard Reset",
}

core.SERVO_CMDS = SERVO_CMDS
core.IO_CMDS = IO_CMDS

function core.cmd_name(devtype, cmd)
    local t = is_io_family(devtype) and IO_CMDS or SERVO_CMDS
    return t[cmd] or string.format("Unknown (0x%X)", cmd)
end

local BRD_BAUD = {
    [0x81] =    9600, [0x3F] =   19200, [0x14] =   57600, [0x0A] =  115200,
    [0x27] =  125000, [0x0F] =  312500, [0x07] =  625000, [0x03] = 1250000,
}
core.BRD_BAUD = BRD_BAUD

local EXT_SUBCMDS = {
    [0x00] = "Stop on limits", [0x01] = "Hall init", [0x02] = "Repeat",
    [0x04] = "Hardware sync",  [0x05] = "Watchdog",  [0x10] = "Motor error limit",
}

-- Status items: bit -> { name, size }  (size nil = unknown)
local SERVO_ITEMS = {
    [0]  = { "Position",                 4 },
    [1]  = { "A/D value",                1 },
    [2]  = { "Velocity",                 2 },
    [3]  = { "Auxiliary status",         1 },
    [4]  = { "Home position",            4 },
    [5]  = { "Device ID + version",      2 },
    [6]  = { "Position error",           2 },
    [7]  = { "Free path points",         1 },
    [8]  = { "Digital inputs",           2 },
    [9]  = { "Analog inputs",            2 },
    [10] = { "Unknown item 10",          nil },
    [11] = { "Unknown item 11",          nil },
    [12] = { "Watchdog",                 2 },
    [13] = { "Position + position error", 6 },
    [14] = { "Unknown item 14",          nil },
    [15] = { "Unknown item 15",          nil },
}

local IO_ITEMS = {
    [0]  = { "Inputs byte 0 + byte 1",   2 },
    [1]  = { "Analog 0",                 1 },
    [2]  = { "Analog 1",                 1 },
    [3]  = { "Analog 2",                 1 },
    [4]  = { "Counter",                  4 },
    [5]  = { "Device ID + version",      2 },
    [6]  = { "Synchronised inputs",      2 },
    [7]  = { "Synchronised counter",     4 },
    [8]  = { "Unknown item 8",           nil },
    [9]  = { "Unknown item 9",           nil },
    [10] = { "Unknown item 10",          nil },
    [11] = { "Unknown item 11",          nil },
    [12] = { "Unknown item 12",          nil },
    [13] = { "Unknown item 13",          nil },
    [14] = { "Unknown item 14",          nil },
    [15] = { "Unknown item 15",          nil },
}

function core.items_for(devtype)
    return is_io_family(devtype) and IO_ITEMS or SERVO_ITEMS
end

-- Predicted reply length: status byte + requested items + checksum.
-- Returns nil (and the offending bit) when an item of unknown size is requested.
function core.reply_length(devtype, bitmap)
    local items = core.items_for(devtype)
    local n = 2
    for b = 0, 15 do
        if bitset(bitmap, b) then
            local it = items[b]
            if not it or not it[2] then return nil, b end
            n = n + it[2]
        end
    end
    return n
end

-- ── Helpers ─────────────────────────────────────────────────────────────────

local function bitstr(value, b, width)
    width = width or 8
    local s = {}
    for i = width - 1, 0, -1 do
        if i == b then s[#s + 1] = bitset(value, i) and "1" or "0" else s[#s + 1] = "." end
        if i % 4 == 0 and i > 0 then s[#s + 1] = " " end
    end
    return table.concat(s)
end

-- Add named bit rows under `tree` for `value` taken from `range`.
-- names: table bit -> label; optional fields: table bit -> ProtoField.bool
local function add_bits(tree, range, value, names, fields, width)
    width = width or 8
    for b = 0, width - 1 do
        local name = names and names[b]
        local fld = fields and fields[b]
        local set = bitset(value, b)
        if fld then
            tree:add(fld, range, set):set_text(string.format("%s = %s: %s",
                bitstr(value, b, width), name or ("bit " .. b), set and "Set" or "Not set"))
        elseif name then
            tree:add(range, string.format("%s = %s: %s", bitstr(value, b, width), name,
                set and "Set" or "Not set"))
        end
    end
end
core.add_bits = add_bits

local function addr_type(addr)
    if addr == 0x00 then return "Default (initialisation)"
    elseif addr == 0xFF then return "Broadcast"
    elseif addr >= 0x80 then return "Group"
    else return "Individual" end
end
core.addr_type = addr_type

-- Checksum over a Lua byte string s[from..to] (1-based inclusive)
local function sum_bytes(s, from, to)
    local acc = 0
    for i = from, to do acc = acc + s:byte(i) end
    return B.band(acc, 0xFF)
end
core.sum_bytes = sum_bytes

-- ── Device type preference ──────────────────────────────────────────────────

local pref_cache_src, pref_cache = nil, {}

local function parse_devtypes(str)
    local t = {}
    for entry in (str or ""):gmatch("[^,;%s]+") do
        local a, ty = entry:match("^([%w]+):([%w%-]+)$")
        if a and ty then
            local addr = a:match("^0[xX]%x+$") and tonumber(a) or tonumber(a, 10)
            local norm = DEVTYPE_ALIASES[ty:lower()]
            if addr and norm then t[addr] = norm end
        end
    end
    return t
end

function core.pref_devtypes()
    local src = proto.prefs.devtypes
    if src ~= pref_cache_src then
        pref_cache_src = src
        pref_cache = parse_devtypes(src)
    end
    return pref_cache
end

-- ── Command decoder ─────────────────────────────────────────────────────────

local TRAJ_BITS = {
    [0] = "Load position", [1] = "Load velocity", [2] = "Load acceleration",
    [3] = "Load PWM", [4] = "Servo mode (1=position servo, 0=PWM)",
    [5] = "Profile mode (1=velocity, 0=trapezoidal)",
    [6] = "Direction (velocity/PWM mode, 1=forward)", [7] = "Start motion now",
}
local STOP_BITS = {
    [0] = "Amplifier enable", [1] = "Motor off", [2] = "Stop abruptly",
    [3] = "Stop smoothly", [4] = "Reserved", [5] = "Reserved", [6] = "Reserved", [7] = "Reserved",
}
local HOME_BITS = {
    [0] = "Home on Limit 1", [1] = "Home on Limit 2", [2] = "Home on index",
    [3] = "Stop abruptly on home", [4] = "Stop smoothly on home", [5] = "Motor off on home",
    [6] = "Reserved", [7] = "Reserved",
}
local RAW_BITS = {
    [0] = "bit 0", [1] = "bit 1", [2] = "bit 2", [3] = "bit 3",
    [4] = "bit 4", [5] = "bit 5", [6] = "bit 6", [7] = "bit 7",
}
local TIMER_BITS = {
    [0] = "Counter mode (1) / timer mode (0)", [1] = "bit 1", [2] = "bit 2", [3] = "bit 3",
    [4] = "bit 4", [5] = "bit 5", [6] = "bit 6", [7] = "bit 7",
}
local SK_OUT0_BITS = {
    [0] = "bit 0", [1] = "bit 1", [2] = "Spindle ON", [3] = "Spindle direction",
    [4] = "bit 4", [5] = "bit 5", [6] = "bit 6", [7] = "bit 7",
}
local SK_OUT1_BITS = {
    [0] = "bit 0", [1] = "Cover Lock", [2] = "Home Enable", [3] = "Test Mode Inhibit",
    [4] = "Safety Link Bridge", [5] = "bit 5", [6] = "bit 6", [7] = "System Lock / Power",
}

local function add_status_bitmap(tree, tvb, off, n, devtype)
    local bitmap = tvb(off, 1):uint()
    if n >= 2 then bitmap = bitmap + tvb(off + 1, 1):uint() * 256 end
    local range = tvb(off, math.min(n, 2))
    local t = tree:add(F.status_items, range, bitmap)
    local items = core.items_for(devtype)
    for b = 0, 15 do
        if bitset(bitmap, b) then
            local it = items[b]
            local size = it and it[2]
            t:add(range, string.format("bit %2d: %s (%s)", b, it and it[1] or "unknown",
                size and (size .. " bytes") or "unknown size"))
        end
    end
    return bitmap
end

local function decode_servo_data(tree, tvb, cmd, off, n)
    if cmd == 0x1 and n >= 2 then
        tree:add(F.set_addr_ind, tvb(off, 1))
        local grp = tvb(off + 1, 1):uint()
        local gt = tree:add(F.set_addr_grp, tvb(off + 1, 1))
        gt:add(F.set_addr_lead, tvb(off + 1, 1), grp < 0x80)
        if grp < 0x80 then
            gt:append_text(string.format("  (group leader for 0x%02X)", B.bor(grp, 0x80)))
        end
    elseif (cmd == 0x2 or cmd == 0x3) and n >= 1 then
        add_status_bitmap(tree, tvb, off, n, "servo")
    elseif cmd == 0x4 and n >= 1 then
        local ctrl = tvb(off, 1):uint()
        local ct = tree:add(F.traj_ctrl, tvb(off, 1))
        add_bits(ct, tvb(off, 1), ctrl, TRAJ_BITS)
        local p = off + 1
        local last = off + n
        if bitset(ctrl, 0) and p + 4 <= last then tree:add_le(F.traj_pos, tvb(p, 4)); p = p + 4 end
        if bitset(ctrl, 1) and p + 4 <= last then tree:add_le(F.traj_vel, tvb(p, 4)); p = p + 4 end
        if bitset(ctrl, 2) and p + 4 <= last then tree:add_le(F.traj_acc, tvb(p, 4)); p = p + 4 end
        if bitset(ctrl, 3) and p + 1 <= last then tree:add(F.traj_pwm, tvb(p, 1)); p = p + 1 end
        if p < last then tree:add(tvb(p, last - p), "Extra trajectory bytes") end
    elseif cmd == 0x6 and n >= 13 then
        tree:add_le(F.gain_kp, tvb(off, 2))
        tree:add_le(F.gain_kd, tvb(off + 2, 2))
        tree:add_le(F.gain_ki, tvb(off + 4, 2))
        tree:add_le(F.gain_il, tvb(off + 6, 2))
        tree:add(F.gain_ol, tvb(off + 8, 1))
        tree:add(F.gain_cl, tvb(off + 9, 1))
        tree:add_le(F.gain_el, tvb(off + 10, 2))
        tree:add(F.gain_sr, tvb(off + 12, 1))
        if n >= 14 then tree:add(F.gain_dc, tvb(off + 13, 1)) end
        if n > 14 then tree:add(tvb(off + 14, n - 14), "Extra gain bytes") end
    elseif cmd == 0x7 and n >= 1 then
        local v = tvb(off, 1):uint()
        add_bits(tree:add(F.stop_ctrl, tvb(off, 1)), tvb(off, 1), v, STOP_BITS)
    elseif cmd == 0x8 and n >= 1 then
        local v = tvb(off, 1):uint()
        local t = tree:add(F.io_ctrl, tvb(off, 1))
        t:append_text("  (bit semantics not decoded; see datasheet)")
        add_bits(t, tvb(off, 1), v, RAW_BITS)
    elseif cmd == 0x9 and n >= 1 then
        local v = tvb(off, 1):uint()
        add_bits(tree:add(F.home_ctrl, tvb(off, 1)), tvb(off, 1), v, HOME_BITS)
    elseif cmd == 0xA and n >= 1 then
        local brd = tvb(off, 1):uint()
        tree:add(F.brd, tvb(off, 1)):append_text(string.format("  (%s baud)",
            tostring(BRD_BAUD[brd] or "unknown")))
    elseif cmd == 0xD and n > 0 then
        if n % 3 == 0 then
            for i = 0, math.floor(n / 3) - 1 do
                local p = off + i * 3
                local v = tvb(p, 1):uint() + tvb(p + 1, 1):uint() * 256 + tvb(p + 2, 1):uint() * 65536
                if v >= 0x800000 then v = v - 0x1000000 end
                tree:add(F.path_point, tvb(p, 3), v)
            end
        else
            tree:add(tvb(off, n), "Path point data (not a multiple of 3 bytes; shown raw)")
        end
    elseif cmd == 0xE and n >= 1 then
        local sub = tvb(off, 1):uint()
        local name = EXT_SUBCMDS[sub] or "Unknown extended subcommand"
        local t = tree:add(F.ext_sub, tvb(off, 1))
        t:append_text("  (" .. name .. ")")
        tree:add(F.ext_name, tvb(off, 1), name)
        if n == 3 then
            tree:add_le(F.ext_value, tvb(off + 1, 2))
        elseif n > 1 then
            tree:add(tvb(off + 1, n - 1), "Extended command parameters")
        end
        return name
    end
end

local function decode_io_data(tree, tvb, cmd, off, n, devtype)
    local sk = (devtype == "sk2310")
    if cmd == 0x1 and n >= 2 then
        tree:add(F.set_addr_ind, tvb(off, 1))
        local grp = tvb(off + 1, 1):uint()
        local gt = tree:add(F.set_addr_grp, tvb(off + 1, 1))
        gt:add(F.set_addr_lead, tvb(off + 1, 1), grp < 0x80)
    elseif (cmd == 0x2 or cmd == 0x3) and n >= 1 then
        add_status_bitmap(tree, tvb, off, n, devtype)
    elseif cmd == 0x4 and n >= 1 then
        tree:add(F.pwm1, tvb(off, 1))
        if n >= 2 then tree:add(F.pwm2, tvb(off + 1, 1)) end
    elseif (cmd == 0x6 or cmd == 0x7) and n >= 1 then
        local b0 = tvb(off, 1):uint()
        add_bits(tree:add(F.out0, tvb(off, 1)), tvb(off, 1), b0, sk and SK_OUT0_BITS or RAW_BITS)
        if n >= 2 then
            local b1 = tvb(off + 1, 1):uint()
            add_bits(tree:add(F.out1, tvb(off + 1, 1)), tvb(off + 1, 1), b1, sk and SK_OUT1_BITS or RAW_BITS)
        end
        if cmd == 0x7 and n >= 3 then tree:add(F.pwm1, tvb(off + 2, 1)) end
        if cmd == 0x7 and n >= 4 then tree:add(F.pwm2, tvb(off + 3, 1)) end
    elseif cmd == 0x8 and n >= 1 then
        local v = tvb(off, 1):uint()
        add_bits(tree:add(F.timer_mode, tvb(off, 1)), tvb(off, 1), v, TIMER_BITS)
    elseif cmd == 0xA and n >= 1 then
        local brd = tvb(off, 1):uint()
        tree:add(F.brd, tvb(off, 1)):append_text(string.format("  (%s baud)",
            tostring(BRD_BAUD[brd] or "unknown")))
    end
end

-- Decode a host-to-device command frame starting at tvb offset 0 (0xAA header).
-- opts.devtype selects the command set.  Returns an info table:
--   { addr, cmd_byte, cmd, data_cnt, data (string), cksum_ok, name, complete, summary }
function core.decode_command(tvb, tree, opts)
    opts = opts or {}
    local devtype = opts.devtype or "servo"
    local len = tvb:len()
    local info = { complete = false, devtype = devtype }

    tree:add(F.direction, "tx"):set_generated()
    tree:add(F.devtype, devtype):set_generated()

    if len < 3 then
        tree:add_proto_expert_info(E.too_short)
        info.summary = "short command fragment"
        return info
    end

    local hdr = tvb(0, 1):uint()
    local ht = tree:add(F.header, tvb(0, 1))
    if hdr ~= 0xAA then ht:add_proto_expert_info(E.bad_header) end

    local addr = tvb(1, 1):uint()
    local at = tree:add(F.address, tvb(1, 1))
    at:add(F.addr_type, tvb(1, 1), addr_type(addr))

    local cmd_byte = tvb(2, 1):uint()
    local cmd      = B.band(cmd_byte, 0x0F)
    local data_cnt = B.rshift(cmd_byte, 4)
    local name     = core.cmd_name(devtype, cmd)
    if cmd == 0xE and not is_io_family(devtype) then
        name = (data_cnt == 0) and "NOP" or "Extended"
    end

    local ct = tree:add(F.command, tvb(2, 1))
    ct:append_text(string.format("  (%s, %d data bytes)", name, data_cnt))
    ct:add(F.cmd, tvb(2, 1), cmd)
    ct:add(F.cmd_name, tvb(2, 1), name)
    ct:add(F.data_count, tvb(2, 1), data_cnt)

    info.addr, info.cmd_byte, info.cmd, info.data_cnt, info.name = addr, cmd_byte, cmd, data_cnt, name

    local data_end = 3 + data_cnt
    if len < data_end + 1 then
        tree:add_proto_expert_info(E.truncated)
        info.summary = string.format("%s addr=0x%02X (truncated)", name, addr)
        return info
    end

    local extra
    if data_cnt > 0 then
        local dt = tree:add(F.data, tvb(3, data_cnt))
        if is_io_family(devtype) then
            decode_io_data(dt, tvb, cmd, 3, data_cnt, devtype)
        else
            extra = decode_servo_data(dt, tvb, cmd, 3, data_cnt)
        end
        info.data = tvb(3, data_cnt):raw()
    else
        info.data = ""
    end

    local cksum_rx   = tvb(data_end, 1):uint()
    local cksum_calc = B.band(addr + cmd_byte + sum_bytes(info.data, 1, #info.data), 0xFF)
    local ckt = tree:add(F.checksum, tvb(data_end, 1))
    local ok  = (cksum_calc == cksum_rx)
    ckt:add(F.cksum_ok, tvb(data_end, 1), ok)
    if not ok then
        ckt:add(F.cksum_exp, tvb(data_end, 1), cksum_calc)
        ckt:add_proto_expert_info(E.bad_checksum)
    end
    info.cksum_ok = ok
    info.complete = true

    local addr_str = (addr == 0xFF) and "broadcast" or string.format("0x%02X", addr)
    local detail = ""
    if (cmd == 0x2 or cmd == 0x3) and data_cnt >= 1 then
        local bm = info.data:byte(1) + ((data_cnt >= 2) and info.data:byte(2) * 256 or 0)
        detail = string.format(" items=0x%04X", bm)
    elseif cmd == 0x1 and data_cnt >= 2 then
        detail = string.format(" -> 0x%02X grp 0x%02X", info.data:byte(1), info.data:byte(2))
    elseif cmd == 0xA and data_cnt >= 1 then
        detail = string.format(" %s baud", tostring(BRD_BAUD[info.data:byte(1)] or "?"))
    elseif extra then
        detail = " " .. extra
    end
    info.summary = string.format("%s addr=%s%s%s", name, addr_str, detail,
        ok and "" or " [BAD CKSUM]")
    return info
end

-- ── Status decoder ──────────────────────────────────────────────────────────

local SERVO_STATUS_NAMES = {
    [0] = "Move done", [1] = "Checksum error", [2] = "Current limit", [3] = "Power on",
    [4] = "Position error", [5] = "Limit 1 / home (diag)", [6] = "Limit 2 (diag)",
    [7] = "Home in progress",
}
local SERVO_STATUS_FIELDS = {
    [0] = F.st_move_done, [1] = F.st_cksum_err, [2] = F.st_cur_limit, [3] = F.st_power_on,
    [4] = F.st_pos_error, [5] = F.st_limit1, [6] = F.st_limit2, [7] = F.st_home_prog,
}
local IO_STATUS_NAMES = {
    [0] = "bit 0", [1] = "Checksum error", [2] = "bit 2", [3] = "bit 3",
    [4] = "bit 4", [5] = "bit 5", [6] = "bit 6", [7] = "bit 7",
}
local IO_STATUS_FIELDS = { [1] = F.st_cksum_err }
local AUX_BITS = {
    [0] = "Index", [1] = "Position wrap", [2] = "Servo on", [3] = "Accel done",
    [4] = "Slew done", [5] = "Servo overrun", [6] = "Path mode", [7] = "Reserved",
}
local SK_IN1_BITS = { [0] = "At Home", [1] = "Test Mode", [2] = "Servo Fault" }
local SK_IN1_FIELDS = { [0] = F.sk_at_home, [1] = F.sk_test_mode, [2] = F.sk_servo_fault }

local function decode_servo_item(tree, tvb, b, off, size, info)
    if b == 0 then tree:add_le(F.position, tvb(off, 4))
    elseif b == 1 then tree:add(F.ad, tvb(off, 1))
    elseif b == 2 then tree:add_le(F.velocity, tvb(off, 2))
    elseif b == 3 then
        local v = tvb(off, 1):uint()
        add_bits(tree:add(F.aux, tvb(off, 1)), tvb(off, 1), v, AUX_BITS)
    elseif b == 4 then tree:add_le(F.home_pos, tvb(off, 4))
    elseif b == 5 then
        tree:add(F.device_id, tvb(off, 1))
        tree:add(F.version, tvb(off + 1, 1))
        info.device_id = tvb(off, 1):uint()
        info.version = tvb(off + 1, 1):uint()
    elseif b == 6 then tree:add_le(F.pos_error, tvb(off, 2))
    elseif b == 7 then tree:add(F.path_points, tvb(off, 1))
    elseif b == 8 then tree:add_le(F.digital_in, tvb(off, 2))
    elseif b == 9 then tree:add_le(F.analog_in, tvb(off, 2))
    elseif b == 12 then tree:add_le(F.watchdog, tvb(off, 2))
    elseif b == 13 then
        tree:add_le(F.position, tvb(off, 4))
        tree:add_le(F.pos_error, tvb(off + 4, 2))
    else
        tree:add(F.item_unknown, tvb(off, size))
    end
end

local function decode_io_item(tree, tvb, b, off, size, info, devtype)
    if b == 0 then
        local b0 = tvb(off, 1):uint()
        local b1 = tvb(off + 1, 1):uint()
        add_bits(tree:add(F.in0, tvb(off, 1)), tvb(off, 1), b0, RAW_BITS)
        local t1 = tree:add(F.in1, tvb(off + 1, 1))
        if devtype == "sk2310" then
            add_bits(t1, tvb(off + 1, 1), b1, SK_IN1_BITS, SK_IN1_FIELDS)
            local code = B.band(B.rshift(b1, 3), 0x1F)
            local name = DIAG_NAMES[code] or "Unknown"
            local dt = t1:add(F.diag, tvb(off + 1, 1), code)
            dt:set_text(string.format("%s = Diagnostic code 0x%02X: %s", bitstr(b1, -1), code, name))
            t1:add(F.diag_name, tvb(off + 1, 1), name):set_generated()
            info.diag = code
            info.diag_name = name
        else
            add_bits(t1, tvb(off + 1, 1), b1, RAW_BITS)
        end
    elseif b == 1 then tree:add(F.analog0, tvb(off, 1))
    elseif b == 2 then tree:add(F.analog1, tvb(off, 1))
    elseif b == 3 then tree:add(F.analog2, tvb(off, 1))
    elseif b == 4 then tree:add_le(F.counter, tvb(off, 4))
    elseif b == 5 then
        tree:add(F.device_id, tvb(off, 1))
        tree:add(F.version, tvb(off + 1, 1))
        info.device_id = tvb(off, 1):uint()
        info.version = tvb(off + 1, 1):uint()
    elseif b == 6 then tree:add_le(F.sync_in, tvb(off, 2))
    elseif b == 7 then tree:add_le(F.sync_counter, tvb(off, 4))
    else
        tree:add(F.item_unknown, tvb(off, size))
    end
end

-- Decode a device-to-host status packet starting at tvb offset 0.
-- ctx = { addr, devtype, bitmap }  (bitmap = items the device was asked to return)
-- Returns { status, cksum_ok, device_id, version, diag, summary }
function core.decode_status(tvb, tree, ctx)
    local devtype = ctx.devtype or "servo"
    local bitmap  = ctx.bitmap or 0
    local len     = tvb:len()
    local info    = { devtype = devtype }

    tree:add(F.direction, "rx"):set_generated()
    tree:add(F.devtype, devtype):set_generated()
    if ctx.addr then
        tree:add(F.address, ctx.addr):set_generated():append_text("  (from command)")
    end

    if len < 2 then
        tree:add_proto_expert_info(E.too_short)
        info.summary = "short status fragment"
        return info
    end

    local status = tvb(0, 1):uint()
    info.status = status
    local st = tree:add(F.status, tvb(0, 1))
    if is_io_family(devtype) then
        add_bits(st, tvb(0, 1), status, IO_STATUS_NAMES, IO_STATUS_FIELDS)
    else
        add_bits(st, tvb(0, 1), status, SERVO_STATUS_NAMES, SERVO_STATUS_FIELDS)
    end

    local items = core.items_for(devtype)
    local off = 1
    local last = len - 1          -- checksum position
    local names = {}
    for b = 0, 15 do
        if bitset(bitmap, b) then
            local it = items[b]
            local size = it and it[2]
            if not size then
                -- Unknown size: hand the rest (minus checksum) to this item.
                size = math.max(last - off, 0)
                local t = tree:add(F.item_unknown, tvb(off, size))
                t:set_text(string.format("%s: %d bytes (size unknown, consumed remainder)",
                    it and it[1] or ("Item " .. b), size))
                t:add_proto_expert_info(E.unknown_item)
                off = off + size
                names[#names + 1] = "?" .. b
            elseif off + size > last then
                tree:add(tvb(off, math.max(last - off, 0)), string.format(
                    "%s: truncated (need %d bytes)", it[1], size)):add_proto_expert_info(E.truncated)
                off = last
                names[#names + 1] = it[1] .. "(trunc)"
            else
                local t = tree:add(tvb(off, size), string.format("%s", it[1]))
                if is_io_family(devtype) then
                    decode_io_item(t, tvb, b, off, size, info, devtype)
                else
                    decode_servo_item(t, tvb, b, off, size, info)
                end
                off = off + size
                names[#names + 1] = it[1]
            end
        end
    end
    if off < last then
        tree:add(F.unmatched, tvb(off, last - off)):add_proto_expert_info(E.unexpected)
    end

    local cksum_rx = tvb(last, 1):uint()
    local raw = tvb(0, last):raw()
    local cksum_calc = sum_bytes(raw, 1, #raw)
    local ckt = tree:add(F.checksum, tvb(last, 1))
    local ok = (cksum_calc == cksum_rx)
    ckt:add(F.cksum_ok, tvb(last, 1), ok)
    if not ok then
        ckt:add(F.cksum_exp, tvb(last, 1), cksum_calc)
        ckt:add_proto_expert_info(E.bad_checksum)
    end
    info.cksum_ok = ok

    local parts = { string.format("status=0x%02X", status) }
    if #names > 0 then parts[#parts + 1] = table.concat(names, ", ") end
    if info.device_id then parts[#parts + 1] = string.format("id=%d v%d", info.device_id, info.version) end
    if info.diag then parts[#parts + 1] = string.format("diag=0x%02X %s", info.diag, info.diag_name) end
    if not ok then parts[#parts + 1] = "[BAD CKSUM]" end
    info.summary = table.concat(parts, " ")
    return info
end

-- ── Request / reply state model ─────────────────────────────────────────────
--
-- Tracks, per bus, the "defined status" bitmap of each address, auto-detected
-- device types and group leaders, so the reply to each command can be
-- predicted (length and content layout).

function core.new_state()
    return { defined = {}, detected = {}, leaders = {} }
end

function core.devtype(state, addr)
    local pref = core.pref_devtypes()[addr]
    if pref then return pref end
    if state and state.detected[addr] then return state.detected[addr] end
    return "servo"
end

-- Parse the minimal header of a command byte string (no tree).  Returns nil
-- when the string is not a complete frame.
function core.parse_command(s)
    if #s < 4 or s:byte(1) ~= 0xAA then return nil end
    local addr = s:byte(2)
    local cmd_byte = s:byte(3)
    local n = B.rshift(cmd_byte, 4)
    if #s < 4 + n then return nil end
    local data = s:sub(4, 3 + n)
    local cksum_ok = (B.band(addr + cmd_byte + sum_bytes(data, 1, #data), 0xFF) == s:byte(4 + n))
    return { addr = addr, cmd_byte = cmd_byte, cmd = B.band(cmd_byte, 0x0F), data_cnt = n,
             data = data, cksum_ok = cksum_ok, len = 4 + n }
end

-- Apply a command to the state.  Returns an expectation describing the reply
-- (or nil when no reply is expected):
--   { addr, devtype, bitmap, len (nil if unknown), unknown_bit, reason }
function core.on_command(state, c)
    local addr, cmd, data = c.addr, c.cmd, c.data
    local target = addr
    local is_group = addr >= 0x80
    if is_group then
        target = state.leaders[addr]     -- nil when the group has no leader
    end

    -- Addresses affected by this command (for state mutation)
    local affected = {}
    if addr == 0xFF then
        for a, _ in pairs(state.defined) do affected[#affected + 1] = a end
        if target then affected[#affected + 1] = target end
    elseif is_group then
        if target then affected[#affected + 1] = target end
    else
        affected[1] = addr
    end

    local bitmap_override = nil

    if cmd == 0xF then                              -- Hard Reset
        if addr == 0xFF or is_group then
            if addr == 0xFF then state.defined = {}; state.leaders = {} end
            for _, a in ipairs(affected) do state.defined[a] = nil end
        else
            state.defined[addr] = nil
        end
        return nil, "hard reset: no reply"
    elseif cmd == 0xA then                          -- Set Baud Rate
        return nil, "set baud: no reply"
    elseif cmd == 0x1 and #data >= 2 then           -- Set Address
        local ind, grp = data:byte(1), data:byte(2)
        if target then
            if ind ~= target then
                state.defined[ind]  = state.defined[target]
                state.detected[ind] = state.detected[target]
                state.defined[target] = nil
            end
            if grp < 0x80 then
                state.leaders[B.bor(grp, 0x80)] = ind
            else
                for g, leader in pairs(state.leaders) do
                    if leader == target then state.leaders[g] = nil end
                end
            end
            target = ind
        end
    elseif cmd == 0x2 and #data >= 1 then           -- Define Status
        local bm = data:byte(1) + ((#data >= 2) and data:byte(2) * 256 or 0)
        for _, a in ipairs(affected) do state.defined[a] = bm end
        if target then state.defined[target] = bm end
    elseif cmd == 0x3 and #data >= 1 then           -- Read Status (one-shot)
        bitmap_override = data:byte(1) + ((#data >= 2) and data:byte(2) * 256 or 0)
    end

    if not target then
        return nil, "group address without leader: no reply"
    end

    local devtype = core.devtype(state, target)
    local bitmap  = bitmap_override or state.defined[target] or 0
    local len, unknown_bit = core.reply_length(devtype, bitmap)
    return { addr = target, devtype = devtype, bitmap = bitmap, len = len,
             unknown_bit = unknown_bit, cmd = cmd }
end

-- Record what a decoded reply taught us (device type from Device ID).
function core.on_reply(state, exp, info)
    if info and info.device_id and exp and exp.addr then
        local detected
        if info.device_id == 0 then detected = "servo"
        elseif info.device_id == 2 then detected = "io" end
        if detected then
            local prev = state.detected[exp.addr]
            -- Keep a more specific preference (sk2310) if the family matches.
            if not (prev == "sk2310" and detected == "io") then
                state.detected[exp.addr] = detected
            end
        end
    end
end

-- Locate the Device ID item (bit 5) in a raw reply string without a tree.
-- Returns { device_id, version } or nil.
function core.peek_device_id(devtype, bitmap, s)
    local items = core.items_for(devtype)
    local off = 2                       -- 1-based; byte 1 is the status byte
    for b = 0, 15 do
        if bitset(bitmap, b) then
            local it = items[b]
            local size = it and it[2]
            if not size then return nil end
            if b == 5 then
                if off + 1 <= #s - 1 then
                    return { device_id = s:byte(off), version = s:byte(off + 1) }
                end
                return nil
            end
            off = off + size
        end
    end
    return nil
end

-- Checksum check for a candidate reply of length L in byte string s (1-based)
function core.reply_cksum_ok(s, L)
    if L < 2 or L > #s then return false end
    return sum_bytes(s, 1, L - 1) == s:byte(L)
end

return core
