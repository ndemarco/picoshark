cmake_minimum_required(VERSION 3.13)

include($ENV{PICO_SDK_PATH}/external/pico_sdk_import.cmake)

project(picoshark C CXX ASM)
set(CMAKE_C_STANDARD 11)
set(CMAKE_CXX_STANDARD 17)

pico_sdk_init()

add_executable(picoshark
    src/main.c
    src/dma.c
    src/parser.c
    src/usb.c
    src/usb_descriptors.c
)

# Generate C header from PIO program
pico_generate_pio_header(picoshark ${CMAKE_CURRENT_LIST_DIR}/src/uart_rx.pio)

target_include_directories(picoshark PRIVATE src)

target_link_libraries(picoshark
    pico_stdlib
    pico_multicore
    hardware_pio
    hardware_dma
    hardware_irq
    tinyusb_device
    tinyusb_board
)

# No USB or UART stdio — we drive USB directly via TinyUSB
pico_enable_stdio_usb(picoshark 0)
pico_enable_stdio_uart(picoshark 0)

# Generate .uf2, .map, .dis etc.
pico_add_extra_outputs(picoshark)
