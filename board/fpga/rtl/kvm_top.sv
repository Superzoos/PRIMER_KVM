// kvm_top - верхний модуль KVM-over-IP.
// PLL, сброс K0, ядро PicoRV32 (UART, GPIO), шина Open Wishbone с периферией:
//   слот 0 (0x2000_0000) - hdmi_rx: вход HDMI (модуль PMOD_DVI): EDID, HPD, измерения, захват кадра в DDR3;
//   слот 1 (0x2000_1000) - eth_sys: Ethernet 100 Мбит (RTL8201F, RMII), буферы кадров;
//   слот 2 (0x2000_2000) - video_tx: передача кадра из DDR3 на ПК пакетами UDP;
//   слот 3 (0x2000_3000) - ddr_arb: состояние DDR3;
//   слот 4 (0x2000_4000) - usb_hid: USB-клавиатура и мышь для удалённого ПК (USB3317, ULPI);
//   0x3000_0000..        - память DDR3 (128 МБ), доступ ядра через ddr_arb.
// DDR3: rPLL pll_ddr (DDR_MEM_CLK_HZ) -> IP ddr3_mi (1:4) -> такт пользователя ddr_clk = DDR_MEM_CLK_HZ / 4
// (имя цепи ddr_clk используется в kvm.sdc).
// HDMI: IP DVI RX dvi_rx (rPLL x5, IDES10) -> пиксельный такт pix_clk (имя цепи - в kvm.sdc) -> hdmi_rx.
module kvm_top (
    input  logic clk_27m,      // H11, генератор 27 МГц
    input  logic key0_n,       // T10, K0: общий сброс (0 = нажата)
    output logic uart_tx,      // M11 -> BL702 (COM-порт)
    input  logic uart_rx,      // T13 <- BL702
    // WB GPIO ядра: LED0..5 = биты 0..5 (kvm.cst, firmware/app/board.h); K1..K3 и DIP заняты DDR3
    inout  wire  [kvm_config_pkg::CPU_GPIO_WIDTH-1:0] gpio,
    // HDMI вход
    input  logic       tmds_clk_p,    // C12/B12: модуль PMOD_DVI в J6
    input  logic       tmds_clk_n,
    input  logic [2:0] tmds_d_p,      // B13, B14, D14 - пины [A] пар = DxN модуля (инверсия - в hdmi_rx)
    input  logic [2:0] tmds_d_n,      // A14, A15, E15
    input  logic       hdmi_scl,      // A11 (J5) <- SCL модуля
    inout  wire        hdmi_sda,      // N6  (J5) <-> SDA модуля
    output logic       hdmi_hpd,      // N9  (J5) -> HPD модуля
    // Ethernet RTL8201F (RMII)
    input  logic       eth_ref_clk,   // A9, 50 МГц от PHY
    input  logic [1:0] eth_rxd,       // F15, C9
    input  logic       eth_crs_dv,    // M6
    input  logic       eth_rx_er,     // L8
    output logic [1:0] eth_txd,       // D16, E14
    output logic       eth_tx_en,     // E16
    output logic       eth_rst_n,     // F10 (общий сброс RTL8201F и USB3317)
    output logic       eth_mdc,       // F14 (общий с DDC SDA HDMI через 2N7002)
    inout  wire        eth_mdio,      // F16 (общий с DDC SCL HDMI через 2N7002)
    // USB device -> удалённый ПК: PHY USB3317 (ULPI) на Dock; его RESETB - общий с RTL8201F (eth_rst_n)
    input  logic       ulpi_clk,      // T15, 60 МГц от PHY
    input  logic       ulpi_dir,      // K12
    input  logic       ulpi_nxt,      // K13
    output logic       ulpi_stp,      // K11
    inout  wire  [7:0] ulpi_data,     // G11, H12, J12, H13, T14, R13, P13, R12
    // DDR3 (SoM)
    output logic [kvm_config_pkg::DDR_ROW_BITS-1:0] ddr_addr,
    output logic [2:0]  ddr_ba,
    output logic        ddr_cs_n,
    output logic        ddr_ras_n,
    output logic        ddr_cas_n,
    output logic        ddr_we_n,
    output logic        ddr_ck,
    output logic        ddr_ck_n,
    output logic        ddr_cke,
    output logic        ddr_odt,
    output logic        ddr_reset_n,
    output logic [1:0]  ddr_dm,
    inout  wire  [15:0] ddr_dq,
    inout  wire  [1:0]  ddr_dqs,
    inout  wire  [1:0]  ddr_dqs_n
);
    localparam int ROW_BITS = kvm_config_pkg::DDR_ROW_BITS;
    localparam int TILE_W   = 32;           // плитка 32x16: hdmi_rx (суммы) и video_tx (пакеты)
    localparam int TILE_H   = 16;

    logic ddr_mem_clk, ddr_lock, ddr_rst, ddr_calib;
    logic pix_clk;          // пиксельный такт HDMI (O_rgb_clk IP DVI RX); имя - в kvm.sdc
    logic ddr_clk;          // такт пользователя DDR3 (clk_out IP); имя - в kvm.sdc

    logic clk_sys;
    logic rst_n;

    clk_rst u_clk_rst (
        .clk_in   (clk_27m),
        .rst_n_in (key0_n),
        .clk_sys  (clk_sys),
        .rst_n    (rst_n)
    );

    // ---------- Ядро и шина ----------
    logic        wb_cyc, wb_stb, wb_we, wb_ack;
    logic [31:0] wb_adr, wb_wdata, wb_rdata;
    logic [3:0]  wb_sel;

    cpu_sys u_cpu_sys (
        .clk      (clk_sys),
        .rst_n    (rst_n),
        .uart_tx  (uart_tx),
        .uart_rx  (uart_rx),
        .gpio     (gpio),
        .wb_cyc   (wb_cyc),
        .wb_stb   (wb_stb),
        .wb_we    (wb_we),
        .wb_adr   (wb_adr),
        .wb_wdata (wb_wdata),
        .wb_sel   (wb_sel),
        .wb_ack   (wb_ack),
        .wb_rdata (wb_rdata)
    );

    localparam int NSLOT = 5;
    logic [NSLOT-1:0]    s_stb, s_ack;
    logic [NSLOT*32-1:0] s_rdata;
    logic                mem_stb, mem_ack;
    logic [31:0]         mem_rdata;

    wb_mux #(.N(NSLOT)) u_wb_mux (
        .clk     (clk_sys),
        .rst_n   (rst_n),
        .m_cyc   (wb_cyc),
        .m_stb   (wb_stb),
        .m_adr   (wb_adr),
        .m_ack   (wb_ack),
        .m_rdata (wb_rdata),
        .s_stb     (s_stb),
        .s_ack     (s_ack),
        .s_rdata   (s_rdata),
        .mem_stb   (mem_stb),
        .mem_ack   (mem_ack),
        .mem_rdata (mem_rdata)
    );

    // ---------- Слот 0: вход HDMI ----------
    logic        rx_rst_n, rx_pll_lock, rx_phase_lock, pix_de, pix_vs, pix_hs;
    logic [3:0]  rx_phase;
    logic [7:0]  pix_r, pix_g, pix_b;
    logic        cw_valid, cw_pop;
    logic [ROW_BITS+9:0] cw_line;
    logic [127:0] cw_data;

    dvi_rx u_dvi_rx (
        .I_rst_n          (rx_rst_n),
        .I_tmds_clk_p     (tmds_clk_p),
        .I_tmds_clk_n     (tmds_clk_n),
        .I_tmds_data_p    (tmds_d_p),
        .I_tmds_data_n    (tmds_d_n),
        .O_pll_lock       (rx_pll_lock),
        .O_pll_phase      (rx_phase),
        .O_pll_phase_lock (rx_phase_lock),
        .O_rgb_clk        (pix_clk),
        .O_rgb_vs         (pix_vs),
        .O_rgb_hs         (pix_hs),
        .O_rgb_de         (pix_de),
        .O_rgb_r          (pix_r),
        .O_rgb_g          (pix_g),
        .O_rgb_b          (pix_b)
    );

    hdmi_rx #(
        .CLK_HZ   (kvm_config_pkg::CPU_CLK_HZ),
        .ROW_BITS (ROW_BITS)
    ) u_hdmi_rx (
        .clk           (clk_sys),
        .rst_n         (rst_n),
        .pix_clk       (pix_clk),
        .pix_de        (pix_de),
        .pix_r         (pix_r),
        .pix_g         (pix_g),
        .pix_b         (pix_b),
        .rx_pll_lock   (rx_pll_lock),
        .rx_phase      (rx_phase),
        .rx_phase_lock (rx_phase_lock),
        .rx_rst_n      (rx_rst_n),
        .ddc_scl       (hdmi_scl),
        .ddc_sda       (hdmi_sda),
        .hpd           (hdmi_hpd),
        .wb_stb        (s_stb[0]),
        .wb_we         (wb_we),
        .wb_adr        (wb_adr[11:0]),
        .wb_wdata      (wb_wdata),
        .wb_ack        (s_ack[0]),
        .wb_rdata      (s_rdata[31:0]),
        .dclk          (ddr_clk),
        .drst          (ddr_rst),
        .cw_valid      (cw_valid),
        .cw_line       (cw_line),
        .cw_data       (cw_data),
        .cw_pop        (cw_pop)
    );

    // ---------- Слот 1: Ethernet ----------
    logic         vb_we;
    logic [7:0]   vb_waddr;
    logic [127:0] vb_wdata;
    logic [1:0]   vb_full_t, vb_free_t;

    eth_sys #(
        .CLK_HZ    (kvm_config_pkg::CPU_CLK_HZ),
        .VID_BYTES (64 + 2 * TILE_W * TILE_H)
    ) u_eth_sys (
        .clk          (clk_sys),
        .rst_n        (rst_n),
        .rmii_ref_clk (eth_ref_clk),
        .rmii_rxd     (eth_rxd),
        .rmii_crs_dv  (eth_crs_dv),
        .rmii_rx_er   (eth_rx_er),
        .rmii_txd     (eth_txd),
        .rmii_tx_en   (eth_tx_en),
        .phy_rst_n    (eth_rst_n),
        .mdc          (eth_mdc),
        .mdio         (eth_mdio),
        .wb_stb       (s_stb[1]),
        .wb_we        (wb_we),
        .wb_adr       (wb_adr[11:0]),
        .wb_wdata     (wb_wdata),
        .wb_ack       (s_ack[1]),
        .wb_rdata     (s_rdata[63:32]),
        .vb_clk       (ddr_clk),
        .vb_we        (vb_we),
        .vb_waddr     (vb_waddr),
        .vb_wdata     (vb_wdata),
        .vb_full_t    (vb_full_t),
        .vb_free_t    (vb_free_t)
    );

    // ---------- DDR3 ----------
    // Сброс IP: снимается синхронно с clk (IPUG281 4.4.3), затем IP ждёт pll_lock и выдаёт ddr_rst.
    logic [2:0] rst27;
    always_ff @(posedge clk_27m or negedge key0_n) begin
        if (!key0_n) rst27 <= '0;
        else         rst27 <= {rst27[1:0], 1'b1};
    end

    pll_ddr u_pll_ddr (
        .clkin  (clk_27m),
        .reset  (1'b0),
        .clkout (ddr_mem_clk),
        .lock   (ddr_lock)
    );

    logic                cmd_ready, cmd_en, wr_data_rdy, wr_data_en, wr_data_end, rd_data_valid, rd_data_end;
    logic [2:0]          cmd;
    logic [ROW_BITS+13:0] cmd_addr;
    logic [127:0]        wr_data, rd_data;
    logic [15:0]         wr_data_mask;

    ddr3_mi u_ddr3 (
        .clk                 (clk_27m),
        .memory_clk          (ddr_mem_clk),
        .pll_lock            (ddr_lock),
        .rst_n               (rst27[2]),
        .clk_out             (ddr_clk),
        .ddr_rst             (ddr_rst),
        .init_calib_complete (ddr_calib),
        .cmd_ready           (cmd_ready),
        .cmd                 (cmd),
        .cmd_en              (cmd_en),
        .addr                (cmd_addr),
        .wr_data_rdy         (wr_data_rdy),
        .wr_data             (wr_data),
        .wr_data_en          (wr_data_en),
        .wr_data_end         (wr_data_end),
        .wr_data_mask        (wr_data_mask),
        .rd_data             (rd_data),
        .rd_data_valid       (rd_data_valid),
        .rd_data_end         (rd_data_end),
        .sr_req              (1'b0),
        .ref_req             (1'b0),
        .sr_ack              (),
        .ref_ack             (),
        .burst               (1'b1),
        .O_ddr_addr          (ddr_addr),
        .O_ddr_ba            (ddr_ba),
        .O_ddr_cs_n          (ddr_cs_n),
        .O_ddr_ras_n         (ddr_ras_n),
        .O_ddr_cas_n         (ddr_cas_n),
        .O_ddr_we_n          (ddr_we_n),
        .O_ddr_clk           (ddr_ck),
        .O_ddr_clk_n         (ddr_ck_n),
        .O_ddr_cke           (ddr_cke),
        .O_ddr_odt           (ddr_odt),
        .O_ddr_reset_n       (ddr_reset_n),
        .O_ddr_dqm           (ddr_dm),
        .IO_ddr_dq           (ddr_dq),
        .IO_ddr_dqs          (ddr_dqs),
        .IO_ddr_dqs_n        (ddr_dqs_n)
    );

    logic                vr_req, vr_ack, vr_valid, vr_done;
    logic [ROW_BITS+9:0] vr_line;
    logic [7:0]          vr_beats;
    logic [127:0]        vr_data;

    // ---------- Окно памяти и слот 3: ddr_arb ----------
    ddr_arb #(
        .ROW_BITS (ROW_BITS),
        .CLK_HZ   (kvm_config_pkg::CPU_CLK_HZ)
    ) u_ddr_arb (
        .clk           (clk_sys),
        .rst_n         (rst_n),
        .mem_stb       (mem_stb),
        .mem_we        (wb_we),
        .mem_adr       (wb_adr),
        .mem_wdata     (wb_wdata),
        .mem_sel       (wb_sel),
        .mem_ack       (mem_ack),
        .mem_rdata     (mem_rdata),
        .reg_stb       (s_stb[3]),
        .reg_adr       (wb_adr[11:0]),
        .reg_ack       (s_ack[3]),
        .reg_rdata     (s_rdata[127:96]),
        .dclk          (ddr_clk),
        .drst          (ddr_rst),
        .calib         (ddr_calib),
        .pll_lock      (ddr_lock),
        .cmd_ready     (cmd_ready),
        .cmd           (cmd),
        .cmd_en        (cmd_en),
        .addr          (cmd_addr),
        .wr_data_rdy   (wr_data_rdy),
        .wr_data       (wr_data),
        .wr_data_en    (wr_data_en),
        .wr_data_end   (wr_data_end),
        .wr_data_mask  (wr_data_mask),
        .rd_data       (rd_data),
        .rd_data_valid (rd_data_valid),
        .vr_req        (vr_req),
        .vr_line       (vr_line),
        .vr_beats      (vr_beats),
        .vr_ack        (vr_ack),
        .vr_valid      (vr_valid),
        .vr_data       (vr_data),
        .vr_done       (vr_done),
        .cw_valid      (cw_valid),
        .cw_line       (cw_line),
        .cw_data       (cw_data),
        .cw_pop        (cw_pop)
    );

    // ---------- Слот 2: передача кадра ----------
    video_tx #(
        .ROW_BITS   (ROW_BITS),
        .TILE_W     (TILE_W),
        .TILE_H     (TILE_H),
        .WIDTH      (kvm_config_pkg::VIDEO_H_ACTIVE),
        .HEIGHT     (kvm_config_pkg::VIDEO_V_ACTIVE)
    ) u_video_tx (
        .clk       (clk_sys),
        .rst_n     (rst_n),
        .wb_stb    (s_stb[2]),
        .wb_we     (wb_we),
        .wb_adr    (wb_adr[11:0]),
        .wb_wdata  (wb_wdata),
        .wb_ack    (s_ack[2]),
        .wb_rdata  (s_rdata[95:64]),
        .dclk      (ddr_clk),
        .drst      (ddr_rst),
        .vr_req    (vr_req),
        .vr_line   (vr_line),
        .vr_beats  (vr_beats),
        .vr_ack    (vr_ack),
        .vr_valid  (vr_valid),
        .vr_data   (vr_data),
        .vr_done   (vr_done),
        .pb_we     (vb_we),
        .pb_waddr  (vb_waddr),
        .pb_wdata  (vb_wdata),
        .pb_full_t (vb_full_t),
        .pb_free_t (vb_free_t)
    );

    // ---------- Слот 4: USB-клавиатура и мышь ----------
    // ULPI: выводы с задержкой на входах (ulpi_io); шину данных ведёт PHY при DIR = 1, иначе - ядро USB
    logic [7:0] ulpi_txdata, ulpi_rxdata;
    logic       ulpi_dir_d, ulpi_nxt_d;
    ulpi_io u_ulpi_io (
        .ulpi_dir (ulpi_dir),  .ulpi_nxt (ulpi_nxt),  .ulpi_data (ulpi_data),
        .txdata   (ulpi_txdata),
        .dir_d    (ulpi_dir_d), .nxt_d   (ulpi_nxt_d), .rxdata   (ulpi_rxdata)
    );

    usb_hid u_usb_hid (
        .clk         (clk_sys),
        .rst_n       (rst_n),
        .wb_stb      (s_stb[4]),
        .wb_we       (wb_we),
        .wb_adr      (wb_adr[11:0]),
        .wb_wdata    (wb_wdata),
        .wb_ack      (s_ack[4]),
        .wb_rdata    (s_rdata[159:128]),
        .usb_clk     (ulpi_clk),
        .phy_rst_n   (eth_rst_n),
        .ulpi_dir    (ulpi_dir_d),
        .ulpi_nxt    (ulpi_nxt_d),
        .ulpi_stp    (ulpi_stp),
        .ulpi_rxdata (ulpi_rxdata),
        .ulpi_txdata (ulpi_txdata)
    );
endmodule
