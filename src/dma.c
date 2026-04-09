#include "dma.h"
#include "hardware/dma.h"
#include "hardware/pio.h"

ringbuf_t ringbuf_ch0;
ringbuf_t ringbuf_ch1;

void dma_rx_init(ringbuf_t *rb, uint dma_chan, PIO pio, uint sm) {
    rb->read_pos      = 0;
    rb->dma_chan      = dma_chan;
    rb->overflow_count = 0;

    dma_channel_config c = dma_channel_get_default_config(dma_chan);

    // Transfer 1 byte per trigger
    channel_config_set_transfer_data_size(&c, DMA_SIZE_8);

    // Source: PIO RX FIFO (fixed address)
    channel_config_set_read_increment(&c, false);

    // Destination: ring buffer (incrementing, wraps at RINGBUF_SIZE)
    channel_config_set_write_increment(&c, true);
    // RING_SIZE = log2(RINGBUF_SIZE) = 12 for 4096; ring on write side
    channel_config_set_ring(&c, true, 12);

    // Pace transfers via PIO RX FIFO not-empty signal
    channel_config_set_dreq(&c, pio_get_dreq(pio, sm, false));

    dma_channel_configure(
        dma_chan,
        &c,
        rb->data,           // Write address (start of ring)
        &pio->rxf[sm],      // Read address (PIO RX FIFO)
        UINT32_MAX,         // Run essentially forever
        true                // Start immediately
    );
}

uint32_t ringbuf_available(const ringbuf_t *rb) {
    // Read the live DMA write address from hardware
    uint32_t write_addr = dma_hw->ch[rb->dma_chan].write_addr;
    uint32_t write_pos  = (write_addr - (uint32_t)rb->data) & RINGBUF_MASK;
    uint32_t read_pos   = rb->read_pos;

    if (write_pos >= read_pos)
        return write_pos - read_pos;
    else
        return RINGBUF_SIZE - read_pos + write_pos;
}

uint8_t ringbuf_read_byte(ringbuf_t *rb) {
    uint8_t byte = rb->data[rb->read_pos];
    rb->read_pos = (rb->read_pos + 1) & RINGBUF_MASK;
    return byte;
}
