# PicoShark Hardware Setup and Modifications

**Document Version:** 1.1  
**Date:** 2024-12-19  
**Status:** Planning

## Table of Contents
1. [Bill of Materials](#bill-of-materials)
2. [Hardware Architecture](#hardware-architecture)
3. [Required Hardware Modifications](#required-hardware-modifications)
4. [Pinout and Connections](#pinout-and-connections)
5. [Network Topology](#network-topology)
6. [Assembly Instructions](#assembly-instructions)

---

## Bill of Materials

### Core Components
| Item | Part Number | Quantity | Purpose |
|------|-------------|----------|---------|
| Raspberry Pi Pico | RP2040 | 1 | Main controller |
| Waveshare Pico-2CH-RS485 | - | 1 | Dual RS-485 interface |
| Raspberry Pi Debug Probe | - | 1 | SWD debugging |
| USB Cable (data capable) | - | 1 | Pico to PC connection |
| RS-485 Network Cables | RJ45, 4-wire | 2 | Tap connections |

### Tools Required for Modifications
- Soldering iron (temperature controlled, 300-350°C)
- Solder wick or desoldering pump
- Fine-tip tweezers
- Multimeter
- Magnifying glass or loupe (recommended)
- ESD wrist strap
- Anti-static work mat

### Optional Components for Mode Select
- Tactile push button (6mm)
- 10kΩ resistor (0805 SMD or through-hole)
- Small gauge wire (30 AWG)

### Optional Test Equipment
- Logic analyzer (for signal verification)
- Oscilloscope (for RS-485 signal quality checks)

---

## Hardware Architecture

```
┌─────────────────────────────────────────────────────────┐
│                    Raspberry Pi Pico                    │
│                       (RP2040)                          │
│                                                         │
│  GP0 (RX CH0) ─────┐                                   │
│  GP1 (TX CH0) ─────┤  Channel 0                        │
│                     │  (auto-direction via S1)          │
│  GP4 (RX CH1) ─────┤  Channel 1                        │
│  GP5 (TX CH1) ─────┤  (auto-direction via S2)          │
│                     │                                    │
│  GP14 ────────────┬─┘  Mode Select (optional)          │
│                   │                                     │
│  GP25 ────────────┘    Built-in LED                    │
└─────────────────────────────────────────────────────────┘
           │
           │ (Stacking headers)
           ↓
┌─────────────────────────────────────────────────────────┐
│           Waveshare Pico-2CH-RS485 Module               │
│                                                         │
│  ┌──────────────────┐         ┌──────────────────┐    │
│  │   U1: SP3485     │         │   U2: SP3485     │    │
│  │   (Channel 0)    │         │   (Channel 1)    │    │
│  │                  │         │                  │    │
│  │ RO(1)→GP0        │         │ RO(1)→GP4        │    │
│  │ RE(2)←[S1 auto]  │         │ RE(2)←[S2 auto]  │    │
│  │ DE(3)←[S1 auto]  │         │ DE(3)←[S2 auto]  │    │
│  │ DI(4)←GP1        │         │ DI(4)←GP5        │    │
│  │ A(6) ↔ RJ45      │         │ A(6) ↔ RJ45      │    │
│  │ B(7) ↔ RJ45      │         │ B(7) ↔ RJ45      │    │
│  └──────────────────┘         └──────────────────┘    │
│                                                         │
│  R8 (120Ω) ← REMOVE THIS       R18 (120Ω) ← REMOVE    │
│                                                         │
│  S1 (NPN) - Auto TX/RX         S2 (NPN) - Auto TX/RX  │
│  └─ Controlled by GP1          └─ Controlled by GP5    │
└─────────────────────────────────────────────────────────┘
```

**Key Feature:** The Waveshare board includes automatic direction control via transistors S1 and S2. When the TX pin goes HIGH (transmitting data), the transistor automatically switches the RS-485 transceiver to transmit mode. When TX is LOW (idle), the transceiver is in receive mode.

---

## Required Hardware Modifications

### Modification 1: Remove Termination Resistors (R8 and R18)

**Purpose:** Passive tap must not load the network with termination impedance.

**Why This is Critical:**

RS-485 networks require termination resistors (120Ω) at the **two physical ends** of the bus only. The Waveshare board has termination resistors built-in, which is fine when it's an endpoint - but PicoShark will be tapping in the **middle** of the network.

**Without removal:**
- Network will have three termination points instead of two
- Parallel resistance becomes ~40Ω instead of 120Ω
- Signal reflections and impedance mismatch
- **Network communication will fail**

**Proper network topology:**
```
┌──────────┐        ┌──────────┐        ┌──────────┐
│ LS-832RL │◄──────►│ LS-773   │◄──────►│ LS-773   │
│  (Host)  │        │ (Device) │        │ (Device) │
└────┬─────┘        └──────────┘        └────┬─────┘
     │                                        │
   120Ω                                     120Ω
 Termination                            Termination
```

**With PicoShark passive tap (before R8/R18 removal - WRONG):**
```
┌──────────┐        ┌──────────┐        ┌──────────┐
│ LS-832RL │◄──────►│ LS-773   │◄──────►│ LS-773   │
│  (Host)  │    │   │ (Device) │        │ (Device) │
└────┬─────┘    │   └──────────┘        └────┬─────┘
     │          │                             │
   120Ω         │                           120Ω
              ┌─┴──────────┐
              │ PicoShark  │  ← ADDING 120Ω TERMINATION
              │ (Sniffer)  │     BREAKS NETWORK!
              └────┬───────┘
                 120Ω (BAD!)
```

**After R8/R18 removal (CORRECT):**
```
┌──────────┐        ┌──────────┐        ┌──────────┐
│ LS-832RL │◄──────►│ LS-773   │◄──────►│ LS-773   │
│  (Host)  │    │   │ (Device) │        │ (Device) │
└────┬─────┘    │   └──────────┘        └────┬─────┘
     │          │                             │
   120Ω         │                           120Ω
              ┌─┴──────────┐
              │ PicoShark  │  ← High impedance tap
              │ (Sniffer)  │     (>10kΩ, passive)
              └────────────┘
```

#### Component Identification

**R8 (Channel 0):**
- Located near U1 (SP3485 transceiver)
- 120Ω resistor between pins 6 (A) and 7 (B)
- SMD resistor, typically marked "121"

**R18 (Channel 1):**
- Located near U2 (SP3485 transceiver)
- 120Ω resistor between pins 6 (A) and 7 (B)
- SMD resistor, typically marked "121"

#### Removal Procedure

**Safety Precautions:**
- Wear ESD wrist strap connected to ground
- Work on anti-static mat
- Ensure board is completely unpowered
- No voltage on RS-485 lines

**Step-by-step:**

1. **Locate R8 on the board**
   - Near U1 (SP3485), between A and B terminals
   - Small rectangular SMD component

2. **Apply flux to both pads** (optional but recommended)
   - Makes solder flow easier
   - Reduces heat damage to PCB

3. **Heat both pads simultaneously**
   - Use soldering iron with chisel tip
   - Contact both pads at once if possible
   - OR heat one pad for 2 seconds, then quickly switch to other pad
   - Wait until solder on both pads is molten

4. **Lift resistor with tweezers**
   - While both pads are molten, gently lift resistor upward
   - May need to rock slightly side-to-side
   - Don't pull hard - reapply heat if stuck

5. **Clean pads with solder wick**
   - Place copper braid over pad
   - Apply iron to wick (not directly to pad)
   - Solder wicks up into the braid
   - Leave pads clean and flat

6. **Repeat for R18**
   - Same procedure for Channel 1

7. **Inspect with magnifier**
   - Verify no solder bridges between A and B pads
   - Pads should be clean, no leftover solder blobs
   - No lifted traces or damaged PCB

#### Verification (CRITICAL - DO NOT SKIP)

**Multimeter resistance measurement:**

Set multimeter to resistance (Ω) mode:

1. **Measure A to B on Channel 0:**
   - Probe 1: H1 pin 1 (485_B_1)
   - Probe 2: H1 pin 3 (485_A_1)
   - **Expected: >10kΩ** (typically 12kΩ from SP3485 input impedance)
   - **FAIL if: <1kΩ** (resistor still present or solder bridge)

2. **Measure A to B on Channel 1:**
   - Probe 1: H3 pin 1 (485_B_2)
   - Probe 2: H3 pin 3 (485_A_2)
   - **Expected: >10kΩ**
   - **FAIL if: <1kΩ**

3. **Document results:**
   ```
   CH0 A-to-B resistance: _____ kΩ  (must be >10kΩ)
   CH1 A-to-B resistance: _____ kΩ  (must be >10kΩ)
   
   Date: __________
   Verified by: __________
   ```

**Checklist before proceeding:**
- [ ] R8 physically removed from board
- [ ] R18 physically removed from board
- [ ] No solder bridges between A and B pads
- [ ] PCB traces undamaged (visual inspection)
- [ ] CH0 A-B resistance >10kΩ (multimeter verified)
- [ ] CH1 A-B resistance >10kΩ (multimeter verified)
- [ ] Photos taken (before/after)

**DO NOT PROCEED** until all checkboxes are marked and measurements pass.

---

### Modification 2: Add Mode Selection Button (OPTIONAL)

**Purpose:** Allow selection between Sniffer Mode and Interface Mode at boot time.

**Note:** This modification is optional. Without it, you can set the mode in firmware via `#define DEFAULT_MODE`.

#### Components Needed

- 1× Tactile push button (6×6mm or similar)
- 1× 10kΩ resistor (0805 SMD or 1/4W through-hole)
- Small gauge wire (~3 inches of 30 AWG)

#### Circuit Design

```
        3.3V
         │
         │ (button pressed)
         ├───┐
         │   │
    ┌────┴───┴────┐
    │   Button    │
    └────┬────────┘
         │
         ├──────► GP14 (Pico Pin 19)
         │
        ┌┴┐
        │ │ 10kΩ
        │ │ (pull-down)
        └┬┘
         │
        GND
```

**Logic:**
- Button NOT pressed (default): GP14 = LOW → **Sniffer Mode**
- Button pressed at boot: GP14 = HIGH → **Interface Mode**

#### Installation Procedure

1. **Solder 10kΩ pull-down resistor**
   - One end to GP14 (Pico pin 19)
   - Other end to GND (any GND pin)
   - Can use through-hole resistor with leads

2. **Solder button**
   - One terminal to GP14 (same connection as resistor)
   - Other terminal to 3.3V (Pin 36)
   - Optionally use short wires for flexible placement

3. **Secure mechanically**
   - Hot glue button to board edge (optional)
   - Ensure no shorts to adjacent pins

4. **Test with multimeter**
   - Button not pressed: GP14 to GND = ~10kΩ
   - Button pressed: GP14 to 3V3 = <10Ω

#### Firmware Integration

```c
#define MODE_SELECT_PIN 14

void setup() {
    gpio_init(MODE_SELECT_PIN);
    gpio_set_dir(MODE_SELECT_PIN, GPIO_IN);
    // Pull-down is external hardware
    
    sleep_ms(100);  // Debounce
    
    if (gpio_get(MODE_SELECT_PIN)) {
        // Button pressed = HIGH
        current_mode = MODE_INTERFACE;
        printf("Interface Mode selected\n");
    } else {
        // Button not pressed = LOW
        current_mode = MODE_SNIFFER;
        printf("Sniffer Mode selected\n");
    }
}
```

---

## Automatic Direction Control (Built-In Feature)

### How It Works

The Waveshare Pico-2CH-RS485 board includes **automatic transmit/receive direction control** via NPN transistors S1 (Channel 0) and S2 (Channel 1). This eliminates the need for manual DE/RE control in firmware.

**Circuit Operation:**

**Receive Mode (default state):**
- TX pin (GP1 or GP5) is idle at logic LOW
- Transistor (S1/S2) is OFF
- DE/RE pins configured for receive mode
- SP3485 receiver enabled, driver disabled
- High-impedance on A/B lines

**Transmit Mode (automatic):**
- When UART begins transmission, TX pin goes HIGH
- Transistor (S1/S2) turns ON
- DE/RE pins automatically switch to transmit mode
- SP3485 driver enabled, receiver disabled
- Drives A/B lines with data

**Return to Receive:**
- TX pin returns to LOW when transmission complete
- Transistor turns OFF
- Returns to receive mode automatically
- No firmware intervention needed

### Implications for Each Mode

**Sniffer Mode:**
- Configure GP1/GP5 as **inputs** (never driven)
- TX pins always stay LOW
- Transceivers permanently in receive mode
- Perfect for passive monitoring

**Interface Mode:**
- Configure GP1/GP5 as **UART TX outputs**
- Automatic direction switching on every transmission
- Firmware just uses standard UART API
- No need to manually toggle DE/RE before/after transmit

**This is a significant simplification!** No additional wiring or complex DE/RE control logic required.

---

## Pinout and Connections

### Complete Pin Mapping

| Pico Pin | GPIO | Function | Connects To | Direction | Notes |
|----------|------|----------|-------------|-----------|-------|
| 1 | GP0 | UART0 RX | U1-RO (pin 1) | Input | Channel 0 receive data |
| 2 | GP1 | UART0 TX | U1-DI (pin 4) | Output | Channel 0 transmit (auto-direction) |
| 6 | GP4 | UART1 RX | U2-RO (pin 1) | Input | Channel 1 receive data |
| 7 | GP5 | UART1 TX | U2-DI (pin 4) | Output | Channel 1 transmit (auto-direction) |
| 19 | GP14 | Digital In | Mode button | Input | Optional: Mode selection |
| 25 | GP25 | Digital Out | Built-in LED | Output | Status indicator |
| 36 | 3V3(OUT) | Power | - | Power | Power supply |
| 38 | GND | Ground | - | Ground | Common ground |

### RS-485 Connector Pinout (RJ45)

**H1 (Channel 0) and H3 (Channel 1) - both use same pinout:**

| Pin | Signal | Description |
|-----|--------|-------------|
| 1 | 485_B | RS-485 B line (inverting) |
| 2 | GND | Signal ground |
| 3 | 485_A | RS-485 A line (non-inverting) |
| 4 | +5V/VDD | Power (not used for passive tap) |
| 5-8 | N.C. | Not connected |

**For LDCN networks (LS-832RL standard):**
- Pin 1: FROM_LDCN_TX / TO_LDCN_RX (differential negative)
- Pin 3: FROM_LDCN_RX / TO_LDCN_TX (differential positive)

---

## Network Topology

### Sniffer Mode Topology (Passive Tap)

```
                                    ┌─────────────┐
                                    │  PC Running │
                                    │  Wireshark  │
                                    └──────┬──────┘
                                           │ USB
                              ┌────────────┴────────────┐
                              │      PicoShark          │
                              │   (Passive Monitor)     │
                              └────┬─────────────┬──────┘
                                   │             │
                          Channel 0│             │Channel 1
                           (tap H→D)             (tap D→H)
                                   │             │
    ┌──────────┐    ┌──────────────┴──────┐     │     ┌──────────┐
    │LS-832RL  │◄───┤   RS-485 Network    ├─────┴────►│ LS-773   │
    │ (Host)   │    │   (Main Bus)        │           │ (Device) │
    └──────────┘    └─────────────────────┘           └──────────┘
         │                                                   │
       120Ω                                               120Ω
    Termination                                       Termination

Key characteristics:
- PicoShark presents >10kΩ impedance (passive)
- No additional termination on network
- Zero impact on bus timing or signal quality
- Both directions monitored simultaneously
```

### Interface Mode Topology (Active Replacement)

```
                                    ┌─────────────┐
                                    │  PC Running │
                                    │  Wireshark  │
                                    └──────┬──────┘
                                           │ USB
                              ┌────────────┴────────────┐
                              │      PicoShark          │
                              │  (Active Interface)     │
                              │  Replaces LS-832RL      │
                              └────┬────────────────────┘
                                   │
                           RS-485 Network
                                   │
                    ┌──────────────┴──────────────┐
                    │                             │
              ┌─────┴─────┐               ┌──────┴──────┐
              │  LS-773   │               │   LS-773    │
              │ (Device)  │               │  (Device)   │
              └───────────┘               └─────────────┘
                    │                             │
                  120Ω                          120Ω
               Termination                  Termination

Key characteristics:
- PicoShark acts as bus master (120Ω termination on one end)
- Bidirectional communication
- Command/response protocol support
- Captures own traffic in PCAP
```

---

## Assembly Instructions

### Step 1: Prepare Workspace

1. Set up anti-static work area
2. Put on ESD wrist strap
3. Gather all tools and components
4. Have good lighting and magnification ready

### Step 2: Modify Waveshare Board

1. **Remove R8 and R18** (follow procedure above)
2. **Verify with multimeter** (>10kΩ A-to-B on both channels)
3. **Optional: Add mode button** (if desired)
4. **Take photos** of completed modifications

### Step 3: Prepare Raspberry Pi Pico

1. **Flash initial test firmware** (LED blink)
   - Verify Pico is functional before assembly
   - Test via USB connection

2. **Optional: Install Debug Probe**
   - Connect SWD pins if using debugger
   - Test with OpenOCD before stacking

### Step 4: Stack Assembly

1. **Align headers carefully**
   - Pico pins must mate correctly with Waveshare socket
   - Check pin 1 alignment (GP0)

2. **Press together gently but firmly**
   - Ensure all pins seated
   - No bent pins

3. **Visual inspection**
   - All pins inserted fully
   - No shorts visible
   - Board stable

### Step 5: Power-On Test (No RS-485 connected yet)

1. **Connect USB to Pico**
2. **Check voltages with multimeter:**
   - 3V3 pin: 3.0-3.6V ✓
   - VCC at U1/U2: 3.0-3.6V ✓
   - No shorts between 3V3 and GND (>1kΩ) ✓

3. **Verify GPIO connections:**
   - Continuity GP0 → U1 pin 1
   - Continuity GP1 → U1 pin 4
   - Continuity GP4 → U2 pin 1
   - Continuity GP5 → U2 pin 4

4. **Check for smoke/heat**
   - Nothing should get hot
   - No burning smell

### Step 6: Firmware Upload

1. Load PicoShark firmware via USB or SWD
2. Verify boot message on USB serial
3. Check mode selection (if button installed)

### Step 7: Ready for Testing

Proceed to **03_CONNECTION_VERIFICATION.md** for systematic testing.

---

## Safety and Best Practices

### Before Connecting to Live Network

- [ ] R8/R18 removal verified with multimeter
- [ ] No shorts on power rails
- [ ] Firmware boots correctly
- [ ] Mode selected properly (Sniffer vs Interface)
- [ ] Network is powered down OR using test bench setup

### ESD Protection

- Always use wrist strap when handling boards
- Store in anti-static bags when not in use
- Work on grounded anti-static mat

### Mechanical Stability

- Ensure Pico is fully seated on Waveshare headers
- No loose connections
- Consider hot glue for strain relief on mode button
- Secure USB cable to prevent pulling on Pico

### Troubleshooting

| Symptom | Likely Cause | Solution |
|---------|-------------|----------|
| No USB enumeration | Pico not seated | Reseat Pico, check pins |
| 0V on 3V3 rail | Short circuit | Check for solder bridges |
| Network fails with PicoShark | R8/R18 not removed | Re-verify multimeter test |
| Hot components | Short or wrong voltage | Power off immediately, inspect |
| Bent Pico pins | Misalignment during assembly | Carefully straighten with tweezers |

---

## Revision History

| Version | Date | Author | Changes |
|---------|------|--------|---------|
| 1.0 | 2024-12-19 | Initial | Hardware setup with three modifications |
| 1.1 | 2024-12-19 | Corrected | Removed DE/RE wiring mod (auto-direction control already present) |
