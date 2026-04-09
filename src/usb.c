#include "usb.h"
#include "tusb.h"
#include "pico/time.h"

#include <string.h>

// ── PCAP structures ───────────────────────────────────────────────────────────

// Standard PCAP global header (24 bytes)
typedef struct __attribute__((packed)) {
    uint32_t magic;         // 0xa1b2c3d4 — native byte order, µs timestamps
    uint16_t ver_major;     // 2
    uint16_t ver_minor;     // 4
    int32_t  thiszone;      // 0 (UTC)
    uint32_t sigfigs;       // 0
    uint32_t snaplen;       // 65535
    uint32_t network;       // 147 = DLT_USER0 (custom protocol)
} pcap_global_hdr_t;

// Standard PCAP per-packet header (16 bytes)
typedef struct __attribute__((packed)) {
    uint32_t ts_sec;
    uint32_t ts_usec;
    uint32_t incl_len;
    uint32_t orig_len;
} pcap_pkt_hdr_t;

static const pcap_global_hdr_t global_hdr = {
    .magic     = 0xa1b2c3d4u,
    .ver_major = 2,
    .ver_minor = 4,
    .thiszone  = 0,
    .sigfigs   = 0,
    .snaplen   = 65535,
    .network   = 147,
};

// ── Timestamp helper ──────────────────────────────────────────────────────────
//
// time_us_32() wraps every ~71 min. We track wraps to produce a monotonic
// 64-bit value, then split into seconds + microseconds for PCAP.
// Timestamps are relative to device power-on (epoch offset = 0).

static uint32_t last_us32 = 0;
static uint32_t wrap_count = 0;

static void ts_to_pcap(uint32_t ts_us, uint32_t *sec_out, uint32_t *usec_out) {
    if (ts_us < last_us32)
        wrap_count++;
    last_us32 = ts_us;

    uint64_t total = ((uint64_t)wrap_count << 32) | ts_us;
    *sec_out  = (uint32_t)(total / 1000000u);
    *usec_out = (uint32_t)(total % 1000000u);
}

// ── PCAP record emission ──────────────────────────────────────────────────────

// Buffer large enough for header + metadata + max LDCN packet
// 16 (pcap hdr) + 2 (channel+flags) + 19 (max LDCN) = 37 bytes
#define PCAP_BUF_SIZE 64

static void send_bytes(const uint8_t *data, uint32_t len) {
    // Spin until CDC is available; packets are dropped only if queue overflows
    while (len > 0) {
        uint32_t sent = tud_cdc_write(data, len);
        data += sent;
        len  -= sent;
        if (len > 0)
            tud_task();  // Let TinyUSB process to make room
    }
}

static void emit_pcap_record(const ldcn_packet_t *pkt) {
    uint8_t  buf[PCAP_BUF_SIZE];
    uint32_t offset = 0;

    // PicoShark payload = channel(1) + flags(1) + LDCN wire bytes
    // LDCN wire bytes = 0xAA + address + command + data[0..n] + checksum
    uint32_t ldcn_len = 4u + pkt->data_count;  // header+addr+cmd+data+cksum
    uint32_t payload  = 2u + ldcn_len;

    // PCAP packet header — avoid unaligned pointer warnings by staging through locals
    uint32_t ts_sec, ts_usec;
    ts_to_pcap(pkt->timestamp_us, &ts_sec, &ts_usec);
    pcap_pkt_hdr_t hdr_val = { ts_sec, ts_usec, payload, payload };
    memcpy(buf + offset, &hdr_val, sizeof(hdr_val));
    offset += sizeof(pcap_pkt_hdr_t);

    // PicoShark metadata
    buf[offset++] = pkt->channel;
    buf[offset++] = pkt->flags;

    // LDCN packet bytes
    buf[offset++] = 0xAA;               // Header
    buf[offset++] = pkt->address;
    buf[offset++] = pkt->command;
    for (int i = 0; i < pkt->data_count; i++)
        buf[offset++] = pkt->data[i];
    buf[offset++] = pkt->checksum_rx;

    send_bytes(buf, offset);
}

// ── Flush policy ──────────────────────────────────────────────────────────────
//
// Flushing after every packet maximises Wireshark responsiveness but increases
// USB overhead. Flush every 8 packets or every 20 ms, whichever comes first.

static uint32_t since_flush = 0;
static uint32_t last_flush_ms = 0;

static void maybe_flush(void) {
    since_flush++;
    uint32_t now_ms = to_ms_since_boot(get_absolute_time());
    if (since_flush >= 8 || (now_ms - last_flush_ms) >= 20) {
        tud_cdc_write_flush();
        since_flush   = 0;
        last_flush_ms = now_ms;
    }
}

// ── USB lifecycle ─────────────────────────────────────────────────────────────

static bool header_sent = false;

static void send_global_header(void) {
    send_bytes((const uint8_t *)&global_hdr, sizeof(global_hdr));
    tud_cdc_write_flush();
    header_sent = true;
}

void usb_init(void) {
    tusb_init();
}

void usb_task(void) {
    tud_task();

    if (!tud_cdc_connected()) {
        header_sent = false;
        return;
    }

    if (!header_sent)
        send_global_header();

    ldcn_packet_t pkt;
    while (packet_dequeue(&pkt)) {
        if (tud_cdc_write_available() >= PCAP_BUF_SIZE)
            emit_pcap_record(&pkt);
        // else: drop — CDC TX buffer full, host not reading fast enough
        maybe_flush();
    }
}

// Invoked by TinyUSB when DTR changes (terminal opens/closes)
void tud_cdc_line_state_cb(uint8_t itf, bool dtr, bool rts) {
    (void)itf; (void)rts;
    if (dtr) {
        // Re-send global header when a new client connects
        header_sent = false;
    }
}

// Drain any bytes the host sends (we don't use them yet)
void tud_cdc_rx_cb(uint8_t itf) {
    (void)itf;
    uint8_t discard[64];
    while (tud_cdc_available())
        tud_cdc_read(discard, sizeof(discard));
}

void core1_main(void) {
    usb_init();
    while (true)
        usb_task();
}
