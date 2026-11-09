/* eth.h - драйвер буферов кадров eth_sys (fpga/rtl/eth_sys.sv). */
#ifndef ETH_H
#define ETH_H

#include <stdint.h>

#define ETH_MAX_FRAME 1536u   /* размер буферов кадров в прошивке (кратен 4) */

int      eth_phy_ready(void);
/* Забрать принятый кадр в buf (выровнен на 4, размер ETH_MAX_FRAME). Возвращает длину или 0. */
uint32_t eth_rx(uint8_t *buf);
/* Отправить кадр (buf выровнен на 4, len <= ETH_MAX_FRAME). Ждёт окончания предыдущей передачи. */
void     eth_tx(const uint8_t *buf, uint32_t len);

#endif /* ETH_H */
