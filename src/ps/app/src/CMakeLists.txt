# Copyright (C) 2023 - 2025 Advanced Micro Devices, Inc.  All rights reserved.
# SPDX-License-Identifier: MIT
cmake_minimum_required(VERSION 3.16)
include(${CMAKE_SOURCE_DIR}/Empty_applicationExample.cmake)
include(${CMAKE_CURRENT_SOURCE_DIR}/UserConfig.cmake)
if(DEFINED ENV{PS_APP_PLATFORM_SW_DIR})
    list(APPEND USER_INCLUDE_DIRECTORIES "$ENV{PS_APP_PLATFORM_SW_DIR}/include")
endif()

set(APP_NAME app)
project(${APP_NAME})

find_package(common)
enable_language(C ASM CXX)

set(CMAKE_C_STANDARD 11)
set(CMAKE_C_STANDARD_REQUIRED ON)
set(CMAKE_C_EXTENSIONS OFF)
set(CMAKE_CXX_EXTENSIONS OFF)
set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)

collect(PROJECT_LIB_DEPS xilstandalone;xiltimer;xilffs;freertos)
collect(PROJECT_LIB_DEPS xil)
collect(PROJECT_LIB_DEPS gcc)
collect(PROJECT_LIB_DEPS c)

collector_create(PROJECT_LIB_HEADERS "${CMAKE_CURRENT_SOURCE_DIR}")
collector_list(_collector_headers PROJECT_LIB_HEADERS)
collector_create(PROJECT_LIB_SOURCES "${CMAKE_CURRENT_SOURCE_DIR}")
collector_list(_collector_sources PROJECT_LIB_SOURCES)

file(GLOB_RECURSE app_headers CONFIGURE_DEPENDS
    "${CMAKE_CURRENT_SOURCE_DIR}/*.h"
    "${CMAKE_CURRENT_SOURCE_DIR}/*.hpp")
file(GLOB_RECURSE _app_source_index CONFIGURE_DEPENDS
    "${CMAKE_CURRENT_SOURCE_DIR}/*.c"
    "${CMAKE_CURRENT_SOURCE_DIR}/*.cc"
    "${CMAKE_CURRENT_SOURCE_DIR}/*.cpp"
    "${CMAKE_CURRENT_SOURCE_DIR}/*.cxx"
    "${CMAKE_CURRENT_SOURCE_DIR}/*.S"
    "${CMAKE_CURRENT_SOURCE_DIR}/*.s"
    "${CMAKE_CURRENT_SOURCE_DIR}/*.asm")
list(APPEND app_headers ${_collector_headers})

# The Vitis collector flattens paths. This source name occurs in two LVGL VGLite
# providers, both disabled in the Zybo profile; enabling VGLite requires pathful entries.
include("${CMAKE_CURRENT_SOURCE_DIR}/cmake/ResolveAppSources.cmake")
if("$ENV{PS_APP_SOURCE_TREE_MODE}" STREQUAL "1")
    # Flow stages build a read-only staged source tree outside a Vitis app component.
    # Select the recursive source index so standalone CMake includes every app unit.
    zynq_gba_filter_disabled_vglite_collision(_source_tree_app_sources
        "${CMAKE_CURRENT_SOURCE_DIR}/ThirdParty/lvgl/lv_conf.h"
        _app_source_index
        USER_COMPILE_SOURCES)
    zynq_gba_resolve_app_sources(app_sources
        "${CMAKE_CURRENT_SOURCE_DIR}"
        _app_source_index
        _source_tree_app_sources)
else()
    zynq_gba_filter_disabled_vglite_collision(_selected_app_sources
        "${CMAKE_CURRENT_SOURCE_DIR}/ThirdParty/lvgl/lv_conf.h"
        _collector_sources
        USER_COMPILE_SOURCES)
    zynq_gba_resolve_app_sources(app_sources
        "${CMAKE_CURRENT_SOURCE_DIR}"
        _app_source_index
        _selected_app_sources)
endif()

# Normalize selected source paths before grouping them into independently configurable targets.
set(_normalized_sources)
foreach(_source IN LISTS app_sources)
    get_filename_component(_absolute_source "${_source}" ABSOLUTE BASE_DIR "${CMAKE_CURRENT_SOURCE_DIR}")
    list(APPEND _normalized_sources "${_absolute_source}")
endforeach()
list(REMOVE_DUPLICATES _normalized_sources)

set(src_ext)
foreach(_source IN LISTS _normalized_sources)
    get_filename_component(_extension "${_source}" EXT)
    list(APPEND src_ext "${_extension}")
endforeach()
if(NOT DEFINED PROJECT_TYPE)
    find_project_type("${src_ext}" PROJECT_TYPE)
endif()
if("${PROJECT_TYPE}" STREQUAL "c++")
    collect(PROJECT_LIB_DEPS stdc++)
endif()

collector_list(_deps PROJECT_LIB_DEPS)
list(APPEND _deps ${USER_LINK_LIBRARIES})
string(REPLACE ";" ",-l" _deps "${_deps}")

if(CMAKE_EXPORT_COMPILE_COMMANDS AND NOT YOCTO)
    set(CMAKE_CXX_STANDARD_INCLUDE_DIRECTORIES ${CMAKE_CXX_IMPLICIT_INCLUDE_DIRECTORIES})
    set(CMAKE_C_STANDARD_INCLUDE_DIRECTORIES ${CMAKE_C_IMPLICIT_INCLUDE_DIRECTORIES})
endif()
if(EXISTS "${CMAKE_SOURCE_DIR}/linker_files/")
    linker_gen("${CMAKE_SOURCE_DIR}/linker_files/")
elseif(NOT DEFINED USER_LINKER_SCRIPT OR "${USER_LINKER_SCRIPT}" STREQUAL "")
    set(USER_LINKER_SCRIPT "${CMAKE_CURRENT_SOURCE_DIR}/lscript.ld")
endif()

string(JOIN " " _user_compile_flags ${USER_COMPILE_OPTIONS})
string(JOIN " " _user_link_flags ${USER_LINK_OPTIONS})

function(ps_app_configure_component target is_third_party)
    target_include_directories(${target} PRIVATE
        "${CMAKE_CURRENT_SOURCE_DIR}"
        ${USER_INCLUDE_DIRECTORIES})
    target_compile_definitions(${target} PRIVATE ${USER_COMPILE_DEFINITIONS})
    if(is_third_party)
        set(_component_options ${USER_THIRD_PARTY_COMPILE_OPTIONS})
        set(_component_c_extensions ON)
        set(_component_cxx_extensions ON)
    else()
        set(_component_options ${USER_COMPILE_OPTIONS})
        set(_component_c_extensions OFF)
        set(_component_cxx_extensions OFF)
    endif()
    # First-party groups keep C11/C++17 strict; vendored sources retain GNU extensions.
    # Project warnings stay on first-party targets; third-party flags remain explicit and separate.
    foreach(_option IN LISTS _component_options)
        target_compile_options(${target} PRIVATE "$<$<COMPILE_LANGUAGE:C,CXX>:${_option}>")
    endforeach()
    set_target_properties(${target} PROPERTIES
        C_STANDARD ${CMAKE_C_STANDARD}
        C_STANDARD_REQUIRED YES
        C_EXTENSIONS ${_component_c_extensions}
        CXX_STANDARD ${CMAKE_CXX_STANDARD}
        CXX_STANDARD_REQUIRED YES
        CXX_EXTENSIONS ${_component_cxx_extensions})
endfunction()

if(NOT "${_normalized_sources}" STREQUAL "")
    # BSP-generated headers and libraries must be ready before any component compiles.
    add_dependency_on_bsp(_normalized_sources)

    # Create one reusable ps_app_<component> OBJECT target per source group.
    set(_component_keys)
    foreach(_source IN LISTS _normalized_sources)
        file(RELATIVE_PATH _relative_source "${CMAKE_CURRENT_SOURCE_DIR}" "${_source}")
        if(_relative_source MATCHES "^ThirdParty/([^/]+)/")
            set(_component "third_party_${CMAKE_MATCH_1}")
        elseif(_relative_source MATCHES "^([^/]+)/")
            set(_component "${CMAKE_MATCH_1}")
        else()
            set(_component "root")
        endif()
        string(REGEX REPLACE "[^A-Za-z0-9_]" "_" _component "${_component}")
        set(_component_var "_PS_APP_SOURCES_${_component}")
        list(APPEND ${_component_var} "${_source}")
        list(APPEND _component_keys "${_component}")
    endforeach()
    list(REMOVE_DUPLICATES _component_keys)

    set(_component_objects)
    foreach(_component IN LISTS _component_keys)
        set(_component_target "ps_app_${_component}")
        set(_component_var "_PS_APP_SOURCES_${_component}")
        add_library(${_component_target} OBJECT ${${_component_var}})
        if(_component MATCHES "^third_party_")
            ps_app_configure_component(${_component_target} TRUE)
        else()
            ps_app_configure_component(${_component_target} FALSE)
        endif()
        list(APPEND _component_objects "$<TARGET_OBJECTS:${_component_target}>")
    endforeach()

    add_executable(${APP_NAME}.elf ${_component_objects})
    target_include_directories(${APP_NAME}.elf PRIVATE
        "${CMAKE_CURRENT_SOURCE_DIR}"
        "${CMAKE_CURRENT_SOURCE_DIR}/Gba/Inc"
        ${USER_INCLUDE_DIRECTORIES})
    if(USER_LINK_OPTIONS)
        target_link_options(${APP_NAME}.elf PRIVATE ${USER_LINK_OPTIONS})
    endif()
    set_target_properties(${APP_NAME}.elf PROPERTIES LINK_DEPENDS "${USER_LINKER_SCRIPT}")
    target_link_directories(${APP_NAME}.elf PRIVATE
        "${CMAKE_SOURCE_DIR}"
        ${CMAKE_LIBRARY_PATH}
        ${USER_LINK_DIRECTORIES})
    set(_linker_command "-Wl,-T -Wl,\"${USER_LINKER_SCRIPT}\" -Wl,--start-group,-l${_deps} -Wl,--end-group")
    target_link_libraries(${APP_NAME}.elf ${_linker_command})
    print_build_info_target(${APP_NAME}.elf "${CMAKE_C_FLAGS} ${_user_compile_flags}" "${USER_COMPILE_DEFINITIONS}" "${CMAKE_C_LINK_FLAGS} ${_user_link_flags}" "${_linker_command}")
    print_elf_size(CMAKE_SIZE ${APP_NAME})
endif()
