// video_tx - передача плиток кадра из буфера в DDR3 на ПК пакетами UDP.
// Кадр RGB565 (2 байта на пиксель, строки через STRIDE байт) делится на плитки TILE_W x TILE_H (32x16).
// Ядро пишет список плиток ({ряд, столбец}) и их число, запускает передачу (START); модуль отправляет по одной
// плитке в пакете. Пакет собирается в буфере передачи eth_sys (2 буфера по 2 КБ, 128-битные строки):
//   байты 0..41   - заголовок Ethernet/IPv4/UDP: шаблон, который прошивка пишет в буфер передачи eth_sys
//                   (слова 448..458, см. eth_sys.sv) - он одинаков для всех пакетов (длины постоянны,
//                   идентификатор 0, DF, контрольная сумма UDP 0);
//   байты 42..63  - заголовок плитки (этот модуль), little-endian:
//                   42 magic u32 "KVT1", 46 upd u16 (номер обновления, регистр UPD), 48 tx u16 (столбец плиток),
//                   50 ty u16 (ряд), 52 index u16 (номер пакета в обновлении), 54 count u16 (пакетов в
//                   обновлении), 56 width u16, 58 height u16 (кадр), 60 format u16 (1 = RGB565), 62 flags u16
//                   (бит 0 - последний пакет обновления);
//   байты 64..    - пиксели плитки: TILE_H строк по TILE_W * 2 байт из DDR3 (порт видео ddr_arb).
// Длина пакета PKT_BYTES = 64 + 2 * TILE_W * TILE_H = 1088 (без FCS). Буферы заполняются по очереди;
// готовность и освобождение - флагами-переключателями (по одному на буфер) между доменами dclk и передачи.
//
// Регистры (слот Wishbone, домен clk; всё, кроме CTRL, менять только при BUSY = 0):
//   0x00 ID        RO  0x5654_5832 ("VTX2")
//   0x04 CTRL      WO  бит 0 START - отправить COUNT плиток из списка (если BUSY = 0)
//   0x08 STATUS    RO  бит 0 BUSY - идёт передача
//   0x0C FB_BASE   RW  байтовый адрес кадра в DDR3 (кратен 16)
//   0x10 STRIDE    RW  байт между началами строк (кратен 16)
//   0x14 SIZE      RW  биты 15:0 - ширина, 31:16 - высота кадра, пикселей (для заголовка)
//   0x18 FRAMES    RO  выполнено передач (обновлений)
//   0x1C PKT_INFO  RO  биты 15:0 - пикселей в пакете (TILE_W * TILE_H), 31:16 - PKT_BYTES
//   0x20 LIST_ADDR WO  номер записи списка для LIST_DATA
//   0x24 LIST_DATA WO  запись списка: биты 6:0 - столбец плитки, 14:8 - ряд; номер записи затем +1
//   0x28 COUNT     RW  плиток в передаче (0..LIST_LEN)
//   0x2C UPD       RW  номер обновления - в заголовок пакетов
module video_tx #(
    parameter int ROW_BITS = 13,
    parameter int TILE_W   = 32,
    parameter int TILE_H   = 16,
    parameter int LIST_LEN = 4096,
    parameter int WIDTH    = 1280,        // значения после сброса
    parameter int HEIGHT   = 720
) (
    // ----- домен ядра -----
    input  logic        clk,
    input  logic        rst_n,
    input  logic        wb_stb,
    input  logic        wb_we,
    input  logic [11:0] wb_adr,
    input  logic [31:0] wb_wdata,
    output logic        wb_ack,
    output logic [31:0] wb_rdata,
    // ----- домен памяти -----
    input  logic        dclk,
    input  logic        drst,               // 1 = сброс
    output logic        vr_req,
    output logic [ROW_BITS+9:0] vr_line,
    output logic [7:0]  vr_beats,
    input  logic        vr_ack,
    input  logic        vr_valid,
    input  logic [127:0] vr_data,
    input  logic        vr_done,
    // буфер пакетов в eth_sys (запись - домен dclk)
    output logic        pb_we,
    output logic [7:0]  pb_waddr,           // {буфер, строка 0..127}
    output logic [127:0] pb_wdata,
    output logic [1:0]  pb_full_t,          // домен dclk: переключается, когда буфер заполнен
    input  logic [1:0]  pb_free_t           // домен передачи: переключается, когда буфер отправлен
);
    localparam int          LB        = ROW_BITS + 10;          // бит адреса 16-байтного слова
    localparam int          TPIX      = TILE_W * TILE_H;
    localparam int          PKT_BYTES = 64 + 2 * TPIX;
    localparam int          RBEATS    = TILE_W * 2 / 16;        // 16-байтных слов в строке плитки
    localparam int          LW        = $clog2(LIST_LEN);
    localparam logic [31:0] ID        = 32'h5654_5832;
    localparam logic [31:0] MAGIC     = 32'h3154_564B;          // 'K','V','T','1'
    localparam logic [15:0] TP16      = TPIX;
    localparam logic [15:0] PB16      = PKT_BYTES;
    localparam logic [7:0]  RBEATS8   = RBEATS;
    localparam logic [11:0] W0        = WIDTH;
    localparam logic [11:0] H0        = HEIGHT;
    localparam logic [11:0] S0        = WIDTH * 2 / 16;
    localparam logic [LW:0] LL        = LIST_LEN;
    localparam int          TH_SH     = $clog2(TILE_H);         // TILE_H и RBEATS - степени 2
    localparam int          RB_SH     = $clog2(RBEATS);
    // пакет - в один буфер eth_sys (128 строк по 16 байт): 4 строки заголовка + пиксели; TILE_W кратно 8

    // =====================================================================
    // Домен ядра: регистры и список плиток
    // =====================================================================
    logic          start_t, done_t;        // start_t - домен clk, done_t - домен dclk
    logic [2:0]    done_s;
    logic [LB-1:0] r_base;                 // в 16-байтных словах
    logic [11:0]   r_stride;               // в 16-байтных словах
    logic [11:0]   r_width, r_height;
    logic [31:0]   r_frames;
    logic [LW:0]   r_count;
    logic [15:0]   r_upd;
    logic [LW-1:0] l_waddr;
    logic          busy, wr;

    // список плиток: пишет ядро (домен clk), читает передача (домен dclk); пишется только при BUSY = 0
    logic [13:0]   list_mem [0:LIST_LEN-1];
    logic [13:0]   list_q;
    logic [LW-1:0] l_raddr;
    always_ff @(posedge clk) if (wr && wb_adr[11:2] == 10'd9 && !busy) list_mem[l_waddr] <= {wb_wdata[14:8], wb_wdata[6:0]};
    always_ff @(posedge dclk) list_q <= list_mem[l_raddr];

    always_ff @(posedge clk) done_s <= {done_s[1:0], done_t};
    assign busy = (start_t != done_s[2]);
    assign wr   = wb_stb & ~wb_ack & wb_we;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            wb_ack   <= 1'b0;
            start_t  <= 1'b0;
            r_base   <= '0;
            r_stride <= S0;
            r_width  <= W0;
            r_height <= H0;
            r_frames <= '0;
            r_count  <= '0;
            r_upd    <= '0;
            l_waddr  <= '0;
        end else begin
            wb_ack <= wb_stb & ~wb_ack;
            if (wr) begin
                case (wb_adr[11:2])
                    10'd1:  if (wb_wdata[0] && !busy) start_t <= ~start_t;
                    10'd3:  if (!busy) r_base   <= wb_wdata[LB+3:4];
                    10'd4:  if (!busy) r_stride <= wb_wdata[15:4];
                    10'd5:  if (!busy) begin
                        r_width  <= wb_wdata[11:0];
                        r_height <= wb_wdata[27:16];
                    end
                    10'd8:  l_waddr <= wb_wdata[LW-1:0];
                    10'd9:  if (!busy) l_waddr <= l_waddr + 1'b1;
                    10'd10: if (!busy) r_count <= (wb_wdata[LW:0] > LL) ? LL : wb_wdata[LW:0];
                    10'd11: if (!busy) r_upd   <= wb_wdata[15:0];
                    default: ;
                endcase
            end
            if (done_s[2] != done_s[1]) r_frames <= r_frames + 1'b1;
        end
    end

    always_comb begin
        case (wb_adr[11:2])
            10'd0:   wb_rdata = ID;
            10'd2:   wb_rdata = {31'b0, busy};
            10'd3:   wb_rdata = {{(28-LB){1'b0}}, r_base, 4'b0};
            10'd4:   wb_rdata = {16'b0, r_stride, 4'b0};
            10'd5:   wb_rdata = {4'b0, r_height, 4'b0, r_width};
            10'd6:   wb_rdata = r_frames;
            10'd7:   wb_rdata = {PB16, TP16};
            10'd10:  wb_rdata = {{(31-LW){1'b0}}, r_count};
            10'd11:  wb_rdata = {16'b0, r_upd};
            default: wb_rdata = 32'h0;
        endcase
    end

    // =====================================================================
    // Домен памяти: сборка пакетов
    // =====================================================================
    logic [1:0] drs;
    always_ff @(posedge dclk or posedge drst) begin
        if (drst) drs <= '0;
        else      drs <= {drs[0], 1'b1};
    end

    logic [2:0] start_s;
    logic [1:0] free_s0, free_s1;
    always_ff @(posedge dclk) begin
        start_s <= {start_s[1:0], start_t};
        free_s0 <= pb_free_t;
        free_s1 <= free_s0;
    end

    typedef enum logic [3:0] {P_IDLE, P_FETCH, P_LIST, P_MUL, P_ADDR, P_WAIT, P_H2, P_H3, P_REQ, P_DATA} pstate_t;
    pstate_t       ps;
    logic          b;                      // текущий буфер
    logic [LB-1:0] f_base, rowa;           // начало кадра; начало текущей строки плитки
    logic [11:0]   f_stride, f_width, f_height;
    logic [LW:0]   f_count, n;             // плиток в передаче; номер текущей
    logic [15:0]   f_upd;
    logic [6:0]    tx, ty;
    logic [LB-1:0] acc, mul;               // адрес начала плитки: f_base + tx * RBEATS + y0 * stride (сдвиги и сложения)
    logic [11:0]   y_rem;                  // необработанные биты y0 = ty * TILE_H
    logic [4:0]    r;                      // строка плитки
    logic [6:0]    line;
    logic          last;

    assign last     = (n + 1'b1 == f_count);
    assign vr_beats = RBEATS8;

    always_ff @(posedge dclk or negedge drs[1]) begin
        if (!drs[1]) begin
            ps <= P_IDLE;  b <= 1'b0;  done_t <= 1'b0;  pb_full_t <= '0;
            f_base <= '0;  rowa <= '0;  f_stride <= '0;  f_width <= '0;  f_height <= '0;
            f_count <= '0;  n <= '0;  f_upd <= '0;  tx <= '0;  ty <= '0;  acc <= '0;  mul <= '0;  y_rem <= '0;
            r <= '0;  line <= '0;
            l_raddr <= '0;  vr_req <= 1'b0;  vr_line <= '0;
            pb_we <= 1'b0;  pb_waddr <= '0;  pb_wdata <= '0;
        end else begin
            pb_we <= 1'b0;
            case (ps)
                P_IDLE: if (start_s[2] != done_t) begin
                    // настройки и список стабильны: ядро меняет их только при BUSY = 0
                    f_base   <= r_base;
                    f_stride <= r_stride;
                    f_width  <= r_width;
                    f_height <= r_height;
                    f_count  <= r_count;
                    f_upd    <= r_upd;
                    n        <= '0;
                    if (r_count == 0) done_t <= ~done_t;
                    else              ps <= P_FETCH;
                end
                P_FETCH: begin                     // адрес списка; данные - через такт
                    l_raddr <= n[LW-1:0];
                    ps      <= P_LIST;
                end
                P_LIST: ps <= P_MUL;               // list_q ещё читается
                // Адрес плитки без умножителя: с умножением (и со сдвигом на $clog2 в выражении) синтез Gowin
                // давал неверное начало ряда плиток (ряд 1 читался со строки 2). Здесь - только конкатенации,
                // сдвиги на 1 бит и сложения: y0 = {ty, нули}, y0 * stride - по битам y0, до 12 тактов.
                P_MUL: begin
                    tx    <= list_q[6:0];
                    ty    <= list_q[13:7];
                    y_rem <= {{(12-7-TH_SH){1'b0}}, list_q[13:7], {TH_SH{1'b0}}};
                    mul   <= {{(LB-12){1'b0}}, f_stride};
                    acc   <= f_base + {{(LB-7-RB_SH){1'b0}}, list_q[6:0], {RB_SH{1'b0}}};
                    ps    <= P_ADDR;
                end
                P_ADDR: begin
                    if (y_rem == 12'd0) begin
                        rowa <= acc;
                        ps   <= P_WAIT;
                    end else begin
                        if (y_rem[0]) acc <= acc + mul;
                        mul   <= {mul[LB-2:0], 1'b0};
                        y_rem <= {1'b0, y_rem[11:1]};
                    end
                end
                P_WAIT: if (pb_full_t[b] == free_s1[b]) ps <= P_H2;       // буфер свободен
                P_H2: begin
                    pb_we    <= 1'b1;
                    pb_waddr <= {b, 7'd2};
                    pb_wdata <= {f_upd, MAGIC, 80'h0};
                    ps       <= P_H3;
                end
                P_H3: begin
                    pb_we    <= 1'b1;
                    pb_waddr <= {b, 7'd3};
                    pb_wdata <= {15'h0, last, 16'd1, 4'h0, f_height, 4'h0, f_width,
                                 {{(15-LW){1'b0}}, f_count}, {{(15-LW){1'b0}}, n}, 9'h0, ty, 9'h0, tx};
                    line     <= 7'd4;
                    r        <= '0;
                    ps       <= P_REQ;
                end
                P_REQ: begin
                    vr_req  <= 1'b1;
                    vr_line <= rowa;
                    if (vr_req && vr_ack) begin
                        vr_req <= 1'b0;
                        ps     <= P_DATA;
                    end
                end
                P_DATA: begin
                    if (vr_valid) begin
                        pb_we    <= 1'b1;
                        pb_waddr <= {b, line};
                        pb_wdata <= vr_data;
                        line     <= line + 1'b1;
                    end
                    if (vr_done) begin
                        if (r != TILE_H - 1) begin            // следующая строка плитки
                            r    <= r + 1'b1;
                            rowa <= rowa + {{(LB-12){1'b0}}, f_stride};
                            ps   <= P_REQ;
                        end else begin                        // пакет собран
                            pb_full_t[b] <= ~pb_full_t[b];
                            b <= ~b;
                            n <= n + 1'b1;
                            if (last) begin
                                done_t <= ~done_t;
                                ps     <= P_IDLE;
                            end else begin
                                ps <= P_FETCH;
                            end
                        end
                    end
                end
                default: ps <= P_IDLE;
            endcase
        end
    end
endmodule
