// ulpi_io - выводы ULPI (USB3317) с задержкой на входе.
//   Такт CLKOUT приходит к триггерам ядра USB через общую трассировку (PR1014, вывод T15 - не вход глобального
//   такта) на 3.8...5.6 нс позже, чем на вывод. Данные PHY меняются уже через 1.5 нс после фронта (USB3317 rev C,
//   табл. 4.3), поэтому без задержки входы ядра ловят их на грани удержания (hold). Задержка IODELAY на всех
//   входах ULPI сдвигает данные позже фронта; запас по setup у входов
//   большой (данные готовы через 3.5 нс, а захват - через период плюс задержка такта).
//   IODELAY: 128 шагов, у GW2A-18 шаг около 18 пс (UG289 4.4.1) -> 127 = около 2.3 нс; static, SDTAP = 0.
//   Шину DATA ведёт PHY при DIR = 1, иначе - ядро (OEN = DIR после задержки: шина освобождается в такте
//   разворота, PHY в нём DATA не читает - USB3317 6.1.1).
module ulpi_io (
    input  logic       ulpi_dir,
    input  logic       ulpi_nxt,
    inout  wire  [7:0] ulpi_data,
    input  logic [7:0] txdata,      // от ядра
    output logic       dir_d,       // к ядру (после задержки)
    output logic       nxt_d,
    output logic [7:0] rxdata
);
    wire [7:0] rx_buf;
    IODELAY u_dly_dir (.DI(ulpi_dir), .SDTAP(1'b0), .SETN(1'b0), .VALUE(1'b0), .DO(dir_d), .DF());
    defparam u_dly_dir.C_STATIC_DLY = 127;
    IODELAY u_dly_nxt (.DI(ulpi_nxt), .SDTAP(1'b0), .SETN(1'b0), .VALUE(1'b0), .DO(nxt_d), .DF());
    defparam u_dly_nxt.C_STATIC_DLY = 127;
    IOBUF u_iob_d0 (.O(rx_buf[0]), .IO(ulpi_data[0]), .I(txdata[0]), .OEN(dir_d));
    IODELAY u_dly_d0 (.DI(rx_buf[0]), .SDTAP(1'b0), .SETN(1'b0), .VALUE(1'b0), .DO(rxdata[0]), .DF());
    defparam u_dly_d0.C_STATIC_DLY = 127;
    IOBUF u_iob_d1 (.O(rx_buf[1]), .IO(ulpi_data[1]), .I(txdata[1]), .OEN(dir_d));
    IODELAY u_dly_d1 (.DI(rx_buf[1]), .SDTAP(1'b0), .SETN(1'b0), .VALUE(1'b0), .DO(rxdata[1]), .DF());
    defparam u_dly_d1.C_STATIC_DLY = 127;
    IOBUF u_iob_d2 (.O(rx_buf[2]), .IO(ulpi_data[2]), .I(txdata[2]), .OEN(dir_d));
    IODELAY u_dly_d2 (.DI(rx_buf[2]), .SDTAP(1'b0), .SETN(1'b0), .VALUE(1'b0), .DO(rxdata[2]), .DF());
    defparam u_dly_d2.C_STATIC_DLY = 127;
    IOBUF u_iob_d3 (.O(rx_buf[3]), .IO(ulpi_data[3]), .I(txdata[3]), .OEN(dir_d));
    IODELAY u_dly_d3 (.DI(rx_buf[3]), .SDTAP(1'b0), .SETN(1'b0), .VALUE(1'b0), .DO(rxdata[3]), .DF());
    defparam u_dly_d3.C_STATIC_DLY = 127;
    IOBUF u_iob_d4 (.O(rx_buf[4]), .IO(ulpi_data[4]), .I(txdata[4]), .OEN(dir_d));
    IODELAY u_dly_d4 (.DI(rx_buf[4]), .SDTAP(1'b0), .SETN(1'b0), .VALUE(1'b0), .DO(rxdata[4]), .DF());
    defparam u_dly_d4.C_STATIC_DLY = 127;
    IOBUF u_iob_d5 (.O(rx_buf[5]), .IO(ulpi_data[5]), .I(txdata[5]), .OEN(dir_d));
    IODELAY u_dly_d5 (.DI(rx_buf[5]), .SDTAP(1'b0), .SETN(1'b0), .VALUE(1'b0), .DO(rxdata[5]), .DF());
    defparam u_dly_d5.C_STATIC_DLY = 127;
    IOBUF u_iob_d6 (.O(rx_buf[6]), .IO(ulpi_data[6]), .I(txdata[6]), .OEN(dir_d));
    IODELAY u_dly_d6 (.DI(rx_buf[6]), .SDTAP(1'b0), .SETN(1'b0), .VALUE(1'b0), .DO(rxdata[6]), .DF());
    defparam u_dly_d6.C_STATIC_DLY = 127;
    IOBUF u_iob_d7 (.O(rx_buf[7]), .IO(ulpi_data[7]), .I(txdata[7]), .OEN(dir_d));
    IODELAY u_dly_d7 (.DI(rx_buf[7]), .SDTAP(1'b0), .SETN(1'b0), .VALUE(1'b0), .DO(rxdata[7]), .DF());
    defparam u_dly_d7.C_STATIC_DLY = 127;
endmodule
