/* hdmi.h - вход HDMI: EDID, HPD, захват кадра или тестовая картинка. */
#ifndef HDMI_H
#define HDMI_H

#include <stdint.h>

/* Загрузить EDID, выставить HPD. Вызывать после video_init(). */
void     hdmi_init(void);
/* Раз в 10 мс: состояние приёмника, включение/выключение захвата. */
void     hdmi_poll(uint32_t now_ms);
/* Захват в буфер кадра включён */
int      hdmi_capturing(void);
/* Закрепить последний полный кадр захвата за отправкой: 1 и номер буфера (0..2) или 0 - кадра нет
 * (захват выключен или ещё не записан ни один полный кадр). Освободить - hdmi_unlock_frame(). */
int      hdmi_lock_frame(uint32_t *idx);
void     hdmi_unlock_frame(void);
/* Для протокола (kvm_status_t.hdmi_flags): биты 0..3 - PLL, фаза, кадры, CAPTURING (hdmi_rx STATUS),
 * бит 4 - HPD, бит 5 - захват включён прошивкой */
uint32_t hdmi_flags(void);
/* Размер последнего кадра: ширина | высота << 16 */
uint32_t hdmi_res(void);

#endif /* HDMI_H */
