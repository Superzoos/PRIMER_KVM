/* hdmi.c - вход HDMI (fpga/rtl/hdmi_rx.sv): EDID, HPD, переключение буфера кадра между захватом и
 * тестовой картинкой.
 *   Старт: HPD = 0, EDID (edid_data.h) в память hdmi_rx, проверка, HPD = 1 - источник читает EDID.
 *   Сигнал годен: PLL и фаза приёмника захвачены, кадры идут, размер VIDEO_H_ACTIVE x VIDEO_V_ACTIVE.
 *   Годен GOOD_MS подряд - захват включается; не годен дольше LOST_MS - передаётся тестовая картинка.
 *   Передача кадра закрепляет последний полный кадр захвата: hdmi_lock_frame() / hdmi_unlock_frame(). */
#include "hdmi.h"
#include "kvm_regs.h"
#include "kvm_config.h"
#include "edid_data.h"
#include "sys.h"
#include "video.h"

#define GOOD_MS  200u
#define LOST_MS  1000u

static int      present, capture, bad, good;
static uint32_t t_good, t_bad, last_res, t_res;

static uint32_t rd32le(const uint8_t *p)
{
    return (uint32_t)p[0] | ((uint32_t)p[1] << 8) | ((uint32_t)p[2] << 16) | ((uint32_t)p[3] << 24);
}

static void put_res(uint32_t res)
{
    put_u32(res & 0xFFFFu); put_str("x"); put_u32(res >> 16);
}

void hdmi_init(void)
{
    if (HDMI->ID != HDMI_ID_VALUE) { put_str("HDMI: ОШИБКА, hdmi_rx не отвечает\n"); return; }
    HDMI->CTRL = 0;                                       /* HPD = 0, пока EDID не загружен */
    for (uint32_t i = 0; i < 64u; i++)
        HDMI->EDID[i] = (4u * i < EDID_LEN) ? rd32le(&edid_data[4u * i]) : 0u;
    for (uint32_t i = 0; i < EDID_LEN / 4u; i++) {
        if (HDMI->EDID[i] != rd32le(&edid_data[4u * i])) { put_str("HDMI: ОШИБКА, EDID не записался\n"); return; }
    }
    HDMI->CAP_BASE   = video_fb_base();
    HDMI->CAP_STRIDE = video_fb_stride();
    HDMI->CAP_SIZE   = VIDEO_H_ACTIVE | (VIDEO_V_ACTIVE << 16);
    HDMI->CAP_BSIZE  = video_fb_bsize();
    HDMI->CAP_HOFS   = video_fb_hofs();
    HDMI->CTRL = HDMI_CTRL_HPD;
    present = 1;
    put_str("HDMI: EDID "); put_u32(VIDEO_H_ACTIVE); put_str("x"); put_u32(VIDEO_V_ACTIVE);
    put_str(", "); put_u32(VIDEO_PIXEL_CLK_HZ / 1000u); put_str(" кГц\n");
}

void hdmi_poll(uint32_t now_ms)
{
    if (!present) return;
    uint32_t st  = HDMI->STATUS;
    uint32_t res = HDMI->RES;
    const uint32_t want = VIDEO_H_ACTIVE | (VIDEO_V_ACTIVE << 16);
    int video = (st & HDMI_ST_PLL_LOCK) && (st & HDMI_ST_PHASE_LOCK) && (st & HDMI_ST_VIDEO);
    int ok    = video && res == want && video_ready();

    /* неподдерживаемый размер кадра - не чаще раза в секунду */
    if (video && res != want && res != last_res && (uint32_t)(now_ms - t_res) >= 1000u) {
        put_str("HDMI: кадр "); put_res(res); put_str(" не поддерживается (нужен "); put_res(want); put_str(")\n");
        t_res = now_ms;
    }
    last_res = video ? res : 0;

    if (!capture) {
        if (ok) {
            if (!good) { good = 1; t_good = now_ms; }
            if ((uint32_t)(now_ms - t_good) >= GOOD_MS) {
                HDMI->CTRL = HDMI_CTRL_HPD | HDMI_CTRL_CAP_EN;
                capture = 1;
                bad = 0;
                put_str("HDMI: сигнал "); put_res(res); put_str(", захват\n");
            }
        } else {
            good = 0;
        }
    } else {
        if (ok) {
            bad = 0;
        } else {
            if (!bad) { bad = 1; t_bad = now_ms; }
            if ((uint32_t)(now_ms - t_bad) > LOST_MS) {
                HDMI->CTRL = HDMI_CTRL_HPD;               /* захват выключится с началом кадра */
                capture = 0;
                good = 0;
                put_str("HDMI: нет сигнала - тестовая картинка\n");
            }
        }
    }
}

int hdmi_capturing(void) { return capture; }

int hdmi_lock_frame(uint32_t *idx)
{
    if (!present || !capture) return 0;
    HDMI->BUF = HDMI_BUF_LOCK;
    uint32_t t0 = cycles(), s;
    while (((s = HDMI->BUF) & HDMI_BUF_BUSY) && ms_since(t0) < 2u) { }
    if ((s & HDMI_BUF_BUSY) || !(s & HDMI_BUF_LOCKED)) return 0;   /* полного кадра ещё нет */
    *idx = HDMI_BUF_IDX(s);
    return 1;
}

void hdmi_unlock_frame(void)
{
    if (present) HDMI->BUF = HDMI_BUF_UNLOCK;
}

uint32_t hdmi_flags(void)
{
    if (!present) return 0;
    uint32_t st = HDMI->STATUS;
    return (st & 0x0Fu) | ((HDMI->CTRL & HDMI_CTRL_HPD) ? (1u << 4) : 0u) | (capture ? (1u << 5) : 0u);
}

uint32_t hdmi_res(void) { return present ? HDMI->RES : 0u; }
