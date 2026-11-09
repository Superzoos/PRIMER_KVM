# Toolchain-файл xPack GNU RISC-V Embedded GCC.
# RISCV_DIR и RISCV_PREFIX передаёт scripts/fw-build.ps1 из config/project.cfg.
set(CMAKE_SYSTEM_NAME Generic)
set(CMAKE_SYSTEM_PROCESSOR riscv32)

# Нужны и при проверках компилятора (try_compile)
list(APPEND CMAKE_TRY_COMPILE_PLATFORM_VARIABLES RISCV_DIR RISCV_PREFIX)
set(CMAKE_TRY_COMPILE_TARGET_TYPE STATIC_LIBRARY)

if(NOT RISCV_DIR OR NOT RISCV_PREFIX)
    message(FATAL_ERROR "RISCV_DIR/RISCV_PREFIX не заданы: запускайте scripts/fw-build.ps1")
endif()

set(_rv "${RISCV_DIR}/bin/${RISCV_PREFIX}")
set(CMAKE_C_COMPILER   "${_rv}gcc.exe")
set(CMAKE_ASM_COMPILER "${_rv}gcc.exe")
set(RV_OBJCOPY         "${_rv}objcopy.exe")
