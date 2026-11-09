/* usb.c - USB-клавиатура и мышь для удалённого ПК (fpga/rtl/usb_hid.sv, протокол - kvm_proto.h, KVM_CMD_INPUT).
 * Приложение на ПК присылает полное состояние клавиатуры и мыши; прошивка отправляет отчёт HID, только когда
 * он изменился. Колесо и горизонтальная прокрутка приходят накопительными счётчиками: в отчёт идёт разность с
 * прошлым пакетом (повтор пакета не крутит колесо второй раз); если прошлый отчёт мыши ещё не забран хостом,
 * разность добавляется к нему. Нет пакетов 0.5 с или ACTIVE = 0 - все клавиши и кнопки отпускаются. */
#include "usb.h"
#include "kvm_regs.h"
#include "kvm_proto.h"
#include "sys.h"

#define TIMEOUT_MS 500u

static int      ok, active, have_ctr;
static uint8_t  kbd[8], ms[7], wheel_ctr, pan_ctr;
static int32_t  wacc, pacc;
static uint32_t last_ms, last_st = 0xFFFFFFFFu;

static uint32_t le32(const uint8_t *b) { return b[0] | (b[1] << 8) | (b[2] << 16) | ((uint32_t)b[3] << 24); }

static void send_kbd(void)
{
    USB->KBD0 = le32(&kbd[0]);
    USB->KBD1 = le32(&kbd[4]);
    USB->CTRL = USB_CTRL_KBD;
}

static void send_mouse(void)
{
    USB->MOUSE0 = le32(&ms[0]);
    USB->MOUSE1 = ms[4] | (ms[5] << 8) | (ms[6] << 16);
    USB->CTRL   = USB_CTRL_MOUSE;
}

/* Отпустить все клавиши и кнопки (координаты мыши остаются) */
static void release(void)
{
    int k = 0;
    for (uint32_t i = 0; i < 8u; i++) { k |= kbd[i]; kbd[i] = 0; }
    if (k) send_kbd();
    if (ms[0] | ms[5] | ms[6]) { ms[0] = 0; ms[5] = 0; ms[6] = 0; send_mouse(); }
    wacc = pacc = 0;
}

static int8_t clamp8(int32_t v) { return (int8_t)(v > 127 ? 127 : v < -127 ? -127 : v); }

void usb_init(void)
{
    if (USB->ID != USB_ID_VALUE) { put_str("USB: ОШИБКА, usb_hid не отвечает\n"); return; }
    ok = 1;
}

void usb_input(const uint8_t *p, uint32_t n, uint32_t now_ms)
{
    if (!ok || n < sizeof(kvm_input_t)) return;
    last_ms = now_ms;
    if (!(p[0] & KVM_IN_ACTIVE)) {
        if (active) { release(); active = 0; put_str("USB: управление выключено\n"); }
        return;
    }
    if (!active) { active = 1; have_ctr = 0; put_str("USB: управление включено\n"); }

    /* клавиатура: модификаторы, 0, 6 клавиш */
    uint8_t k[8] = { p[1], 0, p[2], p[3], p[4], p[5], p[6], p[7] };
    int kch = 0;
    for (uint32_t i = 0; i < 8u; i++) { kch |= k[i] != kbd[i]; kbd[i] = k[i]; }
    if (kch) send_kbd();

    /* мышь: кнопки, X, Y; колесо - разность счётчиков */
    int8_t dw = 0, dp = 0;
    if (have_ctr) { dw = (int8_t)(uint8_t)(p[14] - wheel_ctr); dp = (int8_t)(uint8_t)(p[15] - pan_ctr); }
    wheel_ctr = p[14];
    pan_ctr   = p[15];
    have_ctr  = 1;
    if (!(USB->STATUS & USB_ST_MOUSE_PEND)) { wacc = 0; pacc = 0; }   /* прошлый отчёт забран */
    wacc += dw;
    pacc += dp;
    uint8_t m[7] = { (uint8_t)(p[8] & 0x1Fu), p[10], p[11], p[12], p[13], (uint8_t)clamp8(wacc), (uint8_t)clamp8(pacc) };
    int mch = dw || dp;
    for (uint32_t i = 0; i < 5u; i++) mch |= m[i] != ms[i];
    for (uint32_t i = 0; i < 7u; i++) ms[i] = m[i];
    if (mch) send_mouse();
}

void usb_poll(uint32_t now_ms)
{
    if (!ok) return;
    if (active && (uint32_t)(now_ms - last_ms) > TIMEOUT_MS) {
        release();
        active = 0;
        put_str("USB: нет команд от приложения 0.5 с - клавиши и кнопки отпущены\n");
    }
    uint32_t st = USB->STATUS & (USB_ST_ONLINE | USB_ST_HIGHSPEED | USB_ST_SUSPEND);
    if (st != last_st) {
        last_st = st;
        if (!(st & USB_ST_ONLINE)) put_str("USB: не подключено к удалённому ПК\n");
        else {
            put_str((st & USB_ST_HIGHSPEED) ? "USB: подключено к удалённому ПК (High Speed" : "USB: подключено к удалённому ПК (Full Speed");
            put_str((st & USB_ST_SUSPEND) ? ", ПК в спящем режиме)\n" : ")\n");
        }
    }
}

uint32_t usb_flags(void)
{
    if (!ok) return 0;
    return (USB->STATUS & 0xFFFFu) | (active ? (1u << 16) : 0u);
}
