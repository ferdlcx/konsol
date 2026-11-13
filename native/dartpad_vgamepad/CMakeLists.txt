cmake_minimum_required(VERSION 3.16)
project(dartpad_vgamepad LANGUAGES C CXX)

option(USE_VIGEM "Build with Windows ViGEmClient backend" OFF)

add_library(dartpad_vgamepad SHARED
  dartpad_vgamepad.c
  dartpad_vgamepad.h
)

target_compile_definitions(dartpad_vgamepad PRIVATE DARTPAD_VGAMEPAD_EXPORTS)

if(WIN32 AND USE_VIGEM)
  target_compile_definitions(dartpad_vgamepad PRIVATE USE_VIGEM=1)
  # Link against ViGEmClient and setupapi on Windows
  target_link_libraries(dartpad_vgamepad PRIVATE ViGEmClient setupapi)
endif()
