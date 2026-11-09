/* video.c - буферы кадра в DDR3 и передача кадра на ПК (fpga/rtl/video_tx.sv).
 * Кадр RGB565, VIDEO_H_ACTIVE x VIDEO_V_ACTIVE. Буферы с начала DDR3, через FB_BSIZE (кратно 1 МБ):
 *   0, 1, 2 - буферы захвата HDMI (тройная буферизация в hdmi_rx.sv: захват пишет в свободный, отправка
 *             закрепляет последний полный кадр - разрывов и битых кадров нет);
 *   3       - тестовая картинка: рисуется при старте, передаётся, пока захват выключен.
 * Передача - обновлениями из плиток 32x16 (video_update, протокол - kvm_proto.h): в буфере захвата за кадром
 * (FB_HOFS) - таблица CRC-32 плиток от hdmi_rx (ряды сверху вниз, по 4 плитки в 16-байтном слове). Прошивка
 * сравнивает её с таблицей плиток, которые есть у ПК (FB_PREV), пишет список изменившихся плиток в video_tx и
 * запускает передачу; KVM_UPD_FULL и смена источника (тестовая картинка / захват) - все плитки. Закреплённый
 * буфер захвата освобождает video_poll(), когда передача закончилась. */
#include "video.h"
#include "kvm_regs.h"
#include "kvm_proto.h"
#include "sys.h"
#include "hdmi.h"

#define FB_OFFSET  0u
#define FB_W       VIDEO_H_ACTIVE
#define FB_H       VIDEO_V_ACTIVE
#define FB_STRIDE  (FB_W * 2u)
#define FB_BSIZE   ((FB_STRIDE * FB_H + 0xFFFFFu) & ~0xFFFFFu)   /* шаг буферов, кратен 1 МБ */
#define FB_TEST    (FB_OFFSET + 3u * FB_BSIZE)                   /* буфер тестовой картинки */
#define FB_HOFS    (FB_STRIDE * FB_H)                            /* таблица сумм плиток в буфере захвата */
#define TILE_W     32u
#define TILE_H     16u
#define T_COLS     (FB_W / TILE_W)
#define T_ROWS     ((FB_H + TILE_H - 1u) / TILE_H)
#define T_GRP      ((T_COLS + 3u) / 4u)                          /* 16-байтных слов таблицы на ряд плиток */
#define FB_PREV    (FB_OFFSET + 4u * FB_BSIZE)                   /* суммы плиток, которые есть у ПК */
#if FB_HOFS % 16u != 0u || FB_HOFS + T_ROWS * T_GRP * 16u > FB_BSIZE || FB_W % TILE_W != 0u || \
    T_COLS * T_ROWS > VTX_LIST_LEN || T_ROWS > 127u
#error "буфер кадра: таблица сумм плиток не помещается, ширина не кратна 32 или слишком много плиток"
#endif

#define RGB(r, g, b) ((uint16_t)((((r) >> 3) << 11) | (((g) >> 2) << 5) | ((b) >> 3)))

static volatile uint32_t *const fb = (volatile uint32_t *)(DDR_MEM_BASE + FB_TEST);
static int fb_ok, fb_locked;
static int      pc_src = -1;   /* что есть у ПК: -1 - ничего, 0 - тестовая картинка, 1 - захват (суммы в FB_PREV) */
static uint16_t upd_no;

/* ---------- Рисование: 32-битные записи, по 2 пикселя (x и ширины чётные) ---------- */
static volatile uint32_t *px_addr(uint32_t x, uint32_t y)
{
    return fb + ((y * FB_STRIDE + x * 2u) >> 2);
}

static void rect(uint32_t x, uint32_t y, uint32_t w, uint32_t h, uint16_t c)
{
    uint32_t v = c | ((uint32_t)c << 16);
    for (uint32_t j = 0; j < h; j++) {
        volatile uint32_t *p = px_addr(x, y + j);
        for (uint32_t i = 0; i < w / 2u; i++) p[i] = v;
    }
}

/* Строка y: n ступеней по ширине кадра, цвет ступени k - color(k) */
static void steps(uint32_t y0, uint32_t h, uint32_t n, uint16_t (*color)(uint32_t))
{
    for (uint32_t k = 0; k < n; k++) {
        uint32_t x0 = (FB_W * k / n) & ~1u, x1 = (FB_W * (k + 1u) / n) & ~1u;
        rect(x0, y0, x1 - x0, h, color(k));
    }
}

static uint16_t c_red(uint32_t k)   { return (uint16_t)(k << 11); }           /* 32 ступени */
static uint16_t c_green(uint32_t k) { return (uint16_t)(k << 5); }            /* 64 ступени */
static uint16_t c_blue(uint32_t k)  { return (uint16_t)k; }                   /* 32 ступени */
static uint16_t c_gray(uint32_t k)  { uint32_t v = k * 255u / 15u; return RGB(v, v, v); }  /* 16 ступеней */

/* ---------- Шрифт 5x7 (столбцы, бит 0 - верхняя строка) ---------- */
static const uint8_t font[][5] = {
    {0x3E,0x51,0x49,0x45,0x3E}, {0x00,0x42,0x7F,0x40,0x00}, {0x42,0x61,0x51,0x49,0x46}, {0x21,0x41,0x45,0x4B,0x31}, /* 0-3 */
    {0x18,0x14,0x12,0x7F,0x10}, {0x27,0x45,0x45,0x45,0x39}, {0x3C,0x4A,0x49,0x49,0x30}, {0x01,0x71,0x09,0x05,0x03}, /* 4-7 */
    {0x36,0x49,0x49,0x49,0x36}, {0x06,0x49,0x49,0x29,0x1E},                                                         /* 8-9 */
    {0x7E,0x11,0x11,0x11,0x7E}, {0x7F,0x49,0x49,0x49,0x36}, {0x3E,0x41,0x41,0x41,0x22}, {0x7F,0x41,0x41,0x22,0x1C}, /* A-D */
    {0x7F,0x49,0x49,0x49,0x41}, {0x7F,0x09,0x09,0x09,0x01}, {0x3E,0x41,0x49,0x49,0x7A}, {0x7F,0x08,0x08,0x08,0x7F}, /* E-H */
    {0x00,0x41,0x7F,0x41,0x00}, {0x20,0x40,0x41,0x3F,0x01}, {0x7F,0x08,0x14,0x22,0x41}, {0x7F,0x40,0x40,0x40,0x40}, /* I-L */
    {0x7F,0x02,0x0C,0x02,0x7F}, {0x7F,0x04,0x08,0x10,0x7F}, {0x3E,0x41,0x41,0x41,0x3E}, {0x7F,0x09,0x09,0x09,0x06}, /* M-P */
    {0x3E,0x41,0x51,0x21,0x5E}, {0x7F,0x09,0x19,0x29,0x46}, {0x46,0x49,0x49,0x49,0x31}, {0x01,0x01,0x7F,0x01,0x01}, /* Q-T */
    {0x3F,0x40,0x40,0x40,0x3F}, {0x1F,0x20,0x40,0x20,0x1F}, {0x3F,0x40,0x38,0x40,0x3F}, {0x63,0x14,0x08,0x14,0x63}, /* U-X */
    {0x07,0x08,0x70,0x08,0x07}, {0x61,0x51,0x49,0x45,0x43},                                                         /* Y-Z */
    {0x00,0x00,0x00,0x00,0x00}, {0x08,0x08,0x08,0x08,0x08}, {0x00,0x60,0x60,0x00,0x00}, {0x00,0x36,0x36,0x00,0x00}, /* ' ' - . : */
};

static const uint8_t *glyph(char c)
{
    if (c >= 'a' && c <= 'z') c = (char)(c - 'a' + 'A');
    if (c >= '0' && c <= '9') return font[c - '0'];
    if (c >= 'A' && c <= 'Z') return font[10 + (c - 'A')];
    if (c == '-') return font[37];
    if (c == '.') return font[38];
    if (c == ':') return font[39];
    return font[36];
}

static uint32_t slen(const char *s) { uint32_t n = 0; while (s[n]) n++; return n; }

/* Текст: ячейка 6x8 точек, каждая точка - scale x scale пикселей; x чётный */
static void text(uint32_t x, uint32_t y, const char *s, uint32_t scale, uint16_t fg, uint16_t bg)
{
    uint32_t n = slen(s);
    for (uint32_t ry = 0; ry < 8u * scale; ry++) {
        uint32_t row = ry / scale;
        volatile uint32_t *p = px_addr(x, y + ry);
        uint32_t pend = 0, have = 0;
        for (uint32_t i = 0; i < n; i++) {
            const uint8_t *g = glyph(s[i]);
            for (uint32_t col = 0; col < 6u; col++) {
                uint16_t c = (col < 5u && row < 7u && ((g[col] >> row) & 1u)) ? fg : bg;
                for (uint32_t k = 0; k < scale; k++) {
                    if (have) { *p++ = pend | ((uint32_t)c << 16); have = 0; }
                    else      { pend = c; have = 1; }
                }
            }
        }
    }
}

static char *cat(char *d, const char *s) { while (*s) *d++ = *s++; *d = 0; return d; }

static char *cat_u32(char *d, uint32_t v)
{
    char b[11];
    int i = 10;
    b[i] = 0;
    do { b[--i] = (char)('0' + v % 10u); v /= 10u; } while (v);
    return cat(d, &b[i]);
}

/* ---------- Тестовая картинка ---------- */
static void test_pattern(uint32_t ddr_bytes, const char *fw_build)
{
    static const uint16_t bars[8] = {
        RGB(255,255,255), RGB(255,255,0), RGB(0,255,255), RGB(0,255,0),
        RGB(255,0,255),   RGB(255,0,0),   RGB(0,0,255),   RGB(0,0,0)
    };
    const uint32_t hb = FB_H * 2u / 3u;           /* цветные полосы */
    const uint32_t hs = (FB_H - hb) / 4u;         /* 4 полосы ступеней */

    for (uint32_t k = 0; k < 8u; k++) {
        uint32_t x0 = (FB_W * k / 8u) & ~1u, x1 = (FB_W * (k + 1u) / 8u) & ~1u;
        rect(x0, 0, x1 - x0, hb, bars[k]);
    }
    steps(hb,           hs, 32u, c_red);
    steps(hb + hs,      hs, 64u, c_green);
    steps(hb + 2u * hs, hs, 32u, c_blue);
    steps(hb + 3u * hs, FB_H - hb - 3u * hs, 16u, c_gray);

    /* рамка 2 пикселя: края кадра должны быть видны целиком */
    const uint16_t w = RGB(255,255,255);
    rect(0, 0, FB_W, 2, w);
    rect(0, FB_H - 2u, FB_W, 2, w);
    rect(0, 0, 2, FB_H, w);
    rect(FB_W - 2u, 0, 2, FB_H, w);

    /* надписи в чёрном окне по центру полос */
    char l2[32], l3[40];
    char *e = cat(l2, "DDR3 ");
    e = cat_u32(e, ddr_bytes >> 20);
    cat(e, " MB OK");
    e = cat(l3, "FW ");
    cat(e, fw_build);
    const char *l1 = "PRIMER KVM";
    uint32_t w1 = slen(l1) * 48u, w2 = slen(l2) * 24u, w3 = slen(l3) * 18u;
    uint32_t bw = w1 > w3 ? w1 : w3;
    if (w2 > bw) bw = w2;
    bw += 64u;
    const uint32_t bh = 64u + 16u + 32u + 16u + 24u + 64u;
    if (bw > FB_W || bh > hb) return;
    uint32_t bx = ((FB_W - bw) / 2u) & ~1u, by = (hb - bh) / 2u;
    const uint16_t k = RGB(0,0,0);
    rect(bx - 4u, by - 4u, bw + 8u, bh + 8u, w);
    rect(bx, by, bw, bh, k);
    text((bx + (bw - w1) / 2u) & ~1u, by + 32u, l1, 8u, w, k);
    text((bx + (bw - w2) / 2u) & ~1u, by + 32u + 64u + 16u, l2, 4u, RGB(0,255,0), k);
    text((bx + (bw - w3) / 2u) & ~1u, by + 32u + 64u + 16u + 32u + 16u, l3, 3u, RGB(160,160,160), k);
}

void video_init(uint32_t ddr_bytes, const char *fw_build)
{
    if (VTX->ID != VTX_ID_VALUE) { put_str("Видео: ОШИБКА, video_tx не отвечает\n"); return; }
    if (ddr_bytes < FB_PREV + 4u * T_COLS * T_ROWS) { put_str("Видео: нет DDR3, кадр не передаётся\n"); return; }

    VTX->FB_BASE = FB_TEST;
    VTX->STRIDE  = FB_STRIDE;
    VTX->SIZE    = FB_W | (FB_H << 16);

    test_pattern(ddr_bytes, fw_build);
    fb_ok = 1;
}

/* ---------- Плитки ---------- */
static uint32_t ddr_rd(uint32_t ofs) { return DDR_MEM[ofs >> 2]; }

/* Сумма плитки (r, c) из таблицы FPGA в буфере base */
static uint32_t tile_hw(uint32_t base, uint32_t r, uint32_t c)
{
    return ddr_rd(base + FB_HOFS + (r * T_GRP + c / 4u) * 16u + (c % 4u) * 4u);
}

void video_update(const net_peer_t *peer, int full, kvm_update_t *u)
{
    u->result  = KVM_UPD_STARTED;
    u->source  = 0;
    u->upd     = upd_no;
    u->tiles   = 0;
    u->tile_w  = TILE_W;
    u->tile_h  = TILE_H;
    u->width   = FB_W;
    u->height  = FB_H;
    u->reserved = 0;
    u->updates = VTX->FRAMES;
    if (!fb_ok) { u->result = KVM_UPD_NO_VIDEO; return; }
    if (VTX->STATUS & VTX_ST_BUSY) { u->result = KVM_UPD_BUSY; return; }
    if (fb_locked) { hdmi_unlock_frame(); fb_locked = 0; }

    /* источник: последний полный кадр захвата (закрепляется до конца передачи) или тестовая картинка */
    uint32_t idx, base = FB_TEST;
    int src = 0;
    if (hdmi_lock_frame(&idx)) {
        base = FB_OFFSET + idx * FB_BSIZE;
        fb_locked = 1;
        src = 1;
    }

    /* список плиток: все (KVM_UPD_FULL, смена источника) или изменившиеся с прошлого обновления */
    int all = full || src != pc_src;
    uint32_t n = 0, i = 0;
    volatile uint32_t *prev = DDR_MEM + (FB_PREV >> 2);
    VTX->LIST_ADDR = 0;
    for (uint32_t r = 0; r < T_ROWS; r++) {
        for (uint32_t c = 0; c < T_COLS; c++, i++) {
            if (src) {
                uint32_t h = tile_hw(base, r, c);
                if (!all && prev[i] == h) continue;
                prev[i] = h;
            } else if (!all) {
                continue;
            }
            VTX->LIST_DATA = VTX_TILE(c, r);
            n++;
        }
    }
    pc_src = src;
    upd_no++;
    u->source = (uint8_t)src;
    u->upd    = upd_no;
    u->tiles  = (uint16_t)n;
    if (!n) {                                     /* изменений нет - пакетов не будет */
        if (fb_locked) { hdmi_unlock_frame(); fb_locked = 0; }
        return;
    }

    VTX->FB_BASE = base;
    VTX->COUNT   = n;
    VTX->UPD     = upd_no;
    uint32_t hdr[12];
    for (uint32_t k = 0; k < 12u; k++) hdr[k] = 0;
    net_udp_header((uint8_t *)hdr, peer, (VTX->PKT_INFO >> 16) - NET_HDR_LEN);
    for (uint32_t k = 0; k < 11u; k++) ETH_VID_TPL[k] = hdr[k];
    VTX->CTRL = VTX_CTRL_START;
}

uint32_t video_frames(void) { return VTX->FRAMES; }

void video_poll(void)
{
    if (fb_locked && !(VTX->STATUS & VTX_ST_BUSY)) { hdmi_unlock_frame(); fb_locked = 0; }
}

int      video_ready(void)     { return fb_ok; }
uint32_t video_fb_base(void)   { return FB_OFFSET; }
uint32_t video_fb_stride(void) { return FB_STRIDE; }
uint32_t video_fb_bsize(void)  { return FB_BSIZE; }
uint32_t video_fb_hofs(void)   { return FB_HOFS; }
