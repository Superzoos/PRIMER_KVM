// usb_hid - USB-устройство "клавиатура + мышь" для удалённого ПК (PHY USB3317 на Dock, ULPI).
//   Ядро - Gowin USB 2.0 Device Controller (IPUG927, ULPI, High Speed; модуль usb_dev_ctl, ip-gen.ps1): оно само
//   отвечает на стандартные запросы и отдаёт описатели из usb_desc_rom (scripts/usbdesc.py). Здесь:
//   - IF0 - клавиатура с поддержкой BIOS (boot), EP1 IN, отчёт 8 байт: модификаторы, 0, 6 кодов клавиш (HID);
//   - IF1 - мышь с абсолютными координатами, EP2 IN, отчёт 7 байт: кнопки (биты 4:0 - левая, правая, средняя,
//     назад, вперёд), X u16, Y u16 (0..32767 - весь экран), колесо i8, горизонтальная прокрутка i8;
//   - описатель отчётов HID: у ядра один адрес на все интерфейсы, поэтому он выбирается по wIndex запроса
//     GET_DESCRIPTOR(HID report), который ядро передаёт наружу вместе со всеми пакетами SETUP (setup_o);
//   - запросы класса HID (EP0): SET_IDLE, SET_PROTOCOL, SET_REPORT (светодиоды клавиатуры) - запоминаются;
//     GET_REPORT, GET_IDLE, GET_PROTOCOL - ответ через txval_i (как GET_LINE_CODING в примере Gowin);
//   - отчёт отправляется один раз, когда хост опросит конечную точку (IN); пока ядро процессора не дало новый
//     отчёт - NAK (txcork_i = 1).
//
// Регистры (слот Wishbone, домен clk):
//   0x00 ID      RO  0x5553_4248 ("USBH")
//   0x04 CTRL    WO  бит 0 - отправить отчёт клавиатуры (KBD0/KBD1), бит 1 - отправить отчёт мыши (MOUSE0/MOUSE1)
//   0x08 STATUS  RO  бит 0 ONLINE (устройство сконфигурировано хостом), 1 HIGHSPEED, 2 SUSPEND, 3 KBD_PEND и
//                    4 MOUSE_PEND (отчёт ещё не забран хостом), 5 BOOT (клавиатура в режиме boot),
//                    биты 15:8 - светодиоды клавиатуры (бит 8 NumLock, 9 CapsLock, 10 ScrollLock),
//                    биты 23:16 - число сбросов шины USB (циклический)
//   0x0C KBD0    RW  байты 0..3 отчёта клавиатуры (байт 0 - биты 7:0)
//   0x10 KBD1    RW  байты 4..7
//   0x14 MOUSE0  RW  байты 0..3 отчёта мыши
//   0x18 MOUSE1  RW  байты 4..6 (биты 23:0)
// KBDn/MOUSEn менять до записи CTRL; отчёт копируется в домен USB по CTRL (они стабильны - ядро пишет следующий
// не раньше чем через ~1 мс).
module usb_hid (
    input  logic        clk,
    input  logic        rst_n,
    input  logic        wb_stb,
    input  logic        wb_we,
    input  logic [11:0] wb_adr,
    input  logic [31:0] wb_wdata,
    output logic        wb_ack,
    output logic [31:0] wb_rdata,
    // ULPI (USB3317), домен usb_clk = ULPI CLKOUT 60 МГц
    input  logic        usb_clk,
    input  logic        phy_rst_n,                    // RESETB USB3317 (общий с RTL8201F, eth_sys): 0 - PHY в сбросе
    input  logic        ulpi_dir,
    input  logic        ulpi_nxt,
    output logic        ulpi_stp,
    input  logic [7:0]  ulpi_rxdata,
    output logic [7:0]  ulpi_txdata
);
    localparam logic [31:0] ID = 32'h5553_4248;

    // =====================================================================
    // Домен clk: регистры
    // =====================================================================
    logic [31:0] r_kbd0, r_kbd1, r_ms0, r_ms1;
    logic        kbd_t, ms_t;                         // запросы отправки (переключатели) -> домен USB
    logic [2:0]  kdone_s, mdone_s;                    // отчёт забран хостом <- домен USB
    logic [15:0] st_s1, st_s2;                        // {сбросы[7:0]... см. ниже} из домена USB
    logic [7:0]  rst_cnt_s1, rst_cnt_s2;
    logic        u_kdone_t, u_mdone_t;                // домен USB
    logic [15:0] u_st;                                // {светодиоды, 2'b0, boot, suspend, highspeed, online}... (домен USB)
    logic [7:0]  u_rst_cnt;
    logic        wr;
    assign wr = wb_stb & ~wb_ack & wb_we;

    always_ff @(posedge clk) begin
        kdone_s    <= {kdone_s[1:0], u_kdone_t};
        mdone_s    <= {mdone_s[1:0], u_mdone_t};
        st_s1      <= u_st;        st_s2      <= st_s1;          // медленные флаги, по отдельности
        rst_cnt_s1 <= u_rst_cnt;   rst_cnt_s2 <= rst_cnt_s1;
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            wb_ack <= 1'b0;
            r_kbd0 <= '0;  r_kbd1 <= '0;  r_ms0 <= '0;  r_ms1 <= '0;
            kbd_t  <= 1'b0;  ms_t <= 1'b0;
        end else begin
            wb_ack <= wb_stb & ~wb_ack;
            if (wr) begin
                case (wb_adr[7:2])
                    6'd1: begin
                        if (wb_wdata[0]) kbd_t <= ~kbd_t;
                        if (wb_wdata[1]) ms_t  <= ~ms_t;
                    end
                    6'd3: r_kbd0 <= wb_wdata;
                    6'd4: r_kbd1 <= wb_wdata;
                    6'd5: r_ms0  <= wb_wdata;
                    6'd6: r_ms1  <= {8'h0, wb_wdata[23:0]};
                    default: ;
                endcase
            end
        end
    end

    always_comb begin
        case (wb_adr[7:2])
            6'd0:    wb_rdata = ID;
            6'd2:    wb_rdata = {8'h0, rst_cnt_s2, st_s2[15:8], 2'b0, st_s2[5],
                                 mdone_s[2] != ms_t, kdone_s[2] != kbd_t, st_s2[2:0]};
            6'd3:    wb_rdata = r_kbd0;
            6'd4:    wb_rdata = r_kbd1;
            6'd5:    wb_rdata = r_ms0;
            6'd6:    wb_rdata = r_ms1;
            default: wb_rdata = 32'h0;
        endcase
    end

    // =====================================================================
    // Домен USB
    // =====================================================================
    // Сброс ядра USB. Пока RESETB = 0, выводы USB3317 (и CLKOUT) в третьем состоянии (USB3317 rev C, п. 2.1.2),
    // такта нет. Ядро держится в сбросе, пока PHY в сбросе, и ещё ~3 мс по такту CLKOUT после его появления:
    // запуск PLL PHY (TSTART до 2.28 мс, табл. 4.2) - чтобы ядро настраивало PHY, когда тот уже готов.
    localparam logic [17:0] START_CYC = 18'd180000;   // 3 мс при 60 МГц
    logic       ures_n;
    assign ures_n = rst_n & phy_rst_n;
    logic [2:0]  urs;
    logic [17:0] ucnt;
    logic        u_rst;
    always_ff @(posedge usb_clk or negedge ures_n) begin
        if (!ures_n) begin
            urs   <= '0;
            ucnt  <= '0;
            u_rst <= 1'b1;
        end else begin
            urs <= {urs[1:0], 1'b1};
            if (urs[2]) begin
                if (ucnt != START_CYC) ucnt <= ucnt + 1'b1;
                else                         u_rst <= 1'b0;
            end
        end
    end

    // ---------- ядро ----------
    logic        busrst, highspeed, suspend, online;
    logic [7:0]  txdat, rxdat;
    logic        txval, txcork, txpop, txact, txpktfin, rxval, rxact, rxpktval, setup, sof;
    logic [11:0] txlen;
    logic [3:0]  endpt;
    logic [7:0]  inf_alter_o, inf_sel_o;
    logic        inf_set_o;
    logic [15:0] d_raddr;
    logic [7:0]  d_index, d_type, d_rdata;
    logic [15:0] dev_a, dev_l, qual_a, qual_l, fs_a, fs_l, hs_a, hs_l, os_a, os_l, lang_a, lang_l;
    logic [15:0] ven_a, ven_l, prod_a, prod_l, kr_a, kr_l, mr_a, mr_l;
    logic        hid_sel;                         // описатель отчётов: 0 - клавиатуры, 1 - мыши

    usb_desc_rom u_rom (
        .addr (d_raddr),  .data (d_rdata),
        .dev_addr (dev_a), .dev_len (dev_l), .qual_addr (qual_a), .qual_len (qual_l),
        .fscfg_addr (fs_a), .fscfg_len (fs_l), .hscfg_addr (hs_a), .hscfg_len (hs_l),
        .oscfg_addr (os_a), .oscfg_len (os_l), .lang_addr (lang_a), .lang_len (lang_l),
        .vendor_addr (ven_a), .vendor_len (ven_l), .product_addr (prod_a), .product_len (prod_l),
        .kbdrpt_addr (kr_a), .kbdrpt_len (kr_l), .mouserpt_addr (mr_a), .mouserpt_len (mr_l)
    );

    usb_dev_ctl u_ctl (
        .clk_i                  (usb_clk),
        .reset_i                (u_rst),
        .usbrst_o               (busrst),
        .highspeed_o            (highspeed),
        .suspend_o              (suspend),
        .online_o               (online),
        .txdat_i                (txdat),
        .txval_i                (txval),
        .txdat_len_i            (txlen),
        .txiso_pid_i            (4'b0011),
        .txcork_i               (txcork),
        .txpop_o                (txpop),
        .txact_o                (txact),
        .txpktfin_o             (txpktfin),
        .rxdat_o                (rxdat),
        .rxval_o                (rxval),
        .rxrdy_i                (1'b1),
        .rxact_o                (rxact),
        .rxpktval_o             (rxpktval),
        .setup_o                (setup),
        .endpt_o                (endpt),
        .sof_o                  (sof),
        .inf_alter_i            (8'd0),
        .inf_alter_o            (inf_alter_o),
        .inf_sel_o              (inf_sel_o),
        .inf_set_o              (inf_set_o),
        .descrom_raddr_o        (d_raddr),
        .desc_index_o           (d_index),
        .desc_type_o            (d_type),
        .descrom_rdata_i        (d_rdata),
        .desc_dev_addr_i        (dev_a),
        .desc_dev_len_i         (dev_l),
        .desc_qual_addr_i       (qual_a),
        .desc_qual_len_i        (qual_l),
        .desc_fscfg_addr_i      (fs_a),
        .desc_fscfg_len_i       (fs_l),
        .desc_hscfg_addr_i      (hs_a),
        .desc_hscfg_len_i       (hs_l),
        .desc_oscfg_addr_i      (os_a),
        .desc_hidrpt_addr_i     (hid_sel ? mr_a : kr_a),
        .desc_hidrpt_len_i      (hid_sel ? mr_l : kr_l),
        .desc_bos_addr_i        (16'd0),
        .desc_bos_len_i         (16'd0),
        .desc_strlang_addr_i    (lang_a),
        .desc_strvendor_addr_i  (ven_a),
        .desc_strvendor_len_i   (ven_l),
        .desc_strproduct_addr_i (prod_a),
        .desc_strproduct_len_i  (prod_l),
        .desc_strserial_addr_i  (16'd0),
        .desc_strserial_len_i   (16'd0),
        .desc_have_strings_i    (1'b1),
        .ulpi_nxt_i             (ulpi_nxt),
        .ulpi_dir_i             (ulpi_dir),
        .ulpi_rxdata_i          (ulpi_rxdata),
        .ulpi_txdata_o          (ulpi_txdata),
        .ulpi_stp_o             (ulpi_stp)
    );

    // ---------- отчёты: из домена clk по переключателям ----------
    logic [2:0]  kbd_s, ms_s;
    logic [63:0] kbd_buf, ms_buf, kbd_new, ms_new;    // байт 0 - биты 7:0
    logic        kbd_pend, ms_pend, kbd_nv, ms_nv;    // ждёт опроса хоста; есть новый, ещё не перенесённый
    logic        kn_t, kb_t, mn_t, mb_t;              // значение переключателя запроса у нового отчёта / в буфере
    logic [3:0]  idx;                                 // номер байта в передаче (txpop - следующий)
    logic        ep1_tx, ep2_tx;
    assign ep1_tx = txact && endpt == 4'd1;
    assign ep2_tx = txact && endpt == 4'd2;

    // ---------- EP0: SETUP и запросы класса ----------
    logic [3:0]  sb;                                  // номер байта пакета SETUP
    logic [7:0]  s_type, s_req, s_vlo, s_vhi, s_ilo;
    logic [15:0] s_len;
    logic        ep0_send, rep_out;
    logic [63:0] ep0_buf;
    logic [3:0]  ep0_len;
    logic [7:0]  leds, idle0, idle1;
    logic        proto0, proto1;                     // 0 - boot, 1 - report

    // данные IN по номеру конечной точки (ядро переключает их вместе с endpt_o, IPUG927 3.5)
    always_comb begin
        txval  = 1'b0;
        txcork = 1'b1;
        txlen  = 12'd0;
        txdat  = 8'h00;
        case (endpt)
            4'd0: begin
                txval  = ep0_send;
                txcork = 1'b0;
                txlen  = {8'h0, ep0_len};
                txdat  = ep0_buf[idx*8 +: 8];
            end
            4'd1: begin
                txcork = ~kbd_pend;
                txlen  = 12'd8;
                txdat  = kbd_buf[idx*8 +: 8];
            end
            4'd2: begin
                txcork = ~ms_pend;
                txlen  = 12'd7;
                txdat  = ms_buf[idx*8 +: 8];
            end
            default: ;
        endcase
    end

    function automatic logic [3:0] min_len(input logic [3:0] n, input logic [15:0] w);
        return (w < {12'h0, n}) ? w[3:0] : n;
    endfunction

    always_ff @(posedge usb_clk or posedge u_rst) begin
        if (u_rst) begin
            kbd_s <= '0;  ms_s <= '0;
            kbd_buf <= '0;  ms_buf <= '0;  kbd_new <= '0;  ms_new <= '0;
            kbd_pend <= 1'b0;  ms_pend <= 1'b0;  kbd_nv <= 1'b0;  ms_nv <= 1'b0;
            u_kdone_t <= 1'b0;  u_mdone_t <= 1'b0;  idx <= '0;
            kn_t <= 1'b0;  kb_t <= 1'b0;  mn_t <= 1'b0;  mb_t <= 1'b0;
            sb <= '0;  s_type <= '0;  s_req <= '0;  s_vlo <= '0;  s_vhi <= '0;  s_ilo <= '0;  s_len <= '0;
            ep0_send <= 1'b0;  rep_out <= 1'b0;  ep0_buf <= '0;  ep0_len <= '0;
            leds <= '0;  idle0 <= '0;  idle1 <= '0;  proto0 <= 1'b1;  proto1 <= 1'b1;  hid_sel <= 1'b0;
            u_rst_cnt <= '0;
        end else begin
            kbd_s <= {kbd_s[1:0], kbd_t};
            ms_s  <= {ms_s[1:0], ms_t};

            // новый отчёт: забрать из регистров (стабильны) и перенести в буфер, когда его не передают
            if (kbd_s[2] != kbd_s[1]) begin
                kbd_new <= {r_kbd1, r_kbd0};
                kn_t    <= kbd_s[1];
                kbd_nv  <= 1'b1;
            end else if (kbd_nv && !ep1_tx) begin
                kbd_buf  <= kbd_new;
                kb_t     <= kn_t;
                kbd_pend <= 1'b1;
                kbd_nv   <= 1'b0;
            end
            if (ms_s[2] != ms_s[1]) begin
                ms_new <= {r_ms1, r_ms0};
                mn_t   <= ms_s[1];
                ms_nv  <= 1'b1;
            end else if (ms_nv && !ep2_tx) begin
                ms_buf  <= ms_new;
                mb_t    <= mn_t;
                ms_pend <= 1'b1;
                ms_nv   <= 1'b0;
            end

            // передача IN: номер байта; пакет подтверждён хостом (txpktfin) - отчёт забран
            if (!txact)     idx <= '0;
            else if (txpop) idx <= idx + 1'b1;
            // (если в этом же такте в буфер переносится новый отчёт - флаг не сбрасывать)
            if (txpktfin && endpt == 4'd1) begin
                if (!(kbd_nv && !ep1_tx && kbd_s[2] == kbd_s[1])) kbd_pend <= 1'b0;
                u_kdone_t <= kb_t;
            end
            if (txpktfin && endpt == 4'd2) begin
                if (!(ms_nv && !ep2_tx && ms_s[2] == ms_s[1])) ms_pend <= 1'b0;
                u_mdone_t <= mb_t;
            end

            // SETUP: 8 байт при setup_o (endpt 0)
            if (!setup) sb <= '0;
            else if (rxval && sb != 4'd8) begin
                sb <= sb + 1'b1;
                case (sb)
                    4'd0: begin
                        s_type   <= rxdat;
                        ep0_send <= 1'b0;
                        rep_out  <= 1'b0;
                    end
                    4'd1: s_req <= rxdat;
                    4'd2: s_vlo <= rxdat;
                    4'd3: s_vhi <= rxdat;
                    4'd4: begin
                        s_ilo <= rxdat;
                        // GET_DESCRIPTOR (стандартный, к интерфейсу), тип 0x22 - выбрать описатель отчётов
                        if (s_type == 8'h81 && s_req == 8'h06 && s_vhi == 8'h22) hid_sel <= (rxdat == 8'd1);
                    end
                    4'd6: s_len[7:0] <= rxdat;
                    4'd7: begin
                        s_len[15:8] <= rxdat;
                        if (s_type == 8'h21) begin                   // класс, хост -> интерфейс
                            case (s_req)
                                8'h0A: if (s_ilo == 8'd0) idle0 <= s_vhi; else idle1 <= s_vhi;    // SET_IDLE
                                8'h0B: if (s_ilo == 8'd0) proto0 <= s_vlo[0]; else proto1 <= s_vlo[0];  // SET_PROTOCOL
                                8'h09: rep_out <= (s_ilo == 8'd0);    // SET_REPORT: 1 байт светодиодов
                                default: ;
                            endcase
                        end else if (s_type == 8'hA1) begin          // класс, интерфейс -> хост
                            case (s_req)
                                8'h01: begin                         // GET_REPORT
                                    ep0_buf  <= (s_ilo == 8'd0) ? kbd_buf : ms_buf;
                                    ep0_len  <= min_len((s_ilo == 8'd0) ? 4'd8 : 4'd7, {rxdat, s_len[7:0]});
                                    ep0_send <= 1'b1;
                                end
                                8'h02: begin                         // GET_IDLE
                                    ep0_buf  <= {56'h0, (s_ilo == 8'd0) ? idle0 : idle1};
                                    ep0_len  <= min_len(4'd1, {rxdat, s_len[7:0]});
                                    ep0_send <= 1'b1;
                                end
                                8'h03: begin                         // GET_PROTOCOL
                                    ep0_buf  <= {63'h0, (s_ilo == 8'd0) ? proto0 : proto1};
                                    ep0_len  <= min_len(4'd1, {rxdat, s_len[7:0]});
                                    ep0_send <= 1'b1;
                                end
                                default: ;
                            endcase
                        end
                    end
                    default: ;
                endcase
            end
            // этап данных SET_REPORT (OUT, EP0): первый байт - светодиоды клавиатуры
            if (rep_out && !setup && rxact && endpt == 4'd0 && rxval) begin
                leds    <= rxdat;
                rep_out <= 1'b0;
            end

            if (busrst) begin                                // сброс шины: протокол отчётов по умолчанию
                proto0 <= 1'b1;  proto1 <= 1'b1;  idle0 <= '0;  idle1 <= '0;
                u_rst_cnt <= u_rst_cnt + 1'b1;
            end
        end
    end

    assign u_st = {leds, 2'b00, ~proto0, 2'b00, suspend, highspeed, online};
endmodule
