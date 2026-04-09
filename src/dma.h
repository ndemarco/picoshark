#pragma once

#include <stdint.h>
#include <stdbool.h>
#include "hardware/dma.h"
#include "hardware/pio.h"

// Ring buffer size — must be a power of 2
#define RINGBUF_SIZE 4096
#define RINGBUF_MASK (RINGBUF_SIZE - 1)

typedef struct {
    uint8_t  data[RINGBUF_SIZE];
    uint32_t read_pos;      // Updated by CPU (Core 0 parser)
    uint      dma_chan;     // Associated DMA channel — used to read write pos
    uint32_t overflow_count;
} ringbuf_t;

extern ringbuf_t ringbuf_ch0;
extern ringbuf_t ringbuf_ch1;

// Initialise a DMA channel to continuously fill a ring buffer from a PIO RX FIFO.
void dma_rx_init(ringbuf_t *rb, uint dma_chan, PIO pio, uint sm);

// Number of bytes available to read (based on live DMA write address).
uint32_t ringbuf_available(const ringbuf_t *rb);

// Read one byte; caller must ensure available > 0.
uint8_t ringbuf_read_byte(ringbuf_t *rb);
