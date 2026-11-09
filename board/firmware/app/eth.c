/* eth.c - драйвер буферов кадров eth_sys. */
#include "eth.h"
#include "kvm_regs.h"

int eth_phy_ready(void)
{
    return (ETH->STATUS & ETH_ST_PHY_READY) != 0;
}

uint32_t eth_rx(uint8_t *buf)
{
    if (!(ETH->STATUS & ETH_ST_RX_AVAIL)) return 0;
    uint32_t len = ETH->RX_LEN;
    if (len > ETH_MAX_FRAME) {          /* не помещается - пропустить */
        ETH->RX_POP = 1;
        return 0;
    }
    uint32_t *dst = (uint32_t *)buf;
    for (uint32_t i = 0; i < (len + 3u) / 4u; i++) dst[i] = ETH_BUF[i];
    ETH->RX_POP = 1;
    return len;
}

void eth_tx(const uint8_t *buf, uint32_t len)
{
    while (ETH->STATUS & ETH_ST_TX_BUSY) { }
    const uint32_t *src = (const uint32_t *)buf;
    for (uint32_t i = 0; i < (len + 3u) / 4u; i++) ETH_BUF[i] = src[i];
    ETH->TX_LEN = len;
}
