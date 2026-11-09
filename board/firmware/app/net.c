/* net.c - минимальный стек: ARP (ответ на запросы своего IP), IPv4 без фрагментации,
 * ICMP echo (ping), UDP на порт NET_UDP_PORT (ответ - через net_udp_handler).
 * Адреса - из config/project.cfg (kvm_config.h). Контрольная сумма UDP не считается (0 допустим в IPv4). */
#include "net.h"
#include "eth.h"
#include "kvm_config.h"

static const uint8_t my_mac[6] = NET_MAC_ADDR_BYTES;
static const uint8_t my_ip[4]  = {
    (uint8_t)(NET_IP_ADDR >> 24), (uint8_t)(NET_IP_ADDR >> 16),
    (uint8_t)(NET_IP_ADDR >> 8),  (uint8_t)NET_IP_ADDR
};

static uint32_t tx_words[ETH_MAX_FRAME / 4u];
static uint8_t *const tx = (uint8_t *)tx_words;
static uint16_t ip_id;

static uint16_t rd16(const uint8_t *p) { return (uint16_t)((p[0] << 8) | p[1]); }
static void wr16(uint8_t *p, uint16_t v) { p[0] = (uint8_t)(v >> 8); p[1] = (uint8_t)v; }

static int same(const uint8_t *a, const uint8_t *b, uint32_t n)
{
    while (n--) if (*a++ != *b++) return 0;
    return 1;
}

static void copy(uint8_t *d, const uint8_t *s, uint32_t n)
{
    while (n--) *d++ = *s++;
}

static uint16_t csum(const uint8_t *p, uint32_t n)
{
    uint32_t s = 0;
    while (n > 1) { s += (uint32_t)((p[0] << 8) | p[1]); p += 2; n -= 2; }
    if (n) s += (uint32_t)(p[0] << 8);
    while (s >> 16) s = (s & 0xFFFFu) + (s >> 16);
    return (uint16_t)~s;
}

static void eth_hdr(const uint8_t *dst_mac, uint16_t type)
{
    copy(tx, dst_mac, 6);
    copy(tx + 6, my_mac, 6);
    wr16(tx + 12, type);
}

/* ---------- ARP ---------- */
static void arp_input(const uint8_t *f, uint32_t len)
{
    const uint8_t *a = f + 14;
    if (len < 42) return;
    if (rd16(a) != 1 || rd16(a + 2) != 0x0800 || a[4] != 6 || a[5] != 4) return;
    if (rd16(a + 6) != 1 || !same(a + 24, my_ip, 4)) return;   /* только запросы нашего IP */

    eth_hdr(a + 8, 0x0806);
    uint8_t *o = tx + 14;
    wr16(o, 1); wr16(o + 2, 0x0800); o[4] = 6; o[5] = 4; wr16(o + 6, 2);
    copy(o + 8, my_mac, 6);
    copy(o + 14, my_ip, 4);
    copy(o + 18, a + 8, 6);
    copy(o + 24, a + 14, 4);
    eth_tx(tx, 42);
}

/* ---------- IPv4 ---------- */
/* Заголовок IPv4 (20 байт) в o: от нас к dst_ip, данные plen байт. */
static void ip_hdr(uint8_t *o, const uint8_t *dst_ip, uint8_t proto, uint32_t plen, uint16_t id)
{
    o[0] = 0x45; o[1] = 0;
    wr16(o + 2, (uint16_t)(20u + plen));
    wr16(o + 4, id);
    wr16(o + 6, 0x4000);                 /* не фрагментировать */
    o[8] = 64; o[9] = proto;
    wr16(o + 10, 0);
    copy(o + 12, my_ip, 4);
    copy(o + 16, dst_ip, 4);
    wr16(o + 10, csum(o, 20));
}

/* Заголовок ответа: Ethernet + IPv4 отправителю пакета ip из кадра f. Возвращает начало данных. */
static uint8_t *ip_reply(const uint8_t *f, const uint8_t *ip, uint8_t proto, uint32_t plen)
{
    eth_hdr(f + 6, 0x0800);
    ip_hdr(tx + 14, ip + 12, proto, plen, ip_id++);
    return tx + 34;
}

void net_udp_header(uint8_t *h, const net_peer_t *peer, uint32_t plen)
{
    copy(h, peer->mac, 6);
    copy(h + 6, my_mac, 6);
    wr16(h + 12, 0x0800);
    ip_hdr(h + 14, peer->ip, 17, 8u + plen, 0);
    uint8_t *u = h + 34;
    wr16(u, NET_UDP_PORT);
    wr16(u + 2, peer->port);
    wr16(u + 4, (uint16_t)(8u + plen));
    wr16(u + 6, 0);
}

static void icmp_input(const uint8_t *f, const uint8_t *ip, const uint8_t *p, uint32_t plen)
{
    if (plen < 8 || p[0] != 8 || 34u + plen > ETH_MAX_FRAME) return;   /* только echo request */
    uint8_t *o = ip_reply(f, ip, 1, plen);
    copy(o, p, plen);
    o[0] = 0;                            /* echo reply */
    wr16(o + 2, 0);
    wr16(o + 2, csum(o, plen));
    eth_tx(tx, 34u + plen);
}

static void udp_input(const uint8_t *f, const uint8_t *ip, const uint8_t *p, uint32_t plen)
{
    if (plen < 8) return;
    uint32_t ulen = rd16(p + 4);
    if (ulen < 8 || ulen > plen || rd16(p + 2) != NET_UDP_PORT) return;

    net_peer_t peer;
    copy(peer.mac, f + 6, 6);
    copy(peer.ip, ip + 12, 4);
    peer.port = rd16(p);
    uint32_t n = net_udp_handler(&peer, p + 8, ulen - 8, tx + 42, ETH_MAX_FRAME - 42);
    if (n == 0) return;
    uint8_t *u = ip_reply(f, ip, 17, 8u + n);
    wr16(u, NET_UDP_PORT);
    wr16(u + 2, rd16(p));
    wr16(u + 4, (uint16_t)(8u + n));
    wr16(u + 6, 0);
    eth_tx(tx, 42u + n);
}

static void ip_input(const uint8_t *f, uint32_t len)
{
    const uint8_t *ip = f + 14;
    if (len < 34 || (ip[0] >> 4) != 4) return;
    uint32_t ihl = (ip[0] & 0x0Fu) * 4u;
    uint32_t tot = rd16(ip + 2);
    if (ihl < 20 || tot < ihl || 14u + tot > len) return;
    if (!same(ip + 16, my_ip, 4)) return;
    if (rd16(ip + 6) & 0x3FFFu) return;  /* фрагменты не поддерживаются */

    const uint8_t *p = ip + ihl;
    uint32_t plen = tot - ihl;
    if (ip[9] == 1)       icmp_input(f, ip, p, plen);
    else if (ip[9] == 17) udp_input(f, ip, p, plen);
}

void net_input(const uint8_t *frame, uint32_t len)
{
    if (len < 14) return;
    uint16_t type = rd16(frame + 12);
    if (type == 0x0806)      arp_input(frame, len);
    else if (type == 0x0800) ip_input(frame, len);
}
