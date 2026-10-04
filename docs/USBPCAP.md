# Capturing LDCN through the LS-832RL with USBPcap

The Logosol LS-832RL is an FTDI-based USB-to-RS485 converter. When the vendor
"LDCN Utility" (or any host software) talks to LDCN devices through it, every
byte on the RS-485 bus passes through USB bulk transfers. Capturing those on
Windows with USBPcap and decoding them with `dissector/ldcn_usb.lua` gives a
full host-side view of the protocol, including device-to-host status packets,
without any hardware tap.

The PicoShark hardware sniffer (`docs/USAGE.md`) remains the tool for bus-side
captures; both share the same decoder (`dissector/ldcn_core.lua`).

---

## 1. Install USBPcap

1. Download the USBPcap installer from <https://desowin.org/usbpcap/> (or tick
   the "USBPcap" component in the Wireshark Windows installer).
2. Run it as Administrator, accept the driver install, **reboot**.
3. Start Wireshark. The capture list now shows `USBPcap1`, `USBPcap2`, ...
   one per USB root hub.

## 2. Identify the LS-832RL

The converter uses the FTDI vendor ID `0403` (product ID normally `6001`,
FT232R family).

- In Windows Device Manager: Ports (COM & LPT) → the USB Serial Port →
  Properties → Details → Hardware Ids. Look for `USB\VID_0403&PID_6001`.
- To find which USBPcap root hub it hangs on, in Wireshark click the gear icon
  next to each `USBPcapN` interface; the dialog lists the attached devices
  with their VID/PID. Tick only the FTDI device (fewer unrelated USB packets).
- Alternatively capture on every `USBPcapN` for a few seconds while the LDCN
  Utility is running and filter on `usb.idVendor == 0x0403` to see the bus and
  device address in the enumeration packets, or just `usb.transfer_type == 0x03`
  to see which device carries bulk traffic.

Note the **bus id** and **device address** (`usb.bus_id`, `usb.device_address`,
shown in the Source/Destination columns as e.g. `1.5.1`): you will use them as
the dissector's device filter.

## 3. Capture

1. Plug in the LS-832RL **before** starting the capture if you want the
   descriptor packets (lets Wireshark's built-in FTDI dissector recognise the
   device). Starting the capture mid-session also works; the LDCN dissector does
   not depend on it.
2. Start capturing on the `USBPcapN` interface that hosts the converter.
3. Run the LDCN Utility: scan the bus, read status, move an axis, change
   outputs. Every operation produces host→device commands and device→host
   status replies.
4. Stop and save as pcapng.

## 4. Install the Lua dissector

Copy **all three** files from `dissector/` into Wireshark's personal plugins
folder:

| OS      | Folder |
|---------|--------|
| Windows | `%APPDATA%\Wireshark\plugins\` |
| Linux   | `~/.local/lib/wireshark/plugins/` |
| macOS   | `~/.local/lib/wireshark/plugins/` |

```
ldcn_core.lua   shared protocol tables, field definitions, decoders, state model
ldcn.lua        PicoShark front-end (DLT_USER0 captures)
ldcn_usb.lua    USB/FTDI front-end (USBPcap and Linux usbmon captures)
```

Help → About Wireshark → Folders shows the exact "Personal Lua Plugins" path.
Then **Analyze → Reload Lua Plugins** (`Ctrl+Shift+L`), or restart Wireshark.
Lua load errors appear in Tools → Lua → Console (or at start-up).

Wireshark 3.6 or newer is recommended. The dissector works with Lua 5.1/5.2
(Wireshark ≤ 4.2) and Lua 5.4 (Wireshark 4.4+).

## 5. Set the preferences

Edit → Preferences → Protocols:

**LDCN** (`ldcn`)

| Preference | Meaning |
|-----------|---------|
| Device types by address | `addr:type` pairs, e.g. `1:servo,2:servo,10:io,11:sk2310`. Types: `servo` (LS-231SE, PIC-SERVO), `io` (LS-773, PIC-I/O), `sk2310` (SK-2310g2 with diagnostic-code and output-bit names). Unlisted addresses default to `servo`, but a Device ID status item (ID 0 → servo, ID 2 → io) in a reply overrides the default automatically. |

**LDCN over USB** (`ldcn_usb`)

| Preference | Meaning |
|-----------|---------|
| Decode LDCN on USB bulk transfers | Master switch. |
| USB device filter (bus.address) | e.g. `1.5`. Restricts decoding to the LS-832RL so bulk traffic from other USB devices is not fed into the LDCN byte streams. Strongly recommended when anything else (USB disk, webcam) shares the root hub. |
| FTDI endpoint wMaxPacketSize | `64` for the LS-832RL (FT232R, full speed). Each USB packet from an FTDI chip starts with two modem-status bytes that are stripped; when one URB holds several USB packets the stripping repeats every `wMaxPacketSize` bytes. Use `512` for high-speed FTDI parts. Ignored when Wireshark's own FTDI FT dissector already decoded the packet. |
| Strict request/reply | LDCN is half-duplex: a new command implies the previous reply is over. When set, a command sent while a reply is still incomplete flags the stale bytes (`ldcn.unexpected`) and the unanswered command (`ldcn.no_reply`). Clear it if the host pipelines commands without waiting. |

## 6. How the decode works

- **Direction.** `usb.endpoint_address.direction` (IN = device→host = RX,
  OUT = host→device = TX); `usb.src == "host"` is the fallback.
- **Byte streams.** Payloads are concatenated per direction per USB device
  (`bus.address`). USB packet boundaries are ignored for framing, so an LDCN
  frame split over several URBs is reassembled; intermediate packets show
  `LDCN segment` with a *Reassembled in frame* link.
- **TX framing.** `0xAA` header, address, command byte; length =
  3 + (command byte high nibble) + 1 checksum byte.
- **RX framing.** Status packets have no header. The dissector predicts the
  reply length from the last command: 1 status byte + the sizes of the items
  selected by the Define Status bitmap (or by a one-shot Read Status bitmap) +
  1 checksum byte. Item sizes depend on the device type (servo vs. I/O family).
  Group addresses (≥ 0x80) get no reply unless a group leader exists (set with
  Set Address, group byte bit 7 clear); Hard Reset and Set Baud Rate get none.
- **Mismatches.** If the predicted length's checksum does not match, every
  length whose checksum matches is tried (preferring one that fills the URB)
  and the packet gets the `ldcn.unexpected` expert info stating the predicted
  and found lengths. Bytes that fit nowhere appear as `ldcn.unmatched` with raw
  hex. This is how undocumented status items show up: look for `ldcn.unexpected`
  right after a Define Status / Read Status with an unusual bitmap.

## 7. Filter cheat sheet

| Filter | Shows |
|--------|-------|
| `ldcn` | Every packet carrying LDCN bytes (commands, status, segments, unmatched) |
| `ldcn.direction == "tx"` / `== "rx"` | Host→device commands / device→host status |
| `ldcn.cmd == 3` | Read Status commands (`2` Define Status, `4` Load Trajectory / Set PWM, `6` Set Gain / Set Outputs, `0xF` Hard Reset) |
| `ldcn.address == 0x01` | Commands to address 1 and the replies predicted from them |
| `ldcn.status_items` | Commands carrying a status bitmap; `ldcn.status_items & 0x20` = Device ID requested |
| `ldcn.device_id` | Replies that identify the device (`ldcn.device_id == 2` = I/O family) |
| `ldcn.diag` | SK-2310g2 replies carrying a diagnostic code; `ldcn.diag == 0x10` = emergency stop |
| `ldcn.sk.servo_fault == 1` | SK-2310g2 Servo Fault bit set |
| `ldcn.status.cksum_error == 1` | Device reports a checksum error in the last command |
| `ldcn.unexpected` | Reply length did not match the prediction (undocumented item, lost bytes) |
| `ldcn.unmatched` | Raw bytes that could not be framed |
| `ldcn.no_reply` | Commands that got no reply before the next command |
| `ldcn.checksum.valid == 0` | Checksum failures in either direction |
| `ldcn.response_in` / `ldcn.response_to` | Follow request/reply pairs (also clickable in the detail pane) |
| `usb.transfer_type == 0x03 && usb.device_address == 5` | The raw USB bulk traffic of device address 5 |

## 8. Troubleshooting

**No `LDCN` rows at all.** Check the device filter preference matches
`usb.bus_id`.`usb.device_address` of the converter, that the traffic is bulk
(`usb.transfer_type == 0x03`), and that all three Lua files loaded (Tools →
Lua → Console, or Help → About → Plugins).

**Every reply is `ldcn.unexpected`.** Wrong device type for that address (set
the preference), or the FTDI `wMaxPacketSize` is wrong (the two status bytes
land inside the payload), or the capture started mid-conversation so the
Define Status bitmap is unknown (the dissector assumes an empty bitmap until it
sees one; a Read Status with an explicit bitmap resynchronises it).

**Commands decode but every reply shows "reply bytes with no pending
command".** The direction field is inverted or missing for this capture
format. Report the Wireshark version and `usb.endpoint_address` value.

**I/O Control (servo command 0x8) bits show only raw bit numbers.** The bit
semantics vary between PIC-SERVO firmware generations and are deliberately
not named; consult the LS-231SE datasheet.
