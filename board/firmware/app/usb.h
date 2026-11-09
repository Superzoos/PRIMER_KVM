/* usb.h - USB-клавиатура и мышь для удалённого ПК (fpga/rtl/usb_hid.sv): отчёты из команд KVM_CMD_INPUT. */
#ifndef USB_H
#define USB_H

#include <stdint.h>

/* Проверить usb_hid, сообщение в UART */
void     usb_init(void);
/* Пакет KVM_CMD_INPUT (данные после заголовка KVM, n байт) */
void     usb_input(const uint8_t *p, uint32_t n, uint32_t now_ms);
/* Раз в 10 мс: отпустить всё, если команд нет 0.5 с; сообщения о подключении к ПК */
void     usb_poll(uint32_t now_ms);
/* Для kvm_status_t.usb_flags */
uint32_t usb_flags(void);

#endif /* USB_H */
