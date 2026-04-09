#pragma once

// TinyUSB configuration for PicoShark
// Single CDC interface: PCAP stream output

#define CFG_TUSB_MCU            OPT_MCU_RP2040
#define CFG_TUSB_RHPORT0_MODE   (OPT_MODE_DEVICE | OPT_MODE_FULL_SPEED)
// CFG_TUSB_OS is set to OPT_OS_NONE by the pico SDK's tinyusb_device target
#define CFG_TUSB_DEBUG          0

#define CFG_TUD_ENABLED         1
#define CFG_TUD_ENDPOINT0_SIZE  64

// Enable CDC only
#define CFG_TUD_CDC             1
#define CFG_TUD_MSC             0
#define CFG_TUD_HID             0
#define CFG_TUD_MIDI            0
#define CFG_TUD_VENDOR          0

// CDC buffers — TX large for PCAP burst writes
#define CFG_TUD_CDC_RX_BUFSIZE  64
#define CFG_TUD_CDC_TX_BUFSIZE  2048
#define CFG_TUD_CDC_EP_BUFSIZE  64
