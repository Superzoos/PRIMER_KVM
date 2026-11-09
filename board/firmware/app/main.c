/* main.c - прошивка ядра PicoRV32 проекта PRIMER_KVM.
 * Сеть: ARP, ping и протокол KVM (kvm_proto.h) на UDP-порту NET_UDP_PORT.
 * DDR3: проверка при старте; буфер кадра с тестовой картинкой; передача кадра на ПК по запросу.
 * HDMI: EDID и HPD; захват в три буфера кадра, пока есть сигнал, иначе тестовая картинка (hdmi.c, video.c).
 * USB: клавиатура и мышь для удалённого ПК по командам KVM_CMD_INPUT (usb.c).
 *   LED0 - мигает 1 Гц (ядро работает);  LED1 - идёт захват HDMI;  LED2 - DDR3 прошла проверку;
 *   LED3 - за последнюю секунду передавался кадр;  LED4 - за последнюю секунду принимались кадры Ethernet;
 *   LED5 - ПК-приложение на связи (запросы < 3 с назад).
 * UART: сводка при запуске, события (HDMI, приложение, USB) и ошибки. */
#include <stdint.h>
#include "kvm_config.h"
#include "picorv32.h"
#include "wbuart.h"
#include "board.h"
#include "kvm_regs.h"
#include "kvm_proto.h"
#include "sys.h"
#include "eth.h"
#include "net.h"
#include "mdio.h"
#include "ddr.h"
#include "video.h"
#include "hdmi.h"
#include "usb.h"

/* Вызывается из start.S при прерывании; прерывания не используются. */
uint32_t *irq(uint32_t *regs, uint32_t irqs)
{
    (void)irqs;
    return regs;
}

/* ---------- Время ---------- */
static uint32_t now_ms, last_cyc;

static void time_update(void)
{
    while ((uint32_t)(cycles() - last_cyc) >= CPU_CLK_HZ / 1000u) {
        last_cyc += CPU_CLK_HZ / 1000u;
        now_ms++;
    }
}

/* ---------- Протокол KVM ---------- */
static const char fw_build[] = __DATE__ " " __TIME__;
static uint32_t client_ms, ddr_bytes;
static int client_on;

static void wr16le(uint8_t *p, uint32_t v) { p[0] = (uint8_t)v; p[1] = (uint8_t)(v >> 8); }

static void wr32le(uint8_t *p, uint32_t v)
{
    p[0] = (uint8_t)v; p[1] = (uint8_t)(v >> 8); p[2] = (uint8_t)(v >> 16); p[3] = (uint8_t)(v >> 24);
}

static uint32_t rd32le(const uint8_t *p)
{
    return (uint32_t)p[0] | ((uint32_t)p[1] << 8) | ((uint32_t)p[2] << 16) | ((uint32_t)p[3] << 24);
}

uint32_t net_udp_handler(const net_peer_t *peer, const uint8_t *in, uint32_t n, uint8_t *out, uint32_t max)
{
    if (n < KVM_HDR_LEN || rd32le(in) != KVM_MAGIC || max < KVM_HDR_LEN + sizeof(kvm_status_t)) return 0;

    client_ms = now_ms;
    if (!client_on) { client_on = 1; put_str("Приложение: подключено\n"); }

    uint8_t cmd = in[4];
    wr32le(out, KVM_MAGIC);
    out[4] = (uint8_t)(cmd | KVM_REPLY);
    out[5] = 0;
    out[6] = in[6];
    out[7] = in[7];
    uint8_t *s = out + KVM_HDR_LEN;

    if (cmd == KVM_CMD_STATUS) {
        wr32le(s + 0,  now_ms);
        wr32le(s + 4,  CPU_CLK_HZ);
        wr32le(s + 8,  ETH->RX_FRAMES);
        wr32le(s + 12, ETH->RX_ERRORS);
        wr32le(s + 16, ETH->RX_DROPPED);
        wr32le(s + 20, ETH->TX_FRAMES);
        wr32le(s + 24, HDMI->TMDS_KHZ);
        uint32_t i = 0;
        for (; i < KVM_FW_LEN - 1u && fw_build[i]; i++) s[28 + i] = (uint8_t)fw_build[i];
        for (; i < KVM_FW_LEN; i++) s[28 + i] = 0;
        wr32le(s + 52, ddr_bytes >> 20);
        wr32le(s + 56, video_frames());
        wr32le(s + 60, ETH->VID_PKTS);
        wr32le(s + 64, hdmi_flags());
        wr32le(s + 68, hdmi_res());
        wr32le(s + 72, usb_flags());
        return KVM_HDR_LEN + sizeof(kvm_status_t);
    }
    if (cmd == KVM_CMD_ECHO) {
        uint32_t len = n > max ? max : n;
        for (uint32_t i = KVM_HDR_LEN; i < len; i++) out[i] = in[i];
        return len;
    }
    if (cmd == KVM_CMD_INPUT) {                       /* клавиатура и мышь для удалённого ПК; без ответа */
        usb_input(in + KVM_HDR_LEN, n - KVM_HDR_LEN, now_ms);
        return 0;
    }
    if (cmd == KVM_CMD_UPDATE) {
        kvm_update_t u;
        video_update(peer, in[5] & KVM_UPD_FULL, &u);
        s[0] = u.result;
        s[1] = u.source;
        wr16le(s + 2,  u.upd);
        wr16le(s + 4,  u.tiles);
        wr16le(s + 6,  u.tile_w);
        wr16le(s + 8,  u.tile_h);
        wr16le(s + 10, u.width);
        wr16le(s + 12, u.height);
        wr16le(s + 14, 0);
        wr32le(s + 16, u.updates);
        return KVM_HDR_LEN + sizeof(kvm_update_t);
    }
    return 0;
}

/* ---------- PHY RTL8201F ---------- */
/* Поиск PHY по MDIO и включение режима RXDV на выводе CRS_DV:
 * Page 7 Register 16 (RMSR) бит 2 Rg_rmii_rxdv_sel = 1 (даташит RTL8201F, 7.16; так же делает пример Sipeed).
 * Без этого IP MII to RMII получает CRS_DV, который в конце кадра мигает, и все кадры приходят с ошибкой. */
static void phy_setup(void)
{
    uint32_t addr = 32;
    uint16_t id1 = 0xFFFF, id2 = 0xFFFF;
    for (uint32_t a = 0; a < 32; a++) {
        id1 = mdio_read(a, 2);
        if (id1 != 0xFFFF && id1 != 0x0000) { addr = a; id2 = mdio_read(a, 3); break; }
    }
    if (addr == 32) { put_str("Сеть: ОШИБКА, PHY не отвечает по MDIO\n"); return; }
    (void)id2;

    mdio_write(addr, 31, 7);                    /* страница 7 */
    uint16_t r0 = mdio_read(addr, 16);
    mdio_write(addr, 16, (uint16_t)(r0 | (1u << 2)));
    mdio_write(addr, 31, 0);                    /* страница 0 */

    (void)mdio_read(addr, 1);                   /* BMSR: бит линка защёлкивается - читаем дважды */
    uint16_t bmsr = mdio_read(addr, 1);
    put_str((bmsr & (1u << 2)) ? "Сеть: линк есть\n" : "Сеть: линка нет\n");
}

/* ---------- main ---------- */
static uint32_t rx_words[ETH_MAX_FRAME / 4u];

int main(void)
{
    wbuart_init(CPU_UART_BAUD);
    PICO_WBGPIO->OUT = LED_MASK;    /* все LED погашены */
    PICO_WBGPIO->DIR = LED_MASK;    /* LED - выходы */
    last_cyc = cycles();

    put_str("\nPRIMER_KVM, прошивка "); put_str(fw_build); put_str("\n");

    static const uint8_t mac[6] = NET_MAC_ADDR_BYTES;
    put_str("Сеть: IP ");
    for (int i = 3; i >= 0; i--) { put_u32((NET_IP_ADDR >> (8 * i)) & 0xFFu); if (i) put_str("."); }
    put_str(", UDP "); put_u32(NET_UDP_PORT);
    put_str(", MAC ");
    for (int i = 0; i < 6; i++) { put_hex(mac[i], 2); if (i < 5) put_str(":"); }
    put_str(ETH->ID == ETH_ID_VALUE ? "\n" : " - ОШИБКА, eth_sys не отвечает\n");

    ddr_bytes = ddr_init();
    video_init(ddr_bytes, fw_build);
    hdmi_init();
    usb_init();
    time_update();

    uint32_t rx_ms = 0xFFFF0000u, vid_ms = 0xFFFF0000u, t10 = 0, t_err = 0;
    uint32_t last_err = ETH->RX_ERRORS, last_drop = ETH->RX_DROPPED, last_frames = video_frames();
    int phy_said = 0, phy_done = 0;
    uint32_t phy_ms = 0;

    for (;;) {
        time_update();
        put_poll();                                          /* журнал UART - без ожидания (sys.c) */

        uint32_t len = eth_rx((uint8_t *)rx_words);
        if (len) {
            rx_ms = now_ms;
            net_input((const uint8_t *)rx_words, len);
        }

        if ((uint32_t)(now_ms - t10) < 10u) continue;      /* остальное - раз в 10 мс */
        t10 = now_ms;

        if (!phy_said && eth_phy_ready()) { phy_said = 1; phy_ms = now_ms; }
        if (phy_said && !phy_done && (uint32_t)(now_ms - phy_ms) >= 200u) { phy_done = 1; phy_setup(); }

        if (!ddr_bytes) {                                    /* калибровка DDR3 завершилась позже */
            ddr_bytes = ddr_poll(now_ms);
            if (ddr_bytes) {
                video_init(ddr_bytes, fw_build);
                hdmi_init();
            }
        }

        if (client_on && (uint32_t)(now_ms - client_ms) > 3000u) {
            client_on = 0;
            put_str("Приложение: отключено\n");
        }

        uint32_t frames = video_frames();
        if (frames != last_frames) { last_frames = frames; vid_ms = now_ms; }

        hdmi_poll(now_ms);
        video_poll();
        usb_poll(now_ms);

        uint32_t led = ((now_ms / 500u) & 1u)                                    /* LED0 */
                     | (hdmi_capturing() ? (1u << 1) : 0u)                       /* LED1 */
                     | (ddr_bytes ? (1u << 2) : 0u)                              /* LED2 */
                     | (((uint32_t)(now_ms - vid_ms) < 1000u) ? (1u << 3) : 0u)  /* LED3 */
                     | (((uint32_t)(now_ms - rx_ms) < 1000u) ? (1u << 4) : 0u)   /* LED4 */
                     | (client_on ? (1u << 5) : 0u);                             /* LED5 */
        PICO_WBGPIO->OUT = ~(led << GPIO_LED_SHIFT) & LED_MASK;

        if ((uint32_t)(now_ms - t_err) >= 10000u) {          /* ошибки приёма Ethernet - не чаще раза в 10 с */
            t_err = now_ms;
            uint32_t e = ETH->RX_ERRORS, dr = ETH->RX_DROPPED;
            if (e != last_err || dr != last_drop) {
                put_str("Сеть: ошибок приёма +"); put_u32(e - last_err);
                put_str(", отброшено +"); put_u32(dr - last_drop); put_str("\n");
                last_err = e; last_drop = dr;
            }
        }
    }
}
