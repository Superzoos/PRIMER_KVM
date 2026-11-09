// afifo - асинхронная FIFO (указатели в коде Грея, синхронизаторы по 2 триггера).
// Чтение - с показом вперёд: rd_valid/rd_data - текущее слово, rd_pop - забрать его.
// Глубина 2^AW слов; память - BSRAM (запись в домене wclk, чтение в домене rclk).
// wptr_gray/rptr_gray - указатели в коде Грея (их можно синхронизировать в любой домен и по разности узнать
// заполнение).
module afifo #(
    parameter int W  = 32,
    parameter int AW = 8
) (
    // запись
    input  logic         wclk,
    input  logic         wrst_n,
    input  logic         wr,
    input  logic [W-1:0] wdata,
    output logic         wfull,
    // чтение
    input  logic         rclk,
    input  logic         rrst_n,
    output logic         rd_valid,
    output logic [W-1:0] rd_data,
    input  logic         rd_pop,
    // указатели (код Грея): записи - домен wclk, чтения - домен rclk
    output logic [AW:0]  wptr_gray,
    output logic [AW:0]  rptr_gray
);
    logic [W-1:0] mem [0:(1<<AW)-1];
    logic [AW:0]  wbin, wgray, rgray_w1, rgray_w2;     // домен записи
    logic [AW:0]  rbin, rgray, wgray_r1, wgray_r2;     // домен чтения
    assign wptr_gray = wgray;
    assign rptr_gray = rgray;

    // ---------- запись ----------
    logic [AW:0] wbin_n, wgray_n;
    assign wbin_n  = wbin + 1'b1;
    assign wgray_n = wbin_n ^ (wbin_n >> 1);

    always_ff @(posedge wclk) if (wr && !wfull) mem[wbin[AW-1:0]] <= wdata;

    always_ff @(posedge wclk or negedge wrst_n) begin
        if (!wrst_n) begin
            wbin <= '0;  wgray <= '0;  rgray_w1 <= '0;  rgray_w2 <= '0;
        end else begin
            rgray_w1 <= rgray;
            rgray_w2 <= rgray_w1;
            if (wr && !wfull) begin
                wbin  <= wbin_n;
                wgray <= wgray_n;
            end
        end
    end
    // полна: указатель записи догнал указатель чтения на целый круг
    assign wfull = (wgray == {~rgray_w2[AW:AW-1], rgray_w2[AW-2:0]});

    // ---------- чтение ----------
    logic [AW:0] rbin_n;
    logic        mem_empty, fetch;
    assign rbin_n    = rbin + 1'b1;
    assign mem_empty = (rgray == wgray_r2);
    assign fetch     = !mem_empty && (!rd_valid || rd_pop);

    always_ff @(posedge rclk) if (fetch) rd_data <= mem[rbin[AW-1:0]];

    always_ff @(posedge rclk or negedge rrst_n) begin
        if (!rrst_n) begin
            rbin <= '0;  rgray <= '0;  wgray_r1 <= '0;  wgray_r2 <= '0;  rd_valid <= 1'b0;
        end else begin
            wgray_r1 <= wgray;
            wgray_r2 <= wgray_r1;
            if (fetch) begin
                rbin     <= rbin_n;
                rgray    <= rbin_n ^ (rbin_n >> 1);
                rd_valid <= 1'b1;
            end else if (rd_pop) begin
                rd_valid <= 1'b0;
            end
        end
    end
endmodule
