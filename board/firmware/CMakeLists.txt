# Прошивка ядра PicoRV32 проекта PRIMER_KVM. Сборка: scripts/fw-build.ps1
# (параметры FW_NAME, CPU_ITCM_KB, CPU_DTCM_KB берутся из config/project.cfg).
cmake_minimum_required(VERSION 3.21)

foreach(v FW_NAME CPU_ITCM_KB CPU_DTCM_KB)
    if(NOT DEFINED ${v})
        message(FATAL_ERROR "${v} не задан: запускайте scripts/fw-build.ps1")
    endif()
endforeach()

project(${FW_NAME} C ASM)

# Линкер-скрипт с размерами ITCM/DTCM
set(LDS ${CMAKE_BINARY_DIR}/kvm.ld)
configure_file(linker/kvm.ld.in ${LDS} @ONLY)

set(ARCH_FLAGS -march=rv32imc_zicsr -mabi=ilp32)

add_executable(${FW_NAME}
    sdk/start.S
    sdk/bsp/wbuart.c
    sdk/bsp/wbgpio.c
    app/main.c
    app/eth.c
    app/net.c
    app/util.c
    app/mdio.c
    app/sys.c
    app/ddr.c
    app/video.c
    app/hdmi.c
    app/usb.c
)
set_target_properties(${FW_NAME} PROPERTIES SUFFIX ".elf" LINK_DEPENDS ${LDS})
target_include_directories(${FW_NAME} PRIVATE include app sdk sdk/bsp)
target_compile_options(${FW_NAME} PRIVATE
    ${ARCH_FLAGS} -Os -g -ffreestanding -fno-tree-loop-distribute-patterns
    -ffunction-sections -fdata-sections -Wall -Wextra)
target_link_options(${FW_NAME} PRIVATE
    ${ARCH_FLAGS} -nostartfiles -nostdlib -Wl,--gc-sections -T${LDS})
target_link_libraries(${FW_NAME} PRIVATE gcc)

# ELF -> BIN (вход для make_hex и merge_bit)
add_custom_command(TARGET ${FW_NAME} POST_BUILD
    COMMAND ${RV_OBJCOPY} -O binary $<TARGET_FILE:${FW_NAME}> ${CMAKE_BINARY_DIR}/${FW_NAME}.bin
    VERBATIM)
