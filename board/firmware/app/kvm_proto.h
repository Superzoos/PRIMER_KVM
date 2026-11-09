/* kvm_proto.h - протокол KVM поверх UDP (порт NET_UDP_PORT). Все поля - little-endian.
 * Та же структура - в host-app/KvmClient/KvmLink.cs.
 *
 * Управление. Заголовок (8 байт): magic u32 = "KVM1", cmd u8, flags u8 (0), seq u16.
 * Ответ: тот же заголовок, cmd | KVM_REPLY, тот же seq.
 *   KVM_CMD_STATUS - запрос без данных; ответ - kvm_status_t.
 *   KVM_CMD_ECHO   - ответ повторяет данные запроса.
 *   KVM_CMD_UPDATE - обновление изображения на адрес и порт отправителя запроса; ответ - kvm_update_t.
 *                    flags запроса: KVM_UPD_FULL - все плитки (при старте и после потери пакета).
 *                    Иначе - только плитки, изменившиеся с прошлого обновления (по CRC-32 плиток от FPGA).
 *                    Если result = KVM_UPD_STARTED и tiles > 0, следом (или до ответа) приходят tiles пакетов
 *                    плиток; все плитки обновления - из одного полного кадра. Приложение применяет обновление
 *                    целиком, когда получены все tiles пакетов; если нет - просит KVM_UPD_FULL.
 *
 * Пакеты плиток (fpga/rtl/video_tx.sv): заголовок 22 байта, затем tile_w * tile_h пикселей RGB565 (u16),
 * строки плитки сверху вниз. magic u32 = "KVT1", upd u16, tx u16, ty u16 (столбец и ряд плитки),
 * index u16 (номер пакета в обновлении), count u16 (пакетов в обновлении), width u16, height u16 (кадр),
 * format u16 (1 = RGB565), flags u16 (бит 0 - последний пакет обновления). */
#ifndef KVM_PROTO_H
#define KVM_PROTO_H

#include <stdint.h>

#define KVM_MAGIC        0x314D564Bu   /* байты 'K','V','M','1' */
#define KVM_TILE_MAGIC   0x3154564Bu   /* байты 'K','V','T','1' */
#define KVM_HDR_LEN      8u
#define KVM_CMD_STATUS   0x01u
#define KVM_CMD_ECHO     0x02u
#define KVM_CMD_UPDATE   0x04u
#define KVM_CMD_INPUT    0x05u         /* состояние клавиатуры и мыши, kvm_input_t; ответа нет */
#define KVM_UPD_FULL     0x01u         /* flags запроса UPDATE */
#define KVM_REPLY        0x80u
#define KVM_FW_LEN       24u

typedef struct {
    uint32_t uptime_ms;
    uint32_t cpu_hz;
    uint32_t rx_frames;
    uint32_t rx_errors;
    uint32_t rx_dropped;
    uint32_t tx_frames;
    uint32_t tmds_khz;         /* пиксельный такт HDMI, кГц */
    char     fw[KVM_FW_LEN];   /* дата и время сборки прошивки, с нулём в конце */
    uint32_t ddr_mb;           /* объём DDR3, прошедшей проверку при старте; 0 - ошибка */
    uint32_t vid_frames;       /* выполнено обновлений */
    uint32_t vid_packets;      /* передано пакетов плиток */
    uint32_t hdmi_flags;       /* бит 0 PLL, 1 фаза, 2 кадры идут, 3 захват идёт, 4 HPD, 5 захват включён */
    uint32_t hdmi_res;         /* ширина | высота << 16 последнего принятого кадра */
    uint32_t usb_flags;        /* биты 15:0 - usb_hid STATUS (USB_ST_*, светодиоды); бит 16 - управление включено */
} kvm_status_t;                /* 76 байт */
_Static_assert(sizeof(kvm_status_t) == 76, "kvm_status_t");

/* KVM_CMD_INPUT: полное состояние клавиатуры и мыши (не изменения) - потеря пакета не страшна, следующий его
 * исправит. ПК шлёт пакет при каждом изменении и не реже 20 раз в секунду, пока управление включено; нет пакетов
 * 0.5 с или ACTIVE = 0 - плата отпускает все клавиши и кнопки. */
#define KVM_IN_ACTIVE    0x01u         /* flags: управление включено */
typedef struct {
    uint8_t  flags;            /* KVM_IN_* */
    uint8_t  mods;             /* модификаторы HID: 0 LCtrl, 1 LShift, 2 LAlt, 3 LGui, 4 RCtrl, 5 RShift, 6 RAlt, 7 RGui */
    uint8_t  keys[6];          /* коды нажатых клавиш (HID Usage Page 0x07), 0 - нет */
    uint8_t  buttons;          /* мышь: 0 левая, 1 правая, 2 средняя, 3 назад, 4 вперёд */
    uint8_t  reserved;
    uint16_t x, y;             /* 0..32767 - весь экран удалённого ПК */
    uint8_t  wheel;            /* счётчик щелчков колеса (накопительный, по модулю 256): плата берёт разность */
    uint8_t  pan;              /* то же, горизонтальная прокрутка */
} kvm_input_t;                 /* 16 байт */
_Static_assert(sizeof(kvm_input_t) == 16, "kvm_input_t");

#define KVM_UPD_STARTED     0u   /* обновление передаётся (или пустое: tiles = 0) */
#define KVM_UPD_BUSY        1u   /* предыдущее обновление ещё передаётся */
#define KVM_UPD_NO_VIDEO    2u   /* буфер кадра недоступен (ошибка DDR3) */

typedef struct {
    uint8_t  result;           /* KVM_UPD_* */
    uint8_t  source;           /* 0 - тестовая картинка, 1 - захват HDMI */
    uint16_t upd;              /* номер обновления (поле upd пакетов) */
    uint16_t tiles;            /* пакетов плиток в обновлении */
    uint16_t tile_w;
    uint16_t tile_h;
    uint16_t width;
    uint16_t height;
    uint16_t reserved;
    uint32_t updates;          /* выполнено обновлений до этого запроса */
} kvm_update_t;                /* 20 байт */
_Static_assert(sizeof(kvm_update_t) == 20, "kvm_update_t");

#endif /* KVM_PROTO_H */
