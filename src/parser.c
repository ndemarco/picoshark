#include "parser.h"
#include "hardware/pio.h"
#include "uart_rx.pio.h"

#include <string.h>

// ── Globals ───────────────────────────────────────────────────────────────────

packet_queue_t packet_queue;
volatile uint32_t current_baud = 19200;

const baud_entry_t baud_table[] = {
    {0x81,    9600},
    {0x3F,   19200},   // Default
    {0x14,   57600},
    {0x0A,  115200},
    {0x27,  125000},
    {0x0F,  312500},
    {0x07,  625000},
    {0x03, 1250000},
};
const int baud_table_size = sizeof(baud_table) / sizeof(baud_table[0]);

// ── Helpers ───────────────────────────────────────────────────────────────────

static void reset_parser(packet_parser_t *p) {
    p->state          = STATE_IDLE;
    p->data_idx       = 0;
    p->data_remaining = 0;
}

static void emit_packet(ldcn_packet_t *pkt) {
    uint32_t next = (packet_queue.write_idx + 1) & (PACKET_QUEUE_SIZE - 1);
    if (next == packet_queue.read_idx) {
        packet_queue.overflow_count++;
        return;
    }
    memcpy(&packet_queue.packets[packet_queue.write_idx], pkt, sizeof(*pkt));
    __sync_synchronize();  // Ensure packet data visible to Core 1 before index update
    packet_queue.write_idx = next;
}

static bool is_set_baud_rate(const ldcn_packet_t *pkt) {
    return (pkt->cmd_value == 0x0A) &&
           (pkt->data_count == 1) &&
           (pkt->address >= 0x80);      // Group/broadcast address
}

static void handle_baud_change(const ldcn_packet_t *pkt) {
    if (pkt->flags & PKT_FLAG_BAD_CHECKSUM)
        return;

    uint8_t brd = pkt->data[0];
    for (int i = 0; i < baud_table_size; i++) {
        if (baud_table[i].brd == brd) {
            current_baud = baud_table[i].baud;
            // PIO baud rate switch happens in main.c which watches current_baud
            return;
        }
    }
    // Unknown BRD — ignore; bus will re-sync on next start bit
}

// ── Public API ────────────────────────────────────────────────────────────────

void parser_init(packet_parser_t *p) {
    memset(p, 0, sizeof(*p));
    p->state = STATE_IDLE;
}

void parser_process_byte(packet_parser_t *p, uint8_t byte,
                         uint32_t timestamp_us, uint8_t channel,
                         bool framing_error) {
    p->last_byte_us = timestamp_us;

    // Framing errors get attached to the next emitted packet
    if (framing_error)
        p->pkt.flags |= PKT_FLAG_FRAMING_ERROR;

    switch (p->state) {

    case STATE_IDLE:
        if (byte != LDCN_HEADER_BYTE)
            break;
        memset(&p->pkt, 0, sizeof(p->pkt));
        p->pkt.timestamp_us = timestamp_us;
        p->pkt.channel      = channel;
        p->state            = STATE_ADDRESS;
        break;

    case STATE_ADDRESS:
        p->pkt.address = byte;
        p->state       = STATE_COMMAND;
        break;

    case STATE_COMMAND: {
        p->pkt.command    = byte;
        p->pkt.cmd_value  = byte & 0x0Fu;
        p->pkt.data_count = (byte >> 4) & 0x0Fu;

        if (p->pkt.data_count > LDCN_MAX_DATA_BYTES) {
            p->pkt.flags |= PKT_FLAG_INVALID_COUNT;
            p->invalid++;
            reset_parser(p);
            break;
        }

        p->data_idx       = 0;
        p->data_remaining = p->pkt.data_count;
        p->state = (p->data_remaining > 0) ? STATE_DATA : STATE_CHECKSUM;
        break;
    }

    case STATE_DATA:
        p->pkt.data[p->data_idx++] = byte;
        if (--p->data_remaining == 0)
            p->state = STATE_CHECKSUM;
        break;

    case STATE_CHECKSUM: {
        p->pkt.checksum_rx = byte;

        uint8_t sum = p->pkt.address + p->pkt.command;
        for (int i = 0; i < p->pkt.data_count; i++)
            sum += p->pkt.data[i];
        p->pkt.checksum_calc = sum;

        if (sum != byte) {
            p->pkt.flags |= PKT_FLAG_BAD_CHECKSUM;
            p->checksum_errors++;
        }

        // header(1) + address(1) + command(1) + data(n) + checksum(1)
        p->pkt.length = 4 + p->pkt.data_count;

        if (is_set_baud_rate(&p->pkt))
            handle_baud_change(&p->pkt);

        emit_packet(&p->pkt);
        p->packets_ok++;
        reset_parser(p);
        break;
    }
    }
}

void parser_check_timeout(packet_parser_t *p, uint32_t now_us) {
    if (p->state == STATE_IDLE)
        return;
    if ((now_us - p->last_byte_us) < 100000u)   // 100 ms
        return;

    p->pkt.flags |= PKT_FLAG_TRUNCATED;
    p->pkt.length = 0;
    emit_packet(&p->pkt);
    p->truncated++;
    reset_parser(p);
}

bool packet_dequeue(ldcn_packet_t *out) {
    if (packet_queue.read_idx == packet_queue.write_idx)
        return false;
    __sync_synchronize();
    memcpy(out, &packet_queue.packets[packet_queue.read_idx], sizeof(*out));
    packet_queue.read_idx = (packet_queue.read_idx + 1) & (PACKET_QUEUE_SIZE - 1);
    return true;
}
