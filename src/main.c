#include "pico/stdlib.h"
#include "pico/multicore.h"
#include "hardware/pio.h"
#include "hardware/irq.h"
#include "hardware/timer.h"

#include "uart_rx.pio.h"
#include "dma.h"
#include "parser.h"
#include "usb.h"

// ── GPIO pin assignments (Waveshare Pico-2CH-RS485) ───────────────────────────
//
//   CH0 RX: GP0    CH0 TX: GP1  (sniffer only — TX pin unused)
//   CH1 RX: GP4    CH1 TX: GP5  (sniffer only — TX pin unused)

#define CH0_RX_PIN  0
#define CH1_RX_PIN  4

// ── DMA channel assignments ───────────────────────────────────────────────────

#define DMA_CH0  0
#define DMA_CH1  1

// ── PIO state machine assignments ─────────────────────────────────────────────

#define PIO_INST   pio0
#define SM_CH0     0
#define SM_CH1     1

// ── Framing error flags (set in IRQ handler, read by parser loop) ─────────────

static volatile bool framing_error_ch0 = false;
static volatile bool framing_error_ch1 = false;

// PIO IRQ handler — irq 0 rel SM0 → PIO IRQ0; irq 0 rel SM1 → PIO IRQ1
static void pio_irq_handler(void) {
    if (pio_interrupt_get(PIO_INST, 0)) {
        pio_interrupt_clear(PIO_INST, 0);
        framing_error_ch0 = true;
    }
    if (pio_interrupt_get(PIO_INST, 1)) {
        pio_interrupt_clear(PIO_INST, 1);
        framing_error_ch1 = true;
    }
}

// ── Baud rate switching ───────────────────────────────────────────────────────

static uint32_t last_baud = 0;

static void check_baud_switch(void) {
    uint32_t baud = current_baud;
    if (baud == last_baud)
        return;
    last_baud = baud;
    // Switch both channels simultaneously
    uart_rx_set_baud(PIO_INST, SM_CH0, baud);
    uart_rx_set_baud(PIO_INST, SM_CH1, baud);
}

// ── Core 0: parser loop ───────────────────────────────────────────────────────

static packet_parser_t parser_ch0;
static packet_parser_t parser_ch1;

static void parser_loop(void) {
    uint32_t now;

    while (true) {
        now = time_us_32();

        // Drain CH0 ring buffer
        uint32_t avail0 = ringbuf_available(&ringbuf_ch0);
        for (uint32_t i = 0; i < avail0; i++) {
            bool fe = framing_error_ch0;
            framing_error_ch0 = false;
            uint8_t b = ringbuf_read_byte(&ringbuf_ch0);
            parser_process_byte(&parser_ch0, b, time_us_32(), 0, fe);
        }

        // Drain CH1 ring buffer
        uint32_t avail1 = ringbuf_available(&ringbuf_ch1);
        for (uint32_t i = 0; i < avail1; i++) {
            bool fe = framing_error_ch1;
            framing_error_ch1 = false;
            uint8_t b = ringbuf_read_byte(&ringbuf_ch1);
            parser_process_byte(&parser_ch1, b, time_us_32(), 1, fe);
        }

        // Timeout detection
        parser_check_timeout(&parser_ch0, now);
        parser_check_timeout(&parser_ch1, now);

        // Apply any baud rate change detected by parser
        check_baud_switch();
    }
}

// ── Entry point ───────────────────────────────────────────────────────────────

int main(void) {
    // Clocks & stdlib (sets system clock to 125 MHz)
    stdio_init_all();

    // Launch Core 1 — runs TinyUSB + PCAP output
    multicore_launch_core1(core1_main);

    // Load PIO UART RX program (shared between both state machines)
    uint offset = pio_add_program(PIO_INST, &uart_rx_program);

    // Initialise CH0 and CH1 state machines
    uart_rx_program_init(PIO_INST, SM_CH0, offset, CH0_RX_PIN, 19200);
    uart_rx_program_init(PIO_INST, SM_CH1, offset, CH1_RX_PIN, 19200);

    // Enable PIO IRQ for framing error detection
    // irq 0 rel on SM0 → PIO IRQ0, on SM1 → PIO IRQ1
    pio_set_irq0_source_enabled(PIO_INST, pis_interrupt0, true);
    pio_set_irq0_source_enabled(PIO_INST, pis_interrupt1, true);
    irq_set_exclusive_handler(PIO0_IRQ_0, pio_irq_handler);
    irq_set_enabled(PIO0_IRQ_0, true);

    // Initialise DMA ring buffers (start immediately)
    dma_rx_init(&ringbuf_ch0, DMA_CH0, PIO_INST, SM_CH0);
    dma_rx_init(&ringbuf_ch1, DMA_CH1, PIO_INST, SM_CH1);

    // Initialise parsers
    parser_init(&parser_ch0);
    parser_init(&parser_ch1);

    last_baud = 19200;

    // Core 0 runs the parser loop forever
    parser_loop();
}
