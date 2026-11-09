// i2c_edid - ведомый I2C для чтения EDID по линиям DDC (VESA E-DDC: адрес 0x50, сначала запись смещения,
// затем последовательное чтение; повторный START без STOP поддержан). Только чтение: записанные данные
// подтверждаются и отбрасываются. Другие адреса (0x30 - указатель сегмента и т.д.) не подтверждаются.
// SCL и SDA проходят синхронизатор и фильтр помех (FILT тактов clk подряд одинаково); SDA меняется
// только при SCL = 0 (по спаду SCL). Растяжения SCL нет.
module i2c_edid #(
    parameter logic [6:0] ADDR = 7'h50,
    parameter int         FILT = 8            // ~0.2 мкс при 40 МГц; бит DDC (100 кГц) - 10 мкс
) (
    input  logic       clk,
    input  logic       rst_n,
    input  logic       scl_i,
    input  logic       sda_i,
    output logic       sda_low,               // 1 - тянуть SDA в 0
    output logic [7:0] rd_addr,               // адрес байта EDID
    input  logic [7:0] rd_data,               // байт по rd_addr (задержка не больше нескольких тактов)
    output logic       active                 // идёт обмен с нами (для индикации)
);
    // ---------- синхронизация и фильтр ----------
    logic [2:0] scl_s, sda_s;
    logic [$clog2(FILT+1)-1:0] scl_cnt, sda_cnt;
    logic scl, sda, scl_d, sda_d;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            scl_s <= '1;  sda_s <= '1;  scl_cnt <= '0;  sda_cnt <= '0;
            scl <= 1'b1;  sda <= 1'b1;  scl_d <= 1'b1;  sda_d <= 1'b1;
        end else begin
            scl_s <= {scl_s[1:0], scl_i};
            sda_s <= {sda_s[1:0], sda_i};
            if (scl_s[2] == scl) scl_cnt <= '0;
            else if (scl_cnt == FILT - 1) begin scl <= scl_s[2]; scl_cnt <= '0; end
            else scl_cnt <= scl_cnt + 1'b1;
            if (sda_s[2] == sda) sda_cnt <= '0;
            else if (sda_cnt == FILT - 1) begin sda <= sda_s[2]; sda_cnt <= '0; end
            else sda_cnt <= sda_cnt + 1'b1;
            scl_d <= scl;
            sda_d <= sda;
        end
    end

    logic scl_rise, scl_fall, start, stop;
    assign scl_rise = scl & ~scl_d;
    assign scl_fall = ~scl & scl_d;
    assign start    = scl & scl_d & sda_d & ~sda;     // SDA 1->0 при SCL = 1
    assign stop     = scl & scl_d & ~sda_d & sda;     // SDA 0->1 при SCL = 1

    // ---------- протокол ----------
    typedef enum logic [3:0] {S_IDLE, S_ADDR, S_ADDR_ACK, S_OFS, S_OFS_ACK, S_WR, S_WR_ACK, S_RD, S_RD_ACK} st_t;
    st_t        st;
    logic [3:0] bitcnt;
    logic [7:0] sh, ptr, tx;
    logic       rw, mack;

    assign rd_addr = ptr;
    assign active  = (st != S_IDLE);

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            st <= S_IDLE;  bitcnt <= '0;  sh <= '0;  ptr <= '0;  tx <= '0;  rw <= 1'b0;  mack <= 1'b0;
            sda_low <= 1'b0;
        end else if (start) begin
            st <= S_ADDR;  bitcnt <= '0;  sda_low <= 1'b0;
        end else if (stop) begin
            st <= S_IDLE;  sda_low <= 1'b0;
        end else if (scl_rise) begin
            case (st)
                S_ADDR, S_OFS, S_WR: begin
                    sh     <= {sh[6:0], sda};
                    bitcnt <= bitcnt + 1'b1;
                end
                S_RD:     bitcnt <= bitcnt + 1'b1;
                S_RD_ACK: mack   <= ~sda;                 // 0 на 9-м такте - ведущий хочет ещё байт
                default: ;
            endcase
        end else if (scl_fall) begin
            case (st)
                S_ADDR: if (bitcnt == 4'd8) begin
                    if (sh[7:1] == ADDR) begin
                        rw      <= sh[0];
                        sda_low <= 1'b1;                  // ACK
                        st      <= S_ADDR_ACK;
                    end else begin
                        st <= S_IDLE;                     // не наш адрес - NACK
                    end
                end
                S_ADDR_ACK: begin
                    bitcnt <= '0;
                    if (rw) begin
                        tx      <= rd_data;
                        sda_low <= ~rd_data[7];
                        st      <= S_RD;
                    end else begin
                        sda_low <= 1'b0;
                        st      <= S_OFS;
                    end
                end
                S_OFS: if (bitcnt == 4'd8) begin
                    ptr     <= sh;
                    sda_low <= 1'b1;
                    st      <= S_OFS_ACK;
                end
                S_OFS_ACK: begin
                    sda_low <= 1'b0;
                    bitcnt  <= '0;
                    st      <= S_WR;
                end
                S_WR: if (bitcnt == 4'd8) begin
                    sda_low <= 1'b1;                      // подтвердить и отбросить
                    st      <= S_WR_ACK;
                end
                S_WR_ACK: begin
                    sda_low <= 1'b0;
                    bitcnt  <= '0;
                    st      <= S_WR;
                end
                S_RD: begin
                    if (bitcnt == 4'd8) begin
                        sda_low <= 1'b0;                  // отпустить SDA на такт ACK ведущего
                        ptr     <= ptr + 1'b1;
                        st      <= S_RD_ACK;
                    end else begin
                        sda_low <= ~tx[3'd7 - bitcnt[2:0]];
                    end
                end
                S_RD_ACK: begin
                    if (mack) begin
                        tx      <= rd_data;               // байт по новому ptr (готов за такт ACK)
                        sda_low <= ~rd_data[7];
                        bitcnt  <= '0;
                        st      <= S_RD;
                    end else begin
                        st <= S_IDLE;                     // NACK - конец чтения, ждём STOP/START
                    end
                end
                default: ;
            endcase
        end
    end
endmodule
