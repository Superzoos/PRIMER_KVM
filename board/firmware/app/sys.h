/* sys.h - общие мелочи: счётчик тактов ядра и вывод в UART. */
#ifndef SYS_H
#define SYS_H

#include <stdint.h>
#include "kvm_config.h"

/* Счётчик тактов ядра (CSR cycle, ENABLE_COUNTERS в pico_define.vh) */
static inline uint32_t cycles(void)
{
    uint32_t c;
    __asm__ volatile ("csrr %0, 0xc00" : "=r"(c));
    return c;
}

/* Миллисекунд прошло с момента t0 = cycles() (до ~95 с при 45 МГц) */
static inline uint32_t ms_since(uint32_t t0)
{
    return (uint32_t)(cycles() - t0) / (CPU_CLK_HZ / 1000u);
}

void put_str(const char *s);        /* в очередь UART; отправляет put_poll() (вызывать в главном цикле) */
void put_poll(void);
void put_u32(uint32_t v);
void put_hex(uint32_t v, uint32_t digits);

#endif /* SYS_H */
