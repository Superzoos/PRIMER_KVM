// hdmi_rx - вход HDMI/DVI (модуль Sipeed PMOD_DVI): EDID и HPD, измерение сигнала, захват кадра в DDR3.
//   IP DVI RX (dvi_rx, в kvm_top) даёт пиксельный такт и RGB888 + DE. Здесь:
//   - поправка полярности: у пар данных модуля P на пине [B] (kvm.cst), поэтому приёмник видит инверсный
//     поток. Декодер TMDS при инверсии даёт D[0] без изменений и D[7:1] инверсными (раскрытие инверсии
//     по биту 9 сохраняется, выбор XOR/XNOR по биту 8 меняется) -> данные ^ 8'hFE. DE не меняется
//     (инверсные управляющие символы - тоже управляющие);
//   - кадр определяется по DE (без VS/HS, полярность не важна): новая строка - фронт DE; новый кадр - если
//     с прошлого фронта прошло больше 1.5 периодов строки (кадровое гашение);
//   - ширина/высота последнего кадра, счётчик кадров, частота пиксельного такта;
//   - захват (CTRL.CAP_EN): с начала следующего кадра пиксели RGB565 упаковываются по 8 в 128-битные слова,
//     через асинхронную FIFO уходят в домен DDR3 и пишутся в один из трёх буферов (CAP_BASE + n * CAP_BSIZE,
//     n = 0..2), строки через CAP_STRIDE байт; выключение CAP_EN действует с начала следующего кадра;
//   - три буфера (домен DDR3): в начале кадра захват берёт буфер, который не "последний готовый" (LATEST) и
//     не закреплён отправкой (LOCKED), - такой есть всегда. Кадр становится LATEST только после записи
//     последнего слова сумм плиток (флаг eof, см. ниже): неполные и битые кадры никогда не становятся
//     LATEST и не передаются. Отправка закрепляет LATEST (BUF.LOCK) и освобождает (BUF.UNLOCK) - пока буфер
//     закреплён, захват в него не пишет. Включение CAP_EN сбрасывает HAS_FRAME (старый кадр не отдаётся);
//   - суммы плиток: CRC-32 каждой плитки 32x16 (алгоритм - у crc_px ниже) при захвате; таблица в буфере с
//     CAP_HOFS: ряды плиток сверху вниз, в ряду - 128-битные слова по 4 плитки (плитка 4n - биты 31:0),
//     ceil(столбцов/4) слов на ряд. Кадр становится LATEST после последнего слова сумм, если в нём не было
//     строки не той длины и потери слов (иначе кадр не отдаётся). Пиксели за пределами CAP_SIZE не пишутся;
//     ширина CAP_SIZE кратна 32 и не больше 2048;
//   - слово FIFO: {hash, eof, sof, eol, 128 бит}: hash = 1 - слово сумм (eof - последнее в полном кадре),
//     иначе 8 пикселей (sof - первое слово кадра, eol - последнее слово строки);
//   - EDID: 256 байт в памяти, их пишет ядро; ведомый I2C 0x50 на линиях DDC; HPD - бит CTRL.
//
// Регистры (слот Wishbone, домен clk):
//   0x000 ID          RO  0x4844_5258 ("HDRX")
//   0x004 CTRL        RW  бит 0 HPD, бит 1 CAP_EN, бит 2 RX_RESET (1 - держать IP DVI RX в сбросе); после сброса 0
//   0x008 TMDS_KHZ    RO  частота пиксельного такта (= такт TMDS), кГц, обновляется каждую 1 мс
//   0x00C STATUS      RO  бит 0 PLL_LOCK, 1 PHASE_LOCK, 2 VIDEO (кадр был < 100 мс назад), 3 CAPTURING,
//                         4 DDC (идёт обмен по DDC), 5 OVERFLOW (FIFO захвата переполнялась), биты 11:8 - фаза PLL.
//                         Запись в STATUS сбрасывает OVERFLOW и FIFO_MAX
//   0x010 RES         RO  ширина | высота << 16 последнего кадра
//   0x014 FRAMES      RO  принято кадров
//   0x018 CAP_FRAMES  RO  захвачено кадров
//   0x01C CAP_BASE    RW  байтовый адрес буфера 0 в DDR3 (кратен 16); менять при CAP_EN = 0 и CAPTURING = 0
//   0x020 CAP_STRIDE  RW  байт между строками (кратен 16); так же
//   0x03C CAP_BSIZE   RW  расстояние между буферами, байт (кратно 16); так же
//   0x044 CAP_HOFS    RW  смещение таблицы сумм плиток от начала буфера, байт (кратно 16); так же
//   0x040 BUF         W   бит 0 LOCK - закрепить LATEST за отправкой; бит 1 UNLOCK - освободить
//                     R   бит 0 BUSY (LOCK ещё выполняется), 1 LOCKED, 3:2 номер закреплённого буфера,
//                         4 HAS_FRAME (есть готовый кадр), 7:6 номер LATEST. LOCK при HAS_FRAME = 0 -> LOCKED = 0
//   Диагностика приёма (счётчики циклические, разность двух чтений - число событий за интервал):
//   0x024 CAP_SIZE    RW  ожидаемый кадр: ширина | высота << 16 (для BAD_LINES/BAD_FRAMES; 0 - не считать)
//   0x028 LOCK_LOSS   RO  биты 15:0 - потерь захвата PLL приёмника, 31:16 - потерь фазы (по спаду флага)
//   0x02C BAD_LINES   RO  строк, у которых длина DE != ширины CAP_SIZE (24 бита)
//   0x030 BAD_FRAMES  RO  кадров, у которых число строк != высоты CAP_SIZE (24 бита)
//   0x034 LOST_WORDS  RO  слов захвата (8 пикселей), потерянных из-за полной FIFO (24 бита)
//   0x038 FIFO_MAX    RO  наибольшее заполнение FIFO захвата, слов (из 256), с последней записи в STATUS
//   0x100..0x1FF EDID RW  256 байт EDID словами (байт 0 - биты 7:0 слова 0)
module hdmi_rx #(
    parameter int CLK_HZ   = 40_500_000,
    parameter int ROW_BITS = 13
) (
    input  logic        clk,
    input  logic        rst_n,
    // от IP DVI RX
    input  logic        pix_clk,
    input  logic        pix_de,
    input  logic [7:0]  pix_r,
    input  logic [7:0]  pix_g,
    input  logic [7:0]  pix_b,
    input  logic        rx_pll_lock,
    input  logic [3:0]  rx_phase,
    input  logic        rx_phase_lock,
    output logic        rx_rst_n,
    // DDC и HPD
    input  logic        ddc_scl,
    inout  wire         ddc_sda,
    output logic        hpd,
    // Wishbone (stb уже выбран дешифратором)
    input  logic        wb_stb,
    input  logic        wb_we,
    input  logic [11:0] wb_adr,
    input  logic [31:0] wb_wdata,
    output logic        wb_ack,
    output logic [31:0] wb_rdata,
    // запись в DDR3 (домен dclk, к ddr_arb)
    input  logic        dclk,
    input  logic        drst,
    output logic        cw_valid,
    output logic [ROW_BITS+9:0] cw_line,      // адрес 16-байтного слова
    output logic [127:0] cw_data,
    input  logic        cw_pop
);
    localparam logic [31:0] ID  = 32'h4844_5258;
    localparam int          LB  = ROW_BITS + 10;
    localparam int          WIN = CLK_HZ / 1000;

    // =====================================================================
    // Домен clk: регистры
    // =====================================================================
    logic        r_hpd, r_cap_en, r_rx_rst;
    logic [LB-1:0] r_base, r_bsize, r_hofs;
    logic        lock_t, unlock_t;            // запросы в домен DDR3 (переключатели)
    logic [2:0]  ack_s;                       // ответ на LOCK из домена DDR3
    logic [5:0]  bst_s1, bst_s2;              // {LATEST, HAS_FRAME, номер LOCKED, LOCKED} из домена DDR3
    logic        d_ack_t;                     // домен DDR3
    logic [5:0]  d_bst;
    logic [11:0] r_stride;                    // в 16-байтных словах
    logic        ovf_sticky;
    logic [31:0] frames, cap_frames;
    logic [15:0] res_w, res_h;
    logic        video;
    logic [31:0] pix_khz;
    logic [2:0]  frm_s, cap_s, ovf_s;
    logic [1:0]  capt_s, lock_s, plock_s;
    logic [3:0]  phase_s1, phase_s2;
    logic        ddc_active;
    logic [15:0] r_cap_w, r_cap_h;
    logic [15:0] pll_loss, ph_loss;
    logic        lock_d, plock_d;
    logic [23:0] bl_g1, bl_g2, bf_g1, bf_g2, lw_g1, lw_g2;   // счётчики из домена пикселей (код Грея)
    logic [8:0]  fw_g1, fw_g2, fr_g1, fr_g2;                 // указатели FIFO захвата (код Грея)
    logic [8:0]  f_wptr, f_rptr;
    logic [8:0]  fifo_max, f_level;
    logic [23:0] bl_b, bf_b, lw_b, fw_b, fr_b;
    // счётчики ошибок в домене пикселей: двоичный + копия в коде Грея для чтения из домена clk
    logic [23:0] bl_bin, bf_bin, lw_bin, bl_gray, bf_gray, lw_gray;

    function automatic logic [23:0] g2b(input logic [23:0] g);   // код Грея -> двоичный
        logic [23:0] b;
        b[23] = g[23];
        for (int i = 22; i >= 0; i--) b[i] = b[i+1] ^ g[i];
        return b;
    endfunction

    logic        frm_t, cap_t, ovf_t, capturing;     // домен пикселей
    logic [15:0] f_w, f_h;                            // домен пикселей, стабильны между кадрами

    assign hpd      = r_hpd;
    assign rx_rst_n = rst_n & ~r_rx_rst;

    // EDID: 64 слова. Один порт записи (ядро) и один порт чтения (BSRAM SDP): читает I2C, а при обращении
    // ядра к окну EDID - ядро (только при загрузке и проверке EDID, пока HPD = 0 и ПК его не читает).
    logic [31:0] edid_mem [0:63];
    logic [31:0] edid_q;
    logic [7:0]  i2c_addr;
    logic [31:0] i2c_word;
    logic [5:0]  edid_ra;
    logic        wr, cpu_edid;
    assign wr       = wb_stb & ~wb_ack & wb_we;
    assign cpu_edid = wb_stb & (wb_adr[11:8] == 4'h1);
    assign edid_ra  = cpu_edid ? wb_adr[7:2] : i2c_addr[7:2];

    always_ff @(posedge clk) begin
        if (wr && wb_adr[11:8] == 4'h1) edid_mem[wb_adr[7:2]] <= wb_wdata;
        edid_q <= edid_mem[edid_ra];
    end
    assign i2c_word = edid_q;

    // ---------- I2C (DDC) ----------
    logic sda_low;
    assign ddc_sda = sda_low ? 1'b0 : 1'bz;
    i2c_edid #(.ADDR(7'h50)) u_i2c (
        .clk     (clk),
        .rst_n   (rst_n),
        .scl_i   (ddc_scl),
        .sda_i   (ddc_sda),
        .sda_low (sda_low),
        .rd_addr (i2c_addr),
        .rd_data (i2c_word[i2c_addr[1:0]*8 +: 8]),
        .active  (ddc_active)
    );

    // ---------- синхронизация событий из домена пикселей ----------
    always_ff @(posedge clk) begin
        frm_s    <= {frm_s[1:0], frm_t};
        cap_s    <= {cap_s[1:0], cap_t};
        ovf_s    <= {ovf_s[1:0], ovf_t};
        capt_s   <= {capt_s[0], capturing};
        lock_s   <= {lock_s[0], rx_pll_lock};
        plock_s  <= {plock_s[0], rx_phase_lock};
        phase_s1 <= rx_phase;
        phase_s2 <= phase_s1;
        ack_s    <= {ack_s[1:0], d_ack_t};
        bst_s1   <= d_bst;
        bst_s2   <= bst_s1;
        bl_g1 <= bl_gray;  bl_g2 <= bl_g1;
        bf_g1 <= bf_gray;  bf_g2 <= bf_g1;
        lw_g1 <= lw_gray;  lw_g2 <= lw_g1;
        fw_g1 <= f_wptr;   fw_g2 <= fw_g1;
        fr_g1 <= f_rptr;   fr_g2 <= fr_g1;
    end
    assign bl_b = g2b(bl_g2);
    assign bf_b = g2b(bf_g2);
    assign lw_b = g2b(lw_g2);
    assign fw_b = g2b({15'b0, fw_g2});
    assign fr_b = g2b({15'b0, fr_g2});
    // заполнение FIFO: указатели синхронизированы в разное время, поэтому разность может кратко выйти за
    // 0..256 (указатель чтения "обогнал" запись) - такие значения не учитываются
    assign f_level = fw_b[8:0] - fr_b[8:0];

    // ---------- частота пиксельного такта: счётчик Грея, окно 1 мс ----------
    logic [23:0] p_bin, p_gray, pg1, pg2, pg2b, p_prev;
    always_ff @(posedge pix_clk) begin
        p_bin  <= p_bin + 1'b1;
        p_gray <= p_bin ^ (p_bin >> 1);
    end
    always_ff @(posedge clk) begin
        pg1 <= p_gray;
        pg2 <= pg1;
    end
    always_comb begin
        pg2b[23] = pg2[23];
        for (int i = 22; i >= 0; i--) pg2b[i] = pg2b[i+1] ^ pg2[i];
    end

    logic [$clog2(WIN)-1:0] win;
    logic [6:0] vid_ms;                       // мс с последнего кадра (насыщение 127)

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            wb_ack <= 1'b0;
            r_hpd <= 1'b0;  r_cap_en <= 1'b0;  r_rx_rst <= 1'b0;
            r_base <= '0;  r_stride <= '0;  ovf_sticky <= 1'b0;  r_bsize <= '0;  lock_t <= 1'b0;  unlock_t <= 1'b0;
            r_hofs <= '0;
            frames <= '0;  cap_frames <= '0;  res_w <= '0;  res_h <= '0;
            win <= '0;  p_prev <= '0;  pix_khz <= '0;  vid_ms <= 7'd127;
            r_cap_w <= '0;  r_cap_h <= '0;  pll_loss <= '0;  ph_loss <= '0;
            lock_d <= 1'b0;  plock_d <= 1'b0;  fifo_max <= '0;
        end else begin
            wb_ack <= wb_stb & ~wb_ack;
            lock_d  <= lock_s[1];
            plock_d <= plock_s[1];
            if (lock_d & ~lock_s[1])   pll_loss <= pll_loss + 1'b1;
            if (plock_d & ~plock_s[1]) ph_loss  <= ph_loss + 1'b1;
            if (f_level <= 9'd256 && f_level > fifo_max) fifo_max <= f_level;
            if (wr && wb_adr[11:8] == 4'h0) begin
                case (wb_adr[7:2])
                    6'd1: begin
                        r_hpd    <= wb_wdata[0];
                        r_cap_en <= wb_wdata[1];
                        r_rx_rst <= wb_wdata[2];
                    end
                    6'd3: begin
                        ovf_sticky <= 1'b0;
                        fifo_max   <= '0;
                    end
                    6'd7: r_base   <= wb_wdata[LB+3:4];
                    6'd8: r_stride <= wb_wdata[15:4];
                    6'd9: {r_cap_h, r_cap_w} <= wb_wdata;
                    6'd15: r_bsize <= wb_wdata[LB+3:4];
                    6'd17: r_hofs  <= wb_wdata[LB+3:4];
                    6'd16: begin
                        if (wb_wdata[0]) lock_t   <= ~lock_t;
                        if (wb_wdata[1]) unlock_t <= ~unlock_t;
                    end
                    default: ;
                endcase
            end
            // кадр: забрать размеры (стабильны до следующего кадра, ~16 мс)
            if (frm_s[2] != frm_s[1]) begin
                frames <= frames + 1'b1;
                res_w  <= f_w;
                res_h  <= f_h;
                vid_ms <= '0;
            end
            if (cap_s[2] != cap_s[1]) cap_frames <= cap_frames + 1'b1;
            if (ovf_s[2] != ovf_s[1]) ovf_sticky <= 1'b1;
            if (win == WIN - 1) begin
                win     <= '0;
                pix_khz <= {8'b0, pg2b - p_prev};
                p_prev  <= pg2b;
                if (vid_ms != 7'd127) vid_ms <= vid_ms + 1'b1;
            end else begin
                win <= win + 1'b1;
            end
        end
    end
    assign video = (vid_ms < 7'd100);

    always_comb begin
        if (wb_adr[11:8] == 4'h1) wb_rdata = edid_q;
        else begin
            case (wb_adr[7:2])
                6'd0:    wb_rdata = ID;
                6'd1:    wb_rdata = {29'b0, r_rx_rst, r_cap_en, r_hpd};
                6'd2:    wb_rdata = pix_khz;
                6'd3:    wb_rdata = {20'b0, phase_s2, 2'b0, ovf_sticky, ddc_active, capt_s[1], video,
                                     plock_s[1], lock_s[1]};
                6'd4:    wb_rdata = {res_h, res_w};
                6'd5:    wb_rdata = frames;
                6'd6:    wb_rdata = cap_frames;
                6'd7:    wb_rdata = {{(28-LB){1'b0}}, r_base, 4'b0};
                6'd8:    wb_rdata = {16'b0, r_stride, 4'b0};
                6'd9:    wb_rdata = {r_cap_h, r_cap_w};
                6'd10:   wb_rdata = {ph_loss, pll_loss};
                6'd11:   wb_rdata = {8'b0, bl_b};
                6'd12:   wb_rdata = {8'b0, bf_b};
                6'd13:   wb_rdata = {8'b0, lw_b};
                6'd14:   wb_rdata = {23'b0, fifo_max};
                6'd15:   wb_rdata = {{(28-LB){1'b0}}, r_bsize, 4'b0};
                6'd17:   wb_rdata = {{(28-LB){1'b0}}, r_hofs, 4'b0};
                6'd16:   wb_rdata = {24'b0, bst_s2[5:4], 1'b0, bst_s2[3:1], bst_s2[0], lock_t ^ ack_s[2]};
                default: wb_rdata = 32'h0;
            endcase
        end
    end

    // =====================================================================
    // Домен пикселей: кадр, размеры, упаковка RGB565
    // =====================================================================
    logic [2:0] prs;
    always_ff @(posedge pix_clk or negedge rst_n) begin
        if (!rst_n) prs <= '0;
        else        prs <= {prs[1:0], 1'b1};
    end
    logic p_rst_n;
    assign p_rst_n = prs[2];

    logic [1:0] capen_p;
    always_ff @(posedge pix_clk) capen_p <= {capen_p[0], r_cap_en};

    // CAP_SIZE квазистатичен (ядро пишет его при старте), синхронизатор не нужен
    logic [15:0] cap_w_p, cap_h_p;
    always_ff @(posedge pix_clk) begin
        cap_w_p <= r_cap_w;
        cap_h_p <= r_cap_h;
    end


    // поправка полярности (см. заголовок)
    logic        de, de_d;
    logic [15:0] px;
    always_ff @(posedge pix_clk) begin
        de <= pix_de;
        px <= {pix_r[7:3] ^ 5'h1F, pix_g[7:2] ^ 6'h3F, pix_b[7:3] ^ 5'h1F};   // ^FE: биты 7..1 инверсны
    end

    logic [16:0]  since;                      // тактов с последнего фронта DE (насыщение)
    logic [16:0]  lper;                       // период строки
    logic [16:0]  lines_p1, lines_p2;         // lines + 1, lines + 2 (регистры - без сумматора в сравнениях)
    logic [15:0]  wcnt, lines, line_w;        // wcnt - пикселей строки уже принято
    logic [2:0]   k;                          // пикселей в собираемом слове
    logic [111:0] acc;                        // пиксели 0..6 собираемого слова
    logic         sof_p;                      // следующее слово - первое в кадре
    logic         fbad;                       // в кадре ошибка: строка не той длины или потеря слова
    logic         f_wr;
    logic [131:0] f_wdata;                    // {hash, eof, sof, eol, данные} (см. заголовок)
    logic         f_full;

    logic         ls, new_frame, cap_now, last_px, in_frame;
    logic [15:0]  widx, lines_now;
    logic [2:0]   k_now;
    logic [127:0] word;
    // Сравнения с периодом строки, CAP_SIZE и номером пикселя - на такт раньше, в регистрах (r_*): иначе цепочка
    // "период строки -> новый кадр -> номер строки -> в кадре -> запись в FIFO" не укладывается в такт.
    logic [17:0]  thr;                                                 // порог кадрового гашения: 1.5 периода
    logic         r_gap, r_lin_cur, r_lin_next, r_x_ok, r_x_last;
    logic         c_same, c_inc, c_one, l_inc, l_inc2, l_two;      // сравнения от регистра wcnt
    logic         r_lin_eq, r_lin_eqn;                             // lines_now == высоте (без ls / если ls)
    logic         h_le1, h_le2, h_li, h_li1, h_li2, h_eq1, h_eq2;  // сравнения от регистра lines
    assign ls        = de & ~de_d;                                     // первый пиксель строки
    assign new_frame = ls && r_gap;                                    // ... и кадра (since > 1.5 * lper)
    assign cap_now   = new_frame ? capen_p[1] : capturing;
    assign widx      = ls ? 16'd0 : wcnt;                              // номер текущего пикселя
    assign h_le1     = (cap_h_p >= 16'd1);
    assign h_le2     = (cap_h_p >= 16'd2);
    assign h_eq1     = (cap_h_p == 16'd1);
    assign h_eq2     = (cap_h_p == 16'd2);
    assign h_li      = ({1'b0, lines} <= {1'b0, cap_h_p});
    assign h_li1     = (lines_p1 <= {1'b0, cap_h_p});
    assign h_li2     = (lines_p2 <= {1'b0, cap_h_p});
    assign c_same    = ({1'b0, wcnt} < {1'b0, cap_w_p});
    assign c_inc     = ({1'b0, wcnt} + 17'd1 < {1'b0, cap_w_p});
    assign c_one     = (cap_w_p > 16'd1);
    assign l_inc     = ({1'b0, wcnt} + 17'd1 == {1'b0, cap_w_p});
    assign l_inc2    = ({1'b0, wcnt} + 17'd2 == {1'b0, cap_w_p});
    assign l_two     = (cap_w_p == 16'd2);
    assign lines_now = new_frame ? 16'd1 : ls ? lines_p1[15:0] : lines;  // номер строки текущего пикселя (с 1)
    // за пределами CAP_SIZE не пишем
    assign in_frame  = (new_frame ? (cap_h_p != 16'd0) : ls ? r_lin_next : r_lin_cur) &&
                       (ls ? (cap_w_p != 16'd0) : r_x_ok);
    assign last_px   = ls ? (cap_w_p == 16'd1) : r_x_last;
    assign k_now     = ls ? 3'd0 : k;
    always_ff @(posedge pix_clk) begin
        thr        <= {1'b0, lper} + {2'b0, lper[16:1]};
        r_gap      <= ({1'b0, since} + 1'b1) > thr;                     // since на следующем такте > порога
        // строка следующего такта в кадре (r_lin_cur - без ls, r_lin_next - если он начало строки) и равна
        // высоте (r_lin_eq/r_lin_eqn); lines_now = new_frame ? 1 : ls ? lines + 1 : lines - сравнения считаются
        // от регистров для всех случаев, new_frame и ls только выбирают
        r_lin_cur  <= new_frame ? h_le1 : ls ? h_li1 : h_li;
        r_lin_next <= new_frame ? h_le2 : ls ? h_li2 : h_li1;
        r_lin_eq   <= new_frame ? h_eq1 : ls ? (lines_p1 == {1'b0, cap_h_p}) : (lines == cap_h_p);
        r_lin_eqn  <= new_frame ? h_eq2 : ls ? (lines_p2 == {1'b0, cap_h_p}) : (lines_p1 == {1'b0, cap_h_p});
        // пиксель следующего такта в кадре / последний в строке. wcnt_n = de ? (ls ? 1 : wcnt + 1) : wcnt -
        // сравнения для всех трёх случаев считаются от регистров, de и ls только выбирают готовый результат
        r_x_ok     <= de ? (ls ? c_one : c_inc) : c_same;
        r_x_last   <= de ? (ls ? l_two : l_inc2) : l_inc;
    end
    always_comb begin
        word = {16'b0, acc};                  // хвост неполного слова - мусор за концом строки
        word[k_now*16 +: 16] = px;
    end

    // ---------- контрольные суммы плиток 32x16 (стадия B - на такт позже) ----------
    // CRC-32 (отражённый, многочлен 0xEDB88320, начальное значение 0xFFFFFFFF, без финального XOR) по байтам
    // пикселей плитки в порядке памяти: строки сверху вниз, в строке слева направо, пиксель - младший байт
    // первым. Сумма столбца плиток между строками хранится в colram (64 столбца - ширина до 2048).
    function automatic logic [31:0] crc_px(input logic [31:0] c, input logic [15:0] d);
        logic [31:0] r;
        r = c;
        for (int i = 0; i < 16; i++) r = (r >> 1) ^ (32'hEDB8_8320 & {32{r[0] ^ d[i]}});
        return r;
    endfunction

    logic         b_v;                        // стадия B: пиксель захватываемого кадра
    logic [15:0]  b_x, b_px, b_line;          // номер пикселя в строке, пиксель, номер строки (с 1)
    logic [31:0]  crc, ram_q, ram_f, crc_n, b_g;
    logic [31:0]  colram [0:63];
    logic [127:0] hw;                         // суммы до 4 плиток подряд - одно слово таблицы в DDR3
    logic         hash_pend, hash_eof;
    logic [5:0]   b_col, ncols_m1;
    // признаки пикселя стадии B - регистры, посчитанные на стадии A (сравнения не стоят перед CRC)
    logic         b_sub0, b_sub31, b_lastcol, b_first, b_tile_end, b_lastline;
    logic         a_lastline;                                      // стадия A: строка - последняя в кадре
    assign b_col      = b_x[10:5];
    assign ncols_m1   = cap_w_p[10:5] - 1'b1;
    assign a_lastline = new_frame ? (cap_h_p == 16'd1) : ls ? r_lin_eqn : r_lin_eq;
    // CRC линейна: crc_px(c, d) = crc_px(c, 0) ^ crc_px(0, d). Часть от пикселя (b_g) и часть от суммы столбца
    // из памяти (ram_f) считаются на такт раньше; в цикле - только crc_px(crc, 0) ^ b_g.
    localparam logic [31:0] F_INIT = 32'hBE26_ED00;               // = crc_px(32'hFFFF_FFFF, 16'h0)
    assign crc_n      = (b_sub0 ? (b_first ? F_INIT : ram_f) : crc_px(crc, 16'h0)) ^ b_g;

    // colram: запись столбца, который закончился (пиксель 31), и чтение следующего - разные адреса.
    // Выход памяти - через второй регистр ram_f = crc_px(ram_q, 0) (выход BSRAM поздний, сразу за ним CRC не
    // укладывалась в такт): в строке читается столбец b_col + 1, на пикселе 31 ram_f забирает его (адрес
    // выставлен на пикселе 30); вне строки читается столбец 0 и ram_f обновляется каждый такт.
    logic       ram_we;
    logic [5:0] ram_ra;
    assign ram_we = b_v && b_sub31;
    assign ram_ra = b_v ? b_col + 1'b1 : 6'd0;
    always_ff @(posedge pix_clk) begin
        if (ram_we) colram[b_col] <= crc_n;
        ram_q <= colram[ram_ra];
        if (!b_v || b_sub31) ram_f <= crc_px(ram_q, 16'h0);
    end

    always_ff @(posedge pix_clk or negedge p_rst_n) begin
        if (!p_rst_n) begin
            de_d <= 1'b0;  since <= '1;  lper <= '0;  wcnt <= '0;  lines <= '0;  line_w <= '0;
            lines_p1 <= 17'd1;  lines_p2 <= 17'd2;
            f_w <= '0;  f_h <= '0;  frm_t <= 1'b0;  cap_t <= 1'b0;  ovf_t <= 1'b0;  capturing <= 1'b0;
            k <= '0;  acc <= '0;  sof_p <= 1'b0;  fbad <= 1'b0;  f_wr <= 1'b0;  f_wdata <= '0;
            bl_bin <= '0;  bf_bin <= '0;  lw_bin <= '0;  bl_gray <= '0;  bf_gray <= '0;  lw_gray <= '0;
            b_v <= 1'b0;  b_x <= '0;  b_px <= '0;  b_line <= '0;  crc <= '0;  hw <= '0;  b_g <= '0;
            hash_pend <= 1'b0;  hash_eof <= 1'b0;
        end else begin
            de_d <= de;
            f_wr <= 1'b0;
            bl_gray <= bl_bin ^ (bl_bin >> 1);
            bf_gray <= bf_bin ^ (bf_bin >> 1);
            lw_gray <= lw_bin ^ (lw_bin >> 1);
            if (since != '1) since <= since + 1'b1;

            if (ls) begin                                  // начало строки
                since <= 17'd1;
                lper  <= since;                            // период строки (после гашения - большой,
                                                           // следующая строка его исправит)
                if (new_frame) begin
                    f_w   <= line_w;
                    f_h   <= lines;
                    if (cap_h_p != 16'd0 && lines != cap_h_p) bf_bin <= bf_bin + 1'b1;
                    lines    <= 16'd1;
                    lines_p1 <= 17'd2;
                    lines_p2 <= 17'd3;
                    frm_t <= ~frm_t;
                    if (capturing) cap_t <= ~cap_t;        // предыдущий кадр захвачен целиком
                    capturing <= capen_p[1];
                    fbad  <= 1'b0;
                end else begin
                    lines    <= lines + 1'b1;
                    lines_p1 <= lines_p1 + 1'b1;
                    lines_p2 <= lines_p2 + 1'b1;
                end
            end
            if (de)         wcnt   <= widx + 1'b1;
            if (~de & de_d) begin                          // конец строки
                line_w <= wcnt;
                if (cap_w_p != 16'd0 && wcnt != cap_w_p) begin
                    bl_bin <= bl_bin + 1'b1;
                    fbad   <= 1'b1;
                end
            end

            // стадия B: суммы плиток; слово сумм - после последнего столбца группы из 4 (или последнего
            // столбца) в последней строке ряда плиток
            b_v        <= de && cap_now && in_frame;
            b_x        <= widx;
            b_px       <= px;
            b_g        <= crc_px(32'h0, px);
            b_line     <= lines_now;
            b_sub0     <= (widx[4:0] == 5'd0);
            b_sub31    <= (widx[4:0] == 5'd31);
            b_lastcol  <= (widx[10:5] == ncols_m1);
            b_first    <= (lines_now[3:0] == 4'd1);                    // первая строка ряда плиток
            b_lastline <= a_lastline;
            b_tile_end <= (lines_now[3:0] == 4'd0) || a_lastline;      // последняя строка ряда плиток
            hash_pend <= 1'b0;
            if (b_v) begin
                crc <= crc_n;
                if (b_sub31 && b_tile_end) begin
                    hw[b_col[1:0]*32 +: 32] <= crc_n;
                    if (b_col[1:0] == 2'd3 || b_lastcol) begin
                        hash_pend <= 1'b1;
                        hash_eof  <= b_lastcol && b_lastline;          // последнее слово кадра
                    end
                end
            end

            // слово сумм: через 2 такта после последнего пикселя столбца - со словом пикселей не совпадает
            // (те пишутся на пикселях 8n+7). Флаг eof (кадр полный и без ошибок) - только на нём.
            if (hash_pend) begin
                f_wr    <= 1'b1;
                f_wdata <= {1'b1, hash_eof && !fbad && !f_full, 2'b00, hw};
                if (f_full) begin
                    ovf_t  <= ~ovf_t;
                    lw_bin <= lw_bin + 1'b1;
                    fbad   <= 1'b1;
                end
            end

            // упаковка пикселей: слово готово на 8-м пикселе или на последнем пикселе строки
            if (de && cap_now && in_frame) begin
                if (k_now == 3'd7 || last_px) begin
                    f_wr    <= 1'b1;
                    f_wdata <= {2'b00, new_frame | sof_p, last_px, word};
                    sof_p   <= 1'b0;
                    k       <= '0;
                    if (f_full) begin
                        ovf_t  <= ~ovf_t;
                        lw_bin <= lw_bin + 1'b1;
                        fbad   <= 1'b1;
                    end
                end else begin
                    acc[k_now*16 +: 16] <= px;
                    k     <= k_now + 1'b1;
                    sof_p <= sof_p | new_frame;
                end
            end
        end
    end

    // =====================================================================
    // FIFO в домен DDR3 и адреса записи
    // =====================================================================
    logic [1:0] drs;
    always_ff @(posedge dclk or posedge drst) begin
        if (drst) drs <= '0;
        else      drs <= {drs[0], 1'b1};
    end

    logic         q_valid;
    logic [131:0] q_data;
    afifo #(.W(132), .AW(8)) u_fifo (
        .wclk     (pix_clk),
        .wrst_n   (p_rst_n),
        .wr       (f_wr),
        .wdata    (f_wdata),
        .wfull    (f_full),
        .rclk     (dclk),
        .rrst_n   (drs[1]),
        .rd_valid (q_valid),
        .rd_data  (q_data),
        .rd_pop   (cw_pop),
        .wptr_gray(f_wptr),
        .rptr_gray(f_rptr)
    );

    // ---------- три буфера (см. заголовок) ----------
    // r_base/r_bsize/r_stride стабильны, пока захват выключен и кадр дописан (ядро меняет их только тогда)
    logic [LB-1:0] b0, b1, b2, sof_base;
    always_ff @(posedge dclk) begin
        b0 <= r_base;
        b1 <= r_base + r_bsize;
        b2 <= r_base + (r_bsize << 1);
    end

    logic [1:0] latest, locked, wr_idx, pick;
    logic       has_frame, lock_v, wr_v, ack_pend;
    logic [2:0] blk_s, unlock_s, capen_d;
    logic       free0, free1;
    assign free0 = !(has_frame && latest == 2'd0) && !(lock_v && locked == 2'd0);
    assign free1 = !(has_frame && latest == 2'd1) && !(lock_v && locked == 2'd1);
    assign pick  = free0 ? 2'd0 : free1 ? 2'd1 : 2'd2;     // из трёх хотя бы один свободен
    assign sof_base = (pick == 2'd0) ? b0 : (pick == 2'd1) ? b1 : b2;
    assign d_bst = {latest, has_frame, locked, lock_v};

    always_ff @(posedge dclk or negedge drs[1]) begin
        if (!drs[1]) begin
            latest <= '0;  locked <= '0;  wr_idx <= '0;  has_frame <= 1'b0;  lock_v <= 1'b0;  wr_v <= 1'b0;
            ack_pend <= 1'b0;  d_ack_t <= 1'b0;  blk_s <= '0;  unlock_s <= '0;  capen_d <= '0;
        end else begin
            blk_s    <= {blk_s[1:0], lock_t};
            unlock_s <= {unlock_s[1:0], unlock_t};
            capen_d  <= {capen_d[1:0], r_cap_en};
            if (cw_pop && !q_data[131] && q_data[129]) begin   // первое слово кадра: выбрать буфер
                wr_idx <= pick;
                wr_v   <= 1'b1;
            end
            if (cw_pop && q_data[131] && q_data[130] && wr_v) begin   // последнее слово сумм полного кадра
                latest    <= wr_idx;
                has_frame <= 1'b1;
                wr_v      <= 1'b0;
            end
            if (capen_d[2] == 1'b0 && capen_d[1] == 1'b1) has_frame <= 1'b0;   // включение захвата
            if (unlock_s[2] != unlock_s[1]) lock_v <= 1'b0;
            if (blk_s[2] != blk_s[1]) begin
                lock_v   <= has_frame;
                locked   <= latest;
                ack_pend <= 1'b1;                        // ответ - на следующем такте, после записи состояния
            end
            if (ack_pend) begin
                ack_pend <= 1'b0;
                d_ack_t  <= ~d_ack_t;
            end
        end
    end

    // слова пикселей: строки с начала буфера через CAP_STRIDE; слова сумм: подряд с CAP_HOFS от начала буфера
    logic [LB-1:0] d_line, cur_base;
    logic [11:0]   d_x, h_idx;
    assign cw_valid = q_valid;
    assign cw_data  = q_data[127:0];
    assign cw_line  = q_data[131] ? cur_base + r_hofs + {{(LB-12){1'b0}}, h_idx} :
                      q_data[129] ? sof_base : d_line + {{(LB-12){1'b0}}, d_x};

    always_ff @(posedge dclk or negedge drs[1]) begin
        if (!drs[1]) begin
            cur_base <= '0;  h_idx <= '0;
        end else if (cw_pop) begin
            if (q_data[131]) h_idx <= h_idx + 1'b1;
            else if (q_data[129]) begin
                cur_base <= sof_base;
                h_idx    <= '0;
            end
        end
    end

    always_ff @(posedge dclk or negedge drs[1]) begin
        if (!drs[1]) begin
            d_line <= '0;  d_x <= '0;
        end else if (cw_pop && !q_data[131]) begin
            if (q_data[128]) begin                        // конец строки
                d_line <= (q_data[129] ? sof_base : d_line) + {{(LB-12){1'b0}}, r_stride};
                d_x    <= '0;
            end else begin
                d_line <= q_data[129] ? sof_base : d_line;
                d_x    <= (q_data[129] ? 12'd0 : d_x) + 1'b1;
            end
        end
    end
endmodule
