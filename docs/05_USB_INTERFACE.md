# PicoShark USB Interface Design

**Document Version:** 1.0  
**Date:** 2024-12-19  
**Status:** Planning

## Table of Contents
1. [Overview](#overview)
2. [USB Device Architecture](#usb-device-architecture)
3. [PCAP File Format](#pcap-file-format)
4. [TinyUSB Implementation](#tinyusb-implementation)
5. [Wireshark Integration](#wireshark-integration)
6. [Performance Optimization](#performance-optimization)

---

## Overview

PicoShark presents as a USB CDC (Communications Device Class) serial port that outputs PCAP-formatted data. This allows direct capture via Wireshark or any tool that can read from a serial port.

### Design Rationale

**Why CDC + PCAP?**
1. **Universal compatibility**: Works on Windows, Linux, macOS without drivers
2. **Simple usage**: `cat /dev/ttyACM0 | wireshark -k -i -`
3. **No host software required**: Standard tools only
4. **Future extensibility**: Can migrate to extcap plugin later

**Alternative considered (extcap plugin):**
- Pros: Better Wireshark integration, native interface
- Cons: Requires installation, platform-specific code
- Decision: Phase 2 enhancement, not MVP

---

## USB Device Architecture

### Device Descriptor

```c
#define USB_VID           0x2E8A  // Raspberry Pi
#define USB_PID           0x000A  // Generic CDC
#define USB_DEVICE_VER    0x0100  // v1.0

tusb_desc_device_t const desc_device = {
    .bLength            = sizeof(tusb_desc_device_t),
    .bDescriptorType    = TUSB_DESC_DEVICE,
    .bcdUSB             = 0x0200,  // USB 2.0
    .bDeviceClass       = TUSB_CLASS_CDC,
    .bDeviceSubClass    = 0,
    .bDeviceProtocol    = 0,
    .bMaxPacketSize0    = 64,
    .idVendor           = USB_VID,
    .idProduct          = USB_PID,
    .bcdDevice          = USB_DEVICE_VER,
    .iManufacturer      = 1,  // "PicoShark"
    .iProduct           = 2,  // "LDCN Protocol Sniffer"
    .iSerialNumber      = 3,  // Unique per device
    .bNumConfigurations = 1
};
```

### String Descriptors

```c
const char* string_desc_arr[] = {
    (const char[]) { 0x09, 0x04 },  // Language: English
    "PicoShark",                     // Manufacturer
    "LDCN Protocol Sniffer v1.0",   // Product
    "000000000001",                  // Serial (unique per device)
};
```

### Configuration Descriptor

**Single CDC Interface:**
```c
Configuration 1:
  - Interface 0: CDC Control
      - Endpoint 0x81 IN (Interrupt, 8 bytes)
  - Interface 1: CDC Data
      - Endpoint 0x02 OUT (Bulk, 64 bytes) [unused]
      - Endpoint 0x82 IN (Bulk, 64 bytes)  [PCAP stream]
```

**Optional: Dual CDC (future enhancement)**
```c
Configuration 1:
  - Interface 0/1: CDC #0 (PCAP stream)
  - Interface 2/3: CDC #1 (Debug messages)
```

---

## PCAP File Format

### Global Header (24 bytes, sent once at start)

```c
typedef struct {
    uint32_t magic_number;   // 0xa1b2c3d4 (native byte order)
    uint16_t version_major;  // 2
    uint16_t version_minor;  // 4
    int32_t  thiszone;       // GMT offset (0)
    uint32_t sigfigs;        // Timestamp accuracy (0)
    uint32_t snaplen;        // Max packet size (65535)
    uint32_t network;        // Data link type (DLT_USER0 = 147)
} pcap_hdr_t;

const pcap_hdr_t pcap_global_header = {
    .magic_number   = 0xa1b2c3d4,
    .version_major  = 2,
    .version_minor  = 4,
    .thiszone       = 0,
    .sigfigs        = 0,
    .snaplen        = 65535,
    .network        = 147  // DLT_USER0 (custom protocol)
};
```

**Why DLT_USER0 (147)?**
- Reserved for private use
- Allows custom dissector in Wireshark
- Standard PCAP viewers won't corrupt data

### Packet Record Header (16 bytes, per packet)

```c
typedef struct {
    uint32_t ts_sec;    // Timestamp seconds (Unix epoch)
    uint32_t ts_usec;   // Timestamp microseconds
    uint32_t incl_len;  // Captured length
    uint32_t orig_len;  // Original length (same as incl_len)
} pcap_pkthdr_t;
```

### PicoShark Custom Payload

```c
typedef struct {
    uint8_t channel;       // 0 or 1
    uint8_t flags;         // packet_flags_t from parser
    uint8_t ldcn_data[];   // Variable length LDCN packet
} picoshark_payload_t;

// Total PCAP packet structure:
// [pcap_pkthdr_t][channel][flags][LDCN packet bytes...]
```

**Example PCAP packet:**
```
┌─────────────────────────────────────────────────────────────┐
│ PCAP Record Header (16 bytes)                               │
├───────────────┬───────────────┬─────────────┬───────────────┤
│ ts_sec        │ ts_usec       │ incl_len    │ orig_len      │
│ 1702993234    │ 456789        │ 7           │ 7             │
├───────────────┴───────────────┴─────────────┴───────────────┤
│ PicoShark Payload (7 bytes)                                 │
├─────────┬─────────┬─────────────────────────────────────────┤
│ channel │ flags   │ LDCN packet (5 bytes)                   │
│ 0x00    │ 0x00    │ 0xAA 0x01 0x0E 0x0F                     │
└─────────┴─────────┴─────────────────────────────────────────┘

Total: 16 + 2 + 5 = 23 bytes on wire
```

### Timestamp Conversion

```c
void convert_timestamp(uint32_t timestamp_us, pcap_pkthdr_t *hdr) {
    // timestamp_us from time_us_32() wraps every ~71 minutes
    // Need to track wraparound and add epoch offset
    
    static uint32_t boot_time_sec = 0;  // Set on first packet
    static uint32_t last_us = 0;
    static uint32_t wrap_count = 0;
    
    // Detect wraparound
    if (timestamp_us < last_us) {
        wrap_count++;
    }
    last_us = timestamp_us;
    
    // Calculate absolute time
    uint64_t total_us = ((uint64_t)wrap_count << 32) + timestamp_us;
    
    hdr->ts_sec = boot_time_sec + (total_us / 1000000);
    hdr->ts_usec = total_us % 1000000;
}
```

**Alternative (simpler for MVP):**
```c
// Use relative time from boot (0 = device boot time)
hdr->ts_sec = timestamp_us / 1000000;
hdr->ts_usec = timestamp_us % 1000000;
```

---

## TinyUSB Implementation

### Core 1 Main Loop

```c
void core1_main() {
    // Initialize TinyUSB
    tusb_init();
    
    // Send PCAP global header once
    send_pcap_global_header();
    
    while (1) {
        // TinyUSB processing
        tud_task();
        
        // Process packet queue
        if (tud_cdc_connected() && tud_cdc_write_available() >= 64) {
            process_packet_queue();
        }
        
        // Handle mode commands (future: switch to Interface Mode)
        // handle_mode_commands();
    }
}
```

### PCAP Global Header Transmission

```c
void send_pcap_global_header() {
    // Wait for CDC connection
    while (!tud_cdc_connected()) {
        tud_task();
        sleep_ms(10);
    }
    
    // Send header
    tud_cdc_write(&pcap_global_header, sizeof(pcap_global_header));
    tud_cdc_write_flush();
}
```

### Packet Processing and Transmission

```c
#define PCAP_BUFFER_SIZE 128

void process_packet_queue() {
    ldcn_packet_t packet;
    
    // Dequeue one packet (Core 1 consumer)
    if (!dequeue_packet(&packet)) {
        return;  // Queue empty
    }
    
    // Build PCAP record in local buffer
    uint8_t pcap_buffer[PCAP_BUFFER_SIZE];
    size_t offset = 0;
    
    // 1. PCAP packet header
    pcap_pkthdr_t *hdr = (pcap_pkthdr_t*)pcap_buffer;
    convert_timestamp(packet.timestamp_us, hdr);
    
    hdr->incl_len = 2 + packet.length;  // channel + flags + LDCN data
    hdr->orig_len = hdr->incl_len;
    offset += sizeof(pcap_pkthdr_t);
    
    // 2. PicoShark metadata
    pcap_buffer[offset++] = packet.channel;
    pcap_buffer[offset++] = packet.flags;
    
    // 3. LDCN packet data
    pcap_buffer[offset++] = packet.header;
    pcap_buffer[offset++] = packet.address;
    pcap_buffer[offset++] = packet.command;
    
    for (int i = 0; i < packet.data_count; i++) {
        pcap_buffer[offset++] = packet.data[i];
    }
    
    pcap_buffer[offset++] = packet.checksum_received;
    
    // 4. Transmit to USB
    uint32_t written = tud_cdc_write(pcap_buffer, offset);
    
    if (written < offset) {
        // USB buffer full - packet lost
        log_warning("USB buffer full, packet dropped");
    }
    
    // Flush periodically (not every packet for efficiency)
    static uint32_t packet_count = 0;
    if (++packet_count % 10 == 0) {
        tud_cdc_write_flush();
    }
}
```

### USB Callbacks

```c
// Invoked when CDC line state changes (DTR/RTS)
void tud_cdc_line_state_cb(uint8_t itf, bool dtr, bool rts) {
    if (dtr) {
        // Terminal opened - resend PCAP header
        send_pcap_global_header();
    }
}

// Invoked when CDC line coding changes (baud rate, etc.)
void tud_cdc_line_coding_cb(uint8_t itf, cdc_line_coding_t const* p_line_coding) {
    // Ignore - CDC settings don't affect RS-485 baud rate
    // (Baud rate controlled by LDCN protocol, not USB serial settings)
}

// Invoked when data received from host
void tud_cdc_rx_cb(uint8_t itf) {
    // Future: Handle mode switch commands
    // For now: drain and ignore
    uint8_t buf[64];
    tud_cdc_read(buf, sizeof(buf));
}
```

---

## Wireshark Integration

### Usage Instructions (for end users)

**Linux/macOS:**
```bash
# Direct pipe to Wireshark
cat /dev/ttyACM0 | wireshark -k -i -

# Or save to file first
cat /dev/ttyACM0 > capture.pcap
wireshark capture.pcap
```

**Windows (PowerShell):**
```powershell
# Requires COM port identification (e.g., COM3)
# Use Tera Term or similar to identify port

# Direct capture
Get-Content COM3 -Encoding Byte -ReadCount 0 | wireshark -k -i -

# Or use TShark
tshark -i \\.\USBPcap1 -Y "usb.src == 1.2.0"
```

**Windows (Alternative - PuTTY + pipe):**
```bash
# 1. Open PuTTY, connect to COM port, log to file (raw binary)
# 2. Open file in Wireshark
```

### Lua Dissector (ldcn.lua)

**Installation:**
- Windows: `%APPDATA%\Wireshark\plugins\ldcn.lua`
- Linux: `~/.local/lib/wireshark/plugins/ldcn.lua`
- macOS: `/Applications/Wireshark.app/Contents/PlugIns/wireshark/ldcn.lua`

**Dissector Implementation:**

```lua
-- LDCN Protocol Dissector for Wireshark
-- Decodes PicoShark PCAP captures

ldcn_proto = Proto("LDCN", "Logosol Distributed Control Network")

-- Fields
local f_channel = ProtoField.uint8("ldcn.channel", "Channel", base.DEC)
local f_flags = ProtoField.uint8("ldcn.flags", "Flags", base.HEX)
local f_header = ProtoField.uint8("ldcn.header", "Header", base.HEX)
local f_address = ProtoField.uint8("ldcn.address", "Address", base.HEX)
local f_command = ProtoField.uint8("ldcn.command", "Command", base.HEX)
local f_cmd_value = ProtoField.uint8("ldcn.cmd_value", "Command Value", base.HEX)
local f_data_count = ProtoField.uint8("ldcn.data_count", "Data Count", base.DEC)
local f_data = ProtoField.bytes("ldcn.data", "Data")
local f_checksum = ProtoField.uint8("ldcn.checksum", "Checksum", base.HEX)
local f_checksum_valid = ProtoField.bool("ldcn.checksum_valid", "Checksum Valid")

ldcn_proto.fields = {
    f_channel, f_flags, f_header, f_address, f_command,
    f_cmd_value, f_data_count, f_data, f_checksum, f_checksum_valid
}

-- Command names lookup table
local command_names = {
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
    [0xF] = "Hard Reset"
}

-- Flag bit meanings
local flag_meanings = {
    [0x01] = "Bad Checksum",
    [0x02] = "Invalid Count",
    [0x04] = "Truncated",
    [0x08] = "Framing Error"
}

function ldcn_proto.dissector(buffer, pinfo, tree)
    pinfo.cols.protocol = "LDCN"
    
    local length = buffer:len()
    if length == 0 then return end
    
    local subtree = tree:add(ldcn_proto, buffer(), "LDCN Packet")
    
    -- Parse PicoShark metadata
    local channel = buffer(0,1):uint()
    local flags = buffer(1,1):uint()
    
    subtree:add(f_channel, buffer(0,1))
    
    -- Decode flags
    local flags_tree = subtree:add(f_flags, buffer(1,1))
    for bit, meaning in pairs(flag_meanings) do
        if bit_and(flags, bit) ~= 0 then
            flags_tree:add(buffer(1,1), meaning)
        end
    end
    
    -- Parse LDCN packet
    if length < 5 then
        subtree:add_expert_info(PI_MALFORMED, PI_ERROR, "Packet too short")
        return
    end
    
    local header = buffer(2,1):uint()
    local address = buffer(3,1):uint()
    local command = buffer(4,1):uint()
    
    local cmd_value = bit_and(command, 0x0F)
    local data_count = bit_rshift(command, 4)
    
    subtree:add(f_header, buffer(2,1))
    
    -- Decode address type
    local addr_tree = subtree:add(f_address, buffer(3,1))
    if address == 0x00 then
        addr_tree:append_text(" (Default)")
    elseif address >= 0x80 then
        addr_tree:append_text(" (Group)")
    else
        addr_tree:append_text(" (Individual)")
    end
    
    -- Decode command
    local cmd_tree = subtree:add(f_command, buffer(4,1))
    local cmd_name = command_names[cmd_value] or "Unknown"
    cmd_tree:append_text(" (" .. cmd_name .. ")")
    
    subtree:add(f_cmd_value, buffer(4,1), cmd_value)
    subtree:add(f_data_count, buffer(4,1), data_count)
    
    -- Parse data bytes
    if data_count > 0 then
        if length < 5 + data_count then
            subtree:add_expert_info(PI_MALFORMED, PI_ERROR, "Data truncated")
            return
        end
        
        subtree:add(f_data, buffer(5, data_count))
        
        -- Special handling for Set Baud Rate
        if cmd_value == 0xA and data_count == 1 then
            local brd = buffer(5,1):uint()
            local baud = math.floor(5000000 / (brd + 1))
            subtree:add(buffer(5,1), "BRD: " .. brd .. " (" .. baud .. " baud)")
        end
    end
    
    -- Parse checksum
    local cksum_offset = 5 + data_count
    if length < cksum_offset + 1 then
        subtree:add_expert_info(PI_MALFORMED, PI_ERROR, "Checksum missing")
        return
    end
    
    local checksum_rx = buffer(cksum_offset, 1):uint()
    
    -- Calculate expected checksum
    local checksum_calc = address + command
    for i = 0, data_count - 1 do
        checksum_calc = checksum_calc + buffer(5 + i, 1):uint()
    end
    checksum_calc = bit_and(checksum_calc, 0xFF)
    
    local cksum_tree = subtree:add(f_checksum, buffer(cksum_offset, 1))
    local valid = (checksum_calc == checksum_rx)
    
    cksum_tree:add(f_checksum_valid, valid)
    
    if not valid then
        cksum_tree:append_text(string.format(" (Expected: 0x%02X)", checksum_calc))
        cksum_tree:add_expert_info(PI_CHECKSUM, PI_ERROR, "Bad checksum")
    end
    
    -- Update Info column
    pinfo.cols.info = string.format("CH%d: %s [Addr: 0x%02X]", 
                                    channel, cmd_name, address)
    
    if not valid then
        pinfo.cols.info:append(" [Bad Checksum]")
    end
end

-- Register dissector
local usb_table = DissectorTable.get("wtap_encap")
usb_table:add(wtap.USER0, ldcn_proto)  -- DLT_USER0 = 147
```

### Display Filters (for users)

**Common filters:**
```
ldcn                           # Show all LDCN packets
ldcn.channel == 0              # Host→Device direction
ldcn.channel == 1              # Device→Host direction
ldcn.address == 0x01           # Packets to/from device 1
ldcn.cmd_value == 0x0A         # Set Baud Rate commands
ldcn.checksum_valid == false   # Show checksum errors
ldcn.flags != 0                # Show any flagged packets
```

---

## Performance Optimization

### Throughput Analysis

**USB Full Speed (12 Mbps):**
- Theoretical max: 1.5 MB/sec
- Practical (with overhead): ~1 MB/sec

**LDCN at max rate (1.25 Mbps):**
- Bytes/sec: 156,250
- With PCAP overhead (16B + 2B per packet):
  - Avg packet: 7 bytes LDCN data
  - PCAP packet: 18 + 7 = 25 bytes
  - Overhead: 18/25 = 72%
- Total throughput: 156,250 × (25/7) ≈ 558 KB/sec

**Conclusion:** USB bandwidth sufficient (558 KB/sec < 1 MB/sec)

### Buffering Strategy

**Why packet queue is needed:**
- USB transmission can block (host not reading)
- Parser should never wait for USB
- Queue absorbs bursts

**Queue sizing:**
```
32 packets × 32 bytes = 1024 bytes
At 1000 pkt/sec: 32ms buffering
Sufficient for USB polling delays
```

### Flush Strategy

**Options:**
1. **Flush every packet:** Low latency, high USB overhead
2. **Flush every 10 packets:** Balanced
3. **Flush every 100ms:** Batched, might lose data on disconnect

**Recommendation:** Flush every 10 packets (chosen in implementation)

### Memory Management

**Static allocation (preferred for embedded):**
```c
// All buffers statically allocated at compile time
uint8_t pcap_buffer[PCAP_BUFFER_SIZE];
packet_queue_t packet_queue;  // Fixed size

// No malloc/free in critical path
// Deterministic memory usage
```

---

## Testing

### Unit Tests

```c
void test_pcap_header_format() {
    pcap_hdr_t hdr = pcap_global_header;
    
    assert(hdr.magic_number == 0xa1b2c3d4);
    assert(hdr.version_major == 2);
    assert(hdr.version_minor == 4);
    assert(hdr.network == 147);  // DLT_USER0
}

void test_timestamp_conversion() {
    pcap_pkthdr_t hdr;
    
    // Test case: 1.5 seconds
    convert_timestamp(1500000, &hdr);
    
    assert(hdr.ts_sec == 1);
    assert(hdr.ts_usec == 500000);
}

void test_pcap_packet_build() {
    ldcn_packet_t packet = {
        .timestamp_us = 1000000,
        .channel = 0,
        .flags = 0,
        .header = 0xAA,
        .address = 0x01,
        .command = 0x0E,
        .data_count = 0,
        .checksum_received = 0x0F,
        .length = 4
    };
    
    uint8_t pcap_buffer[128];
    size_t len = build_pcap_packet(&packet, pcap_buffer);
    
    // Verify PCAP header
    pcap_pkthdr_t *hdr = (pcap_pkthdr_t*)pcap_buffer;
    assert(hdr->incl_len == 2 + 4);  // metadata + LDCN
    assert(hdr->orig_len == 2 + 4);
    
    // Verify payload
    assert(pcap_buffer[16] == 0);    // channel
    assert(pcap_buffer[17] == 0);    // flags
    assert(pcap_buffer[18] == 0xAA); // LDCN header
}
```

### Integration Tests

```c
void test_usb_pcap_stream() {
    // Requires physical USB connection
    
    // 1. Connect device
    // 2. Open CDC port
    // 3. Read first 24 bytes
    // 4. Verify PCAP global header
    // 5. Send test packet
    // 6. Read PCAP record + payload
    // 7. Validate format
}
```

### Wireshark Validation

```bash
# Capture to file
cat /dev/ttyACM0 > test.pcap &
PID=$!

# Send test commands
python3 send_ldcn_commands.py

# Stop capture
sleep 5
kill $PID

# Validate with tshark
tshark -r test.pcap -V | grep -A10 "LDCN"

# Check for errors
tshark -r test.pcap -Y "ldcn.checksum_valid == false"
```

---

## Future Enhancements

### Phase 2: Dual CDC Interface

**Interface 0:** PCAP stream (as current)  
**Interface 1:** Debug/control channel

```c
// Debug messages
printf_cdc1("Baud rate changed to 115200\n");

// Mode control
if (tud_cdc_n_available(1)) {
    char cmd = tud_cdc_n_read_char(1);
    if (cmd == 's') switch_to_sniffer_mode();
    if (cmd == 'i') switch_to_interface_mode();
}
```

### Phase 3: Extcap Plugin

**Benefits:**
- Native Wireshark interface
- No manual piping required
- Platform-independent

**Implementation:**
- Python script implementing extcap API
- Communicates with PicoShark via CDC
- Provides capture interface to Wireshark

**Reference:** https://www.wireshark.org/docs/wsdg_html_chunked/ChCaptureExtcap.html

### Phase 4: Configuration Interface

**Via USB CDC control channel:**
- Select channels to capture (CH0, CH1, both)
- Filter by address (capture only device 0x01)
- Timestamp format (relative, absolute)
- Buffer sizes

---

## Troubleshooting

### Device Not Recognized

**Symptoms:** PicoShark doesn't appear as COM/ttyACM port

**Solutions:**
- Windows: Check Device Manager, install CDC driver if needed
- Linux: Check `dmesg | grep tty`, verify permissions
- macOS: Check `ls /dev/tty.*`
- Try different USB cable (must be data-capable)
- Check USB VID/PID in code matches device

### Invalid PCAP File

**Symptoms:** Wireshark reports "file appears to be damaged"

**Solutions:**
- Verify magic number (0xa1b2c3d4) at file start
- Check for truncated global header (must be 24 bytes)
- Ensure binary mode when capturing (not text)
- Windows: Use binary-safe tools (not notepad)

### Wireshark Shows Garbage

**Symptoms:** Packets decode incorrectly

**Solutions:**
- Verify Lua dissector installed correctly
- Check DLT type in PCAP header (must be 147)
- Reload Lua dissector: Ctrl+Shift+L in Wireshark
- Check byte order (should be native)

### USB Disconnects During Capture

**Symptoms:** CDC port closes unexpectedly

**Solutions:**
- Reduce capture rate (fewer packets/sec)
- Increase USB buffer sizes in OS
- Check power supply (use powered hub if needed)
- Disable USB selective suspend (Windows power settings)

---

## Reference Implementation Checklist

**Initialization:**
- [ ] TinyUSB initialized correctly
- [ ] PCAP global header sent on connection
- [ ] Device descriptors valid
- [ ] String descriptors set

**Runtime Operation:**
- [ ] Packet queue drained efficiently
- [ ] PCAP records formatted correctly
- [ ] Timestamps converted properly
- [ ] Flush strategy balances latency/throughput

**Error Handling:**
- [ ] USB buffer full handled gracefully
- [ ] Host disconnect/reconnect supported
- [ ] Malformed packets transmitted with flags
- [ ] No data corruption on overflow

**Testing:**
- [ ] Wireshark recognizes PCAP format
- [ ] Lua dissector decodes packets
- [ ] Long captures stable (no memory leaks)
- [ ] Performance meets requirements

---

## Revision History

| Version | Date | Author | Changes |
|---------|------|--------|---------|
| 1.0 | 2024-12-19 | Initial | USB interface design specification |
