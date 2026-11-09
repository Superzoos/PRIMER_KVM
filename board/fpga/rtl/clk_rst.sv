// clk_rst - такты и сбросы.
// clk_sys = CPU_CLK_HZ от PLL (fpga/ip/pll_sys/pll_sys.v, создаёт scripts/ip-gen.ps1).
// rst_n: асинхронная установка кнопкой K0 или пока PLL не захвачен,
// синхронное снятие через 3 такта clk_sys.
module clk_rst (
    input  logic clk_in,     // 27 МГц
    input  logic rst_n_in,   // кнопка K0, 0 = сброс
    output logic clk_sys,
    output logic rst_n       // 0 = сброс
);
    logic lock;

    pll_sys u_pll (
        .clkin  (clk_in),
        .reset  (1'b0),
        .clkout (clk_sys),
        .lock   (lock)
    );

    logic       arst_n;
    logic [2:0] sync;

    assign arst_n = rst_n_in & lock;

    always_ff @(posedge clk_sys or negedge arst_n) begin
        if (!arst_n) sync <= '0;
        else         sync <= {sync[1:0], 1'b1};
    end

    assign rst_n = sync[2];
endmodule
