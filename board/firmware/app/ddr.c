/* ddr.c - запуск и проверка DDR3 через окно памяти ядра (fpga/rtl/ddr_arb.sv). */
#include "ddr.h"
#include "kvm_regs.h"
#include "sys.h"

#define DATA_OFFSET  (64u << 20)   /* область теста данных: 64 МБ от начала (кадр - в начале памяти) */
#define DATA_WORDS   65536u        /* 256 КБ */

static uint32_t lfsr(uint32_t x)    /* 32-битный LFSR Галуа, многочлен x^32+x^22+x^2+x+1 */
{
    return (x >> 1) ^ ((0u - (x & 1u)) & 0x80200003u);
}

static uint32_t fail(const char *what, uint32_t off, uint32_t wr, uint32_t rd)
{
    put_str("DDR3: ОШИБКА, "); put_str(what);
    put_str(": адрес 0x"); put_hex(DDR_MEM_BASE + off, 8);
    put_str(", записано 0x"); put_hex(wr, 8);
    put_str(", прочитано 0x"); put_hex(rd, 8); put_str("\n");
    return 0;
}

#define WAIT_MS 3000u

static int waiting;            /* калибровка не завершилась за WAIT_MS - ждём дальше в ddr_poll() */

static void diag(void)                     /* состояние IP, если калибровка не завершилась */
{
    uint32_t st = DDR->STATUS;
    put_str("  PLL памяти: ");     put_str((st & DDR_ST_PLL_LOCK) ? "захвачен" : "НЕ захвачен");
    put_str(", сброс IP: ");       put_str((st & DDR_ST_IP_RST) ? "НЕ снят" : "снят");
    put_str(", такт пользователя "); put_u32(DDR->DCLK_KHZ);
    put_str(" кГц (ожидается ");   put_u32(DDR_MEM_CLK_HZ / 4000u); put_str(")\n");
}

static uint32_t test(void);

uint32_t ddr_init(void)
{
    if (DDR->ID != DDR_ID_VALUE) { put_str("DDR3: ОШИБКА, ddr_arb не отвечает\n"); return 0; }

    uint32_t t0 = cycles();
    while (!(DDR->STATUS & DDR_ST_READY)) {
        if (ms_since(t0) > WAIT_MS) {
            put_str("DDR3: калибровка не завершилась за 3 с, ожидание продолжается\n");
            diag();
            waiting = 1;
            return 0;
        }
    }
    return test();
}

uint32_t ddr_poll(uint32_t now_ms)
{
    if (!waiting || !(DDR->STATUS & DDR_ST_READY)) return 0;
    waiting = 0;
    put_str("DDR3: калибровка завершилась через "); put_u32(now_ms); put_str(" мс\n");
    return test();
}

static uint32_t test(void)
{
    uint32_t mb = DDR->SIZE_MB, size = mb << 20;

    volatile uint32_t *m = DDR_MEM;

    /* 1. Адресные линии: по адресам 0 и 2^k - разные значения. Замкнутая или оборванная линия
     *    даёт совпадение адресов, и одно из значений затрётся. */
    m[0] = 0x5A5A5A5Au;
    for (uint32_t a = 4; a < size; a <<= 1) m[a >> 2] = a ^ 0x5A5A5A5Au;
    if (m[0] != 0x5A5A5A5Au) return fail("адреса", 0, 0x5A5A5A5Au, m[0]);
    for (uint32_t a = 4; a < size; a <<= 1) {
        uint32_t r = m[a >> 2];
        if (r != (a ^ 0x5A5A5A5Au)) return fail("адреса", a, a ^ 0x5A5A5A5Au, r);
    }

    /* 2. Запись байтами и полусловами (маска байтов IP) */
    volatile uint8_t  *b = (volatile uint8_t *)(DDR_MEM_BASE + 0x100u);
    volatile uint16_t *h = (volatile uint16_t *)(DDR_MEM_BASE + 0x110u);
    for (uint32_t i = 0; i < 8; i++) m[(0x100u >> 2) + i] = 0xFFFFFFFFu;
    for (uint32_t i = 0; i < 16; i++) b[i] = (uint8_t)(0x10u + i);
    for (uint32_t i = 0; i < 8; i++)  h[i] = (uint16_t)(0xC000u + i);
    for (uint32_t i = 0; i < 4; i++) {
        uint32_t e = 0x10u + 4u * i;
        e = e | ((e + 1u) << 8) | ((e + 2u) << 16) | ((e + 3u) << 24);
        uint32_t r = m[(0x100u >> 2) + i];
        if (r != e) return fail("запись байтами", 0x100u + 4u * i, e, r);
        e = (0xC000u + 2u * i) | ((0xC001u + 2u * i) << 16);
        r = m[(0x110u >> 2) + i];
        if (r != e) return fail("запись полусловами", 0x110u + 4u * i, e, r);
    }

    /* 3. Данные: псевдослучайная последовательность в 256 КБ */
    volatile uint32_t *d = DDR_MEM + (DATA_OFFSET >> 2);
    uint32_t x = 0xACE1u;
    for (uint32_t i = 0; i < DATA_WORDS; i++) { d[i] = x; x = lfsr(x); }
    x = 0xACE1u;
    for (uint32_t i = 0; i < DATA_WORDS; i++) {
        uint32_t r = d[i];
        if (r != x) return fail("данные", DATA_OFFSET + 4u * i, x, r);
        x = lfsr(x);
    }

    put_str("DDR3: "); put_u32(mb); put_str(" МБ, проверка пройдена\n");
    return size;
}
