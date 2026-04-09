#pragma once

#include "parser.h"

// Initialise TinyUSB and send the PCAP global header.
// Must be called from Core 1 before the USB task loop.
void usb_init(void);

// Main USB task — call in a tight loop on Core 1.
// Drains the inter-core packet queue and writes PCAP records to the CDC port.
void usb_task(void);

// Entry point for Core 1.
void core1_main(void);
