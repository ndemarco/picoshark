#pragma once

#include <stdint.h>
#include <stdbool.h>

// ── LDCN packet limits ────────────────────────────────────────────────────────

#define LDCN_MAX_DATA_BYTES  15   // Upper nibble of command byte max value
#define LDCN_HEADER_BYTE     0xAAu

// Packet flags (mirrored into PCAP payload so Wireshark can display them)
typedef enum {
    PKT_FLAG_NONE          = 0x00,
    PKT_FLAG_BAD_CHECKSUM  = 0x01,
    PKT_FLAG_INVALID_COUNT = 0x02,
    PKT_FLAG_TRUNCATED     = 0x04,
    PKT_FLAG_FRAMING_ERROR = 0x08,
} packet_flags_t;

// ── Parsed packet ─────────────────────────────────────────────────────────────

typedef struct {
    uint32_t timestamp_us;              // From time_us_32() at header byte
    uint8_t  channel;                   // 0 = CH0, 1 = CH1
    uint8_t  flags;                     // packet_flags_t bitfield

    uint8_t  address;
    uint8_t  command;                   // Full command byte
    uint8_t  cmd_value;                 // command & 0x0F
    uint8_t  data_count;                // command >> 4
    uint8_t  data[LDCN_MAX_DATA_BYTES];
    uint8_t  checksum_rx;
    uint8_t  checksum_calc;
    uint8_t  length;                    // Total wire bytes (header..checksum)
} ldcn_packet_t;

// ── Parser FSM ────────────────────────────────────────────────────────────────

typedef enum {
    STATE_IDLE,
    STATE_ADDRESS,
    STATE_COMMAND,
    STATE_DATA,
    STATE_CHECKSUM,
} parser_state_t;

typedef struct {
    parser_state_t  state;
    ldcn_packet_t   pkt;
    uint8_t         data_idx;
    uint8_t         data_remaining;
    uint32_t        last_byte_us;   // For timeout detection

    // Statistics
    uint32_t packets_ok;
    uint32_t checksum_errors;
    uint32_t truncated;
    uint32_t invalid;
} packet_parser_t;

// ── Inter-core packet queue (Core 0 produces, Core 1 consumes) ────────────────

#define PACKET_QUEUE_SIZE  32   // Must be power of 2

typedef struct {
    ldcn_packet_t   packets[PACKET_QUEUE_SIZE];
    volatile uint32_t write_idx;    // Core 0 writer
    volatile uint32_t read_idx;     // Core 1 reader
    uint32_t overflow_count;
} packet_queue_t;

extern packet_queue_t packet_queue;

// ── LDCN baud rate table ──────────────────────────────────────────────────────

typedef struct {
    uint8_t  brd;           // BRD byte sent in Set Baud Rate command
    uint32_t baud;
} baud_entry_t;

extern const baud_entry_t baud_table[];
extern const int          baud_table_size;

// Current network baud rate (updated on Set Baud Rate detection)
extern volatile uint32_t current_baud;

// ── API ───────────────────────────────────────────────────────────────────────

void parser_init(packet_parser_t *p);

// Feed one byte into the parser. channel: 0 or 1.
// framing_error: set true when the PIO reported a framing error on this byte.
void parser_process_byte(packet_parser_t *p, uint8_t byte,
                         uint32_t timestamp_us, uint8_t channel,
                         bool framing_error);

// Call periodically to detect inter-packet timeout (100 ms).
void parser_check_timeout(packet_parser_t *p, uint32_t now_us);

// Dequeue one completed packet into *out. Returns false if queue empty.
bool packet_dequeue(ldcn_packet_t *out);
