/* board.h - назначение битов WB GPIO на плате Tang Primer 20K Dock
 * (совпадает с fpga/constraints/kvm.cst). */
#ifndef BOARD_H
#define BOARD_H

#define GPIO_LED_SHIFT  0u      /* LED0..LED5: биты 0..5, выход, 0 = горит */
/* K1..K3 и DIP SW0..SW4 не подключены: их пины в парах IO с пинами DDR3 (fpga/constraints/kvm.cst) */

#define LED_COUNT       6u
#define LED_MASK        (0x3Fu << GPIO_LED_SHIFT)

#endif /* BOARD_H */
