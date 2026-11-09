/* sys.c - вывод в UART (WB UART ядра) через очередь.
 * Строка журнала на 115200 бод - 5..20 мс; ожидание UART задерживало бы приём пакетов (у eth_sys два буфера
 * кадров). put_* кладут байты в очередь, put_poll() из главного цикла отправляет их, пока UART свободен;
 * ожидание - только при переполнении очереди. */
#include "sys.h"
#include "wbuart.h"

#define TXQ 1024u                                   /* степень двойки; DTCM всего 8 КБ */
static char     txq[TXQ];
static uint32_t txq_w, txq_r;

static int tx_busy(void) { return (PICO_WBUART->TXREG & (1UL << 8)) != 0; }   /* как wbuart_putc (BSP) */

static void tx_byte(char c)
{
    uint32_t tmp = PICO_WBUART->TXREG & (~0xffUL);
    PICO_WBUART->TXREG = tmp + ((uint32_t)c & 0xffu);
}

void put_poll(void)
{
    while (txq_r != txq_w && !tx_busy()) {
        tx_byte(txq[txq_r]);
        txq_r = (txq_r + 1u) & (TXQ - 1u);
    }
}

static void put_c(char c)
{
    uint32_t n = (txq_w + 1u) & (TXQ - 1u);
    while (n == txq_r) {                            /* очередь полна - отправить один байт, дождавшись UART */
        while (tx_busy()) ;
        tx_byte(txq[txq_r]);
        txq_r = (txq_r + 1u) & (TXQ - 1u);
    }
    txq[txq_w] = c;
    txq_w = n;
}

void put_str(const char *s)
{
    while (*s) {
        char c = *s++;
        put_c(c);
        if (c == '\n') put_c('\r');
    }
    put_poll();
}

void put_u32(uint32_t v)
{
    char b[11];
    int i = 10;
    b[i] = 0;
    do { b[--i] = (char)('0' + v % 10u); v /= 10u; } while (v);
    put_str(&b[i]);
}

void put_hex(uint32_t v, uint32_t digits)
{
    static const char d[] = "0123456789ABCDEF";
    while (digits--) put_c(d[(v >> (4u * digits)) & 0xFu]);
    put_poll();
}
