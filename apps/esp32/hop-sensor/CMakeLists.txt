# ESP-IDF top-level project for hop-sensor (core-ffi-03).
#
# A real, buildable ESP-IDF project that runs a full Hop client on an ESP32-class chip by linking the
# `minimal` libhop static library (no UniFFI, no SQLite) through its C ABI (hop.h). The only steps a
# user performs are:
#   1. ./build-libhop-esp.sh            # cross-compile libhop.a for the chip's Rust target
#   2. idf.py set-target esp32c3        # or esp32 / esp32s3 / esp32c6 ...
#   3. idf.py build                     # links libhop.a + main into a flashable image
#   4. idf.py -p /dev/ttyUSB0 flash monitor   # the only ON-HARDWARE step
#
# See README.md for the full walkthrough (targets, prerequisites, bearer wiring).

cmake_minimum_required(VERSION 3.16)

include($ENV{IDF_PATH}/tools/cmake/project.cmake)

project(hop-sensor)
