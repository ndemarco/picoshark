# PicoShark Usage Guide

PicoShark is a passive dual-channel serial sniffer that streams live captures to Wireshark as PCAP over USB. It was built with LDCN (Logosol Distributed Control Network, an RS-485 protocol) as the target, but **the capture layer is generic**: any UART signal can be sniffed as long as appropriate hardware converts each direction of a full-duplex stream to 3.3 V TTL levels the Pico can read. The LDCN Wireshark dissector is an optional protocol-decoding layer on top.

---

## Hardware

### Required

- Raspberry Pi Pico (RP2040)
- Waveshare Pico-2CH-RS485 expansion board

### Critical hardware modification

**Remove resistors R8 and R18** from the Waveshare board before connecting to any bus.

These are 120 Ω termination resistors. Leaving them in place turns the sniffer into an active bus terminator, which changes the bus impedance and can corrupt traffic or damage transceivers. With R8 and R18 removed, input impedance is >10 kΩ — a true passive tap.

### GPIO pin assignments

| Channel | Function | GPIO |
|---------|----------|------|
| CH0     | RX input | GP0  |
| CH1     | RX input | GP4  |

TX pins (GP1, GP5) are currently unused in sniffer mode.

### Wiring for RS-485 / LDCN

Connect the Waveshare RS-485 terminals directly across the bus wires:

```
RS-485 bus A ──┬── Waveshare CH0 A
               └── Waveshare CH1 A

RS-485 bus B ──┬── Waveshare CH0 B
               └── Waveshare CH1 B
```

Because LDCN is half-duplex (one direction at a time on a shared pair), both channels see the same signal. Use CH0 and CH1 at two physically separate points on the bus to observe propagation, or wire only CH0 for a single-point tap.

### General UART use (non-RS-485)

For any full-duplex UART, tap each direction separately:

- **CH0 RX (GP0)** ← TX line from device A (after level conversion to 3.3 V TTL)
- **CH1 RX (GP4)** ← TX line from device B (after level conversion to 3.3 V TTL)

The `channel` field in each captured packet tells you which direction the byte came from.

**Level conversion examples:**

| Signal level | Conversion method |
|---|---|
| RS-232 (±12 V) | MAX3232 or similar RS-232 ↔ TTL IC |
| 5 V TTL/CMOS | Resistor voltage divider (e.g. 10 kΩ + 20 kΩ) or level-shift IC |
| 3.3 V TTL | Direct connection |

> The Pico's GPIO pins are **not** 5 V tolerant. Always ensure signal levels are ≤ 3.3 V before connecting.

---

## Building the firmware

### Prerequisites

```bash
sudo apt install cmake gcc-arm-none-eabi libnewlib-arm-none-eabi libstdc++-arm-none-eabi-newlib

# Clone pico-sdk if not present
git clone https://github.com/raspberrypi/pico-sdk /opt/pico-sdk --recurse-submodules
export PICO_SDK_PATH=/opt/pico-sdk
```

### Build

```bash
cd picoshark
mkdir build && cd build
PICO_SDK_PATH=/opt/pico-sdk cmake ..
make -j$(nproc)
```

Output: `build/picoshark.uf2` (~47 KB)

---

## Flashing

1. Hold the **BOOTSEL** button on the Pico and connect it to the host via USB.
2. The Pico mounts as a USB mass storage device (e.g. `RPI-RP2`).
3. Copy the UF2 file to the drive:

```bash
cp build/picoshark.uf2 /media/$USER/RPI-RP2/
```

The Pico reboots automatically. After a moment, a CDC serial port appears:

```
Linux:   /dev/ttyACM0  (or ttyACM1, check dmesg)
macOS:   /dev/tty.usbmodem*
Windows: COMx  (check Device Manager)
```

> **WSL2 note:** USB devices are not automatically visible inside WSL2. Either use the UF2 drag-and-drop from Windows Explorer, or set up `usbipd-win` to forward the USB device.

---

## Capturing with Wireshark

### Linux / macOS

Pipe directly to Wireshark for live capture:

```bash
cat /dev/ttyACM0 | wireshark -k -i -
```

Save to file instead:

```bash
cat /dev/ttyACM0 > capture.pcap
# open later:
wireshark capture.pcap
```

### Identifying the correct port

```bash
dmesg | grep ttyACM
# Look for: cdc_acm ... ttyACM0: USB ACM device
```

### Windows

Use a named pipe bridge. In PowerShell:

```powershell
# Identify the COM port in Device Manager first, e.g. COM3
# Then pipe to Wireshark:
& "C:\Program Files\Wireshark\Wireshark.exe" -k -i \\.\pipe\picoshark &
cmd /c "type COM3 > \\.\pipe\picoshark"
```

Alternatively, capture to a file with a terminal emulator (PuTTY in raw/binary logging mode) and open in Wireshark.

---

## Wireshark LDCN dissector

The LDCN dissector decodes PicoShark captures for LDCN traffic. For other protocols, write a dissector for **DLT_USER0 (link type 147)** using the same registration pattern.

### Installation

| OS      | Path |
|---------|------|
| Linux   | `~/.local/lib/wireshark/plugins/ldcn.lua` |
| macOS   | `~/.local/lib/wireshark/plugins/ldcn.lua` |
| Windows | `%APPDATA%\Wireshark\plugins\ldcn.lua` |

Copy `dissector/ldcn.lua` from this repository to the appropriate path, then reload:

**Wireshark → Analyze → Reload Lua Plugins** (or `Ctrl+Shift+L`)

### Display filters

| Filter | Shows |
|--------|-------|
| `ldcn` | All LDCN packets |
| `ldcn.channel == 0` | Packets seen on CH0 |
| `ldcn.channel == 1` | Packets seen on CH1 |
| `ldcn.address == 0x01` | Traffic to/from device address 1 |
| `ldcn.cmd_value == 0x0A` | Set Baud Rate commands |
| `ldcn.checksum_valid == false` | Checksum errors |
| `ldcn.flags != 0` | Any flagged packets (errors, truncated, framing) |

---

## Baud rate

The firmware starts at **19200 baud** (LDCN default after reset).

### Automatic baud-rate tracking (LDCN)

When the parser sees a valid LDCN `Set Baud Rate` command (command `0x0A` sent to a group address), it reconfigures both PIO state machines automatically. No intervention required.

Supported rates:

| BRD byte | Baud rate |
|----------|-----------|
| `0x81`   | 9600      |
| `0x3F`   | 19200     |
| `0x14`   | 57600     |
| `0x0A`   | 115200    |
| `0x27`   | 125000    |
| `0x0F`   | 312500    |
| `0x07`   | 625000    |
| `0x03`   | 1250000   |

### Non-LDCN use

Baud rate is fixed at 19200 unless you change `19200` in `src/main.c` and rebuild. A configuration channel for runtime baud-rate selection is a planned future feature.

---

## Troubleshooting

**No packets captured**
- Confirm R8 and R18 are removed from the Waveshare board.
- Check wiring polarity — RS-485 A/B are swapped on some cables.
- Verify baud rate matches the target device (default 19200).
- Check `ldcn.flags` column in Wireshark for framing errors (wrong baud rate symptom).

**Wireshark shows raw bytes / no dissection**
- Install `dissector/ldcn.lua` to the correct plugins path.
- Reload with `Ctrl+Shift+L`.
- Confirm the capture file uses link type 147 (`DLT_USER0`): `tshark -r capture.pcap -V | head`.

**USB port not detected after flashing**
- Use a data-capable USB cable (some cables are charge-only).
- Try a different USB port.

**Framing errors on every packet**
- Baud rate mismatch. Check the actual line rate with an oscilloscope or a known-good UART monitor.
- Check signal voltage levels — levels outside 0–3.3 V will cause framing errors and may damage the Pico.
