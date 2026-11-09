// ddr_arb - доступ к DDR3 через IP ddr3_mi (режим 1:4, BL8: одна команда = 16 байт = одно 128-битное слово).
//
// Порт ядра (домен clk): окно памяти на шине Wishbone, 32-битные слова, запись по байтам (sel -> wr_data_mask).
//   Запись отложенная: подтверждается сразу, ядро ждёт, только если предыдущая операция ещё не выполнена.
//   Чтение: ядро ждёт данных (~0.3..1 мкс). До готовности памяти (калибровка) чтение даёт 0, запись теряется.
//   Перенос между доменами: флаг-переключатель запроса/ответа; адрес и данные стабильны, пока запрос не выполнен.
// Порт видео (домен dclk): чтение vr_beats 16-байтных слов подряд с адреса vr_line; данные - в порядке команд
//   (IPUG281 4.4.8), vr_valid/vr_data по мере прихода, vr_done - после последнего слова.
// Порт записи захвата (домен dclk): поток слов с адресами, пишется пачками до CAP_BURST слов.
// Арбитраж: захват (иначе переполнится FIFO), затем ядро, затем видео; после пачки захвата очередь
// сначала ядру и видео. Пачка видео - 80 слов (~1 мкс).
//
// Регистры (слот Wishbone, домен clk):
//   0x00 ID       RO  0x4444_5233 ("DDR3")
//   0x04 STATUS   RO  бит 0 READY - калибровка завершена (init_calib_complete),
//                     бит 1 PLL_LOCK - PLL памяти захвачен, бит 2 IP_RST - IP в сбросе (ddr_rst)
//   0x08 SIZE_MB  RO  объём, МБ
//   0x0C DCLK_KHZ RO  частота такта пользователя (clk_out IP), кГц, обновляется каждую 1 мс
//
// Адрес IP: {rank, bank, row, column} в 16-битных словах (IPUG281 4.4.5) = байтовый адрес / 2, rank = 0.
module ddr_arb #(
    parameter int ROW_BITS = 13,
    parameter int CLK_HZ   = 45_000_000     // частота clk (для измерения DCLK_KHZ)
) (
    // ----- домен ядра -----
    input  logic           clk,
    input  logic           rst_n,
    input  logic           mem_stb,          // окно памяти (stb уже выбран дешифратором)
    input  logic           mem_we,
    input  logic [31:0]    mem_adr,          // байтовый адрес, используются младшие AB бит
    input  logic [31:0]    mem_wdata,
    input  logic [3:0]     mem_sel,
    output logic           mem_ack,
    output logic [31:0]    mem_rdata,
    input  logic           reg_stb,          // регистры
    input  logic [11:0]    reg_adr,
    output logic           reg_ack,
    output logic [31:0]    reg_rdata,
    // ----- домен памяти (clk_out IP) -----
    input  logic           dclk,
    input  logic           drst,             // ddr_rst IP, 1 = сброс
    input  logic           calib,            // init_calib_complete
    input  logic           pll_lock,         // LOCK PLL памяти (для диагностики)
    input  logic           cmd_ready,
    output logic [2:0]     cmd,
    output logic           cmd_en,
    output logic [ROW_BITS+13:0] addr,
    input  logic           wr_data_rdy,
    output logic [127:0]   wr_data,
    output logic           wr_data_en,
    output logic           wr_data_end,
    output logic [15:0]    wr_data_mask,     // 1 = байт не записывать
    input  logic [127:0]   rd_data,
    input  logic           rd_data_valid,
    // порт видео
    input  logic           vr_req,           // держать до vr_ack
    input  logic [ROW_BITS+9:0] vr_line,     // адрес 16-байтного слова (байтовый адрес / 16)
    input  logic [7:0]     vr_beats,         // число слов, 1..255
    output logic           vr_ack,           // запрос принят (импульс)
    output logic           vr_valid,
    output logic [127:0]   vr_data,
    output logic           vr_done,          // импульс после последнего слова
    // порт записи захвата (поток 16-байтных слов с адресами, hdmi_rx)
    input  logic           cw_valid,
    input  logic [ROW_BITS+9:0] cw_line,
    input  logic [127:0]   cw_data,
    output logic           cw_pop
);
    localparam int          AB      = ROW_BITS + 14;           // бит байтового адреса (128 МБ при 13)
    localparam logic [31:0] ID      = 32'h4444_5233;
    localparam logic [31:0] SIZE_MB = 32'd1 << (AB - 20);
    localparam logic [2:0]  CMD_WR  = 3'b000;                  // IPUG281 табл. 4-1
    localparam logic [2:0]  CMD_RD  = 3'b001;

    // =====================================================================
    // Домен ядра
    // =====================================================================
    logic          req_t;                 // переключается при каждом запросе (домен clk)
    logic          rsp_t;                 // переключается при каждом ответе (домен dclk)
    logic [2:0]    calib_s, rsp_s, lock_s, drst_s;
    always_ff @(posedge clk) begin
        calib_s <= {calib_s[1:0], calib};
        rsp_s   <= {rsp_s[1:0], rsp_t};
        lock_s  <= {lock_s[1:0], pll_lock};
        drst_s  <= {drst_s[1:0], drst};
    end

    // ---------- Частота dclk: счётчик в коде Грея (без сброса), окно 1 мс в домене clk ----------
    localparam int WIN = CLK_HZ / 1000;
    logic [23:0] d_bin, d_gray, dg1, dg2, dg2b, d_prev, d_khz;
    always_ff @(posedge dclk) begin
        d_bin  <= d_bin + 1'b1;
        d_gray <= d_bin ^ (d_bin >> 1);
    end
    always_ff @(posedge clk) begin
        dg1 <= d_gray;
        dg2 <= dg1;
    end
    always_comb begin
        dg2b[23] = dg2[23];
        for (int i = 22; i >= 0; i--) dg2b[i] = dg2b[i+1] ^ dg2[i];
    end
    logic [$clog2(WIN)-1:0] win;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            win <= '0;  d_prev <= '0;  d_khz <= '0;
        end else if (win == WIN - 1) begin
            win    <= '0;
            d_khz  <= dg2b - d_prev;
            d_prev <= dg2b;
        end else begin
            win <= win + 1'b1;
        end
    end
    logic ready_c;
    assign ready_c = calib_s[2];

    logic          c_we;
    logic [AB-1:0] c_adr;
    logic [31:0]   c_wdata;
    logic [3:0]    c_sel;
    logic [31:0]   c_rdata;               // домен dclk, стабилен после ответа
    logic          rd_wait, busy;
    assign busy = (req_t != rsp_s[2]);

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            req_t <= 1'b0;  c_we <= 1'b0;  c_adr <= '0;  c_wdata <= '0;  c_sel <= '0;
            rd_wait <= 1'b0;  mem_ack <= 1'b0;  mem_rdata <= '0;
        end else begin
            mem_ack <= 1'b0;
            if (rd_wait) begin
                if (!busy) begin
                    rd_wait   <= 1'b0;
                    mem_ack   <= 1'b1;
                    mem_rdata <= c_rdata;
                end
            end else if (mem_stb && !mem_ack) begin
                if (!ready_c) begin
                    mem_ack   <= 1'b1;            // память не готова: не зависать
                    mem_rdata <= '0;
                end else if (!busy) begin
                    req_t   <= ~req_t;
                    c_we    <= mem_we;
                    c_adr   <= mem_adr[AB-1:0];
                    c_wdata <= mem_wdata;
                    c_sel   <= mem_sel;
                    if (mem_we) mem_ack <= 1'b1;  // отложенная запись
                    else        rd_wait <= 1'b1;
                end
            end
        end
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) reg_ack <= 1'b0;
        else        reg_ack <= reg_stb & ~reg_ack;
    end
    always_comb begin
        case (reg_adr[11:2])
            10'd0:   reg_rdata = ID;
            10'd1:   reg_rdata = {29'b0, drst_s[2], lock_s[2], ready_c};
            10'd2:   reg_rdata = SIZE_MB;
            10'd3:   reg_rdata = {8'b0, d_khz};
            default: reg_rdata = 32'h0;
        endcase
    end

    // =====================================================================
    // Домен памяти
    // =====================================================================
    logic [1:0] drs;
    always_ff @(posedge dclk or posedge drst) begin
        if (drst) drs <= '0;
        else      drs <= {drs[0], 1'b1};
    end
    logic dr_n;
    assign dr_n = drs[1];

    logic [2:0] req_s;
    always_ff @(posedge dclk) req_s <= {req_s[1:0], req_t};

    localparam logic [5:0] CAP_BURST = 6'd32;
    typedef enum logic [2:0] {S_IDLE, S_CW, S_CR, S_CRW, S_VR, S_CAP} state_t;
    state_t st;
    logic                 c_pend;
    logic [ROW_BITS+9:0]  v_line;
    logic [7:0]           v_cmds, v_left;
    logic [1:0]           lane;
    logic                 fire;
    logic [5:0]           cap_n;
    logic                 cap_last;           // последней была пачка захвата

    assign c_pend = (req_s[2] != rsp_t);     // запрос ядра ещё не выполнен
    assign lane   = c_adr[3:2];

    // команды: valid/ready, передача при cmd_en & cmd_ready (IPUG281 4.4.5);
    // запись ядра - команда и данные в одном такте, когда IP готов принять и то и другое
    always_comb begin
        cmd          = CMD_RD;
        cmd_en       = 1'b0;
        addr         = '0;
        wr_data_en   = 1'b0;
        wr_data_end  = 1'b0;
        case (st)
            S_CW: begin
                cmd         = CMD_WR;
                cmd_en      = cmd_ready & wr_data_rdy;
                wr_data_en  = cmd_ready & wr_data_rdy;
                wr_data_end = cmd_ready & wr_data_rdy;
                addr        = {1'b0, c_adr[AB-1:4], 3'b000};
            end
            S_CR: begin
                cmd_en = cmd_ready;
                addr   = {1'b0, c_adr[AB-1:4], 3'b000};
            end
            S_VR: begin
                cmd_en = cmd_ready & (v_cmds != 8'd0);
                addr   = {1'b0, v_line, 3'b000};
            end
            S_CAP: begin
                cmd         = CMD_WR;
                cmd_en      = cmd_ready & wr_data_rdy & cw_valid;
                wr_data_en  = cmd_ready & wr_data_rdy & cw_valid;
                wr_data_end = cmd_ready & wr_data_rdy & cw_valid;
                addr        = {1'b0, cw_line, 3'b000};
            end
            default: ;
        endcase
    end
    assign fire = cmd_en;   // cmd_en выставляется только вместе с cmd_ready

    assign cw_pop  = (st == S_CAP) & fire;
    assign wr_data = (st == S_CAP) ? cw_data : {4{c_wdata}};
    always_comb begin
        wr_data_mask = 16'hFFFF;
        wr_data_mask[lane*4 +: 4] = ~c_sel;
        if (st == S_CAP) wr_data_mask = 16'h0000;
    end

    assign vr_valid = (st == S_VR) & rd_data_valid;
    assign vr_data  = rd_data;

    always_ff @(posedge dclk or negedge dr_n) begin
        if (!dr_n) begin
            st <= S_IDLE;  rsp_t <= 1'b0;  c_rdata <= '0;
            v_line <= '0;  v_cmds <= '0;  v_left <= '0;
            vr_ack <= 1'b0;  vr_done <= 1'b0;  cap_n <= '0;  cap_last <= 1'b0;
        end else begin
            vr_ack  <= 1'b0;
            vr_done <= 1'b0;
            case (st)
                S_IDLE: begin
                    if (calib && cw_valid && !(cap_last && (c_pend || (vr_req && !vr_ack)))) begin
                        st    <= S_CAP;
                        cap_n <= '0;
                    end else if (calib && c_pend) begin
                        st       <= c_we ? S_CW : S_CR;
                        cap_last <= 1'b0;
                    end else if (calib && vr_req && !vr_ack) begin
                        cap_last <= 1'b0;
                        st     <= S_VR;
                        v_line <= vr_line;
                        v_cmds <= vr_beats;
                        v_left <= vr_beats;
                        vr_ack <= 1'b1;
                    end
                end
                S_CW: if (fire) begin
                    rsp_t  <= ~rsp_t;
                    st     <= S_IDLE;
                end
                S_CR: if (fire) st <= S_CRW;
                S_CRW: if (rd_data_valid) begin
                    c_rdata <= rd_data[lane*32 +: 32];
                    rsp_t   <= ~rsp_t;
                    st      <= S_IDLE;
                end
                S_VR: begin
                    if (fire) begin
                        v_cmds <= v_cmds - 1'b1;
                        v_line <= v_line + 1'b1;
                    end
                    if (rd_data_valid) begin
                        v_left <= v_left - 1'b1;
                        if (v_left == 8'd1) begin
                            vr_done <= 1'b1;
                            st      <= S_IDLE;
                        end
                    end
                end
                S_CAP: begin
                    if (fire) cap_n <= cap_n + 1'b1;
                    if (!cw_valid || (fire && cap_n == CAP_BURST - 1'b1)) begin
                        st       <= S_IDLE;
                        cap_last <= 1'b1;
                    end
                end
                default: st <= S_IDLE;
            endcase
        end
    end
endmodule
