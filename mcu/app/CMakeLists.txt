cmake_minimum_required(VERSION 3.20.0)
find_package(Zephyr REQUIRED HINTS $ENV{ZEPHYR_BASE})
project(hybrid_link)
target_sources(app PRIVATE src/main.c src/matrix.c src/bars.c)
# app_proto.h holds the MPU <-> MCU contract, shared with mcu/tests/, and
# bars.c is compiled a second time by mcu/tests/bars/ to run on the host.
target_include_directories(app PRIVATE include)
