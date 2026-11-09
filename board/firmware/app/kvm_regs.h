/* kvm_regs.h - регистры своей периферии на шине Open Wishbone ядра (fpga/rtl/wb_mux.sv):
 * 0x2000_0000 + (слот << 12) - периферия, окна по 4 КБ; 0x3000_0000 - память DDR3. */
#ifndef KVM_REGS_H
#define KVM_REGS_H

#include <stdint.h>
#include "picorv32.h"

#define KVM_WB_SLOT(n)   (OPEN_WB_BASE + ((uint32_t)(n) << 12))

/* Слот 0: hdmi_rx (fpga/rtl/hdmi_rx.sv) - вход HDMI (модуль PMOD_DVI) */
typedef struct {
    volatile uint32_t ID;          /* 0x00 RO  0x48445258 "HDRX" */
    volatile uint32_t CTRL;        /* 0x04 RW  HDMI_CTRL_* (после сброса 0) */
    volatile uint32_t TMDS_KHZ;    /* 0x08 RO  частота пиксельного такта, кГц */
    volatile uint32_t STATUS;      /* 0x0C RO  HDMI_ST_*; запись - сброс HDMI_ST_OVERFLOW и FIFO_MAX */
    volatile uint32_t RES;         /* 0x10 RO  ширина | высота << 16 последнего кадра */
    volatile uint32_t FRAMES;      /* 0x14 RO  принято кадров */
    volatile uint32_t CAP_FRAMES;  /* 0x18 RO  захвачено кадров */
    volatile uint32_t CAP_BASE;    /* 0x1C RW  адрес буфера в DDR3 (кратен 16) */
    volatile uint32_t CAP_STRIDE;  /* 0x20 RW  байт между строками (кратен 16) */
    /* диагностика приёма; счётчики циклические - считать разность двух чтений */
    volatile uint32_t CAP_SIZE;    /* 0x24 RW  ожидаемый кадр: ширина | высота << 16 (0 - не считать ошибки) */
    volatile uint32_t LOCK_LOSS;   /* 0x28 RO  потерь PLL приёмника (биты 15:0) и фазы (31:16) */
    volatile uint32_t BAD_LINES;   /* 0x2C RO  строк с длиной != ширины CAP_SIZE (24 бита) */
    volatile uint32_t BAD_FRAMES;  /* 0x30 RO  кадров с числом строк != высоты CAP_SIZE (24 бита) */
    volatile uint32_t LOST_WORDS;  /* 0x34 RO  слов захвата (8 пикселей), потерянных при полной FIFO (24 бита) */
    volatile uint32_t FIFO_MAX;    /* 0x38 RO  наибольшее заполнение FIFO захвата, слов из 256 */
    volatile uint32_t CAP_BSIZE;   /* 0x3C RW  расстояние между тремя буферами захвата, байт (кратно 16) */
    volatile uint32_t BUF;         /* 0x40 W: HDMI_BUF_LOCK / HDMI_BUF_UNLOCK; R: HDMI_BUF_* */
    volatile uint32_t CAP_HOFS;    /* 0x44 RW  смещение таблицы сумм плиток от начала буфера, байт (кратно 16) */
    uint32_t          reserved[46];
    volatile uint32_t EDID[64];    /* 0x100 RW 256 байт EDID (байт 0 - биты 7:0 слова 0) */
} HDMI_RegDef;

#define HDMI               ((HDMI_RegDef *)KVM_WB_SLOT(0))
#define HDMI_ID_VALUE      0x48445258u
#define HDMI_CTRL_HPD      (1u << 0)
#define HDMI_CTRL_CAP_EN   (1u << 1)
#define HDMI_CTRL_RX_RESET (1u << 2)
#define HDMI_ST_PLL_LOCK   (1u << 0)
#define HDMI_ST_PHASE_LOCK (1u << 1)
#define HDMI_ST_VIDEO      (1u << 2)   /* кадр был < 100 мс назад */
#define HDMI_ST_CAPTURING  (1u << 3)
#define HDMI_ST_DDC        (1u << 4)   /* идёт обмен по DDC */
#define HDMI_ST_OVERFLOW   (1u << 5)   /* FIFO захвата переполнялась */
#define HDMI_ST_PHASE(s)   (((s) >> 8) & 0xFu)
#define HDMI_BUF_LOCK      (1u << 0)   /* запись: закрепить последний готовый кадр за отправкой */
#define HDMI_BUF_UNLOCK    (1u << 1)   /* запись: освободить */
#define HDMI_BUF_BUSY      (1u << 0)   /* чтение: LOCK ещё выполняется */
#define HDMI_BUF_LOCKED    (1u << 1)   /* чтение: буфер закреплён */
#define HDMI_BUF_IDX(s)    (((s) >> 2) & 3u)   /* номер закреплённого буфера */
#define HDMI_BUF_HAS_FRAME (1u << 4)   /* есть готовый кадр */

/* Слот 1: eth_sys (fpga/rtl/eth_sys.sv) */
typedef struct {
    volatile uint32_t ID;          /* 0x00 RO  0x45544831 "ETH1" */
    volatile uint32_t STATUS;      /* 0x04 RO  ETH_ST_* */
    volatile uint32_t RX_LEN;      /* 0x08 RO  длина текущего принятого кадра */
    volatile uint32_t RX_POP;      /* 0x0C WO  освободить текущий кадр */
    volatile uint32_t TX_LEN;      /* 0x10 WO  отправить кадр из буфера передачи */
    volatile uint32_t RX_FRAMES;   /* 0x14 RO */
    volatile uint32_t RX_ERRORS;   /* 0x18 RO */
    volatile uint32_t RX_DROPPED;  /* 0x1C RO */
    volatile uint32_t TX_FRAMES;   /* 0x20 RO  кадров ядра */
    volatile uint32_t MDIO;        /* 0x24 RW  ETH_MDIO_* */
    volatile uint32_t VID_PKTS;    /* 0x28 RO  пакетов видео */
} ETH_RegDef;

#define ETH               ((ETH_RegDef *)KVM_WB_SLOT(1))
#define ETH_BUF           ((volatile uint32_t *)(KVM_WB_SLOT(1) + 0x800u))  /* чтение - RX, запись - TX */
#define ETH_VID_TPL       (ETH_BUF + 448)   /* шаблон заголовка пакета видео: 42 байта (11 слов) */
#define ETH_ID_VALUE      0x45544831u
#define ETH_ST_RX_AVAIL   (1u << 0)
#define ETH_ST_TX_BUSY    (1u << 1)
#define ETH_ST_PHY_READY  (1u << 2)
#define ETH_MDIO_MDC      (1u << 0)   /* линия MDC */
#define ETH_MDIO_OUT      (1u << 1)   /* 0 - тянуть MDIO в 0, 1 - отпустить */
#define ETH_MDIO_IN       (1u << 8)   /* чтение: состояние линии MDIO */

/* Слот 2: video_tx (fpga/rtl/video_tx.sv) - передача плиток по списку. Всё, кроме CTRL, менять при BUSY = 0. */
typedef struct {
    volatile uint32_t ID;          /* 0x00 RO  0x56545832 "VTX2" */
    volatile uint32_t CTRL;        /* 0x04 WO  VTX_CTRL_START */
    volatile uint32_t STATUS;      /* 0x08 RO  VTX_ST_BUSY */
    volatile uint32_t FB_BASE;     /* 0x0C RW  байтовый адрес кадра в DDR3, кратен 16 */
    volatile uint32_t STRIDE;      /* 0x10 RW  байт между строками, кратен 16 */
    volatile uint32_t SIZE;        /* 0x14 RW  ширина | высота << 16 */
    volatile uint32_t FRAMES;      /* 0x18 RO  выполнено передач (обновлений) */
    volatile uint32_t PKT_INFO;    /* 0x1C RO  пикселей в пакете (плитке) | длина пакета << 16 */
    volatile uint32_t LIST_ADDR;   /* 0x20 WO  номер записи списка для LIST_DATA */
    volatile uint32_t LIST_DATA;   /* 0x24 WO  VTX_TILE(столбец, ряд); номер записи затем +1 */
    volatile uint32_t COUNT;       /* 0x28 RW  плиток в передаче */
    volatile uint32_t UPD;         /* 0x2C RW  номер обновления в заголовке пакетов */
} VTX_RegDef;

#define VTX               ((VTX_RegDef *)KVM_WB_SLOT(2))
#define VTX_ID_VALUE      0x56545832u
#define VTX_LIST_LEN      4096u
#define VTX_TILE(c, r)    ((uint32_t)(c) | ((uint32_t)(r) << 8))   /* столбец и ряд плитки - до 127 */
#define VTX_CTRL_START    (1u << 0)
#define VTX_ST_BUSY       (1u << 0)

/* Слот 3: ddr_arb (fpga/rtl/ddr_arb.sv) */
typedef struct {
    volatile uint32_t ID;          /* 0x00 RO  0x44445233 "DDR3" */
    volatile uint32_t STATUS;      /* 0x04 RO  DDR_ST_* */
    volatile uint32_t SIZE_MB;     /* 0x08 RO  объём, МБ */
    volatile uint32_t DCLK_KHZ;    /* 0x0C RO  такт пользователя DDR3 (clk_out IP), кГц */
} DDR_RegDef;

#define DDR               ((DDR_RegDef *)KVM_WB_SLOT(3))
#define DDR_ID_VALUE      0x44445233u
#define DDR_ST_READY      (1u << 0)   /* калибровка завершена */
#define DDR_ST_PLL_LOCK   (1u << 1)   /* PLL памяти захвачен */
#define DDR_ST_IP_RST     (1u << 2)   /* IP в сбросе (ddr_rst) */

/* Память DDR3: 32-битные слова; запись байтами/полусловами тоже работает (маска байтов IP).
 * Запись отложенная (~0.2 мкс), чтение ждёт данных (~0.5 мкс). */
#define DDR_MEM_BASE      0x30000000u
#define DDR_MEM           ((volatile uint32_t *)DDR_MEM_BASE)

/* Слот 4: usb_hid (fpga/rtl/usb_hid.sv) - USB-клавиатура и мышь для удалённого ПК */
typedef struct {
    volatile uint32_t ID;          /* 0x00 RO  0x55534248 "USBH" */
    volatile uint32_t CTRL;        /* 0x04 WO  USB_CTRL_KBD / USB_CTRL_MOUSE - отправить отчёт */
    volatile uint32_t STATUS;      /* 0x08 RO  USB_ST_*, светодиоды - биты 15:8, сбросы шины - 23:16 */
    volatile uint32_t KBD0;        /* 0x0C RW  отчёт клавиатуры, байты 0..3 */
    volatile uint32_t KBD1;        /* 0x10 RW  байты 4..7 */
    volatile uint32_t MOUSE0;      /* 0x14 RW  отчёт мыши, байты 0..3 */
    volatile uint32_t MOUSE1;      /* 0x18 RW  байты 4..6 */
} USB_RegDef;

#define USB               ((USB_RegDef *)KVM_WB_SLOT(4))
#define USB_ID_VALUE      0x55534248u
#define USB_CTRL_KBD      (1u << 0)
#define USB_CTRL_MOUSE    (1u << 1)
#define USB_ST_ONLINE     (1u << 0)   /* устройство сконфигурировано хостом */
#define USB_ST_HIGHSPEED  (1u << 1)
#define USB_ST_SUSPEND    (1u << 2)
#define USB_ST_KBD_PEND   (1u << 3)   /* отчёт клавиатуры ещё не забран хостом */
#define USB_ST_MOUSE_PEND (1u << 4)
#define USB_ST_BOOT       (1u << 5)   /* клавиатура в режиме boot (BIOS) */
#define USB_ST_LEDS(s)    (((s) >> 8) & 0xFFu)

#endif /* KVM_REGS_H */
