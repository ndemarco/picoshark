# PicoShark Packet Parser Architecture

**Document Version:** 1.0  
**Date:** 2024-12-19  
**Status:** Planning

## Table of Contents
1. [Overview](#overview)
2. [LDCN Packet Structure](#ldcn-packet-structure)
3. [Parser State Machine](#parser-state-machine)
4. [Data Structures](#data-structures)
5. [Baud Rate Detection](#baud-rate-detection)
6. [Error Handling](#error-handling)
7. [Performance Analysis](#performance-analysis)

---

## Overview

The packet parser converts raw byte streams from PIO/DMA ring buffers into validated LDCN packet structures. It operates on CPU Core 0 with minimal overhead, feeding parsed packets to Core 1 for USB transmission.

### Design Goals

1. **Zero-copy parsing**: Work directly from ring buffers
2. **Streaming operation**: Process bytes as they arrive
3. **Graceful degradation**: Log malformed packets, continue capturing
4. **Automatic baud detection**: Trigger PIO reconfiguration on Set Baud Rate commands
5. **Minimal latency**: Parse within 10-50µs per packet

---

## LDCN Packet Structure

### Command Packet (Host → Device)

```
┌────────┬─────────┬─────────┬──────────────┬──────────┐
│ Header │ Address │ Command │  Data Bytes  │ Checksum │
│  0xAA  │  1 byte │ 1 byte  │   0-15 bytes │  1 byte  │
└────────┴─────────┴─────────┴──────────────┴──────────┘
         └──────────────── Included in checksum ────────┘

Min length: 4 bytes (header + addr + cmd + cksum)
Max length: 19 bytes (header + addr + cmd + 15 data + cksum)
```

**Command Byte Format:**
```
Bits 7-4: Data byte count (0-15)
Bits 3-0: Command value (0-15)

Example: 0x24 = 0010 0100
         Upper nibble (2) = 2 data bytes follow
         Lower nibble (4) = Command 0x4 (Set PWM)
```

**Checksum Calculation:**
```
checksum = (address + command + data[0] + data[1] + ... + data[n]) & 0xFF

Example packet: 0xAA 0x01 0x12 0x0F 0x22
  Address:  0x01
  Command:  0x12 (upper=1 data byte, lower=2=Define Status)
  Data[0]:  0x0F
  Checksum: (0x01 + 0x12 + 0x0F) & 0xFF = 0x22 ✓
```

### Status Packet (Device → Host)

```
┌────────┬───────────────┬──────────┐
│ Status │ Optional Data │ Checksum │
│ 1 byte │   0-N bytes   │  1 byte  │
└────────┴───────────────┴──────────┘
└────── Included in checksum ──────┘

Length varies based on Define Status configuration
Min: 2 bytes (status + checksum)
Max: ~50 bytes (all status items enabled)
```

**Status Byte Format:**
```
Bit 0: (undefined for LS-773 I/O nodes)
Bit 1: Checksum error on last received command
Bit 2-7: (undefined or device-specific)
```

---

## Parser State Machine

### State Diagram

```
                    ┌──────────┐
                    │   IDLE   │◄──────────────┐
                    └────┬─────┘               │
                         │                     │
                    RX: 0xAA                   │
                         │                     │
                         ▼                     │
                    ┌──────────┐               │
                    │  HEADER  │               │
                    └────┬─────┘               │
                         │                     │
                    RX: address                │
                         │                     │
                         ▼                     │
                    ┌──────────┐               │
                    │ ADDRESS  │               │
                    └────┬─────┘               │
                         │                     │
                    RX: command                │
                         │                     │
                         ▼                     │
                    ┌──────────┐               │
                    │ COMMAND  │               │
                    └────┬─────┘               │
                         │                     │
         Extract data count (N)                │
                         │                     │
                         ▼                     │
                    ┌──────────┐               │
              ┌────►│   DATA   │──────┐        │
              │     └────┬─────┘      │        │
              │          │            │        │
         N > 0│     RX: data[i]  N == 0│       │
              │          │            │        │
              │     i++, N--          │        │
              │          │            │        │
              └──────────┘            ▼        │
                              ┌──────────┐     │
                              │ CHECKSUM │     │
                              └────┬─────┘     │
                                   │           │
                          RX: checksum         │
                                   │           │
                              Validate         │
                                   │           │
                                   ▼           │
                              ┌──────────┐     │
                              │ COMPLETE │─────┘
                              └──────────┘
                               (emit packet)
```

### State Transitions

| Current State | Event | Next State | Action |
|---------------|-------|------------|--------|
| IDLE | RX: 0xAA | HEADER | Store timestamp |
| IDLE | RX: other | IDLE | Ignore |
| HEADER | RX: any | ADDRESS | Store address |
| ADDRESS | RX: any | COMMAND | Store command, extract data_count |
| COMMAND | data_count > 0 | DATA | Store data[0], decrement count |
| COMMAND | data_count == 0 | CHECKSUM | - |
| DATA | more data | DATA | Store data[i++], decrement count |
| DATA | count == 0 | CHECKSUM | - |
| CHECKSUM | RX: cksum | COMPLETE | Validate checksum, emit packet |
| COMPLETE | - | IDLE | Reset state |

### Timeout Handling

If no byte received for >100ms while in active parse:
- Emit partial packet with `TRUNCATED` flag
- Log error
- Return to IDLE

---

## Data Structures

### Packet Structure

```c
#define MAX_DATA_BYTES 15

typedef enum {
    PKT_FLAG_NONE           = 0x00,
    PKT_FLAG_BAD_CHECKSUM   = 0x01,  // Checksum validation failed
    PKT_FLAG_INVALID_COUNT  = 0x02,  // Data count >15
    PKT_FLAG_TRUNCATED      = 0x04,  // Timeout during parse
    PKT_FLAG_FRAMING_ERROR  = 0x08,  // PIO reported framing error
} packet_flags_t;

typedef struct {
    // Metadata
    uint32_t timestamp_us;     // Time of header byte (from time_us_32())
    uint8_t channel;           // 0 or 1
    uint8_t flags;             // packet_flags_t bitfield
    
    // Packet fields
    uint8_t header;            // Always 0xAA (for validation)
    uint8_t address;           // 0x00-0xFF
    uint8_t command;           // Full command byte
    uint8_t data_count;        // Extracted from command upper nibble
    uint8_t data[MAX_DATA_BYTES];
    uint8_t checksum_received;
    uint8_t checksum_calculated;
    
    // Derived fields
    uint8_t cmd_value;         // Command lower nibble (0-15)
    uint8_t length;            // Total packet length in bytes
} ldcn_packet_t;
```

### Parser Context

```c
typedef enum {
    STATE_IDLE,
    STATE_HEADER,
    STATE_ADDRESS,
    STATE_COMMAND,
    STATE_DATA,
    STATE_CHECKSUM,
    STATE_COMPLETE
} parser_state_t;

typedef struct {
    parser_state_t state;
    ldcn_packet_t current_packet;
    
    uint8_t data_idx;          // Current index in data array
    uint8_t data_remaining;    // Bytes left to read
    uint32_t last_byte_time;   // For timeout detection
    
    // Statistics
    uint32_t packets_parsed;
    uint32_t checksum_errors;
    uint32_t truncated_packets;
    uint32_t invalid_packets;
} packet_parser_t;
```

### Packet Queue (Core 0 → Core 1)

```c
#define PACKET_QUEUE_SIZE 32

typedef struct {
    ldcn_packet_t packets[PACKET_QUEUE_SIZE];
    volatile uint32_t write_idx;  // Updated by Core 0
    volatile uint32_t read_idx;   // Updated by Core 1
    uint32_t overflow_count;      // Incremented when queue full
} packet_queue_t;

packet_queue_t packet_queue;
```

---

## Parser Implementation

### Initialization

```c
void parser_init(packet_parser_t *parser) {
    memset(parser, 0, sizeof(packet_parser_t));
    parser->state = STATE_IDLE;
}
```

### Main Parse Function

```c
void parser_process_byte(packet_parser_t *parser, uint8_t byte, 
                        uint32_t timestamp, uint8_t channel) {
    parser->last_byte_time = timestamp;
    
    switch (parser->state) {
        case STATE_IDLE:
            if (byte == 0xAA) {
                // Start of new packet
                memset(&parser->current_packet, 0, sizeof(ldcn_packet_t));
                parser->current_packet.header = byte;
                parser->current_packet.timestamp_us = timestamp;
                parser->current_packet.channel = channel;
                parser->state = STATE_HEADER;
            }
            // Ignore non-header bytes in IDLE
            break;
            
        case STATE_HEADER:
            parser->current_packet.address = byte;
            parser->state = STATE_ADDRESS;
            break;
            
        case STATE_ADDRESS:
            parser->current_packet.command = byte;
            parser->current_packet.cmd_value = byte & 0x0F;
            parser->current_packet.data_count = (byte >> 4) & 0x0F;
            
            // Validate data count
            if (parser->current_packet.data_count > MAX_DATA_BYTES) {
                parser->current_packet.flags |= PKT_FLAG_INVALID_COUNT;
                parser->state = STATE_IDLE;  // Abort parse
                parser->invalid_packets++;
                break;
            }
            
            parser->data_idx = 0;
            parser->data_remaining = parser->current_packet.data_count;
            
            if (parser->data_remaining > 0) {
                parser->state = STATE_DATA;
            } else {
                parser->state = STATE_CHECKSUM;
            }
            break;
            
        case STATE_DATA:
            parser->current_packet.data[parser->data_idx++] = byte;
            parser->data_remaining--;
            
            if (parser->data_remaining == 0) {
                parser->state = STATE_CHECKSUM;
            }
            break;
            
        case STATE_CHECKSUM:
            parser->current_packet.checksum_received = byte;
            
            // Calculate expected checksum
            uint8_t sum = parser->current_packet.address;
            sum += parser->current_packet.command;
            for (int i = 0; i < parser->current_packet.data_count; i++) {
                sum += parser->current_packet.data[i];
            }
            parser->current_packet.checksum_calculated = sum;
            
            // Validate
            if (sum != byte) {
                parser->current_packet.flags |= PKT_FLAG_BAD_CHECKSUM;
                parser->checksum_errors++;
            }
            
            // Calculate total length
            parser->current_packet.length = 4 + parser->current_packet.data_count;
            
            parser->state = STATE_COMPLETE;
            // Fall through to complete
            
        case STATE_COMPLETE:
            // Emit packet to queue
            emit_packet(&parser->current_packet);
            parser->packets_parsed++;
            parser->state = STATE_IDLE;
            break;
    }
}
```

### Timeout Check

```c
void parser_check_timeout(packet_parser_t *parser, uint32_t current_time) {
    if (parser->state == STATE_IDLE) {
        return;  // Nothing in progress
    }
    
    uint32_t elapsed = current_time - parser->last_byte_time;
    
    if (elapsed > 100000) {  // 100ms timeout
        // Mark as truncated
        parser->current_packet.flags |= PKT_FLAG_TRUNCATED;
        parser->current_packet.length = 0;  // Unknown
        
        // Emit partial packet
        emit_packet(&parser->current_packet);
        parser->truncated_packets++;
        
        // Reset to idle
        parser->state = STATE_IDLE;
    }
}
```

### Packet Queue Operations

```c
void emit_packet(ldcn_packet_t *packet) {
    uint32_t next_write = (packet_queue.write_idx + 1) % PACKET_QUEUE_SIZE;
    
    if (next_write == packet_queue.read_idx) {
        // Queue full - drop packet
        packet_queue.overflow_count++;
        return;
    }
    
    // Copy packet to queue
    memcpy(&packet_queue.packets[packet_queue.write_idx], 
           packet, sizeof(ldcn_packet_t));
    
    // Advance write pointer (atomic for Core 1)
    packet_queue.write_idx = next_write;
}

bool dequeue_packet(ldcn_packet_t *out_packet) {
    if (packet_queue.read_idx == packet_queue.write_idx) {
        return false;  // Queue empty
    }
    
    // Copy packet from queue
    memcpy(out_packet, &packet_queue.packets[packet_queue.read_idx],
           sizeof(ldcn_packet_t));
    
    // Advance read pointer
    packet_queue.read_idx = (packet_queue.read_idx + 1) % PACKET_QUEUE_SIZE;
    return true;
}
```

---

## Baud Rate Detection

### Set Baud Rate Command Detection

**Command format:**
```
0xAA 0xFF 0x1A 0x0A 0x23
│    │    │    │    └─ Checksum (0xFF + 0x1A + 0x0A = 0x23)
│    │    │    └────── BRD value (0x0A = 115200 baud)
│    │    └─────────── Command 0x1A (upper=1 data byte, lower=0xA=Set Baud)
│    └──────────────── Address 0xFF (group, all devices)
└───────────────────── Header
```

### Detection Logic

```c
bool is_set_baud_rate_command(ldcn_packet_t *packet) {
    // Check command value (lower nibble)
    if (packet->cmd_value != 0x0A) {
        return false;
    }
    
    // Check data count (should be 1)
    if (packet->data_count != 1) {
        return false;
    }
    
    // Check address is group (typically 0xFF, but any 0x80-0xFF valid)
    if (packet->address < 0x80) {
        return false;  // Individual address, not broadcast
    }
    
    return true;
}

uint8_t extract_brd_value(ldcn_packet_t *packet) {
    return packet->data[0];
}
```

### Triggering Baud Rate Switch

```c
void handle_baud_rate_change(ldcn_packet_t *packet) {
    if (!is_set_baud_rate_command(packet)) {
        return;
    }
    
    // Validate checksum first
    if (packet->flags & PKT_FLAG_BAD_CHECKSUM) {
        log_warning("Ignoring Set Baud Rate with bad checksum");
        return;
    }
    
    uint8_t brd = extract_brd_value(packet);
    const baud_config_t *cfg = lookup_baud_config(brd);
    
    if (!cfg) {
        log_error("Unknown BRD value: 0x%02X", brd);
        return;
    }
    
    log_info("Baud rate change: %d → %d", current_baud, cfg->actual_baud);
    
    // Wait for network silence (safety margin)
    sleep_ms(5);
    
    // Switch both channels
    switch_baud_rate_all_channels(brd);
    
    // Update global state
    current_baud = cfg->actual_baud;
}
```

### Integration into Parser

```c
void parser_process_byte(packet_parser_t *parser, uint8_t byte, 
                        uint32_t timestamp, uint8_t channel) {
    // ... existing parsing logic ...
    
    if (parser->state == STATE_COMPLETE) {
        // Check for baud rate change BEFORE emitting
        if (is_set_baud_rate_command(&parser->current_packet)) {
            handle_baud_rate_change(&parser->current_packet);
        }
        
        // Emit packet to queue
        emit_packet(&parser->current_packet);
        parser->packets_parsed++;
        parser->state = STATE_IDLE;
    }
}
```

---

## Error Handling

### Error Categories

1. **Checksum Errors**
   - Calculated checksum ≠ received checksum
   - Indicates noise, baud mismatch, or transmission error
   - Action: Flag packet, emit to capture (Wireshark shows error)

2. **Invalid Data Count**
   - Command byte specifies >15 data bytes
   - Indicates corrupted command byte or protocol violation
   - Action: Abort parse, return to IDLE, log error

3. **Truncated Packets**
   - Timeout during active parse
   - Indicates device stopped mid-packet (rare)
   - Action: Emit partial packet with flag, log error

4. **Framing Errors**
   - PIO IRQ 4 triggered (stop bit LOW)
   - Indicates baud mismatch or severe noise
   - Action: Flag next packet, log error

5. **Queue Overflows**
   - Packet queue full (Core 1 can't keep up)
   - Indicates USB bottleneck or excessive traffic
   - Action: Drop packet, increment counter, log warning

### Error Logging

```c
typedef struct {
    uint32_t timestamp;
    uint8_t channel;
    uint8_t error_type;  // 0=checksum, 1=invalid_count, 2=truncated, ...
    uint8_t context[16]; // Relevant bytes for debugging
} error_log_entry_t;

#define ERROR_LOG_SIZE 64
error_log_entry_t error_log[ERROR_LOG_SIZE];
uint32_t error_log_idx = 0;

void log_parse_error(packet_parser_t *parser, uint8_t error_type) {
    error_log_entry_t *entry = &error_log[error_log_idx % ERROR_LOG_SIZE];
    
    entry->timestamp = parser->current_packet.timestamp_us;
    entry->channel = parser->current_packet.channel;
    entry->error_type = error_type;
    
    // Copy relevant context
    memcpy(entry->context, &parser->current_packet, sizeof(ldcn_packet_t));
    
    error_log_idx++;
}
```

### Graceful Degradation

**Philosophy:** Never stop capturing due to errors

```c
// Even with errors, emit packets to PCAP
if (packet->flags != PKT_FLAG_NONE) {
    // Still emit - Wireshark will show error flags
    emit_packet(packet);
    
    // But also log for diagnostics
    log_parse_error(parser, get_error_type(packet->flags));
}
```

---

## Performance Analysis

### Per-Byte Processing Cost

**Estimated CPU cycles:**
```c
State IDLE:       5-10 cycles (comparison only)
State HEADER:     10-20 cycles (store, transition)
State ADDRESS:    10-20 cycles (store, transition)
State COMMAND:    20-40 cycles (extract nibbles, validate)
State DATA:       10-20 cycles (store, decrement, check)
State CHECKSUM:   30-60 cycles (calculate, validate, emit)

Average per byte: ~20 cycles
At 125 MHz: ~160 ns per byte
```

**At maximum throughput (1.25 Mbps):**
- Bytes per second: 156,250
- CPU time: 156,250 × 160ns = 25ms/sec = 2.5% CPU

### Per-Packet Processing Cost

**Typical LDCN packet (7 bytes):**
```
Parse time: 7 bytes × 20 cycles = 140 cycles = 1.1µs
Emit time: memcpy + queue management = ~200 cycles = 1.6µs
Total: ~2.7µs per packet
```

**At 1000 packets/sec:**
- CPU time: 1000 × 2.7µs = 2.7ms/sec = 0.27% CPU

### Memory Usage

```c
Per-channel parser:     ~100 bytes
Packet structure:       ~32 bytes
Packet queue (32 deep): 32 × 32 = 1024 bytes
Error log (64 entries): 64 × 32 = 2048 bytes

Total: ~3.5 KB (< 1% of 264 KB SRAM)
```

---

## Testing Strategy

### Unit Tests

```c
void test_valid_packet() {
    packet_parser_t parser;
    parser_init(&parser);
    
    // Simulate NoOp packet: 0xAA 0x01 0x0E 0x0F
    parser_process_byte(&parser, 0xAA, 1000, 0);
    assert(parser.state == STATE_HEADER);
    
    parser_process_byte(&parser, 0x01, 1100, 0);
    assert(parser.state == STATE_ADDRESS);
    
    parser_process_byte(&parser, 0x0E, 1200, 0);
    assert(parser.state == STATE_CHECKSUM);
    assert(parser.current_packet.data_count == 0);
    
    parser_process_byte(&parser, 0x0F, 1300, 0);
    assert(parser.state == STATE_IDLE);
    assert(parser.packets_parsed == 1);
    assert(parser.current_packet.flags == PKT_FLAG_NONE);
}

void test_checksum_error() {
    packet_parser_t parser;
    parser_init(&parser);
    
    // Packet with wrong checksum
    parser_process_byte(&parser, 0xAA, 1000, 0);
    parser_process_byte(&parser, 0x01, 1100, 0);
    parser_process_byte(&parser, 0x0E, 1200, 0);
    parser_process_byte(&parser, 0xFF, 1300, 0);  // Wrong checksum
    
    assert(parser.current_packet.flags & PKT_FLAG_BAD_CHECKSUM);
    assert(parser.checksum_errors == 1);
}

void test_baud_rate_detection() {
    packet_parser_t parser;
    parser_init(&parser);
    
    // Set Baud Rate packet: 0xAA 0xFF 0x1A 0x0A 0x23
    parser_process_byte(&parser, 0xAA, 1000, 0);
    parser_process_byte(&parser, 0xFF, 1100, 0);
    parser_process_byte(&parser, 0x1A, 1200, 0);
    parser_process_byte(&parser, 0x0A, 1300, 0);
    parser_process_byte(&parser, 0x23, 1400, 0);
    
    assert(is_set_baud_rate_command(&parser.current_packet));
    assert(extract_brd_value(&parser.current_packet) == 0x0A);
}
```

### Integration Tests

See `03_CONNECTION_VERIFICATION.md` for hardware integration testing.

---

## Command Reference

### Common LDCN Commands

| Cmd | Name | Data Bytes | Description |
|-----|------|------------|-------------|
| 0x1 | Set Address | 2 | Set individual and group address |
| 0x2 | Define Status | 1 | Define status packet format |
| 0x3 | Read Status | 1 | Request status (non-persistent) |
| 0x4 | Set PWM | 2 | Set PWM outputs (I/O node) |
| 0x5 | Synch Output | 0 | Trigger synchronous output |
| 0x6 | Set Outputs | 2 | Set output bits immediately |
| 0x7 | Set Synch Output | 4 | Buffer outputs for sync |
| 0x8 | Set Timer Mode | 1 | Configure counter/timer |
| 0xA | Set Baud Rate | 1 | Change baud rate (group cmd) |
| 0xC | Synch Input | 0 | Capture inputs synchronously |
| 0xE | NoOp | 0 | Request status (no action) |
| 0xF | Hard Reset | 0 | Reset to power-up state |

---

## Future Enhancements

1. **Command interpretation**: Decode data bytes per command type
2. **Address tracking**: Maintain table of discovered devices
3. **Timing analysis**: Measure response times automatically
4. **Anomaly detection**: Flag unusual patterns (e.g., rapid resets)

---

## Revision History

| Version | Date | Author | Changes |
|---------|------|--------|---------|
| 1.0 | 2024-12-19 | Initial | Packet parser architecture |
