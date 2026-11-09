// eth_sys - Ethernet 100 Мбит, полный дуплекс:
//   RTL8201F (RMII, 50 МГц от PHY) <-> MII to RMII (eth_m2r) <-> TSE MAC в режиме MII (eth_tse_mac)
//   <-> буферы кадров в BSRAM <-> Wishbone (ядро). Стек ARP/IP/UDP - в прошивке.
// MAC сам добавляет FCS и дополняет кадр до 60 байт; принимает кадры 64..1518 байт (IPUG538 4.3).
// MDIO: линиями MDC/MDIO управляет ядро через регистр MDIO (протокол - в прошивке, mdio.c).
// Передача: кадры ядра (буфер 2 КБ) и пакеты видео (video_tx: 2 буфера по 2 КБ, 128-битные строки, запись
// в домене vb_clk). Кадр ядра идёт первым, если ждут оба. Пакет видео длиной VID_BYTES: байты 0..41 берутся
// из шаблона в буфере ядра (слова 448..458, адреса 0xF00..0xF2B окна 0x800), остальное - из буфера видео.
//
// Регистры (слот Wishbone, смещение):
//   0x000 ID          RO  0x4554_4831 ("ETH1")
//   0x004 STATUS      RO  бит 0 RX_AVAIL, бит 1 TX_BUSY, бит 2 PHY_READY
//   0x008 RX_LEN      RO  длина текущего принятого кадра, байт (без FCS)
//   0x00C RX_POP      WO  любая запись - освободить текущий принятый кадр
//   0x010 TX_LEN      WO  запись длины (байт) - отправить кадр из буфера передачи (если TX_BUSY = 0)
//   0x014 RX_FRAMES   RO  принято кадров без ошибок и сохранено
//   0x018 RX_ERRORS   RO  кадров с ошибками (FCS, длина, RX_ER)
//   0x01C RX_DROPPED  RO  отброшено: оба буфера приёма заняты или кадр длиннее 2048 байт
//   0x020 TX_FRAMES   RO  отправлено кадров
//   0x024 MDIO        RW  бит 0 - MDC, бит 1 - MDIO (0 = тянуть в 0, 1 = отпустить); чтение: бит 8 - состояние MDIO
//   0x028 VID_PKTS    RO  отправлено пакетов видео
//   0x800..0xFFF      чтение - текущий принятый кадр, запись - буфер передачи
//                     (32-битные слова, байт 0 кадра - биты 7:0 слова 0; писать только словами)
module eth_sys #(
    parameter int CLK_HZ    = 45_000_000,
    parameter int VID_BYTES = 1344            // длина пакета видео (video_tx PKT_BYTES), 64..2048
) (
    input  logic        clk,
    input  logic        rst_n,
    // RMII (RTL8201F)
    input  logic        rmii_ref_clk,    // 50 МГц от PHY
    input  logic [1:0]  rmii_rxd,
    input  logic        rmii_crs_dv,
    input  logic        rmii_rx_er,
    output logic [1:0]  rmii_txd,
    output logic        rmii_tx_en,
    output logic        phy_rst_n,       // общий с USB3317
    output logic        mdc,
    inout  wire         mdio,            // открытый сток, подтяжка на плате
    // Wishbone (stb уже выбран дешифратором)
    input  logic        wb_stb,
    input  logic        wb_we,
    input  logic [11:0] wb_adr,
    input  logic [31:0] wb_wdata,
    output logic        wb_ack,
    output logic [31:0] wb_rdata,
    // буфер пакетов видео (video_tx)
    input  logic         vb_clk,
    input  logic         vb_we,
    input  logic [7:0]   vb_waddr,         // {буфер, строка}
    input  logic [127:0] vb_wdata,
    input  logic [1:0]   vb_full_t,        // домен vb_clk: буфер заполнен (переключение)
    output logic [1:0]   vb_free_t         // домен передачи: буфер отправлен (переключение)
);
    localparam logic [31:0] ID      = 32'h4554_4831;
    localparam logic [11:0] VLEN    = VID_BYTES;
    localparam int          RST_CYC = CLK_HZ / 100;     // 10 мс

    // =====================================================================
    // Сброс PHY: 10 мс в 0, затем ещё 10 мс до снятия сброса с MAC
    // =====================================================================
    logic [$clog2(2*RST_CYC+1)-1:0] prst_cnt;
    logic phy_ready;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            prst_cnt  <= '0;
            phy_rst_n <= 1'b0;
            phy_ready <= 1'b0;
        end else begin
            if (prst_cnt != 2*RST_CYC) prst_cnt <= prst_cnt + 1'b1;
            if (prst_cnt >= RST_CYC)   phy_rst_n <= 1'b1;
            if (prst_cnt == 2*RST_CYC) phy_ready <= 1'b1;
        end
    end

    // сброс в домене 50 МГц: асинхронная установка, синхронное снятие
    logic [2:0] ref_rs;
    always_ff @(posedge rmii_ref_clk or negedge phy_ready) begin
        if (!phy_ready) ref_rs <= '0;
        else            ref_rs <= {ref_rs[1:0], 1'b1};
    end
    logic eth_rstn;
    assign eth_rstn = ref_rs[2];

    // =====================================================================
    // MII to RMII + TSE MAC
    // =====================================================================
    logic       mii_rx_clk, mii_rx_dv, mii_rx_er, mii_tx_clk, mii_tx_en, mii_tx_er, mii_col, mii_crs;
    logic [3:0] mii_rxd, mii_txd;

    eth_m2r u_m2r (
        .refclk         (rmii_ref_clk),
        .rstn           (eth_rstn),
        .speedis_100    (1'b1),
        .rmii_rx_crs_dv (rmii_crs_dv),
        .rmii_rx_er     (rmii_rx_er),
        .rmii_rxd       (rmii_rxd),
        .rmii_tx_en     (rmii_tx_en),
        .rmii_txd       (rmii_txd),
        .mii_rx_clk     (mii_rx_clk),
        .mii_rx_dv      (mii_rx_dv),
        .mii_rx_er      (mii_rx_er),
        .mii_rxd        (mii_rxd),
        .mii_tx_clk     (mii_tx_clk),
        .mii_tx_en      (mii_tx_en),
        .mii_tx_er      (mii_tx_er),
        .mii_txd        (mii_txd),
        .mii_col        (mii_col),
        .mii_crs        (mii_crs)
    );

    logic       rx_clk, rx_valid, rx_last, rx_error;
    logic [7:0] rx_data;
    logic       tx_clk, tx_valid, tx_last, tx_ready;
    logic [7:0] tx_data;

    eth_tse_mac u_mac (
        .mii_rx_clk           (mii_rx_clk),
        .mii_rxd              (mii_rxd),
        .mii_rx_dv            (mii_rx_dv),
        .mii_rx_er            (mii_rx_er),
        .mii_tx_clk           (mii_tx_clk),
        .mii_txd              (mii_txd),
        .mii_tx_en            (mii_tx_en),
        .mii_tx_er            (mii_tx_er),
        .mii_col              (mii_col),
        .mii_crs              (mii_crs),
        .duplex_status        (1'b0),          // 0 = полный дуплекс
        .rstn                 (eth_rstn),
        .rx_mac_clk           (rx_clk),
        .rx_mac_valid         (rx_valid),
        .rx_mac_data          (rx_data),
        .rx_mac_last          (rx_last),
        .rx_mac_error         (rx_error),
        .rx_statistics_valid  (),
        .rx_statistics_vector (),
        .tx_mac_clk           (tx_clk),
        .tx_mac_valid         (tx_valid),
        .tx_mac_data          (tx_data),
        .tx_mac_last          (tx_last),
        .tx_mac_error         (1'b0),
        .tx_mac_ready         (tx_ready),
        .tx_collision         (),
        .tx_retransmit        (),
        .tx_statistics_valid  (),
        .tx_statistics_vector (),
        .rx_fcs_fwd_ena       (1'b0),
        .rx_jumbo_ena         (1'b0),
        .rx_pause_req         (),
        .rx_pause_val         (),
        .tx_fcs_fwd_ena       (1'b0),
        .tx_ifg_delay_ena     (1'b0),
        .tx_ifg_delay         (8'd0),
        .tx_pause_req         (1'b0),
        .tx_pause_val         (16'd0),
        .tx_pause_source_addr (48'd0),
        .clk                  (clk),
        .miim_phyad           (5'd0),
        .miim_regad           (5'd0),
        .miim_wrdata          (16'd0),
        .miim_wren            (1'b0),
        .miim_rden            (1'b0),
        .miim_rddata          (),
        .miim_rddata_valid    (),
        .miim_busy            (),
        .mdc                  (),
        .mdio_in              (1'b1),
        .mdio_out             (),
        .mdio_oen             ()
    );

    // =====================================================================
    // Приём: 2 буфера по 2 КБ (1024 слова x 32), указатели кадров - 2-битный код Грея
    // =====================================================================
    logic [31:0] rx_mem [0:1023];
    logic        rx_we;
    logic [9:0]  rx_waddr;
    logic [31:0] rx_wdata;
    always_ff @(posedge rx_clk) if (rx_we) rx_mem[rx_waddr] <= rx_wdata;

    // сброс домена приёма
    logic [1:0] rx_rs;
    always_ff @(posedge rx_clk or negedge eth_rstn) begin
        if (!eth_rstn) rx_rs <= '0;
        else           rx_rs <= {rx_rs[0], 1'b1};
    end

    logic [1:0]  wptr, wptr_g;            // кадров записано (домен приёма)
    logic [1:0]  rptr, rptr_g;            // кадров прочитано (домен clk)
    logic [1:0]  rptr_g1, rptr_g2;        // rptr_g в домене приёма
    logic [1:0]  rptr_rx;
    logic [11:0] len0, len1;              // длины кадров в слотах 0 и 1
    logic        in_frame, cur_drop, too_long;
    logic [10:0] bcnt;
    logic [31:0] wword, wword_next;
    logic        ev_ok_t, ev_err_t, ev_drop_t;

    always_ff @(posedge rx_clk) begin
        rptr_g1 <= rptr_g;
        rptr_g2 <= rptr_g1;
    end
    assign rptr_rx = {rptr_g2[1], rptr_g2[1] ^ rptr_g2[0]};

    logic        start, full_rx, drop_now, long_now;
    logic [10:0] idx;
    assign start    = rx_valid & ~in_frame;
    assign full_rx  = (wptr - rptr_rx) == 2'd2;
    assign drop_now = start ? full_rx : cur_drop;
    assign long_now = start ? 1'b0 : too_long;
    assign idx      = start ? 11'd0 : bcnt;

    always_comb begin
        wword_next = (idx[1:0] == 2'd0) ? 32'h0 : wword;
        wword_next[idx[1:0]*8 +: 8] = rx_data;
    end

    always_ff @(posedge rx_clk or negedge rx_rs[1]) begin
        if (!rx_rs[1]) begin
            in_frame <= 1'b0;  cur_drop <= 1'b0;  too_long <= 1'b0;
            bcnt <= '0;  wword <= '0;
            wptr <= '0;  wptr_g <= '0;
            len0 <= '0;  len1 <= '0;
            rx_we <= 1'b0;  rx_waddr <= '0;  rx_wdata <= '0;
            ev_ok_t <= 1'b0;  ev_err_t <= 1'b0;  ev_drop_t <= 1'b0;
        end else begin
            rx_we <= 1'b0;
            if (rx_valid) begin
                in_frame <= ~rx_last;
                cur_drop <= drop_now;
                too_long <= long_now | ((idx == 11'd2047) & ~rx_last);
                if (!long_now && idx != 11'd2047) bcnt <= idx + 1'b1;
                wword <= wword_next;
                if ((idx[1:0] == 2'd3 || rx_last) && !drop_now && !long_now) begin
                    rx_we    <= 1'b1;
                    rx_waddr <= {wptr[0], idx[10:2]};
                    rx_wdata <= wword_next;
                end
                if (rx_last) begin
                    if (rx_error)
                        ev_err_t <= ~ev_err_t;
                    else if (drop_now || long_now)
                        ev_drop_t <= ~ev_drop_t;
                    else begin
                        if (wptr[0]) len1 <= {1'b0, idx} + 12'd1;
                        else         len0 <= {1'b0, idx} + 12'd1;
                        wptr    <= wptr + 1'b1;
                        wptr_g  <= (wptr + 1'b1) ^ ((wptr + 1'b1) >> 1);
                        ev_ok_t <= ~ev_ok_t;
                    end
                end
            end
        end
    end

    // =====================================================================
    // Передача: буфер ядра 2 КБ (512 слов x 32), запуск/завершение - переключением флагов;
    // буферы видео 2 x 2 КБ (256 строк x 128), готовность/освобождение - флагами на буфер
    // =====================================================================
    logic [31:0]  tx_mem [0:511];
    logic [127:0] vb_mem [0:255];
    always_ff @(posedge vb_clk) if (vb_we) vb_mem[vb_waddr] <= vb_wdata;

    logic         src_v;                  // отправляется пакет видео
    logic         vb;                     // буфер видео, который отправляется следующим
    logic [31:0]  tx_q;
    logic [127:0] vb_q;
    logic [10:0]  rb;                     // адрес байта для чтения
    logic [8:0]   tx_ra;
    logic [3:0]   q_lo;
    logic         q_tpl, q_v;
    assign tx_ra = src_v ? {5'b11100, rb[5:2]} : rb[10:2];       // шаблон видео - слова 448..458
    always_ff @(posedge tx_clk) begin
        tx_q  <= tx_mem[tx_ra];
        vb_q  <= vb_mem[{vb, rb[10:4]}];
        q_lo  <= rb[3:0];
        q_tpl <= (rb < 11'd42);
        q_v   <= src_v;
    end
    logic [7:0] q_byte;
    assign q_byte = (q_v && !q_tpl) ? vb_q[q_lo*8 +: 8] : tx_q[q_lo[1:0]*8 +: 8];

    logic [1:0] tx_rs;
    always_ff @(posedge tx_clk or negedge eth_rstn) begin
        if (!eth_rstn) tx_rs <= '0;
        else           tx_rs <= {tx_rs[0], 1'b1};
    end

    logic        start_t, done_t;         // start_t - домен clk, done_t - домен передачи
    logic [11:0] tx_len;                  // домен clk, стабилен пока TX_BUSY
    logic [2:0]  st_sync;
    logic [1:0]  vf_s0, vf_s1;
    logic [11:0] len_tx, cur;
    typedef enum logic [1:0] {T_IDLE, T_LOAD0, T_LOAD1, T_SEND} tstate_t;
    tstate_t tst;
    logic accept, cpu_pend, vid_pend;

    always_ff @(posedge tx_clk) begin
        vf_s0 <= vb_full_t;
        vf_s1 <= vf_s0;
    end
    assign cpu_pend = (st_sync[2] != done_t);           // TX_LEN записан, кадр ещё не отправлен
    assign vid_pend = (vf_s1[vb] != vb_free_t[vb]);     // буфер видео заполнен

    assign accept  = tx_valid & tx_ready;
    assign tx_last = tx_valid & (cur == len_tx - 12'd1);

    always_comb begin
        case (tst)
            T_LOAD0: rb = 11'd0;
            T_LOAD1: rb = 11'd1;
            T_SEND:  rb = accept ? cur[10:0] + 11'd2 : cur[10:0] + 11'd1;
            default: rb = 11'd0;
        endcase
    end

    always_ff @(posedge tx_clk or negedge tx_rs[1]) begin
        if (!tx_rs[1]) begin
            st_sync <= '0;  tst <= T_IDLE;
            tx_valid <= 1'b0;  tx_data <= '0;  cur <= '0;  len_tx <= '0;  done_t <= 1'b0;
            src_v <= 1'b0;  vb <= 1'b0;  vb_free_t <= '0;
        end else begin
            st_sync <= {st_sync[1:0], start_t};
            case (tst)
                T_IDLE: if (cpu_pend) begin                    // tx_len стабилен, пока TX_BUSY
                    len_tx <= tx_len;
                    src_v  <= 1'b0;
                    tst    <= T_LOAD0;
                end else if (vid_pend) begin
                    len_tx <= VLEN;
                    src_v  <= 1'b1;
                    tst    <= T_LOAD0;
                end
                T_LOAD0: tst <= T_LOAD1;
                T_LOAD1: begin
                    tx_data  <= q_byte;
                    cur      <= '0;
                    tx_valid <= 1'b1;
                    tst      <= T_SEND;
                end
                T_SEND: if (accept) begin
                    if (tx_last) begin
                        tx_valid <= 1'b0;
                        tst      <= T_IDLE;
                        if (src_v) begin
                            vb_free_t[vb] <= ~vb_free_t[vb];
                            vb            <= ~vb;
                        end else begin
                            done_t <= ~done_t;
                        end
                    end else begin
                        tx_data <= q_byte;
                        cur     <= cur + 1'b1;
                    end
                end
            endcase
        end
    end

    // =====================================================================
    // Домен clk: указатели, счётчики, Wishbone
    // =====================================================================
    logic [1:0] wptr_g1, wptr_g2, wptr_s;
    logic [2:0] ok_s, err_s, drop_s, done_s;
    logic [1:0] vfr_s0, vfr_s1, vfr_s2;
    always_ff @(posedge clk) begin
        vfr_s0 <= vb_free_t;  vfr_s1 <= vfr_s0;  vfr_s2 <= vfr_s1;
        wptr_g1 <= wptr_g;   wptr_g2 <= wptr_g1;
        ok_s    <= {ok_s[1:0],   ev_ok_t};
        err_s   <= {err_s[1:0],  ev_err_t};
        drop_s  <= {drop_s[1:0], ev_drop_t};
        done_s  <= {done_s[1:0], done_t};
    end
    assign wptr_s = {wptr_g2[1], wptr_g2[1] ^ wptr_g2[0]};

    logic        rx_avail, tx_busy;
    logic [11:0] rx_len_cur;
    assign rx_avail   = (wptr_s != rptr);
    assign tx_busy    = (start_t != done_s[1]);
    assign rx_len_cur = rptr[0] ? len1 : len0;

    logic [31:0] rx_q;
    always_ff @(posedge clk) rx_q <= rx_mem[{rptr[0], wb_adr[10:2]}];

    logic [31:0] cnt_ok, cnt_err, cnt_drop, cnt_tx, cnt_vid;
    logic        mdio_out;
    logic [1:0]  mdio_s;
    assign mdio = mdio_out ? 1'bz : 1'b0;
    always_ff @(posedge clk) mdio_s <= {mdio_s[0], mdio};
    logic        wr;
    assign wr = wb_stb & ~wb_ack & wb_we;

    always_ff @(posedge clk) begin
        if (wr && wb_adr[11]) tx_mem[wb_adr[10:2]] <= wb_wdata;
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            wb_ack <= 1'b0;
            rptr <= '0;  rptr_g <= '0;
            start_t <= 1'b0;  tx_len <= '0;
            cnt_ok <= '0;  cnt_err <= '0;  cnt_drop <= '0;  cnt_tx <= '0;  cnt_vid <= '0;
            mdc <= 1'b0;  mdio_out <= 1'b1;
        end else begin
            wb_ack <= wb_stb & ~wb_ack;
            if (wr && !wb_adr[11]) begin
                case (wb_adr[10:2])
                    9'd3: if (rx_avail) begin                      // RX_POP
                        rptr   <= rptr + 1'b1;
                        rptr_g <= (rptr + 1'b1) ^ ((rptr + 1'b1) >> 1);
                    end
                    9'd4: if (!tx_busy && wb_wdata[11:0] != 12'd0) begin   // TX_LEN
                        tx_len  <= wb_wdata[11:0];
                        start_t <= ~start_t;
                    end
                    9'd9: begin                                    // MDIO
                        mdc      <= wb_wdata[0];
                        mdio_out <= wb_wdata[1];
                    end
                    default: ;
                endcase
            end
            if (ok_s[2]   != ok_s[1])   cnt_ok   <= cnt_ok + 1'b1;
            if (err_s[2]  != err_s[1])  cnt_err  <= cnt_err + 1'b1;
            if (drop_s[2] != drop_s[1]) cnt_drop <= cnt_drop + 1'b1;
            if (done_s[2] != done_s[1]) cnt_tx   <= cnt_tx + 1'b1;
            cnt_vid <= cnt_vid + (vfr_s2[0] ^ vfr_s1[0]) + (vfr_s2[1] ^ vfr_s1[1]);
        end
    end

    always_comb begin
        if (wb_adr[11]) wb_rdata = rx_q;
        else begin
            case (wb_adr[10:2])
                9'd0:    wb_rdata = ID;
                9'd1:    wb_rdata = {29'b0, phy_ready, tx_busy, rx_avail};
                9'd2:    wb_rdata = {20'b0, rx_len_cur};
                9'd5:    wb_rdata = cnt_ok;
                9'd6:    wb_rdata = cnt_err;
                9'd7:    wb_rdata = cnt_drop;
                9'd8:    wb_rdata = cnt_tx;
                9'd9:    wb_rdata = {23'b0, mdio_s[1], 6'b0, mdio_out, mdc};
                9'd10:   wb_rdata = cnt_vid;
                default: wb_rdata = 32'h0;
            endcase
        end
    end
endmodule
