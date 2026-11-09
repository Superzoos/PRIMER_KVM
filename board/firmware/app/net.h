/* net.h - минимальный стек: ARP, IPv4 (без фрагментации), ICMP echo, UDP. */
#ifndef NET_H
#define NET_H

#include <stdint.h>

#define NET_HDR_LEN 42u    /* Ethernet 14 + IPv4 20 + UDP 8 */

/* Отправитель UDP-пакета */
typedef struct {
    uint8_t  mac[6];
    uint8_t  ip[4];
    uint16_t port;
} net_peer_t;

/* Обработать принятый кадр Ethernet. */
void net_input(const uint8_t *frame, uint32_t len);

/* Обработчик UDP-пакетов на порт NET_UDP_PORT (реализован в main.c):
 * peer - отправитель, in/n - данные запроса, out - место под данные ответа (max байт).
 * Возвращает длину ответа или 0. */
uint32_t net_udp_handler(const net_peer_t *peer, const uint8_t *in, uint32_t n, uint8_t *out, uint32_t max);

/* Заголовок Ethernet + IPv4 + UDP (NET_HDR_LEN байт) пакета с данными длиной plen от NET_UDP_PORT к peer:
 * идентификатор IP 0, DF, контрольная сумма UDP 0 - одинаков для всех пакетов одной длины. */
void net_udp_header(uint8_t *h, const net_peer_t *peer, uint32_t plen);

#endif /* NET_H */
