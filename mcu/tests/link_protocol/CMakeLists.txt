# Copyright (c) 2026 Jim Wyatt
# SPDX-License-Identifier: MIT
cmake_minimum_required(VERSION 3.20.0)
find_package(Zephyr REQUIRED HINTS $ENV{ZEPHYR_BASE})
project(link_protocol_test)
target_sources(app PRIVATE src/main.c)
# Test the firmware's own definitions, not a copy of them. This is the same
# header mcu/app/src/main.c includes.
target_include_directories(app PRIVATE ${CMAKE_CURRENT_SOURCE_DIR}/../../app/include)
