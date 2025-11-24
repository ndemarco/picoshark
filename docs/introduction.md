# Pico RS485 Sniffer for Wireshark

*Live RS485 traffic capture with direct pcap output*

---

## 1. Overview

This project turns a Raspberry Pi Pico into an RS485 protocol analyzer that streams pcap-formatted data directly to Wireshark. No bridge scripts or intermediate software required.

### 1.1 Key Features

- Direct pcap output over USB – Wireshark reads the capture stream natively
- Dual USB serial ports – one for configuration, one for capture data
- Configurable DLT for custom Lua dissectors
- 2 Mbps capture capability
- Dual RS485 channel support

### 1.2 System Architecture

```
RS485 Bus ──► UART RX ──► RP2040 ──► USB Composite Device
                                         │
                                         ├── CDC 0: CLI (/dev/ttyACM0)
                                         │   - Configuration
                                         │   - Start/stop capture
                                         │
                                         └── CDC 1: pcap stream (/dev/ttyACM1)
                                             - pcap global header
                                             - pcap packet records
                                                     │
                                                     ▼
                                               Wireshark
```

---

## 2. Hardware

### 2.1 Requirements

| Component | Description |
|-----------|-------------|
| Raspberry Pi Pico | RP2040-based microcontroller |
| RS485 Transceiver | MAX485, SP3485, or similar module |
| USB Cable | Micro-USB for Pico connection |

### 2.2 Default Pin Configuration

| Channel | UART | TX Pin | RX Pin | Notes |
|---------|------|--------|--------|-------|
| 0 | UART0 | GP0 | GP1 | Primary capture channel |
| 1 | UART1 | GP4 | GP5 | Secondary channel |

Pins are configurable via the CLI.

### 2.3 RS485 Transceiver Wiring

```
Pico                    RS485 Transceiver          RS485 Bus
─────                   ─────────────────          ─────────
GP1 (RX) ◄────────────── RO
GP0 (TX) ───────────────► DI
GND ─────────────────────  GND ─────────────────── GND
3.3V ────────────────────  VCC
                           A ──────────────────── A (+)
                           B ──────────────────── B (-)
                           RE ┬── GND (always receive)
                           DE ┘
```

For sniffing only, tie RE and DE low to keep the transceiver in receive mode.

---

## 3. USB Interface

### 3.1 Dual CDC Architecture

The Pico enumerates as a USB composite device with two CDC ACM interfaces:

| Port | Linux | Windows | Purpose |
|------|-------|---------|---------|
| CDC 0 | `/dev/ttyACM0` | COM3 | CLI for configuration |
| CDC 1 | `/dev/ttyACM1` | COM4 | pcap data stream |

Both ports appear automatically when plugging in the device. No drivers required on Linux or Windows 10/11.

### 3.2 CLI Reference

Connect to the CLI port at 115200 baud (or any rate – CDC ignores baud settings).

```
RS485 Sniffer v1.0

Commands:
  help                 Show this help
  status               Show current configuration
  channel <0|1>        Select RS485 channel (default: 0)
  pins <rx> [tx]       Set UART pins (default: 1, 0)
  baud <rate>          Set baud rate (default: 115200)
  databits <7|8>       Set data bits (default: 8)
  parity <N|E|O>       Set parity: None, Even, Odd (default: N)
  stopbits <1|2>       Set stop bits (default: 1)
  dlt <number>         Set pcap DLT type (default: 147)
  start                Begin capture
  stop                 Stop capture
  stats                Show capture statistics
```

**Example session:**

```
> status
Channel:   0
Pins:      RX=GP1, TX=GP0
Baud:      115200
Format:    8N1
DLT:       147 (USER0)
Capture:   stopped

> baud 2000000
Baud: 2000000

> dlt 147
DLT: 147 (USER0)

> start
Capture started. Connect Wireshark to /dev/ttyACM1

> stats
Packets:   1,247
Bytes:     18,392
Errors:    0
Overflows: 0

> stop
Capture stopped.
```

---

## 4. pcap Output Format

### 4.1 Global Header

Sent once when capture starts:

| Field | Size | Value | Description |
|-------|------|-------|-------------|
| Magic | 4 | `0xA1B2C3D4` | pcap magic (native byte order) |
| Version Major | 2 | `2` | |
| Version Minor | 2 | `4` | |
| Timezone | 4 | `0` | GMT |
| Sigfigs | 4 | `0` | Timestamp accuracy |
| Snaplen | 4 | `65535` | Max packet length |
| DLT | 4 | configurable | Data link type |

### 4.2 Packet Record Header

Sent before each captured packet:

| Field | Size | Description |
|-------|------|-------------|
| ts_sec | 4 | Timestamp seconds (from Pico boot or epoch) |
| ts_usec | 4 | Timestamp microseconds |
| incl_len | 4 | Captured length |
| orig_len | 4 | Original length |

Followed by the raw RS485 payload bytes.

### 4.3 DLT Selection

The default DLT is 147 (`DLT_USER0`). DLTs 147-162 are reserved for user-defined protocols:

| DLT | Name |
|-----|------|
| 147 | DLT_USER0 |
| 148 | DLT_USER1 |
| ... | ... |
| 162 | DLT_USER15 |

Choose one and register your Lua dissector against it.

---

## 5. Wireshark Setup

### 5.1 Linux

**Option A: Named pipe (recommended)**

```bash
# Create pipe
mkfifo /tmp/rs485

# Start capture (in background)
cat /dev/ttyACM1 > /tmp/rs485 &

# Open Wireshark
wireshark -k -i /tmp/rs485
```

**Option B: Using socat**

```bash
socat /dev/ttyACM1,raw,echo=0 - | wireshark -k -i -
```

### 5.2 Windows

Windows requires a helper script to bridge the COM port to a named pipe.

**Step 1: Save this as `pipe_bridge.py`:**

```python
import serial
import win32pipe
import win32file
import sys

def main():
    port = sys.argv[1] if len(sys.argv) > 1 else "COM4"
    pipe_name = r"\\.\pipe\rs485"
    
    print(f"Creating pipe: {pipe_name}")
    pipe = win32pipe.CreateNamedPipe(
        pipe_name,
        win32pipe.PIPE_ACCESS_OUTBOUND,
        win32pipe.PIPE_TYPE_BYTE | win32pipe.PIPE_WAIT,
        1, 65536, 65536, 0, None
    )
    
    print(f"Waiting for Wireshark to connect...")
    win32pipe.ConnectNamedPipe(pipe, None)
    print(f"Connected. Opening {port}...")
    
    ser = serial.Serial(port, timeout=0.1)
    print(f"Streaming. Press Ctrl+C to stop.")
    
    try:
        while True:
            data = ser.read(4096)
            if data:
                win32file.WriteFile(pipe, data)
    except KeyboardInterrupt:
        pass
    finally:
        ser.close()
        win32file.CloseHandle(pipe)

if __name__ == "__main__":
    main()
```

**Step 2: Install dependencies:**

```
pip install pyserial pywin32
```

**Step 3: Configure Wireshark:**

1. Open Wireshark
2. Capture → Options → Manage Interfaces → Pipes tab
3. Click "+" and add: `\\.\pipe\rs485`
4. Click OK

**Step 4: Start capture:**

```
python pipe_bridge.py COM4
```

Then select the `\\.\pipe\rs485` interface in Wireshark and start capture.

### 5.3 Verifying the Connection

1. Connect to CLI port, run `start`
2. Open the capture in Wireshark
3. You should see the DLT type in the capture file properties
4. Raw bytes appear as "Data" until you add a dissector

---

## 6. Writing a Lua Dissector

### 6.1 Basic Template

Save as `rs485_dissector.lua` in your Wireshark plugins directory:

```lua
-- RS485 Protocol Dissector
local rs485_proto = Proto("rs485", "RS485 Protocol")

-- Define fields
local f_address = ProtoField.uint8("rs485.address", "Address", base.HEX)
local f_function = ProtoField.uint8("rs485.function", "Function", base.HEX)
local f_data = ProtoField.bytes("rs485.data", "Data")

rs485_proto.fields = { f_address, f_function, f_data }

function rs485_proto.dissector(buffer, pinfo, tree)
    pinfo.cols.protocol = "RS485"
    
    local subtree = tree:add(rs485_proto, buffer(), "RS485 Protocol Data")
    
    if buffer:len() >= 2 then
        subtree:add(f_address, buffer(0, 1))
        subtree:add(f_function, buffer(1, 1))
        if buffer:len() > 2 then
            subtree:add(f_data, buffer(2))
        end
    end
end

-- Register for DLT_USER0 (147)
local wtap_encap_table = DissectorTable.get("wtap_encap")
wtap_encap_table:add(147, rs485_proto)
```

### 6.2 Plugin Installation

| OS | Plugin Directory |
|----|------------------|
| Linux | `~/.local/lib/wireshark/plugins/` |
| Windows | `%APPDATA%\Wireshark\plugins\` |
| macOS | `~/.local/lib/wireshark/plugins/` |

Restart Wireshark or use Analyze → Reload Lua Plugins.

### 6.3 Modbus RTU Example

If you're sniffing Modbus RTU, here's a more complete dissector:

```lua
local modbus_rtu = Proto("modbus_rtu", "Modbus RTU")

local f_addr = ProtoField.uint8("modbus_rtu.address", "Slave Address", base.DEC)
local f_func = ProtoField.uint8("modbus_rtu.function", "Function Code", base.DEC)
local f_data = ProtoField.bytes("modbus_rtu.data", "Data")
local f_crc = ProtoField.uint16("modbus_rtu.crc", "CRC", base.HEX)

modbus_rtu.fields = { f_addr, f_func, f_data, f_crc }

local function_names = {
    [1] = "Read Coils",
    [2] = "Read Discrete Inputs",
    [3] = "Read Holding Registers",
    [4] = "Read Input Registers",
    [5] = "Write Single Coil",
    [6] = "Write Single Register",
    [15] = "Write Multiple Coils",
    [16] = "Write Multiple Registers",
}

function modbus_rtu.dissector(buffer, pinfo, tree)
    if buffer:len() < 4 then return end
    
    pinfo.cols.protocol = "Modbus RTU"
    
    local subtree = tree:add(modbus_rtu, buffer(), "Modbus RTU")
    
    local addr = buffer(0, 1):uint()
    local func = buffer(1, 1):uint()
    
    subtree:add(f_addr, buffer(0, 1))
    local func_tree = subtree:add(f_func, buffer(1, 1))
    
    if function_names[func] then
        func_tree:append_text(" (" .. function_names[func] .. ")")
        pinfo.cols.info = function_names[func]
    end
    
    if buffer:len() > 4 then
        subtree:add(f_data, buffer(2, buffer:len() - 4))
    end
    
    subtree:add_le(f_crc, buffer(buffer:len() - 2, 2))
end

DissectorTable.get("wtap_encap"):add(147, modbus_rtu)
```

---

## 7. Troubleshooting

| Issue | Solution |
|-------|----------|
| Only one serial port appears | Check USB cable (data vs charge-only); try different port |
| No data in Wireshark | Verify `start` command was issued; check pipe setup |
| Garbled data | Verify baud rate matches your RS485 bus |
| Missed packets | Reduce bus traffic or check for buffer overflows with `stats` |
| Wireshark shows "unknown DLT" | Ensure DLT matches your dissector registration |
| Permission denied on `/dev/ttyACM*` | Add user to `dialout` group: `sudo usermod -aG dialout $USER` |

---

## 8. Building the Firmware

### 8.1 Prerequisites

- Pico SDK installed and `PICO_SDK_PATH` set
- CMake 3.13+
- ARM GCC toolchain

### 8.2 Build Steps

```bash
mkdir build && cd build
cmake ..
```

### 8.3 Flashing
Flash in the normal Pico way:

1. Hold BOOTSEL button while plugging in Pico
2. Copy `rs485_sniffer.uf2` to the mounted drive
3. Pico reboots automatically

---

## 9. Technical Notes

### 9.1 Timing Considerations

At 2 Mbps with 10 bits per byte (8N1 + start/stop), the UART receives ~200,000 bytes/second. The RP2040's hardware UART FIFO is 32 bytes deep, giving ~160 µs to service the buffer before overflow.

### 9.2 Packet Framing

The physical layer has no inherent packet boundaries. The sniffer uses an inter-character timeout to detect packet boundaries. The default timeout is 3.5 character times (per Modbus RTU spec), but this is configurable for other protocols.

### 9.3 USB Bandwidth

USB Full Speed (12 Mbps). Each 64-byte USB packet can be sent every 1ms, giving ~64 KB/s throughput per endpoint.

---

## 10. Possible Enhancements

- Hardware timestamping via PIO for sub-microsecond accuracy
- Dual-channel simultaneous capture
- Trigger/filter support
