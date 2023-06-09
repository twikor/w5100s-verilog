module M_W5100S_SPIMaster(
    input                     clk,                // 50MHz, clock 25 mhz SPI, 现用 PLL 输出 W5100S 模块通信专用时钟 50MHz
    input                     rst_n,

    input                     start,              // 模块序列开始信号, 与时钟同步
    input                     write_read,         // 模块读写选择信号
    input         [23:0]      data_in,            // 模块数据输入
    output reg    [7:0]       data_out,           // 模块数据输出

    output reg                busy,               // 模块忙信号
    output reg                data_ready,         // 模块数据接收完成 状态信号

    output                    ss_n,               // SPI 片选信号
    output                    sclk,               // SPI 时钟信号
    output reg                mosi,               // SPI 发送端子
    input                     miso                // SPI 接收端子

);

/* SPI 状态机 一个读写周期 所有状态 */
                                      /*    STATE    ss_n    sclk    ready    idle    */
localparam STATE_IDLE             =  8'b____0000_____1_______0_______0________1_______;
localparam STATE_WAIT1            =  8'b____0001_____0_______0_______0________0_______;

localparam STATE_WRITE_MOSI       =  8'b____0010_____0_______0_______0________0_______;
localparam STATE_WAIT2            =  8'b____0011_____0_______0_______0________0_______;
localparam STATE_SET_CLOCK        =  8'b____0100_____0_______1_______0________0_______;
localparam STATE_WAIT3            =  8'b____0101_____0_______1_______0________0_______;
localparam STATE_READ_MISO        =  8'b____0110_____0_______1_______0________0_______;
localparam STATE_RESET_CLOCK      =  8'b____0111_____0_______0_______0________0_______;
localparam STATE_WAIT4            =  8'b____1000_____0_______0_______0________0_______;

localparam STATE_WAIT5            =  8'b____1001_____1_______0_______0________0_______;
localparam STATE_DONE             =  8'b____1010_____1_______0_______1________0_______;

localparam OPCODE_READ            =  8'h0F;
localparam OPCODE_WRITE           =  8'hF0;

(*noprune*) reg [7:0]   SPI_STATE           = STATE_IDLE;   /*synthesis noprune*/

assign      ss_n                            = SPI_STATE[3]; // 状态赋值 SPI 片选信号
assign      sclk                            = SPI_STATE[2]; // 状态赋值 SPI 时钟信号
assign      ready                           = SPI_STATE[1]; // 状态赋值 SPI 数据接收完成信号
assign      idle                            = SPI_STATE[0]; // 状态赋值 SPI 模块空闲信号

/* 开始信号 上升沿触发信号 start 同步至 电平触发信号 start_flag */

reg           start_flag;
reg  [31:0]   data_mosi_d;
always @(posedge clk or posedge start or posedge ready or negedge rst_n) begin
    if (!rst_n) begin
        busy <= 1'b0;
        data_ready <= 1'b0;

        data_mosi_d <= 32'd0;

        start_flag <= 1'b0;
    end else begin
        if (start) begin
            busy <= 1'b1;
            data_ready <= 1'b0;

            data_mosi_d <= write_read ? {OPCODE_WRITE, data_in[23:0]} : {OPCODE_READ, data_in[23:0]};

            start_flag <= 1'b1;
        end else if (ready) begin
            data_ready <= 1'b1; // 信号会一直持续到下次 start 到来, 不必再同步时钟域了, 耶

            start_flag <= 1'b0;
        end else if (idle && ~start_flag) begin // 保证在数据传输完成后, 再将 busy 信号置为 0; 若只用 idle 信号, 在 idle 态时, start 信号一消失, busy 信号立刻会被置为 0
            busy <= 1'b0;
        end
    end
end

/** SPI 传输数据寄存器 **
  *   SPI 数据帧:
  *     Control Phase + Address Phase + Data Phase
  *         8bit            16bit          8bit
  *           |               |              |
  * 无论写或读取寄存器, MISO 上 Control Phase 与 Address Phase 的时序均为:
  *   {     0x00,         0x01,0x02                                 }
  * 
  */
reg [31:0]  data_mosi           = 32'd0;
reg [31:0]  data_miso           = 32'd0;

reg [4:0]   data_ptr            = 5'd31; // SPI 传输数据寄存器指针, 帧长度 32

/* 输出寄存器 同步 ready 信号 赋值 */

always@(posedge ready) begin // 在数据准备完毕时, 再向输出数据寄存器赋值
    data_out <= data_miso[7:0];
end

/* SPI 状态机 */

always@(posedge clk or negedge rst_n) begin
    if (!rst_n) begin

        SPI_STATE <= STATE_IDLE;

    end
    else begin
        case (SPI_STATE)

            STATE_IDLE: begin
                if (start_flag) begin // 接收到 开始信号 上升沿
                    mosi <= 1'b0;

                    data_miso[data_ptr] <= data_miso[data_ptr];
                    data_ptr <= 5'd31;
                    
                    // data_mosi <= write_read ? {OPCODE_WRITE, data_in[23:0]} : {OPCODE_READ, data_in[23:0]};
                    data_mosi <= data_mosi_d;

                    SPI_STATE <= STATE_WAIT1;
                end
                else begin
                    mosi <= 1'b0;
                    
                    data_miso[data_ptr] <= data_miso[data_ptr];
                    data_ptr <= 5'd31;
                    
                    data_mosi <= data_mosi;

                    SPI_STATE <= STATE_IDLE;
                end
            end
            STATE_WAIT1: begin
                mosi <= 1'b0;
                
                data_miso[data_ptr] <= data_miso[data_ptr];
                data_ptr <= data_ptr;
                
                data_mosi <= data_mosi;

                SPI_STATE <= STATE_WRITE_MOSI;
            end

            STATE_WRITE_MOSI: begin
                mosi <= data_mosi[data_ptr]; // 更新 MOSI 电平
                
                data_miso[data_ptr] <= data_miso[data_ptr];
                data_ptr <= data_ptr;
                
                data_mosi <= data_mosi;

                SPI_STATE <= STATE_WAIT2;
            end
            STATE_WAIT2: begin
                mosi <= mosi;
                
                data_miso[data_ptr] <= data_miso[data_ptr];
                data_ptr <= data_ptr;
                
                data_mosi <= data_mosi;

                SPI_STATE <= STATE_SET_CLOCK;
            end        
            STATE_SET_CLOCK: begin
                mosi <= mosi;
                
                data_miso[data_ptr] <= data_miso[data_ptr];
                data_ptr <= data_ptr;
                
                data_mosi <= data_mosi;

                SPI_STATE <= STATE_WAIT3;
            end
            STATE_WAIT3: begin
                mosi <= mosi;
                
                data_miso[data_ptr] <= data_miso[data_ptr];
                data_ptr <= data_ptr;
                
                data_mosi <= data_mosi;

                SPI_STATE <= STATE_READ_MISO;
            end
            STATE_READ_MISO: begin
                mosi <= mosi;
                
                data_miso[data_ptr] <= miso; // 读取 MISO 电平
                data_ptr <= data_ptr;
                
                data_mosi <= data_mosi;

                SPI_STATE <= STATE_RESET_CLOCK;
            end
            STATE_RESET_CLOCK: begin
                mosi <= mosi;
                
                data_miso[data_ptr] <= data_miso[data_ptr];
                data_ptr <= data_ptr;
                
                data_mosi <= data_mosi;

                SPI_STATE <= STATE_WAIT4;
            end
            STATE_WAIT4: begin
                if (data_ptr == 0) begin // 帧发送完毕
                    mosi <= 1'b0;
                    
                    data_miso[data_ptr] <= data_miso[data_ptr];
                    data_ptr <= 5'd0;
                    
                    data_mosi <= data_mosi;

                    SPI_STATE <= STATE_WAIT5;
                end
                else begin
                    mosi <= 1'b0;
                    
                    data_miso[data_ptr] <= data_miso[data_ptr];
                    data_ptr <= data_ptr - 5'd1;
                    
                    data_mosi <= data_mosi;

                    SPI_STATE <= STATE_WRITE_MOSI;
                end
                
            end

            STATE_WAIT5: begin
                mosi <= 1'b0;
                
                data_miso[data_ptr] <= data_miso[data_ptr];
                data_ptr <= 5'd0;
                
                data_mosi <= data_mosi;

                SPI_STATE <= STATE_DONE;
            end
            STATE_DONE: begin
                mosi <= 1'b0;
                
                data_miso[data_ptr] <= data_miso[data_ptr];
                data_ptr <= 5'd0;
                
                data_mosi <= data_mosi;

                SPI_STATE <= STATE_IDLE;
            end
            
            default: begin
                mosi <= 1'b0;
                
                data_miso[data_ptr] <= 1'b0;
                data_ptr <= 5'd0;

                data_mosi <= 32'd0;
                
                SPI_STATE <= STATE_IDLE;
            end

        endcase
    end
end

endmodule
