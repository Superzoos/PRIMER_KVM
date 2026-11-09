// cpu_sys - ядро Gowin_PicoRV32 (fpga/ip/gowin_picorv32, настройки - pico_define.vh от scripts/ip-gen.ps1).
// UART - в COM-порт BL702; GPIO - на пины платы.
// Шина Open Wishbone (адреса 0x2000_0000..0x3FFF_FFFF, picorv32.h OPEN_WB_BASE) выведена наружу:
// дешифратор и периферия - в kvm_top (wb_mux).
module cpu_sys (
    input  logic        clk,
    input  logic        rst_n,
    output logic        uart_tx,
    input  logic        uart_rx,
    inout  wire  [kvm_config_pkg::CPU_GPIO_WIDTH-1:0] gpio,
    // Open Wishbone (ядро - ведущий)
    output logic        wb_cyc,
    output logic        wb_stb,
    output logic        wb_we,
    output logic [31:0] wb_adr,
    output logic [31:0] wb_wdata,
    output logic [3:0]  wb_sel,
    input  logic        wb_ack,
    input  logic [31:0] wb_rdata
);
    Gowin_PicoRV32_Top u_cpu (
        .wbuart_tx       (uart_tx),
        .wbuart_rx       (uart_rx),
        .gpio_io         (gpio),
        .slv_ext_stb_o   (wb_stb),
        .slv_ext_we_o    (wb_we),
        .slv_ext_cyc_o   (wb_cyc),
        .slv_ext_ack_i   (wb_ack),
        .slv_ext_adr_o   (wb_adr),
        .slv_ext_wdata_o (wb_wdata),
        .slv_ext_rdata_i (wb_rdata),
        .slv_ext_sel_o   (wb_sel),
        .irq_in          (12'h0),
        .clk_in          (clk),
        .resetn_in       (rst_n)
    );
endmodule
