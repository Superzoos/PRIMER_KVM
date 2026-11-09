/* mdio.h - управление PHY по MDIO (IEEE 802.3 clause 22), программно через регистр eth_sys MDIO. */
#ifndef MDIO_H
#define MDIO_H

#include <stdint.h>

/* Чтение регистра PHY; 0xFFFF - PHY не ответил. */
uint16_t mdio_read(uint32_t phy, uint32_t reg);
void     mdio_write(uint32_t phy, uint32_t reg, uint16_t val);

#endif /* MDIO_H */
