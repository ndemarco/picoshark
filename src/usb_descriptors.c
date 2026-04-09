#include "tusb.h"

// ── Endpoint numbers ──────────────────────────────────────────────────────────

#define EPNUM_CDC_NOTIF  0x81   // Interrupt IN  — CDC notifications
#define EPNUM_CDC_OUT    0x02   // Bulk OUT       — host→device (unused)
#define EPNUM_CDC_IN     0x82   // Bulk IN        — PCAP stream to host

// ── Interface numbers ─────────────────────────────────────────────────────────

enum {
    ITF_NUM_CDC_CTRL = 0,
    ITF_NUM_CDC_DATA,
    ITF_NUM_TOTAL
};

// ── String descriptor indices ─────────────────────────────────────────────────

enum {
    STRID_LANGID = 0,
    STRID_MANUFACTURER,
    STRID_PRODUCT,
    STRID_SERIAL,
};

// ── Device descriptor ─────────────────────────────────────────────────────────

static const tusb_desc_device_t desc_device = {
    .bLength            = sizeof(tusb_desc_device_t),
    .bDescriptorType    = TUSB_DESC_DEVICE,
    .bcdUSB             = 0x0200,
    // Use IAD (Interface Association Descriptor) device class so CDC works
    // correctly on all modern OS without driver installation.
    .bDeviceClass       = TUSB_CLASS_MISC,
    .bDeviceSubClass    = MISC_SUBCLASS_COMMON,
    .bDeviceProtocol    = MISC_PROTOCOL_IAD,
    .bMaxPacketSize0    = CFG_TUD_ENDPOINT0_SIZE,
    .idVendor           = 0x2E8Au,  // Raspberry Pi
    .idProduct          = 0x000Au,
    .bcdDevice          = 0x0100,
    .iManufacturer      = STRID_MANUFACTURER,
    .iProduct           = STRID_PRODUCT,
    .iSerialNumber      = STRID_SERIAL,
    .bNumConfigurations = 1,
};

uint8_t const *tud_descriptor_device_cb(void) {
    return (uint8_t const *)&desc_device;
}

// ── Configuration descriptor ──────────────────────────────────────────────────

#define CONFIG_TOTAL_LEN  (TUD_CONFIG_DESC_LEN + TUD_CDC_DESC_LEN)

static const uint8_t desc_configuration[] = {
    // Config header
    TUD_CONFIG_DESCRIPTOR(1, ITF_NUM_TOTAL, STRID_LANGID,
                          CONFIG_TOTAL_LEN, 0x00, 100),
    // CDC interface (control + data)
    TUD_CDC_DESCRIPTOR(ITF_NUM_CDC_CTRL, STRID_LANGID,
                       EPNUM_CDC_NOTIF, 8,
                       EPNUM_CDC_OUT, EPNUM_CDC_IN, 64),
};

uint8_t const *tud_descriptor_configuration_cb(uint8_t index) {
    (void)index;
    return desc_configuration;
}

// ── String descriptors ────────────────────────────────────────────────────────

static const char *string_desc[] = {
    [STRID_LANGID]       = (const char[]){0x09, 0x04},  // English (US)
    [STRID_MANUFACTURER] = "PicoShark",
    [STRID_PRODUCT]      = "LDCN RS-485 Sniffer",
    [STRID_SERIAL]       = "000001",
};

// TinyUSB calls this to get each string descriptor as UTF-16.
// We return a static buffer (safe because USB requests are serialised).
static uint16_t desc_str[64];

uint16_t const *tud_descriptor_string_cb(uint8_t index, uint16_t langid) {
    (void)langid;

    if (index >= sizeof(string_desc) / sizeof(string_desc[0]))
        return NULL;

    const char *str = string_desc[index];
    uint8_t len;

    if (index == STRID_LANGID) {
        // Language ID is raw bytes, not ASCII
        memcpy(&desc_str[1], str, 2);
        len = 1;
    } else {
        len = 0;
        for (const char *p = str; *p; p++)
            desc_str[1 + len++] = (uint16_t)*p;
    }

    // First entry: length (bytes) + descriptor type
    desc_str[0] = (uint16_t)((TUSB_DESC_STRING << 8) | (2 * len + 2));
    return desc_str;
}
