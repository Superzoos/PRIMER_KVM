// wb_mux - дешифратор шины Open Wishbone ядра (окно 0x2000_0000..0x3FFF_FFFF, picorv32.h OPEN_WB_BASE).
//   adr[28] = 0: периферия, слот = adr[15:12]: окна по 4 КБ, слот 0 - 0x2000_0000, слот 1 - 0x2000_1000 ...
//   adr[28] = 1: память DDR3, 0x3000_0000 + байтовый адрес (до 256 МБ).
// Используются только эти биты адреса, поэтому неважно, полный адрес выдаёт ядро или смещение от 0x2000_0000.
// Доступ к пустому слоту подтверждается, чтение даёт 0 (ядро не зависает).
module wb_mux #(
    parameter int N = 1                      // число подключённых слотов периферии (0..N-1)
) (
    input  logic            clk,
    input  logic            rst_n,
    // от ядра
    input  logic            m_cyc,
    input  logic            m_stb,
    input  logic [31:0]     m_adr,
    output logic            m_ack,
    output logic [31:0]     m_rdata,
    // к периферии: общий адрес/данные/we берутся напрямую от ядра, у каждого слота свой stb
    output logic [N-1:0]    s_stb,
    input  logic [N-1:0]    s_ack,
    input  logic [N*32-1:0] s_rdata,
    // к памяти
    output logic            mem_stb,
    input  logic            mem_ack,
    input  logic [31:0]     mem_rdata
);
    logic [3:0] slot;
    logic       req, mem, hit, dflt_ack;

    assign slot = m_adr[15:12];
    assign req  = m_cyc & m_stb;
    assign mem  = m_adr[28];
    assign hit  = ~mem & (slot < N);

    always_comb begin
        for (int i = 0; i < N; i++) s_stb[i] = req & ~mem & (slot == i);
    end
    assign mem_stb = req & mem;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) dflt_ack <= 1'b0;
        else        dflt_ack <= req & ~mem & ~hit & ~dflt_ack;
    end

    assign m_ack   = mem ? mem_ack   : hit ? s_ack[slot]            : dflt_ack;
    assign m_rdata = mem ? mem_rdata : hit ? s_rdata[slot*32 +: 32] : 32'h0;
endmodule
