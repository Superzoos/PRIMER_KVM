/* video.h - буферы кадра в DDR3 и передача кадра на ПК. */
#ifndef VIDEO_H
#define VIDEO_H

#include <stdint.h>
#include "net.h"
#include "kvm_proto.h"

/* Настроить video_tx и нарисовать тестовую картинку в её буфер (ddr_bytes - объём DDR3 или 0). */
void     video_init(uint32_t ddr_bytes, const char *fw_build);
/* Обновление изображения для отправителя запроса peer (KVM_CMD_UPDATE, kvm_proto.h): из последнего полного
 * кадра захвата или тестовой картинки; full - все плитки. Заполняет ответ *u и запускает передачу плиток. */
void     video_update(const net_peer_t *peer, int full, kvm_update_t *u);
/* Раз в 10 мс: освободить буфер захвата, когда его передача закончилась; раз в секунду - статистика плиток */
void     video_poll(void);
/* Выполнено передач (обновлений с плитками) */
uint32_t video_frames(void);
/* Буферы кадра готовы (DDR3 в порядке); адрес буфера захвата 0 в DDR3, шаг строк и шаг буферов, байт */
int      video_ready(void);
uint32_t video_fb_base(void);
uint32_t video_fb_stride(void);
uint32_t video_fb_bsize(void);
/* Смещение таблицы сумм плиток от начала буфера захвата, байт */
uint32_t video_fb_hofs(void);

#endif /* VIDEO_H */
