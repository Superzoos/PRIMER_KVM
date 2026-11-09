/* mdio.c - MDIO clause 22 программно (по образцу драйвера Linux drivers/net/mdio/mdio-bitbang.c).
 * MDC ~500 кГц (полупериод 1 мкс); RTL8201F допускает до 2.5 МГц. MDIO - открытый сток. */
#include "mdio.h"
#include "kvm_regs.h"
#include "kvm_config.h"

#define OP_READ  2u
#define OP_WRITE 1u

static void half_period(void)
{
    uint32_t t0, t;
    __asm__ volatile ("csrr %0, 0xc00" : "=r"(t0));
    do { __asm__ volatile ("csrr %0, 0xc00" : "=r"(t)); } while ((uint32_t)(t - t0) < CPU_CLK_HZ / 1000000u);
}

static void lines(uint32_t mdc, uint32_t out)
{
    ETH->MDIO = (mdc ? ETH_MDIO_MDC : 0u) | (out ? ETH_MDIO_OUT : 0u);
}

static void send_bit(uint32_t v)
{
    lines(0, v);
    half_period();
    lines(1, v);
    half_period();
    lines(0, v);
}

static uint32_t get_bit(void)        /* линия MDIO отпущена */
{
    half_period();
    lines(1, 1);
    half_period();
    lines(0, 1);
    return (ETH->MDIO & ETH_MDIO_IN) ? 1u : 0u;
}

static void send_num(uint32_t v, int bits)
{
    for (int i = bits - 1; i >= 0; i--) send_bit((v >> i) & 1u);
}

static void cmd(uint32_t op, uint32_t phy, uint32_t reg)
{
    for (int i = 0; i < 32; i++) send_bit(1);   /* преамбула */
    send_bit(0);                                /* старт 01 */
    send_bit(1);
    send_bit((op >> 1) & 1u);                   /* операция: чтение 10, запись 01 */
    send_bit(op & 1u);
    send_num(phy, 5);
    send_num(reg, 5);
}

uint16_t mdio_read(uint32_t phy, uint32_t reg)
{
    cmd(OP_READ, phy, reg);
    lines(0, 1);                                /* отпустить линию */
    if (get_bit() != 0) {                       /* PHY должен держать 0 во втором бите оборота */
        for (int i = 0; i < 32; i++) get_bit();
        return 0xFFFF;
    }
    uint32_t v = 0;
    for (int i = 0; i < 16; i++) v = (v << 1) | get_bit();
    get_bit();
    return (uint16_t)v;
}

void mdio_write(uint32_t phy, uint32_t reg, uint16_t val)
{
    cmd(OP_WRITE, phy, reg);
    send_bit(1);                                /* оборот 10 */
    send_bit(0);
    send_num(val, 16);
    lines(0, 1);
    get_bit();
}
