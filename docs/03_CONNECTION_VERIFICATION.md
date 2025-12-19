# PicoShark Connection Verification Procedures

**Document Version:** 1.0  
**Date:** 2024-12-19  
**Status:** Planning

## Table of Contents
1. [Overview](#overview)
2. [Test Equipment Required](#test-equipment-required)
3. [Test Sequence](#test-sequence)
4. [Troubleshooting Guide](#troubleshooting-guide)
5. [Acceptance Criteria](#acceptance-criteria)

---

## Overview

This document provides systematic verification procedures to ensure PicoShark hardware and firmware are functioning correctly before deployment on the LDCN network.

### Testing Philosophy

1. **Incremental complexity:** Start simple, add components progressively
2. **Isolation first:** Test components standalone before integration
3. **Non-destructive:** Network should not be affected by PicoShark
4. **Documented results:** Record all measurements for future reference

### Safety Precautions

- Disconnect RS-485 before hardware modifications
- Verify voltages before connecting to live network
- Use ESD protection when handling boards
- Never connect USB power and external power simultaneously

---

## Test Equipment Required

### Mandatory
- [ ] Multimeter (DC voltage, resistance, continuity)
- [ ] USB cable (data-capable, for Pico)
- [ ] PC with terminal emulator (PuTTY, screen, minicom)
- [ ] Raspberry Pi Debug Probe (for SWD debugging)
- [ ] RS-485 test cables (RJ45 or screw terminal)

### Recommended
- [ ] Oscilloscope (2+ channels, 50 MHz+)
- [ ] Logic analyzer (8+ channels, 50 MHz+)
- [ ] Second Pico or function generator (for signal injection)
- [ ] RS-485 breakout board (for isolated testing)

### Optional
- [ ] Protocol analyzer (for detailed RS-485 analysis)
- [ ] Network tap splitter (commercial RS-485 tap)
- [ ] Power supply (for bench testing without USB)

---

## Test Sequence

### Test 1: Pico Standalone Boot

**Objective:** Verify Pico hardware and USB connectivity work before adding Waveshare module.

**Prerequisites:** None (brand new Pico acceptable)

**Procedure:**

1. **Visual Inspection**
   ```
   [ ] Pico PCB has no visible damage
   [ ] USB connector intact
   [ ] SWD debug pads accessible
   [ ] RP2040 chip properly soldered
   ```

2. **Initial Power-On**
   - Connect Pico to PC via USB
   - Expected: Pico appears as USB mass storage device "RPI-RP2"
   - If not: Hold BOOTSEL button while connecting USB

3. **Upload Blink Firmware**
   - Download blink example from Pico SDK or Arduino
   - Drag .uf2 file to RPI-RP2 drive
   - Pico reboots automatically

4. **Verify LED Blink**
   ```
   Expected: GP25 LED blinks at 1 Hz (on for 0.5s, off for 0.5s)
   Actual: ___________
   ```

5. **Debug Probe Connection**
   - Connect Debug Probe to Pico SWD pins:
     ```
     Debug Probe          Pico
     --------------------------------
     GND (black)    →     GND (pin 3, 8, 13, 18, 23, 28, or 33)
     SWCLK (orange) →     SWCLK (pin 24)
     SWDIO (yellow) →     SWDIO (pin 25)
     ```
   - Connect Debug Probe USB to PC
   - Run: `openocd -f interface/cmsis-dap.cfg -f target/rp2040.cfg`
   - Expected output:
     ```
     Info : clock speed 5000 kHz
     Info : SWD DPIDR 0x0bc12477
     Info : rp2040.core0: hardware has 4 breakpoints, 2 watchpoints
     ```

**Pass Criteria:**
- [ ] LED blinks at 1 Hz
- [ ] OpenOCD connects successfully
- [ ] No errors in OpenOCD output

**Troubleshooting:**
- LED doesn't blink: Check USB cable (must be data-capable), try different USB port
- OpenOCD fails: Check SWD wiring, verify Debug Probe firmware updated
- Pico doesn't enumerate: Press and hold BOOTSEL, connect USB, release BOOTSEL

---

### Test 2: Waveshare Module Power and Detection

**Objective:** Verify Waveshare module is properly mounted and powered.

**Prerequisites:** 
- Test 1 passed
- Hardware modifications completed (R8/R18 removed, DE/RE wires added)

**Procedure:**

1. **Pre-Installation Verification**
   - Verify R8 and R18 removed:
     ```
     Multimeter set to resistance mode
     Measure between A and B on CH0 RJ45: _________ Ω (expect >10kΩ)
     Measure between A and B on CH1 RJ45: _________ Ω (expect >10kΩ)
     
     If <1kΩ, resistor not removed or solder bridge present
     ```

2. **Mount Waveshare on Pico**
   - Use stacking headers (female on Pico bottom, male on Waveshare bottom)
   - Ensure all pins aligned (count pin positions)
   - Press firmly but don't force

3. **Power-On Test (No RS-485 Connected)**
   - Connect Pico USB to PC
   - Measure voltages:
     ```
     Point                 Expected    Actual
     ------------------------------------------------
     Pico Pin 36 (3V3)     3.0-3.6V    _______V
     U1 Pin 8 (VCC)        3.0-3.6V    _______V
     U2 Pin 8 (VCC)        3.0-3.6V    _______V
     U1 Pin 5 (GND)        0.0V        _______V
     U2 Pin 5 (GND)        0.0V        _______V
     ```

4. **Continuity Test**
   - Power off (disconnect USB)
   - Verify GPIO connections:
     ```
     Connection            Expected    Result
     ------------------------------------------------
     GP0 to U1-Pin1 (RO)   Continuity  [ ]
     GP1 to U1-Pin4 (DI)   Continuity  [ ]
     GP4 to U2-Pin1 (RO)   Continuity  [ ]
     GP5 to U2-Pin4 (DI)   Continuity  [ ]
     GP2 to U1-Pin2&3      Continuity  [ ] (if mod added)
     GP11 to U2-Pin2&3     Continuity  [ ] (if mod added)
     ```

5. **Short Circuit Check**
   - Measure resistance between:
     ```
     Test                  Expected    Actual
     ------------------------------------------------
     3V3 to GND            >1kΩ        _______Ω
     GP0 to GND            >100kΩ      _______Ω
     GP0 to 3V3            >100kΩ      _______Ω
     U1-Pin6 (A) to GND    >10kΩ       _______Ω
     U1-Pin7 (B) to GND    >10kΩ       _______Ω
     ```
   - If any measurement <100Ω (except 3V3 to GND), investigate for shorts

**Pass Criteria:**
- [ ] All voltage readings within tolerance
- [ ] All continuity tests pass
- [ ] No short circuits detected
- [ ] R8 and R18 confirmed removed

**Troubleshooting:**
- No 3.3V on Waveshare: Check header pin contact, reseat module
- Short detected: Remove Waveshare, test Pico alone, inspect for solder bridges
- Continuity fail: Check for bent pins in headers

---

### Test 3: PIO UART RX - Isolated Test (No Network)

**Objective:** Verify PIO state machines can receive UART data correctly.

**Prerequisites:**
- Tests 1-2 passed
- Test firmware loaded (PIO RX test program)
- Signal source available (function generator OR second Pico)

**Test Firmware Requirements:**
- Configure PIO SM0 for 19200 baud RX on GP0
- Read from PIO FIFO, output to USB CDC
- Display as hex: `RX: 0x55 0x55 0x55...`

**Procedure:**

**Option A: Using Function Generator**

1. Configure function generator:
   ```
   Waveform: Square wave
   Frequency: 19200 Hz
   Amplitude: 3.3V peak (0V to 3.3V)
   Duty cycle: 50%
   ```

2. Connect:
   ```
   Function Gen → PicoShark
   Signal     →  GP0 (CH0 RX)
   GND        →  GND
   ```

3. Load test firmware, open serial terminal

4. Observe output:
   ```
   Expected: Continuous 0x55 or 0xAA (depending on polarity)
   Actual: _________________________________
   ```

5. Repeat for GP4 (CH1 RX)

**Option B: Using Second Pico**

1. Program second Pico as UART TX:
   ```c
   // Transmit 0x55 continuously at 19200 baud
   uart_init(uart0, 19200);
   gpio_set_function(0, GPIO_FUNC_UART);  // GP0 = TX
   
   while (1) {
       uart_putc_raw(uart0, 0x55);
       sleep_ms(10);
   }
   ```

2. Connect:
   ```
   Pico TX (GP0) → PicoShark RX (GP0)
   Pico GND      → PicoShark GND
   ```

3. Power on TX Pico, observe PicoShark output

**Option C: Loopback Test**

1. Modify test firmware to enable TX on GP1
2. Connect GP1 → GP0 via 1kΩ resistor (current limit)
3. Transmit known pattern, verify reception

**Verification:**

Capture at least 1000 bytes and verify:
```
Test                          Result
------------------------------------------------
Correct byte value (0x55)     [ ] Pass [ ] Fail
No framing errors             [ ] Pass [ ] Fail
Baud rate accuracy            [ ] Pass [ ] Fail
  (measure with oscilloscope)
```

**Baud Rate Accuracy Check (with oscilloscope):**
```
Measure bit period:
  Expected: 1/19200 = 52.08 µs
  Actual: _______ µs
  Error: _______ % (should be <2%)
```

**Pass Criteria:**
- [ ] 100% of bytes received correctly (1000/1000)
- [ ] No framing errors
- [ ] Baud rate within ±2%
- [ ] Works on both CH0 and CH1

**Troubleshooting:**
- Wrong byte values: Check signal polarity (invert?)
- Framing errors: Check baud rate clock divider calculation
- No data received: Verify PIO program loaded, check GPIO init

---

### Test 4: Passive Tap - Network Impact Assessment

**Objective:** Verify PicoShark does not disrupt existing LDCN network.

**Prerequisites:**
- Tests 1-3 passed
- Access to live LDCN network with LS-832RL and servo drives
- Ability to send test commands (via LDCN utility or custom software)

**Procedure:**

**Baseline Measurement (Without PicoShark):**

1. Connect PC → LS-832RL → LDCN Network (normal operation)

2. Send test command sequence (repeat 10 times):
   ```
   Command: NoOp (0x0E) to address 0x01
   Packet: 0xAA 0x01 0x0E [checksum]
   
   Expected response: Status byte from servo drive
   ```

3. Record results:
   ```
   Attempt    Response Time    Success
   -----------------------------------------
   1          _______ ms       [ ] Yes [ ] No
   2          _______ ms       [ ] Yes [ ] No
   ...
   10         _______ ms       [ ] Yes [ ] No
   
   Success rate: _____ / 10
   Avg response time: _______ ms
   ```

4. Measure signal quality with oscilloscope:
   ```
   Parameter                 Measurement
   -----------------------------------------
   Differential voltage      _______ V (expect >1.5V)
   Rise time (10%-90%)       _______ µs
   Overshoot                 _______ V
   Ringing                   [ ] Yes [ ] No
   ```

**With PicoShark Connected (Passive Tap):**

5. Connect PicoShark in parallel:
   ```
   PC → LS-832RL → LDCN Network
                  ↑
                  PicoShark (RX only, via Y-cable or tap)
   ```

6. Repeat test command sequence (10 times)

7. Record results:
   ```
   Attempt    Response Time    Success
   -----------------------------------------
   1          _______ ms       [ ] Yes [ ] No
   2          _______ ms       [ ] Yes [ ] No
   ...
   10         _______ ms       [ ] Yes [ ] No
   
   Success rate: _____ / 10
   Avg response time: _______ ms
   ```

8. Repeat oscilloscope measurements

**Comparison:**

```
Metric                    Without Tap    With Tap    Delta
----------------------------------------------------------------
Success rate              _____          _____       _____
Avg response time         _____ ms       _____ ms    _____ ms
Differential voltage      _____ V        _____ V     _____ V
Rise time                 _____ µs       _____ µs    _____ µs
```

**Pass Criteria:**
- [ ] Success rate unchanged (10/10 both cases)
- [ ] Response time delta <1ms
- [ ] Voltage drop <0.2V
- [ ] No new ringing or oscillation introduced
- [ ] Network continues operating normally with PicoShark powered off

**Troubleshooting:**
- Success rate drops: Check R8/R18 actually removed (termination issue)
- Voltage drop significant: Check for solder bridges on A/B lines
- Ringing introduced: Verify cable quality, shorten tap cables
- Network fails completely: Disconnect PicoShark immediately, inspect for shorts

---

### Test 5: Dual-Channel Simultaneous Capture

**Objective:** Verify both channels capture data independently and simultaneously.

**Prerequisites:**
- Tests 1-4 passed
- Capture firmware loaded
- Live LDCN network available

**Procedure:**

1. Load dual-channel capture firmware:
   - PIO SM0 on GP0 (CH0)
   - PIO SM1 on GP4 (CH1)
   - Both DMA channels active
   - Output to USB CDC: `[CH0] 0xAA 0x01...` and `[CH1] 0x42...`

2. Connect to live network

3. Send known command from PC:
   ```
   Command: ReadStatus (0x13) to address 0x01, no extra data
   Full packet: 0xAA 0x01 0x03 0x00 [checksum]
   
   Where:
     0xAA = Header
     0x01 = Address (device 1)
     0x03 = Command byte (0x0 = 0 data bytes, 0x3 = ReadStatus)
     0x00 = Checksum placeholder (calculate: 0x01 + 0x03 = 0x04)
   
   Corrected packet: 0xAA 0x01 0x03 0x04
   ```

4. Observe PicoShark output:

   **Expected on Channel 0 (Host TX):**
   ```
   [CH0] 0xAA 0x01 0x03 0x04
   Timestamp: T0
   ```

   **Expected on Channel 1 (Device TX):**
   ```
   [CH1] 0x42 [checksum]  (Status response, exact format varies)
   Timestamp: T1 (where T1 > T0, typically T1 - T0 < 1ms)
   ```

5. Verify capture:
   ```
   Check                          Result
   ------------------------------------------------
   CH0 shows command packet       [ ] Pass [ ] Fail
   CH1 shows response packet      [ ] Pass [ ] Fail
   Timestamps sequential (T1>T0)  [ ] Pass [ ] Fail
   No data mixing between CHs     [ ] Pass [ ] Fail
   Checksums valid                [ ] Pass [ ] Fail
   ```

6. Stress test: Send 100 commands rapidly (10/sec), verify all captured

**Pass Criteria:**
- [ ] Both channels capture correctly
- [ ] No crosstalk between channels
- [ ] Timestamps sequential and reasonable
- [ ] 100/100 packets captured in stress test
- [ ] Checksums validate correctly

**Troubleshooting:**
- Data mixing: Check DMA channel assignments, verify ring buffers separate
- Missing packets: Check buffer sizes, increase if needed
- Wrong timestamps: Verify time_us_32() called at correct point

---

### Test 6: Baud Rate Switching

**Objective:** Verify PicoShark correctly detects and switches baud rates.

**Prerequisites:**
- Tests 1-5 passed
- Baud rate switching firmware loaded
- Live LDCN network at 19200 baud (default)

**Procedure:**

1. Verify current baud rate:
   ```
   Send: NoOp to address 1
   Expected: Response received at 19200 baud
   PicoShark should log: "Current baud: 19200"
   ```

2. Send Set Baud Rate command:
   ```
   Command: Set Baud Rate (0x0A) to group 0xFF, BRD=0x0A (115200 baud)
   Packet: 0xAA 0xFF 0x1A 0x0A [checksum]
   
   Calculate checksum: 0xFF + 0x1A + 0x0A = 0x123, lower byte = 0x23
   Full packet: 0xAA 0xFF 0x1A 0x0A 0x23
   ```

3. Observe PicoShark behavior:
   ```
   Expected log output:
   [T0    ] RX CH0: 0xAA 0xFF 0x1A 0x0A 0x23
   [T0+1ms] Baud rate change detected: 19200 → 115200
   [T0+2ms] Switching SM0 to 115200 (div=135.6)
   [T0+2ms] Switching SM1 to 115200 (div=135.6)
   [T0+3ms] Ready at 115200 baud
   ```

4. Wait for silence period (network switches baud rates)

5. Send NoOp at new baud rate (115200):
   ```
   Expected: PicoShark captures packet correctly
   PicoShark log: "RX CH0: 0xAA 0x01 0x0E [checksum]"
   ```

6. Verify continued operation:
   - Send 10 more commands at 115200
   - All should be captured correctly

7. Power cycle network (reset to 19200), verify PicoShark also resets

**Measurements:**

```
Metric                         Measurement
------------------------------------------------
Time from command to switch    _______ ms (expect <5ms)
Bytes lost during switch       _______ (expect 0-5)
First packet at new rate OK?   [ ] Yes [ ] No
Continued capture accurate?    [ ] Yes [ ] No
```

**Pass Criteria:**
- [ ] Baud rate change detected automatically
- [ ] Switch completes within 5ms
- [ ] <5 bytes lost during transition
- [ ] Subsequent captures accurate at new rate
- [ ] Can switch back to 19200 (power cycle test)

**Troubleshooting:**
- Not detecting change: Verify Set Baud Rate packet parsing logic
- Wrong new baud rate: Check BRD lookup table
- No data after switch: Verify clock divider calculation correct
- Many bytes lost: Reduce switch overhead, optimize SM disable/enable sequence

---

### Test 7: Long-Duration Stability

**Objective:** Verify PicoShark operates reliably over extended periods.

**Prerequisites:**
- Tests 1-6 passed
- Live LDCN network
- Ability to generate continuous traffic

**Procedure:**

1. Set up continuous traffic generator:
   ```python
   # Example Python script via LS-832RL
   import serial
   import time
   
   port = serial.Serial('/dev/ttyUSB0', 19200)
   
   for i in range(36000):  # 10 commands/sec for 1 hour
       # Send NoOp to address 1
       port.write(b'\xAA\x01\x0E\x0F')
       time.sleep(0.1)
   ```

2. Start PicoShark capture

3. Monitor for 1 hour (or 10 minutes for initial test):
   ```
   Metric to track:
   - Packets received: _________
   - Packets lost: _________
   - Buffer overflows: _________
   - Checksum errors: _________
   - Framing errors: _________
   - USB disconnects: _________
   ```

4. Check system health:
   ```
   Time     Packets    Lost    CPU %    Mem Free    Temp
   -----------------------------------------------------------
   0 min    0          0       ___%     ____ KB     ____°C
   10 min   6000       __      ___%     ____ KB     ____°C
   20 min   12000      __      ___%     ____ KB     ____°C
   ...
   60 min   36000      __      ___%     ____ KB     ____°C
   ```

5. Examine captured data:
   - Verify first 100 packets valid
   - Verify last 100 packets valid
   - Spot-check middle packets

**Pass Criteria:**
- [ ] Packet loss <0.1% (36 lost out of 36000 acceptable)
- [ ] No buffer overflows
- [ ] Checksum error rate <0.1%
- [ ] USB stays connected (no re-enumerations)
- [ ] No firmware crashes
- [ ] Memory usage stable (no leaks)
- [ ] Temperature <60°C

**Troubleshooting:**
- Packet loss high: Increase buffer sizes, check for CPU starvation
- Buffer overflows: Optimize packet processing speed
- USB disconnects: Check cable quality, reduce USB traffic rate
- Memory leaks: Review packet queue management, add memory logging

---

## Troubleshooting Guide

### Common Issues

| Symptom | Probable Cause | Solution |
|---------|---------------|----------|
| No USB enumeration | Bad cable, wrong port, Pico bricked | Try different cable/port, hold BOOTSEL |
| LED doesn't blink | Firmware not loaded correctly | Re-upload .uf2 file |
| No 3.3V on Waveshare | Poor header contact | Reseat module, check pin alignment |
| Network fails with tap | Termination not removed | Verify R8/R18 removal with multimeter |
| Wrong byte values | Baud rate mismatch | Recalculate clock divider |
| Framing errors | Signal integrity issue | Check cable length, add termination |
| USB drops out | Buffer overflow | Increase buffer size, reduce capture rate |
| Can't control DE/RE | Mod not installed | Check GP2/GP11 wiring |

### Debug Checklist

When something doesn't work:

```
[ ] Power supply voltage correct (3.3V ±0.3V)?
[ ] All grounds connected?
[ ] GPIO pins configured correctly (input/output, pull-up/down)?
[ ] PIO program loaded and enabled?
[ ] DMA channel configured and started?
[ ] Clock dividers calculated correctly?
[ ] Firmware uploaded to correct device?
[ ] USB cable data-capable (not charge-only)?
[ ] RS-485 polarity correct (A to A, B to B)?
[ ] Termination resistors in correct places (endpoints only)?
[ ] Checksums calculated correctly?
[ ] Timestamps overflow handled (32-bit wrap)?
```

---

## Acceptance Criteria

PicoShark is ready for production use when:

**Hardware:**
- [ ] All voltages within specification
- [ ] No short circuits detected
- [ ] Modifications completed correctly (R8/R18 removed, DE/RE wired)
- [ ] Mechanical assembly secure

**Sniffer Mode:**
- [ ] Both channels capture simultaneously
- [ ] No network impact (passive tap verified)
- [ ] Baud rate switching works automatically
- [ ] 1-hour stability test passes (<0.1% loss)
- [ ] USB PCAP output readable by Wireshark

**Interface Mode (if implemented):**
- [ ] Transmit and receive functional
- [ ] DE/RE control timing correct
- [ ] Can control servo drives successfully
- [ ] No conflicts with network devices

**Software:**
- [ ] Wireshark dissector decodes packets correctly
- [ ] All LDCN commands recognized
- [ ] Malformed packets flagged appropriately
- [ ] Baud rate changes visible in capture

---

## Test Log Template

Use this template to document testing results:

```
PicoShark Test Log
==================

Date: _______________
Tester: _______________
Hardware Rev: _______________
Firmware Rev: _______________

Test 1: Pico Standalone Boot
  [ ] Pass [ ] Fail
  Notes: _______________________________________

Test 2: Waveshare Module Power
  [ ] Pass [ ] Fail
  Notes: _______________________________________

Test 3: PIO UART RX
  [ ] Pass [ ] Fail
  Notes: _______________________________________

Test 4: Passive Tap Impact
  [ ] Pass [ ] Fail
  Notes: _______________________________________

Test 5: Dual-Channel Capture
  [ ] Pass [ ] Fail
  Notes: _______________________________________

Test 6: Baud Rate Switching
  [ ] Pass [ ] Fail
  Notes: _______________________________________

Test 7: Long-Duration Stability
  [ ] Pass [ ] Fail
  Notes: _______________________________________

Overall Status: [ ] PASS [ ] FAIL [ ] NEEDS REWORK

Signature: _______________  Date: _______________
```

---

## Revision History

| Version | Date | Author | Changes |
|---------|------|--------|---------|
| 1.0 | 2024-12-19 | Initial | Connection verification procedures |
