-- LDCN over USB: decodes Logosol LDCN traffic carried in USB bulk transfers
-- to/from an FTDI-based USB-to-RS485 converter (Logosol LS-832RL), as captured
-- on Windows with USBPcap (also works with Linux usbmon captures).
--
-- Registered as a post-dissector so it sees every USB packet regardless of
-- whether Wireshark's FTDI FT dissector claimed it:
--   * if the FTDI FT dissector ran, its payload fields are used (modem-status
--     bytes already stripped);
--   * otherwise the raw bulk payload (usb.capdata) is used and, for IN
--     transfers, the two FTDI modem-status bytes at the start of every
--     wMaxPacketSize chunk are stripped.
--
-- Bytes are reassembled into one stream per direction per USB device.
-- Host-to-device (TX) frames are delimited by the 0xAA header plus the data
-- count in the command byte.  Device-to-host (RX) status packets have no
-- header, so their length is predicted from the most recent command using
-- the state model in ldcn_core.lua (Define Status / Read Status bitmaps and
-- per-address device types).  Replies that do not fit the prediction are
-- flagged with the ldcn.unexpected expert info.
--
-- Requires ldcn_core.lua in the same plugins directory.

local function load_core()
    if _G.LDCN_CORE then return _G.LDCN_CORE end
    local src = debug.getinfo(1, "S").source or ""
    local dir = src:match("^@(.*[/\\])") or ""
    return dofile(dir .. "ldcn_core.lua")
end

local core = load_core()
local F, E, B = core.F, core.E, core.bit

local usbp = Proto("ldcn_usb", "LDCN over USB (FTDI / USBPcap)")

usbp.prefs.enabled = Pref.bool("Decode LDCN on USB bulk transfers", true,
    "Run the LDCN post-dissector on USB bulk payloads.")
usbp.prefs.device = Pref.string("USB device filter (bus.address)", "",
    "Only decode bulk traffic of this USB device, written as bus.address " ..
    "(the values of usb.bus_id and usb.device_address, e.g. \"1.5\"). " ..
    "Empty decodes every USB device, each with its own byte streams.")
usbp.prefs.max_packet = Pref.uint("FTDI endpoint wMaxPacketSize", 64,
    "Size of one USB packet on the FTDI IN endpoint. Each packet starts with " ..
    "two modem-status bytes that are stripped. 64 for full-speed parts " ..
    "(FT232R/FT232BM, LS-832RL), 512 for high-speed parts (FT232H/FT2232H).")
usbp.prefs.strict = Pref.bool("Strict request/reply", true,
    "LDCN is half-duplex: a new command means the previous reply is complete. " ..
    "When set, an incomplete or missing reply is closed out (and flagged) as " ..
    "soon as the next command is sent. Clear this if the host pipelines commands.")

-- ── Field extractors (created before register_postdissector) ────────────────

local function field(name)
    local ok, f = pcall(Field.new, name)
    if ok then return f end
    return nil
end

local f_xfer    = field("usb.transfer_type")
local f_dir     = field("usb.endpoint_address.direction")
local f_capdata = field("usb.capdata")
local f_bus     = field("usb.bus_id")
local f_dev     = field("usb.device_address")
local f_src     = field("usb.src")

local ftdi_rx, ftdi_tx = {}, {}
for _, i in ipairs({ "a", "b", "c", "d" }) do
    local r = field("ftdi-ft.if_" .. i .. "_rx_payload")
    local t = field("ftdi-ft.if_" .. i .. "_tx_payload")
    if r then ftdi_rx[#ftdi_rx + 1] = r end
    if t then ftdi_tx[#ftdi_tx + 1] = t end
end

local function first(f)
    if not f then return nil end
    local v = f()
    return v
end

local function all(f)
    if not f then return {} end
    return { f() }
end

-- ── Per-capture state ───────────────────────────────────────────────────────

local streams = {}   -- "bus.addr" -> stream
local results = {}   -- frame number -> result table, or false when not LDCN

function usbp.init()
    streams = {}
    results = {}
end

local function new_dir(name)
    return { name = name, buf = "", base = 0, origins = {}, partial_items = {} }
end

local function get_stream(key)
    local s = streams[key]
    if not s then
        s = { key = key, state = core.new_state(), queue = {}, tx = new_dir("tx"), rx = new_dir("rx") }
        streams[key] = s
    end
    return s
end

-- ── Classification of the current USB packet ────────────────────────────────

local function is_in_direction()
    local dfi = first(f_dir)
    if dfi then
        local v = dfi.value
        if type(v) == "boolean" then return v end
        if type(v) == "number" then return v ~= 0 end
        return tostring(dfi.display):upper():find("IN") ~= nil
    end
    local s = first(f_src)
    if s then return tostring(s.display) ~= "host" end
    return nil
end

-- Returns dir ("tx"/"rx"), chunks { {off=, len=} ... } in frame-tvb coordinates,
-- and the stream key; or nil when the packet carries no LDCN payload.
local function classify()
    local xt = first(f_xfer)
    if not xt or tonumber(xt.value) ~= 3 then return nil end          -- bulk only

    local is_in = is_in_direction()
    if is_in == nil then return nil end

    local bus, dev = first(f_bus), first(f_dev)
    local key = string.format("%s.%s", bus and tostring(bus.value) or "?",
                                        dev and tostring(dev.value) or "?")
    local filt = usbp.prefs.device
    if filt and filt ~= "" then
        if filt ~= key and not (dev and filt == tostring(dev.value)) then return nil end
    end

    local chunks = {}
    for _, fld in ipairs(is_in and ftdi_rx or ftdi_tx) do
        for _, fi in ipairs(all(fld)) do
            local r = fi.range
            if r and r:len() > 0 then chunks[#chunks + 1] = { off = r:offset(), len = r:len() } end
        end
    end

    if #chunks == 0 then
        local cd = first(f_capdata)
        if cd and cd.range and cd.range:len() > 0 then
            local r = cd.range
            if is_in then
                local mps = usbp.prefs.max_packet
                if not mps or mps < 3 then mps = 64 end
                local pos = 0
                while pos < r:len() do
                    local seg = math.min(mps, r:len() - pos)
                    if seg > 2 then
                        chunks[#chunks + 1] = { off = r:offset() + pos + 2, len = seg - 2 }
                    end
                    pos = pos + seg
                end
            else
                chunks[1] = { off = r:offset(), len = r:len() }
            end
        end
    end

    if #chunks == 0 then return nil end
    table.sort(chunks, function(a, b) return a.off < b.off end)
    return is_in and "rx" or "tx", chunks, key
end

-- ── Stream bookkeeping ──────────────────────────────────────────────────────

local function consume(d, n)
    d.buf  = d.buf:sub(n + 1)
    d.base = d.base + n
    while d.origins[1] and d.origins[1].e <= d.base do table.remove(d.origins, 1) end
end

local function origin_frame(d, abs)
    for _, o in ipairs(d.origins) do
        if abs >= o.s and abs < o.e then return o.frame end
    end
    return nil
end

-- Highlight range within this packet for stream bytes [s, e)
local function highlight(res, s, e)
    local lo, hi
    for _, c in ipairs(res.chunks) do
        local cs, ce = c.abs, c.abs + c.len
        local os, oe = math.max(s, cs), math.min(e, ce)
        if oe > os then
            local toff = c.off + (os - cs)
            local tend = c.off + (oe - cs)
            if not lo or toff < lo then lo = toff end
            if not hi or tend > hi then hi = tend end
        end
    end
    if lo then return { off = lo, len = hi - lo } end
    return nil
end

-- Emit an item consuming n bytes from the head of direction buffer d into res.
local function emit(d, res, item, n)
    item.abs_s = d.base
    item.abs_e = d.base + n
    item.first_frame = origin_frame(d, item.abs_s)
    item.hl = highlight(res, item.abs_s, item.abs_e)
    res.items[#res.items + 1] = item
    for _, p in ipairs(d.partial_items) do p.reassembled_in = res.frame end
    d.partial_items = {}
    consume(d, n)
end

-- ── Framing: host → device ──────────────────────────────────────────────────

local function flush_queue(stream, why)
    if #stream.queue == 0 then return end
    local rx = stream.rx
    local head = stream.queue[1]
    if #rx.buf > 0 then
        -- Partial reply bytes that will never complete: turn the pending
        -- segment items into unmatched-bytes items where they were captured.
        local reason = string.format("%s: %d stale reply bytes, predicted %s",
            why, #rx.buf, head.len and (head.len .. " bytes") or "unknown length")
        for _, p in ipairs(rx.partial_items) do
            p.kind = "unframed"
            p.reason = reason
            p.unexpected = true
            p.predicted = head.len
        end
        rx.partial_items = {}
        if head.tx_item then head.tx_item.reply_incomplete = true end
        consume(rx, #rx.buf)
    end
    for _, exp in ipairs(stream.queue) do
        if exp.tx_item and not exp.tx_item.reply_incomplete then
            exp.tx_item.no_reply = true
            exp.tx_item.no_reply_reason = why
        end
    end
    stream.queue = {}
end

local function process_tx(stream, d, res)
    while #d.buf > 0 do
        local buf = d.buf
        if buf:byte(1) ~= 0xAA then
            local nxt = buf:find("\170", 2, true)
            local n = nxt and (nxt - 1) or #buf
            emit(d, res, { kind = "unframed", dir = "tx", bytes = buf:sub(1, n),
                           reason = "no 0xAA header" }, n)
        else
            if #buf < 3 then break end
            local flen = 3 + B.rshift(buf:byte(3), 4) + 1
            if #buf < flen then break end
            local frame = buf:sub(1, flen)
            local c = core.parse_command(frame)
            if usbp.prefs.strict then
                flush_queue(stream, "next command sent before reply completed")
            end
            local exp, reason = core.on_command(stream.state, c)
            local item = { kind = "frame", dir = "tx", bytes = frame,
                           devtype = (exp and exp.devtype) or core.devtype(stream.state, c.addr),
                           expects_reply = exp ~= nil, no_reply_reason = reason }
            if exp then
                exp.tx_item  = item
                exp.tx_frame = res.frame
                stream.queue[#stream.queue + 1] = exp
            end
            emit(d, res, item, flen)
        end
    end
end

-- ── Framing: device → host ──────────────────────────────────────────────────

local function process_rx(stream, d, res)
    while #d.buf > 0 do
        local exp = stream.queue[1]
        local buf = d.buf
        if not exp then
            emit(d, res, { kind = "unframed", dir = "rx", bytes = buf, unexpected = true,
                           reason = "reply bytes with no pending command" }, #buf)
        else
            local plen = exp.len
            local flen, note
            if plen and #buf < plen then break end            -- wait for more bytes
            if plen and core.reply_cksum_ok(buf, plen) then
                flen = plen
            else
                local cands = {}
                for L = 2, #buf do
                    if core.reply_cksum_ok(buf, L) then cands[#cands + 1] = L end
                end
                if #cands > 0 then
                    flen = (cands[#cands] == #buf) and #buf or cands[1]
                    if plen then
                        note = string.format("predicted %d bytes, checksum matches at %d", plen, flen)
                    else
                        note = string.format("no length prediction (status item %s has unknown size), " ..
                            "checksum matches at %d", tostring(exp.unknown_bit), flen)
                    end
                    if #cands > 1 then
                        note = note .. " (candidates: " .. table.concat(cands, ",") .. ")"
                    end
                elseif plen then
                    flen = plen
                    note = string.format("predicted %d bytes but checksum fails", plen)
                else
                    break                                       -- unknown length, nothing fits yet
                end
            end

            local frame = buf:sub(1, flen)
            local item = { kind = "frame", dir = "rx", bytes = frame, predicted = plen,
                           ctx = { addr = exp.addr, devtype = exp.devtype, bitmap = exp.bitmap },
                           unexpected = note, response_to = exp.tx_frame }
            if exp.tx_item then exp.tx_item.response_in = res.frame end
            table.remove(stream.queue, 1)
            core.on_reply(stream.state, exp, core.peek_device_id(exp.devtype, exp.bitmap, frame))
            emit(d, res, item, flen)
        end
    end
end

-- ── First-pass processing ───────────────────────────────────────────────────

local function process(tvb, pinfo)
    local dir, chunks, key = classify()
    if not dir then return nil end

    local stream = get_stream(key)
    local d = (dir == "tx") and stream.tx or stream.rx
    local res = { dir = dir, items = {}, chunks = chunks, frame = pinfo.number, key = key }

    local abs = d.base + #d.buf
    local abs_start = abs
    local parts = {}
    for _, c in ipairs(chunks) do
        parts[#parts + 1] = tvb(c.off, c.len):raw()
        c.abs = abs
        abs = abs + c.len
    end
    local added = table.concat(parts)
    if #added == 0 then return nil end

    d.buf = d.buf .. added
    d.origins[#d.origins + 1] = { s = abs_start, e = abs, frame = pinfo.number }

    if dir == "tx" then process_tx(stream, d, res) else process_rx(stream, d, res) end

    if #d.buf > 0 then
        local s, e = d.base, d.base + #d.buf
        local p = { kind = "partial", dir = dir, bytes = d.buf, abs_s = s, abs_e = e,
                    hl = highlight(res, s, e), first_frame = origin_frame(d, s) }
        res.items[#res.items + 1] = p
        d.partial_items[#d.partial_items + 1] = p
    end
    return res
end

-- ── Rendering (every pass) ──────────────────────────────────────────────────

local function add_root(tree, tvb, item, label)
    if item.hl then
        return tree:add(core.proto, tvb(item.hl.off, item.hl.len), label)
    end
    return tree:add(core.proto, tvb(0, 0), label)
end

local function render(tvb, pinfo, tree, res)
    pinfo.cols.protocol:set("LDCN")
    local infos = {}
    local flagged = false

    for _, it in ipairs(res.items) do
        local ba = ByteArray.new(it.bytes, true)

        if it.kind == "frame" then
            local is_tx = (it.dir == "tx")
            local ftvb = ba:tvb(is_tx and "LDCN command" or "LDCN status")
            local root = add_root(tree, tvb, it, is_tx and "LDCN Command" or "LDCN Status")
            if it.first_frame and it.first_frame ~= res.frame then
                root:add(F.reassembled_from, it.first_frame):set_generated()
            end
            local info
            if is_tx then
                info = core.decode_command(ftvb, root, { devtype = it.devtype })
                if it.response_in then root:add(F.response_in, it.response_in):set_generated() end
                if it.no_reply then
                    root:add_proto_expert_info(E.no_reply, "No reply observed: " .. tostring(it.no_reply_reason))
                elseif not it.expects_reply and it.no_reply_reason then
                    root:add(ftvb(0, 0), "No reply expected (" .. it.no_reply_reason .. ")"):set_generated()
                end
                if it.reply_incomplete then
                    root:add_proto_expert_info(E.unexpected, "Reply to this command was incomplete")
                    flagged = true
                end
            else
                info = core.decode_status(ftvb, root, it.ctx)
                if it.response_to then root:add(F.response_to, it.response_to):set_generated() end
                if it.predicted then root:add(F.predicted_len, it.predicted):set_generated() end
                if it.unexpected then
                    root:add_proto_expert_info(E.unexpected, it.unexpected)
                    flagged = true
                end
            end
            root:append_text(": " .. tostring(info.summary))
            infos[#infos + 1] = (is_tx and "TX " or string.format("RX 0x%02X ", it.ctx.addr or 0)) .. tostring(info.summary)

        elseif it.kind == "unframed" then
            local ftvb = ba:tvb("LDCN unmatched")
            local root = add_root(tree, tvb, it, string.format("LDCN unmatched bytes (%s)", it.dir))
            root:add(F.direction, it.dir):set_generated()
            root:add(F.unmatched, ftvb())
            if it.predicted then root:add(F.predicted_len, it.predicted):set_generated() end
            root:add_proto_expert_info(it.unexpected and E.unexpected or E.unframed, it.reason)
            flagged = flagged or it.unexpected or false
            infos[#infos + 1] = string.format("%s %d unmatched bytes (%s)", it.dir:upper(), #it.bytes, it.reason)

        elseif it.kind == "partial" then
            local root = add_root(tree, tvb, it,
                string.format("LDCN segment (%s, %d bytes buffered)", it.dir, #it.bytes))
            if it.hl then root:add(F.segment, tvb(it.hl.off, it.hl.len)) end
            if it.first_frame and it.first_frame ~= res.frame then
                root:add(F.reassembled_from, it.first_frame):set_generated()
            end
            if it.reassembled_in then root:add(F.reassembled_in, it.reassembled_in):set_generated() end
            infos[#infos + 1] = string.format("%s segment (%d bytes)", it.dir:upper(), #it.bytes)
        end
    end

    if #infos > 0 then
        pinfo.cols.info:set(table.concat(infos, " | ") .. (flagged and "  [UNEXPECTED]" or ""))
    end
end

-- ── Post-dissector entry point ──────────────────────────────────────────────

function usbp.dissector(tvb, pinfo, tree)
    if not usbp.prefs.enabled then return end
    local res = results[pinfo.number]
    if res == nil then
        if pinfo.visited then return end
        res = process(tvb, pinfo)
        results[pinfo.number] = res or false
    end
    if not res then return end
    render(tvb, pinfo, tree, res)
end

register_postdissector(usbp)
