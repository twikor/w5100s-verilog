module M_W5100S (
    input               clk,
    input               spi_mod_clk,
    input               rst_n,

    // 模块 控制与信号接口
    input               at_n,                                   // 内部控制中断
    input      [  7: 0] at_command,                             // 控制指令
    output reg          res_int_n,                              // 内部响应中断
    output reg [ 15: 0] res_int_reg,                            // 响应中断寄存器, 低8位为 W5100S 芯片中断寄存器, 高8位为自定义中断寄存器

    input               send_en_n,                              // 数据发送使能, 只是状态转移开关, 数据发送过程依然由命令触发
    output reg          send_done,                              // 数据发送完成
    input      [ 15: 0] send_size,                              // 数据单次发送大小
    output reg          send_buf_rd_clk,                        // 数据发送读时钟
    output reg          send_buf_rd_en,                         // 数据发送读使能
    input      [  7: 0] send_buf_rd_data,                       // 数据发送读数据
    input               send_buf_rd_empty,                      // 数据发送读空

    input               recv_en_n,                              // 数据接收使能
    output reg          recv_done,                              // 数据接收完成
    output reg [ 15: 0] recv_size,                              // 数据单次接收大小
    output reg          recv_buf_wr_clk,                        // 数据接收时钟
    output reg          recv_buf_wr_en,                         // 数据接收写使能
    output reg [  9: 0] recv_buf_wr_addr,                       // 数据接收写地址
    output reg [  7: 0] recv_buf_wr_data,                       // 数据接收写数据

    output     [ 15: 0] state,                                  // 状态机状态

    // W5100S 硬件接口
    output              w5100s_spi_ss_n,                        // W5100S SPI SS_N
    output              w5100s_spi_sclk,                        // W5100S SPI SCLK
    output              w5100s_spi_mosi,                        // W5100S SPI MOSI
    input               w5100s_spi_miso,                        // W5100S SPI MISO
    output reg          w5100s_rst_n,                           // W5100S 复位信号
    input               w5100s_int_n                            // W5100S 中断信号
);

/* W5100S 驱动模块 指令列表 */

localparam W5100S_CMD_INIT                   = 8'h01;           // 初始化 W5100S
localparam W5100S_CMD_RST_HARD               = 8'h02;           // 硬复位 W5100S
localparam W5100S_CMD_RST_SOFT               = 8'h03;           // 软复位 W5100S
localparam W5100S_CMD_TCP_SERVER_SETUP       = 8'h10;           // 配置 TCP 服务器
localparam W5100S_CMD_TCP_SERVER_SEND_DATA   = 8'h20;           // 发送数据
localparam W5100S_CMD_TCP_SERVER_DISCONNET   = 8'h25;           // 主动断开 TCP 连接

/* W5100S 寄存器列表 初始化 */

// 所有使用到的配置与状态寄存器地址的首地址, 长度在后面附出

// 通用寄存器

localparam W5100S_COMMON_REG_MR_ADDR         = 16'h00_00;       // Config: Mode Register - 模式寄存器                            
localparam W5100S_COMMON_REG_MR_DATA         = 8'h00;           //      0x80: 复位所有寄存器, 0x00: 不复位不禁 ping 不使用 PPPoE
localparam W5100S_COMMON_REG_MR_DATA_RST     = 8'h80;
localparam W5100S_COMMON_REG_MR2_ADDR        = 16'h00_30;       // Config: Mode Register 2 - 模式寄存器2
localparam W5100S_COMMON_REG_MR2_DATA        = 8'h40;           //      0x40: 使能中断引脚
localparam W5100S_COMMON_REG_INTPTMR0_ADDR   = 16'h00_13;       // Config: Interrupt Pending Time Register - 中断挂起时间寄存器
localparam W5100S_COMMON_REG_INTPTMR0_DATA   = 8'h03;           //      {0x03, 0xEB} -> 0x03EB -> 1000 -> 1000*???us = ???s
localparam W5100S_COMMON_REG_INTPTMR1_ADDR   = 16'h00_14;
localparam W5100S_COMMON_REG_INTPTMR1_DATA   = 8'hEB;
localparam W5100S_COMMON_REG_IMR_ADDR        = 16'h00_16;       // Config: Interrupt Mask Register - 中断屏蔽寄存器                  
localparam W5100S_COMMON_REG_IMR_DATA        = 8'h01;           //      0x01: 仅允许 Socket0 中断, 0x81: 允许 Socket0 与 IP 冲突中断
localparam W5100S_COMMON_REG_RTR0_ADDR       = 16'h00_17;       // Config: Retransmission Time Register - 重传超时时间值寄存器             
localparam W5100S_COMMON_REG_RTR0_DATA       = 8'h13;           //      {0x13, 0x88} -> 0x1388 -> 5000 -> 5000*100us = 0.5s
localparam W5100S_COMMON_REG_RTR1_ADDR       = 16'h00_18;            
localparam W5100S_COMMON_REG_RTR1_DATA       = 8'h88;         
localparam W5100S_COMMON_REG_RCR_ADDR        = 16'h00_19;       // Config: Retransmission Count Register - 重传次数寄存器            
localparam W5100S_COMMON_REG_RCR_DATA        = 8'h04;           //      0x04 -> 4次重传机会

localparam W5100S_COMMON_REG_SHAR0_ADDR      = 16'h00_09;       // Network Settings: W5100S Mac Address             [5:0]
localparam W5100S_COMMON_REG_SHAR0_DATA      = 8'h11;           //     {0x11, 0x22, 0x33, 0x44, 0x55, 0x66} -> 11:22:33:44:55:66
localparam W5100S_COMMON_REG_SHAR1_ADDR      = 16'h00_0A;       
localparam W5100S_COMMON_REG_SHAR1_DATA      = 8'h22;       
localparam W5100S_COMMON_REG_SHAR2_ADDR      = 16'h00_0B;       
localparam W5100S_COMMON_REG_SHAR2_DATA      = 8'h33;       
localparam W5100S_COMMON_REG_SHAR3_ADDR      = 16'h00_0C;       
localparam W5100S_COMMON_REG_SHAR3_DATA      = 8'h44;       
localparam W5100S_COMMON_REG_SHAR4_ADDR      = 16'h00_0D;       
localparam W5100S_COMMON_REG_SHAR4_DATA      = 8'h55;       
localparam W5100S_COMMON_REG_SHAR5_ADDR      = 16'h00_0E;       
localparam W5100S_COMMON_REG_SHAR5_DATA      = 8'h66;       
localparam W5100S_COMMON_REG_GAR0_ADDR       = 16'h00_01;       // Network Settings: W5100S Gateway IP Address      [3:0]
localparam W5100S_COMMON_REG_GAR0_DATA       = 8'hC0;           //     {0xC0, 0xA8, 0x0A, 0x01} -> 192.168.10.1
localparam W5100S_COMMON_REG_GAR1_ADDR       = 16'h00_02;       
localparam W5100S_COMMON_REG_GAR1_DATA       = 8'hA8;       
localparam W5100S_COMMON_REG_GAR2_ADDR       = 16'h00_03;       
localparam W5100S_COMMON_REG_GAR2_DATA       = 8'h0A;       
localparam W5100S_COMMON_REG_GAR3_ADDR       = 16'h00_04;       
localparam W5100S_COMMON_REG_GAR3_DATA       = 8'h01;       
localparam W5100S_COMMON_REG_SUBR0_ADDR      = 16'h00_05;       // Network Settings: W5100S Subnet Mask Address     [3:0]
localparam W5100S_COMMON_REG_SUBR0_DATA      = 8'hFF;           //     {0xFF, 0xFF, 0xFF, 0x00} -> 255.255.255.0
localparam W5100S_COMMON_REG_SUBR1_ADDR      = 16'h00_06;       
localparam W5100S_COMMON_REG_SUBR1_DATA      = 8'hFF;       
localparam W5100S_COMMON_REG_SUBR2_ADDR      = 16'h00_07;       
localparam W5100S_COMMON_REG_SUBR2_DATA      = 8'hFF;       
localparam W5100S_COMMON_REG_SUBR3_ADDR      = 16'h00_08;       
localparam W5100S_COMMON_REG_SUBR3_DATA      = 8'h00;       
localparam W5100S_COMMON_REG_SIPR0_ADDR      = 16'h00_0F;       // Network Settings: W5100S IP Address              [3:0]
localparam W5100S_COMMON_REG_SIPR0_DATA      = 8'hC0;           //     {0xC0, 0xA8, 0x0A, 0x0A} -> 192.168.10.10
localparam W5100S_COMMON_REG_SIPR1_ADDR      = 16'h00_10;       
localparam W5100S_COMMON_REG_SIPR1_DATA      = 8'hA8;       
localparam W5100S_COMMON_REG_SIPR2_ADDR      = 16'h00_11;       
localparam W5100S_COMMON_REG_SIPR2_DATA      = 8'h0A;       
localparam W5100S_COMMON_REG_SIPR3_ADDR      = 16'h00_12;       
localparam W5100S_COMMON_REG_SIPR3_DATA      = 8'h0A;       

localparam W5100S_COMMON_REG_TMSR_ADDR       = 16'h00_1B;       // Socket Buffer Settings: TX Memory Size, 在此配置缓存区大小后无需再为 4个 socket 分别单独配置 Sn_TXBUF_SIZE 寄存器
localparam W5100S_COMMON_REG_TMSR_DATA       = 8'b0000_0011;    //     Socket0 分配 8K, 其余 Socket 均为0
localparam W5100S_COMMON_REG_RMSR_ADDR       = 16'h00_1A;       // Socket Buffer Settings: RX Memory Size, 在此配置缓存区大小后无需再为 4个 socket 分别单独配置 Sn_RXBUF_SIZE 寄存器
localparam W5100S_COMMON_REG_RMSR_DATA       = 8'b0000_0011;    //     Socket0 分配 8K, 其余 Socket 均为0

// Socket 寄存器与常用数据值, 此处仅使用 Socket0
//    若要使用其他3个 socket, 只需在 Socket0 的寄存器地址对应加上 offset (0x0100*(n+4)) 即可

localparam W5100S_SOCKET_REG_S0_TXBUF_SIZE_ADDR                   = 16'h04_1F;       // Socket0 TX Buffer Size: Socket0 发送缓存大小寄存器, 已配置 TMSR, 故无需再配置此寄存器 
localparam W5100S_SOCKET_REG_S0_RXBUF_SIZE_ADDR                   = 16'h04_1E;       // Socket0 TX Buffer Size: Socket0 接收缓存大小寄存器, 已配置 RMSR, 故无需再配置此寄存器

localparam W5100S_SOCKET_REG_S0_MR_ADDR                           = 16'h04_00;       // Socket0 Settings: Mode
localparam W5100S_SOCKET_REG_S0_MR_DATA                           = 8'h01;           //     TCP
localparam W5100S_SOCKET_REG_S0_IMR_ADDR                          = 16'h04_2C;       // Socket0 Settings: Interrupt Mask register
localparam W5100S_SOCKET_REG_S0_IMR_DATA                          = 8'h1F;           //     X, X, X, SENDOK, TIMEOUT, RECV, DISCON, CON; 置1来开启对应中断; 0x1F -> 开启所有中断
localparam W5100S_SOCKET_REG_S0_PORTR0_ADDR                       = 16'h04_04;       // Socket0 Settings: Port
localparam W5100S_SOCKET_REG_S0_PORTR0_DATA                       = 8'h01;           //     {0x01, 0xEF} -> 0x01EF -> 495 
localparam W5100S_SOCKET_REG_S0_PORTR1_ADDR                       = 16'h04_05;
localparam W5100S_SOCKET_REG_S0_PORTR1_DATA                       = 8'hEF;

localparam W5100S_SOCKET_REG_S0_CR_ADDR                           = 16'h04_01;       // Socket0 Settings: 设置 Socket 命令
localparam W5100S_SOCKET_REG_S0_CR_DATA_CLR                       = 8'h00;
localparam W5100S_SOCKET_REG_S0_CR_DATA_CMD_OPEN                  = 8'h01;
localparam W5100S_SOCKET_REG_S0_CR_DATA_CMD_LISTEN                = 8'h02;
localparam W5100S_SOCKET_REG_S0_CR_DATA_CMD_CONNECT               = 8'h04;
localparam W5100S_SOCKET_REG_S0_CR_DATA_CMD_DISCON                = 8'h08;
localparam W5100S_SOCKET_REG_S0_CR_DATA_CMD_CLOSE                 = 8'h10;
localparam W5100S_SOCKET_REG_S0_CR_DATA_CMD_SEND                  = 8'h20;
localparam W5100S_SOCKET_REG_S0_CR_DATA_CMD_SEND_MAC              = 8'h21;
localparam W5100S_SOCKET_REG_S0_CR_DATA_CMD_SEND_KEEP             = 8'h22;
localparam W5100S_SOCKET_REG_S0_CR_DATA_CMD_RECV                  = 8'h40;

localparam W5100S_SOCKET_REG_S0_IR_ADDR                           = 16'h04_02;       // Socket0 Interrupt: Socket0 中断寄存器
localparam W5100S_SOCKET_REG_S0_IR_DATA_CHK_INT_CON               = 8'b0000_0001;    //     成功与对方建立连接, Sn_SR 变为 SOCK_ESTABLISHED 状态时
localparam W5100S_SOCKET_REG_S0_IR_DATA_CHK_INT_DISCON            = 8'b0000_0010;    //     接收到对方的 FIN 或 FIN/ACK 包时
localparam W5100S_SOCKET_REG_S0_IR_DATA_CHK_INT_RECV              = 8'b0000_0100;    //     无论何时, 对方已接收数据
localparam W5100S_SOCKET_REG_S0_IR_DATA_CHK_INT_TIMEOUT           = 8'b0000_1000;    //     ARPto 或 TCPto 超时
localparam W5100S_SOCKET_REG_S0_IR_DATA_CHK_INT_SENDOK            = 8'b0001_0000;    //     SEND 命令完成
localparam W5100S_SOCKET_REG_S0_IR_DATA_CHK_INT_ALL               = 8'b1111_1111;    //     所有中断

localparam W5100S_SOCKET_REG_S0_SR_ADDR                           = 16'h04_03;       // Socket0 Status: 查看 Socket 状态
localparam W5100S_SOCKET_REG_S0_SR_DATA_CHK_SOCK_CLOSED           = 8'h00;
localparam W5100S_SOCKET_REG_S0_SR_DATA_CHK_SOCK_INIT             = 8'h13;
localparam W5100S_SOCKET_REG_S0_SR_DATA_CHK_SOCK_LISTEN           = 8'h14;
localparam W5100S_SOCKET_REG_S0_SR_DATA_CHK_SOCK_ESTABLISHED      = 8'h17;
localparam W5100S_SOCKET_REG_S0_SR_DATA_CHK_SOCK_CLOSE_WAIT       = 8'h1C;
localparam W5100S_SOCKET_REG_S0_SR_DATA_CHK_SOCK_UDP              = 8'h22;
localparam W5100S_SOCKET_REG_S0_SR_DATA_CHK_SOCK_IPRAW            = 8'h32;
localparam W5100S_SOCKET_REG_S0_SR_DATA_CHK_SOCK_MACRAW           = 8'h42;

localparam W5100S_SOCKET_REG_S0_TX_WR0_ADDR                       = 16'h04_24;       // Socket0 TX Write Pointer: Socket0 发送写指针寄存器
localparam W5100S_SOCKET_REG_S0_TX_WR1_ADDR                       = 16'h04_25;
localparam W5100S_SOCKET_REG_S0_TX_FSR0_ADDR                      = 16'h04_20;       // Socket0 TX Free Size: Socket0 空闲发送缓存寄存器
localparam W5100S_SOCKET_REG_S0_TX_FSR1_ADDR                      = 16'h04_21;
localparam W5100S_SOCKET_REG_S0_RX_RD0_ADDR                       = 16'h04_28;       // Socket0 RX Read Pointer: Socket0 接收写指针寄存器
localparam W5100S_SOCKET_REG_S0_RX_RD1_ADDR                       = 16'h04_29;
localparam W5100S_SOCKET_REG_S0_RX_RSR0_ADDR                      = 16'h04_26;       // Socket0 RX Received Size Register: Socket0 接收大小寄存器
localparam W5100S_SOCKET_REG_S0_RX_RSR1_ADDR                      = 16'h04_27;

localparam W5100S_SOCKET_VAR_S0_TX_BASE_ADDR                      = 16'h40_00;       // Socket0 TX 缓存基地址
localparam W5100S_SOCKET_VAR_S0_TX_MASK                           = 16'd8191;        // Socket0 TX 缓存大小掩码, 计算方式: 8*1024-1
localparam W5100S_SOCKET_VAR_S0_RX_BASE_ADDR                      = 16'h60_00;       // Socket0 RX 缓存基地址
localparam W5100S_SOCKET_VAR_S0_RX_MASK                           = 16'd8191;        // Socket0 RX 缓存大小掩码
localparam W5100S_SOCKET_VAR_MAX_TX_BUF_SIZE                      = 16'd8192;        // Socket0 TX 最大缓冲区大小
localparam W5100S_SOCKET_VAR_MAX_RX_BUF_SIZE                      = 16'd8192;        // Socket0 RX 最大缓冲区大小
localparam W5100S_SOCKET_VAR_SEND_SIZE                            = 16'd8;           // Socket0 单次发送数据大小; 现在由寄存器 send_size 动态指定
localparam W5100S_SOCKET_VAR_RECV_SIZE_MAX                        = 16'd64;          // Socket0 单次接收数据最大大小

reg [15:0] w5100s_init_seq_regs_addr      [31:0];               // W5100S 通用寄存器 地址
reg [ 7:0] w5100s_init_seq_regs_data      [31:0];               // W5100S 通用寄存器 数据
integer    w5100s_init_seq_regs_cnt;                            // W5100S 通用寄存器 数量
integer    i;
initial begin
    i = 0;

    w5100s_init_seq_regs_addr[i] <= W5100S_COMMON_REG_MR_ADDR;      
    w5100s_init_seq_regs_data[i] <= W5100S_COMMON_REG_MR_DATA;          i = i + 1;
    w5100s_init_seq_regs_addr[i] <= W5100S_COMMON_REG_MR2_ADDR;      
    w5100s_init_seq_regs_data[i] <= W5100S_COMMON_REG_MR2_DATA;         i = i + 1;
    w5100s_init_seq_regs_addr[i] <= W5100S_COMMON_REG_INTPTMR0_ADDR;
    w5100s_init_seq_regs_data[i] <= W5100S_COMMON_REG_INTPTMR0_DATA;    i = i + 1;
    w5100s_init_seq_regs_addr[i] <= W5100S_COMMON_REG_INTPTMR1_ADDR;
    w5100s_init_seq_regs_data[i] <= W5100S_COMMON_REG_INTPTMR1_DATA;    i = i + 1;
    w5100s_init_seq_regs_addr[i] <= W5100S_COMMON_REG_IMR_ADDR;     
    w5100s_init_seq_regs_data[i] <= W5100S_COMMON_REG_IMR_DATA;         i = i + 1;
    w5100s_init_seq_regs_addr[i] <= W5100S_COMMON_REG_RTR0_ADDR;        
    w5100s_init_seq_regs_data[i] <= W5100S_COMMON_REG_RTR0_DATA;        i = i + 1;
    w5100s_init_seq_regs_addr[i] <= W5100S_COMMON_REG_RTR1_ADDR;        
    w5100s_init_seq_regs_data[i] <= W5100S_COMMON_REG_RTR1_DATA;        i = i + 1;
    w5100s_init_seq_regs_addr[i] <= W5100S_COMMON_REG_RCR_ADDR;         
    w5100s_init_seq_regs_data[i] <= W5100S_COMMON_REG_RCR_DATA;         i = i + 1;
    w5100s_init_seq_regs_addr[i] <= W5100S_COMMON_REG_SHAR0_ADDR;       
    w5100s_init_seq_regs_data[i] <= W5100S_COMMON_REG_SHAR0_DATA;       i = i + 1;
    w5100s_init_seq_regs_addr[i] <= W5100S_COMMON_REG_SHAR1_ADDR;       
    w5100s_init_seq_regs_data[i] <= W5100S_COMMON_REG_SHAR1_DATA;       i = i + 1;
    w5100s_init_seq_regs_addr[i] <= W5100S_COMMON_REG_SHAR2_ADDR;       
    w5100s_init_seq_regs_data[i] <= W5100S_COMMON_REG_SHAR2_DATA;       i = i + 1;
    w5100s_init_seq_regs_addr[i] <= W5100S_COMMON_REG_SHAR3_ADDR;       
    w5100s_init_seq_regs_data[i] <= W5100S_COMMON_REG_SHAR3_DATA;       i = i + 1;
    w5100s_init_seq_regs_addr[i] <= W5100S_COMMON_REG_SHAR4_ADDR;       
    w5100s_init_seq_regs_data[i] <= W5100S_COMMON_REG_SHAR4_DATA;       i = i + 1;
    w5100s_init_seq_regs_addr[i] <= W5100S_COMMON_REG_SHAR5_ADDR;       
    w5100s_init_seq_regs_data[i] <= W5100S_COMMON_REG_SHAR5_DATA;       i = i + 1;
    w5100s_init_seq_regs_addr[i] <= W5100S_COMMON_REG_GAR0_ADDR;        
    w5100s_init_seq_regs_data[i] <= W5100S_COMMON_REG_GAR0_DATA;        i = i + 1;
    w5100s_init_seq_regs_addr[i] <= W5100S_COMMON_REG_GAR1_ADDR;        
    w5100s_init_seq_regs_data[i] <= W5100S_COMMON_REG_GAR1_DATA;        i = i + 1;
    w5100s_init_seq_regs_addr[i] <= W5100S_COMMON_REG_GAR2_ADDR;        
    w5100s_init_seq_regs_data[i] <= W5100S_COMMON_REG_GAR2_DATA;        i = i + 1;
    w5100s_init_seq_regs_addr[i] <= W5100S_COMMON_REG_GAR3_ADDR;        
    w5100s_init_seq_regs_data[i] <= W5100S_COMMON_REG_GAR3_DATA;        i = i + 1;
    w5100s_init_seq_regs_addr[i] <= W5100S_COMMON_REG_SUBR0_ADDR;       
    w5100s_init_seq_regs_data[i] <= W5100S_COMMON_REG_SUBR0_DATA;       i = i + 1;
    w5100s_init_seq_regs_addr[i] <= W5100S_COMMON_REG_SUBR1_ADDR;       
    w5100s_init_seq_regs_data[i] <= W5100S_COMMON_REG_SUBR1_DATA;       i = i + 1;
    w5100s_init_seq_regs_addr[i] <= W5100S_COMMON_REG_SUBR2_ADDR;       
    w5100s_init_seq_regs_data[i] <= W5100S_COMMON_REG_SUBR2_DATA;       i = i + 1;
    w5100s_init_seq_regs_addr[i] <= W5100S_COMMON_REG_SUBR3_ADDR;       
    w5100s_init_seq_regs_data[i] <= W5100S_COMMON_REG_SUBR3_DATA;       i = i + 1;
    w5100s_init_seq_regs_addr[i] <= W5100S_COMMON_REG_SIPR0_ADDR;       
    w5100s_init_seq_regs_data[i] <= W5100S_COMMON_REG_SIPR0_DATA;       i = i + 1;
    w5100s_init_seq_regs_addr[i] <= W5100S_COMMON_REG_SIPR1_ADDR;       
    w5100s_init_seq_regs_data[i] <= W5100S_COMMON_REG_SIPR1_DATA;       i = i + 1;
    w5100s_init_seq_regs_addr[i] <= W5100S_COMMON_REG_SIPR2_ADDR;       
    w5100s_init_seq_regs_data[i] <= W5100S_COMMON_REG_SIPR2_DATA;       i = i + 1;
    w5100s_init_seq_regs_addr[i] <= W5100S_COMMON_REG_SIPR3_ADDR;       
    w5100s_init_seq_regs_data[i] <= W5100S_COMMON_REG_SIPR3_DATA;       i = i + 1;

    w5100s_init_seq_regs_addr[i] <= W5100S_COMMON_REG_TMSR_ADDR;    
    w5100s_init_seq_regs_data[i] <= W5100S_COMMON_REG_TMSR_DATA;        i = i + 1;
    w5100s_init_seq_regs_addr[i] <= W5100S_COMMON_REG_RMSR_ADDR; 
    w5100s_init_seq_regs_data[i] <= W5100S_COMMON_REG_RMSR_DATA;        i = i + 1;

    w5100s_init_seq_regs_cnt = i;
end

/* W5100S 控制信号 下降沿捕获与信号同步 */

//  下降沿捕获
//  input   ->     d0     ->     d1
//  1       ->     1      ->     1
//  0       ->     1      ->     1
//  0       ->     0      ->     1  *
//  0       ->     0      ->     0
reg  at_n_d0, at_n_d1;
wire at_n_flag = ~at_n_d0 & at_n_d1; // 捕获 at_n 下降沿, 得到一个时钟周期的脉冲信号
always @(posedge clk or negedge rst_n) begin // 对内部控制中断信号 at_n 延迟两个时钟周期
    if (!rst_n) begin
        at_n_d0 <= 1'b1;
        at_n_d1 <= 1'b1;
    end else begin
        at_n_d0 <= at_n;
        at_n_d1 <= at_n_d0;
    end
end

/* W5100S 内部响应中断信号 下降沿捕获与信号同步 */

//  下降沿捕获
//  input   ->     d0     ->     d1
//  1       ->     1      ->     1
//  0       ->     1      ->     1
//  0       ->     0      ->     1  *
//  0       ->     0      ->     0
reg  res_int_n_d0, res_int_n_d1;
wire res_int_n_flag = ~res_int_n_d0 & res_int_n_d1; // 捕获 res_int_n 下降沿，得到一个时钟周期的脉冲信号
always @(posedge clk or negedge rst_n) begin // 对内部控制中断信号 res_int_n 延迟两个时钟周期
    if (!rst_n) begin
        res_int_n_d0 <= 1'b1;
        res_int_n_d1 <= 1'b1;
    end else begin
        res_int_n_d0 <= res_int_n;
        res_int_n_d1 <= res_int_n_d0;
    end
end

/* W5100S SPI 数据接收 信号同步 - 2周期后自动 信号复位 */

wire spi_data_ready_sync;
// reg  spi_data_ready_sync_rst_n;
M_Helper_AsyncTrapAndReset u_Helper_AsyncTrapAndReset_spi_data_ready (
    .async_sig      (spi_data_ready),
    .outclk         (clk),
    .out_sync_sig   (spi_data_ready_sync),
    .auto_reset     (1'b1),
    .reset          (1'b1)
);

/* W5100S 合并 来自中断与主处理状态机的 SPI 信号 */

// wire            spi_start    = (INT_HANDLER_STATE != INT_HANDLER_STATE_IDLE) ? spi_start_int : spi_start_sta;
// wire            spi_wr       = (INT_HANDLER_STATE != INT_HANDLER_STATE_IDLE) ? spi_wr_int : spi_wr_sta;
// wire [23:0]     spi_data_in  = (INT_HANDLER_STATE != INT_HANDLER_STATE_IDLE) ? spi_data_in_int : spi_data_in_sta;

wire            spi_start    = spi_lock_int ? spi_start_int : spi_start_sta;
wire            spi_wr       = spi_lock_int ? spi_wr_int : spi_wr_sta;
wire [23:0]     spi_data_in  = spi_lock_int ? spi_data_in_int : spi_data_in_sta;

// reg                spi_start, spi_wr;
// reg  [23:0]        spi_data_in;
// always @(posedge clk or negedge rst_n) begin
//     if (!rst_n) begin
//         spi_start <= 1'b0;
//         spi_wr <= 1'b0;
//         spi_data_in <= 24'b0;
//     end else begin
//         spi_start <= spi_lock_int ? spi_start_int : spi_start_sta;
//         spi_wr <= spi_lock_int ? spi_wr_int : spi_wr_sta;
//         spi_data_in <= spi_lock_int ? spi_data_in_int : spi_data_in_sta;
//     end
// end

/* W5100S SPI 主机 总线控制器 */

// wire            spi_state_available = ~spi_busy && ~spi_lock_int;

wire            spi_busy, spi_data_ready;

wire [ 7:0]     spi_data_out;
M_W5100S_SPIMaster u_W5100S_SPIMaster (
    .clk(spi_mod_clk),
    .rst_n(rst_n),

    .start(spi_start),
    .write_read(spi_wr),
    .data_in(spi_data_in),
    .data_out(spi_data_out),
    
    .busy(spi_busy),
    .data_ready(spi_data_ready),
    
    .ss_n(w5100s_spi_ss_n),
    .sclk(w5100s_spi_sclk),
    .mosi(w5100s_spi_mosi),
    .miso(w5100s_spi_miso)
);

/* W5100S 中断处理 
 *     这里先讨论一下中断处理状态机的设计
 *         首先 为什么 int_n 要用电平触发:
 *             若中断来临时主状态机正在使用 SPI 模块, 使用沿触发会使中断处理状态机错过此次中断
 *         然后 (为什么要等待一会儿再进行中断寄存器查询:)
 *             (等待 spi_start 与 spi_state_idle 中间空余时间; 若在刚开始中断处理状态机的状态跳出 IDLE 时主状态机刚好 start_idle,)
 *             (虽然此时已经 spi_lock, 但触发信号已经发出, 中断处理状态机智能等待主状态机此次使用的完成.)
 *         没有然后了, 已经重构完成 :)
 *   
 */

localparam                INT_HANDLER_STATE_IDLE                                      = 8'h00;
localparam                INT_HANDLER_STATE_WAIT_B4_QRY                               = 8'h01;
localparam                INT_HANDLER_STATE_QRY_IR                                    = 8'h02;
localparam                INT_HANDLER_STATE_WAIT_B4_CLR                               = 8'h03;
localparam                INT_HANDLER_STATE_CLR_IR                                    = 8'h04;
localparam                INT_HANDLER_STATE_WAIT_POST1                                = 8'h05;
localparam                INT_HANDLER_STATE_WAIT_POST2                                = 8'h06;

(*noprune*) reg  [15:0]   INT_HANDLER_STATE                                           = INT_HANDLER_STATE_IDLE;     /*synthesis noprune*/

(*noprune*) reg  [31:0]   int_delay_cnter;

reg             int_mask_flag;
reg  [ 3:0]     int_chk_wait_flag;

reg             spi_lock_int;

reg             spi_start_int, spi_wr_int;
reg  [23:0]     spi_data_in_int;
always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        INT_HANDLER_STATE <= INT_HANDLER_STATE_IDLE;

        int_delay_cnter <= 32'h0;

        int_chk_wait_flag <= 4'd0;

        res_int_n <= 1'b1;
        res_int_reg <= 8'h0;

        spi_lock_int <= 1'b0;

        spi_start_int <= 1'b0;
        spi_wr_int <= 1'b0;
        spi_data_in_int <= 24'h0;
    end else begin

        case (INT_HANDLER_STATE)

            INT_HANDLER_STATE_IDLE: begin
                spi_start_int <= 1'b0;

                if (~spi_busy) begin // spi 可用时才转移状态, 使 SPI 寄存器多路器打向中断处理
                    // if (!int_mask_flag && w5100s_int_n_flag) begin // 边沿触发
                    if (!int_mask_flag && !w5100s_int_n) begin // 电平触发
                        spi_lock_int <= 1'b1; // 锁定 SPI 总线, 防止主状态机占用

                        INT_HANDLER_STATE <= INT_HANDLER_STATE_QRY_IR;
                        // INT_HANDLER_STATE <= INT_HANDLER_STATE_WAIT_B4_QRY;
                    end
                end
            end
            INT_HANDLER_STATE_WAIT_B4_QRY: begin
                if (int_delay_cnter <= 32'd100) begin // 间隔一定时间后再切换到下一个状态
                    int_delay_cnter <= int_delay_cnter + 32'd1;
                end else begin
                    int_delay_cnter <= 32'd0;

                    INT_HANDLER_STATE <= INT_HANDLER_STATE_QRY_IR;
                end
            end
            INT_HANDLER_STATE_QRY_IR: begin
                if (~spi_busy) begin // spi 空闲, 判断寄存器数据查询状态, 并继续; idle 信号常态不变, 即信号维持时间长, 故不需要同步时钟域
                    spi_start_int <= 1'b1;
                    spi_wr_int <= 1'b0;
                    spi_data_in_int <= {
                            16'd65535 & W5100S_SOCKET_REG_S0_IR_ADDR,
                            8'd255    & 8'h0 // 读取寄存器时数据段为任意即可, 此处 8bit 全0
                    }; // 读出数据

                    res_int_n <= 1'b1; // 预先清除 内部中断信号

                    INT_HANDLER_STATE <= INT_HANDLER_STATE_WAIT_B4_CLR;
                    // INT_HANDLER_STATE <= INT_HANDLER_STATE_WAIT_B4_CLR;
                end else begin
                    spi_start_int <= 1'b0;

                    INT_HANDLER_STATE <= INT_HANDLER_STATE_QRY_IR;
                end
            end
            INT_HANDLER_STATE_WAIT_B4_CLR: begin
                spi_start_int <= 1'b0;
                if (int_delay_cnter <= 32'd100) begin // 间隔一定时间后再切换到下一个状态
                    int_delay_cnter <= int_delay_cnter + 32'd1;
                end else begin
                    int_delay_cnter <= 32'd0;

                    INT_HANDLER_STATE <= INT_HANDLER_STATE_CLR_IR;
                end
                // if (spi_data_ready) begin // spi 空闲, 判断寄存器数据查询状态, 并继续; idle 信号常态不变, 即信号维持时间长, 故不需要同步时钟域
                //     INT_HANDLER_STATE <= INT_HANDLER_STATE_CLR_IR;
                // end else begin
                //     spi_start_int <= 1'b0;

                //     INT_HANDLER_STATE <= INT_HANDLER_STATE_WAIT_B4_CLR;
                // end
            end
            INT_HANDLER_STATE_CLR_IR: begin
                // if (~spi_busy && spi_data_ready) begin // spi 空闲, 判断寄存器数据查询状态, 并继续; idle 信号常态不变, 即信号维持时间长, 故不需要同步时钟域
                if (~spi_busy) begin // spi 空闲, 判断寄存器数据查询状态, 并继续; idle 信号常态不变, 即信号维持时间长, 故不需要同步时钟域
                    spi_start_int <= 1'b1; // 清空中断寄存器
                    spi_wr_int <= 1'b1;
                    spi_data_in_int <= {
                            16'd65535 & W5100S_SOCKET_REG_S0_IR_ADDR,
                            8'd255    & spi_data_out[7:0]
                    }; // 写入数据

                    res_int_n <= 1'b0; // 拉低以产生 内部中断信号
                    res_int_reg <= {8'h00, spi_data_out[7:0]}; // 读出数据, 存入中断寄存器

                    INT_HANDLER_STATE <= INT_HANDLER_STATE_WAIT_POST2;
                end else begin
                    spi_start_int <= 1'b0;

                    INT_HANDLER_STATE <= INT_HANDLER_STATE_CLR_IR;
                end
            end
            INT_HANDLER_STATE_WAIT_POST1: begin
                spi_start_int <= 1'b0;

                if (int_delay_cnter <= 32'd100) begin // 间隔一定时间后再切换到下一个状态
                    int_delay_cnter <= int_delay_cnter + 32'd1;
                end else begin
                    int_delay_cnter <= 32'd0;

                    INT_HANDLER_STATE <= INT_HANDLER_STATE_WAIT_POST2;
                end
            end
            INT_HANDLER_STATE_WAIT_POST2: begin
                // if (~spi_busy && spi_data_ready) begin
                if (~spi_busy) begin
                    spi_lock_int <= 1'b0; // 解锁 spi 总线
                    res_int_n <= 1'b1; // 拉高 内部中断信号

                    INT_HANDLER_STATE <= INT_HANDLER_STATE_IDLE;
                end else begin
                    spi_start_int <= 1'b0;

                    INT_HANDLER_STATE <= INT_HANDLER_STATE_WAIT_POST2;
                end
            end

            default: begin
                INT_HANDLER_STATE <= INT_HANDLER_STATE_IDLE;
            end

        endcase
        
    end
end

/* W5100S 驱动主程序 状态机 */

localparam                STATE_IDLE_WAIT_INIT                                                          = 16'h01_00;

localparam                STATE_INIT                                                                    = 16'h02_00;
localparam                STATE_INIT_HARD_RESET                                                         = 16'h02_01;
localparam                STATE_INIT_HARD_RESET_WAIT                                                    = 16'h02_02;
localparam                STATE_INIT_SOFT_RESET                                                         = 16'h02_03;
localparam                STATE_INIT_SOFT_RESET_WAIT                                                    = 16'h02_04;
localparam                STATE_INIT_SETUP_COMMON_REGS                                                  = 16'h02_05;

localparam                STATE_IDLE_WAIT_SETUP                                                         = 16'h03_00;

localparam                STATE_TCP_SERVER_SETUP                                                        = 16'h04_00;
localparam                STATE_TCP_SERVER_SETUP_REG_S0_IR_CLR                                          = 16'h04_01;
localparam                STATE_TCP_SERVER_SETUP_REG_S0_MR                                              = 16'h04_02;
localparam                STATE_TCP_SERVER_SETUP_REG_S0_IMR                                             = 16'h04_03;
localparam                STATE_TCP_SERVER_SETUP_REG_S0_PORTR0                                          = 16'h04_04;
localparam                STATE_TCP_SERVER_SETUP_REG_S0_PORTR1                                          = 16'h04_05;
localparam                STATE_TCP_SERVER_SETUP_REG_S0_CR_CMD_OPEN                                     = 16'h04_06;
localparam                STATE_TCP_SERVER_SETUP_REG_S0_CR_CMD_OPEN_WAIT_CLR                            = 16'h04_07;
localparam                STATE_TCP_SERVER_SETUP_REG_S0_SR_STA_SOCK_INIT                                = 16'h04_08;
localparam                STATE_TCP_SERVER_SETUP_REG_S0_CR_CMD_LISTEN                                   = 16'h04_09;
localparam                STATE_TCP_SERVER_SETUP_REG_S0_CR_CMD_LISTEN_WAIT_CLR                          = 16'h04_0A;
localparam                STATE_TCP_SERVER_SETUP_REG_S0_SR_STA_SOCK_LISTEN                              = 16'h04_0B;

localparam                STATE_TCP_SERVER_STAND_BY                                                     = 16'h05_00;
localparam                STATE_TCP_SERVER_STAND_BY_WAIT_CONNECTION                                     = 16'h05_01;
localparam                STATE_TCP_SERVER_STAND_BY_CLR_INT_CON                                         = 16'h05_02;
localparam                STATE_TCP_SERVER_STAND_BY_CLR_INT_CON_WAIT                                    = 16'h05_03;

localparam                STATE_TCP_CONNECTION_ESTABLISHED                                              = 16'h06_00;

localparam                STATE_TCP_SERVER_RECEIVE_DATA                                                 = 16'h07_00;
localparam                STATE_TCP_SERVER_RECEIVE_DATA_INIT_REG_S0_RX_RD0                              = 16'h07_01;
localparam                STATE_TCP_SERVER_RECEIVE_DATA_INIT_REG_S0_RX_RD1                              = 16'h07_02;
localparam                STATE_TCP_SERVER_RECEIVE_DATA_INIT_REG_S0_RX_RSR0                             = 16'h07_03;
localparam                STATE_TCP_SERVER_RECEIVE_DATA_INIT_REG_S0_RX_RSR1                             = 16'h07_04;
localparam                STATE_TCP_SERVER_RECEIVE_DATA_PROC_VAR_OFFSET                                 = 16'h07_05;
localparam                STATE_TCP_SERVER_RECEIVE_DATA_PROC_MERGE_DATA                                 = 16'h07_06;
localparam                STATE_TCP_SERVER_RECEIVE_DATA_PROC_VAR_RECV_SIZE                              = 16'h07_07;
localparam                STATE_TCP_SERVER_RECEIVE_DATA_PROC_TRANSMIT                                   = 16'h07_08;
localparam                STATE_TCP_SERVER_RECEIVE_DATA_PROC_TRANSMIT_POST                              = 16'h07_09;
localparam                STATE_TCP_SERVER_RECEIVE_DATA_PROC_REG_S0_RX_RD0                              = 16'h07_0A;
localparam                STATE_TCP_SERVER_RECEIVE_DATA_PROC_REG_S0_RX_RD1                              = 16'h07_0B;
localparam                STATE_TCP_SERVER_RECEIVE_DATA_PROC_REG_S0_CR_CMD_RECV                         = 16'h07_0C;
localparam                STATE_TCP_SERVER_RECEIVE_DATA_PROC_REG_S0_CR_CMD_RECV_WAIT_CLR                = 16'h07_0D;
localparam                STATE_TCP_SERVER_RECEIVE_DATA_PROC_INT_CLR                                    = 16'h07_0E;
localparam                STATE_TCP_SERVER_RECEIVE_DATA_PROC_POST                                       = 16'h07_0F;

localparam                STATE_TCP_SERVER_SEND_DATA                                                    = 16'h08_00;
localparam                STATE_TCP_SERVER_SEND_DATA_INIT                                               = 16'h08_01;
localparam                STATE_TCP_SERVER_SEND_DATA_INIT_PREPARE_SEND_BUF_RD_PROC1                     = 16'h08_02;
localparam                STATE_TCP_SERVER_SEND_DATA_INIT_PREPARE_SEND_BUF_RD_PROC2                     = 16'h08_03;
localparam                STATE_TCP_SERVER_SEND_DATA_INIT_PREPARE_SEND_BUF_RD_PROC3                     = 16'h08_04;
localparam                STATE_TCP_SERVER_SEND_DATA_INIT_PREPARE_SEND_BUF_RD_PROC4                     = 16'h08_05;
localparam                STATE_TCP_SERVER_SEND_DATA_INIT_PREPARE_SEND_BUF_RD_PROC5                     = 16'h08_06;
localparam                STATE_TCP_SERVER_SEND_DATA_INIT_REG_S0_TX_WR0                                 = 16'h08_07;
localparam                STATE_TCP_SERVER_SEND_DATA_INIT_REG_S0_TX_WR1                                 = 16'h08_08;
localparam                STATE_TCP_SERVER_SEND_DATA_INIT_REG_S0_TX_FSR0                                = 16'h08_09;
localparam                STATE_TCP_SERVER_SEND_DATA_INIT_REG_S0_TX_FSR1                                = 16'h08_0A;
localparam                STATE_TCP_SERVER_SEND_DATA_PROC_VAR_OFFSET                                    = 16'h08_0B;
localparam                STATE_TCP_SERVER_SEND_DATA_PROC_SPLIT_DATA                                    = 16'h08_0C;
localparam                STATE_TCP_SERVER_SEND_DATA_PROC_TRANSMIT_PRE                                  = 16'h08_0D;
localparam                STATE_TCP_SERVER_SEND_DATA_PROC_TRANSMIT                                      = 16'h08_0E;
localparam                STATE_TCP_SERVER_SEND_DATA_PROC_TRANSMIT_POST                                 = 16'h08_0F;
localparam                STATE_TCP_SERVER_SEND_DATA_PROC_REG_S0_TX_WR0                                 = 16'h08_10;
localparam                STATE_TCP_SERVER_SEND_DATA_PROC_REG_S0_TX_WR1                                 = 16'h08_11;
localparam                STATE_TCP_SERVER_SEND_DATA_PROC_REG_S0_CR_CMD_SEND                            = 16'h08_12;
localparam                STATE_TCP_SERVER_SEND_DATA_PROC_REG_S0_CR_CMD_SEND_WAIT_CLR                   = 16'h08_13;
localparam                STATE_TCP_SERVER_SEND_DATA_PROC_INT_WAIT                                      = 16'h08_14;
localparam                STATE_TCP_SERVER_SEND_DATA_PROC_INT_CLR                                       = 16'h08_15;
localparam                STATE_TCP_SERVER_SEND_DATA_PROC_POST                                          = 16'h08_16;

localparam                STATE_TCP_SERVER_DISCONNECT                                                   = 16'h09_00;
localparam                STATE_TCP_SERVER_DISCONNECT_PASSIVE_INIT                                      = 16'h09_10;
localparam                STATE_TCP_SERVER_DISCONNECT_PASSIVE_INIT_REG_S0_CR_CMD_DISCON                 = 16'h09_11;
localparam                STATE_TCP_SERVER_DISCONNECT_PASSIVE_INIT_REG_S0_CR_CMD_DISCON_WAIT_CLR        = 16'h09_12;
localparam                STATE_TCP_SERVER_DISCONNECT_ACTIVE_INIT                                       = 16'h09_20;
localparam                STATE_TCP_SERVER_DISCONNECT_ACTIVE_INIT_REG_S0_CR_CMD_DISCON                  = 16'h09_21;
localparam                STATE_TCP_SERVER_DISCONNECT_ACTIVE_INIT_REG_S0_CR_CMD_DISCON_WAIT_CLR         = 16'h09_22;
localparam                STATE_TCP_SERVER_DISCONNECT_PROC                                              = 16'h09_30;
localparam                STATE_TCP_SERVER_DISCONNECT_PROC_WAIT_ACK                                     = 16'h09_31;
localparam                STATE_TCP_SERVER_DISCONNECT_PROC_CLR_INT_ALL                                  = 16'h09_32;
localparam                STATE_TCP_SERVER_DISCONNECT_PROC_CLR_INT_ALL_WAIT                             = 16'h09_33;

localparam                STATE_PRE                                                                     = 16'h00_00;
localparam                STATE_POST                                                                    = 16'h00_FF;

// (*noprune*) reg [15:0]    CORE_STATE                                                                    = STATE_INIT;     /*synthesis noprune*/
// (*noprune*) reg [15:0]    SUB_STATE                                                                     = STATE_PRE;      /*synthesis noprune*/
(*noprune*) reg  [15:0]   CORE_STATE                                                                    = STATE_IDLE_WAIT_INIT;     /*synthesis noprune*/
(*noprune*) reg  [15:0]   SUB_STATE                                                                     = STATE_PRE;                /*synthesis noprune*/
assign                    state                                                                         = CORE_STATE | SUB_STATE;

reg  [31:0] delay_cnter;

reg  [ 3:0] reg_data_chk_flag;
reg         var_txrx_break_flag;
reg  [15:0] reg_s0_tx_wr, reg_s0_tx_fsr, var_tx_wr_offset, var_tx_wr_addr, var_send_size, var_send_cnt;
reg  [15:0] reg_s0_rx_rd, reg_s0_rx_rsr, var_rx_rd_offset, var_rx_rd_addr, var_recv_size, var_recv_cnt;

reg         send_buf_rd_empty_d0;

reg             spi_start_sta, spi_wr_sta;
reg  [23:0]     spi_data_in_sta;

integer     j, k, l, m;
always @(posedge clk or posedge at_n_flag or negedge rst_n) begin
    if (!rst_n) begin
        // w5100s_rst_n <= 1'b0; // 拉低复位信号

        delay_cnter <= 32'd0;

        send_done <= 1'b0;
        send_buf_rd_clk <= 1'b0;
        send_buf_rd_en <= 1'b0;
        send_buf_rd_empty_d0 <= send_buf_rd_empty;
        recv_done <= 1'b0;
        recv_buf_wr_clk <= 1'b0;
        recv_buf_wr_en <= 1'b0;
        recv_buf_wr_addr <= 10'd0;
        recv_buf_wr_data <= 8'd0;

        reg_data_chk_flag <= 4'd0;
        var_txrx_break_flag <= 1'b0;

        reg_s0_tx_wr <= 16'd0; reg_s0_tx_fsr <= 16'd0; var_tx_wr_offset <= 16'd0; var_tx_wr_addr <= 16'd0; var_send_size <= 16'd0; var_send_cnt <= 16'd0; 
        reg_s0_rx_rd <= 16'd0; reg_s0_rx_rsr <= 16'd0; var_rx_rd_offset <= 16'd0; var_rx_rd_addr <= 16'd0; var_recv_size <= 16'd0; var_recv_cnt <= 16'd0; 
        
        int_mask_flag <= 1'b1; // 初始化完成前禁用中断

        CORE_STATE <= STATE_IDLE_WAIT_INIT;
        SUB_STATE <= STATE_PRE;

        i = 0; j = 0; k = 0; l = 0; m = 0;
    end else begin

        if (at_n_flag) begin // 接收到控制指令, 将在下一个时钟周期跳转至对应状态

            case (at_command)

                W5100S_CMD_INIT: begin
                    CORE_STATE <= STATE_INIT;
                    SUB_STATE <= STATE_PRE;
                end
                W5100S_CMD_RST_HARD: begin
                    CORE_STATE <= STATE_INIT_HARD_RESET;
                    SUB_STATE <= STATE_PRE;
                end
                W5100S_CMD_RST_SOFT: begin
                    CORE_STATE <= STATE_INIT_SOFT_RESET;
                    SUB_STATE <= STATE_PRE;
                end

                W5100S_CMD_TCP_SERVER_SETUP: begin
                    if (CORE_STATE == STATE_IDLE_WAIT_SETUP) begin // 只允许在空闲模式下切换至 TCP 服务器模式
                        CORE_STATE <= STATE_TCP_SERVER_SETUP;
                        SUB_STATE <= STATE_PRE;
                    end
                end

                W5100S_CMD_TCP_SERVER_SEND_DATA: begin
                    if (!send_en_n && CORE_STATE == STATE_TCP_CONNECTION_ESTABLISHED) begin // 只允许在 TCP 连接已建立状态下 发送数据
                        CORE_STATE <= STATE_TCP_SERVER_SEND_DATA;
                        SUB_STATE <= STATE_PRE;
                    end
                end

                default: begin
                    // left intentionally blank
                end

            endcase
            
        end else begin

            if (res_int_n_flag && (res_int_reg[7:0] & W5100S_SOCKET_REG_S0_IR_DATA_CHK_INT_DISCON)) begin // 高优先级中断处理

                CORE_STATE <= STATE_TCP_SERVER_DISCONNECT;
                SUB_STATE <= STATE_TCP_SERVER_DISCONNECT_PASSIVE_INIT;

            end else begin

                case (CORE_STATE)

                    STATE_IDLE_WAIT_INIT: begin // 空闲模式, 等待指令切换模式
                        // left intentionally blank
                    end

                    STATE_INIT: begin

                        case (SUB_STATE)

                            STATE_PRE: begin
                                w5100s_rst_n <= 1'b1; // 拉高复位信号

                                // SUB_STATE <= STATE_INIT_HARD_RESET; // HARD RESET ONLY
                                // SUB_STATE <= STATE_INIT_SOFT_RESET; // SOFT RESET ONLY
                                SUB_STATE <= STATE_INIT_SOFT_RESET_WAIT; // SKIP RESET
                            end

                            STATE_INIT_HARD_RESET: begin // W5100S 硬件复位
                                if (delay_cnter <= 32'd10000) begin // 延时, 保持一段时间 W5100S 的复位信号
                                    w5100s_rst_n <= 1'b0; // 拉低以复位 W5100S 芯片

                                    delay_cnter <= delay_cnter + 32'd1;
                                end else begin
                                    w5100s_rst_n <= 1'b1; // 拉高复位信号

                                    delay_cnter <= 32'd0;

                                    // SUB_STATE <= STATE_INIT_HARD_RESET_WAIT;
                                    SUB_STATE <= STATE_INIT_SOFT_RESET_WAIT;
                                end
                            end
                            STATE_INIT_HARD_RESET_WAIT: begin // 延时至少 Tsta, 保持一段时间后开始向 W5100S 寄存器写入数据
                                if (delay_cnter <= 32'd10000) begin
                                    delay_cnter <= delay_cnter + 32'd1;
                                end else begin
                                    delay_cnter <= 32'd0;

                                    SUB_STATE <= STATE_INIT_SOFT_RESET;
                                end
                            end
                            STATE_INIT_SOFT_RESET:begin // W5100S 软件复位, 用于清空寄存器
                                if (~spi_busy && ~spi_lock_int) begin // spi 空闲, 可进行下一次寄存器数据的写入
                                    spi_start_sta <= 1'b1;
                                    spi_wr_sta <= 1'b1;
                                    spi_data_in_sta <= {
                                            16'd65535 & W5100S_COMMON_REG_MR_ADDR,
                                            8'd255    & W5100S_COMMON_REG_MR_DATA_RST
                                    }; // 写入数据

                                    SUB_STATE <= STATE_INIT_SOFT_RESET_WAIT; // 跳至下一子状态
                                end else begin // spi 非空闲, 抬高片选信号
                                    spi_start_sta <= 1'b0;
                                end
                            end
                            STATE_INIT_SOFT_RESET_WAIT: begin // 延时至少 Tsta, 保持一段时间后开始向 W5100S 寄存器写入数据
                                if (delay_cnter <= 32'd10000) begin
                                    delay_cnter <= delay_cnter + 32'd1;
                                end else begin
                                    delay_cnter <= 32'd0;

                                    SUB_STATE <= STATE_INIT_SETUP_COMMON_REGS;
                                end
                            end
                            STATE_INIT_SETUP_COMMON_REGS: begin // 初始化 W5100S , 配置通用寄存器, 已完全验证 SPI 时序, 共计 25 个寄存器

                                if (j < w5100s_init_seq_regs_cnt) begin // 配置通用寄存器
                                    
                                    if (~spi_busy && ~spi_lock_int) begin // spi 空闲, 可进行下一次寄存器数据的写入
                                        spi_start_sta <= 1'b1;
                                        spi_wr_sta <= 1'b1;
                                        spi_data_in_sta <= {
                                                16'd65535 & w5100s_init_seq_regs_addr[j],
                                                8'd255    & w5100s_init_seq_regs_data[j]
                                        }; // 写入数据

                                        j = j + 1;
                                    end else begin // spi 非空闲, 抬高片选信号
                                        spi_start_sta <= 1'b0;
                                    end

                                end else begin
                                    spi_start_sta <= 1'b0;

                                    SUB_STATE <= STATE_POST;
                                end

                            end

                            STATE_POST: begin // 延时一段时间, 然后进入工作模式
                                if (delay_cnter <= 32'd10000) begin
                                    delay_cnter <= delay_cnter + 32'd1;
                                end else begin
                                    delay_cnter <= 32'd0;

                                    int_mask_flag <= 1'b0; // 使能中断处理

                                    CORE_STATE <= STATE_IDLE_WAIT_SETUP;
                                    SUB_STATE <= STATE_PRE;
                                end
                            end

                        endcase

                    end

                    STATE_IDLE_WAIT_SETUP: begin // 空闲模式, 等待指令切换模式
                        // left intentionally blank
                    end

                    STATE_TCP_SERVER_SETUP: begin // TCP 服务器 配置模式

                        case (SUB_STATE)

                            STATE_PRE: begin
                                SUB_STATE <= STATE_TCP_SERVER_SETUP_REG_S0_MR;
                                // SUB_STATE <= STATE_TCP_SERVER_SETUP_REG_S0_IR_CLR;
                            end

                            STATE_TCP_SERVER_SETUP_REG_S0_IR_CLR: begin
                                if (~spi_busy && ~spi_lock_int) begin // spi 空闲, 判断寄存器数据查询状态, 并继续; idle 信号常态不变, 即信号维持时间长, 故不需要同步时钟域
                                    spi_start_sta <= 1'b1;
                                    spi_wr_sta <= 1'b1;
                                    spi_data_in_sta <= {
                                            16'd65535 & W5100S_SOCKET_REG_S0_IR_ADDR,
                                            8'd255    & W5100S_SOCKET_REG_S0_IR_DATA_CHK_INT_ALL // 向 全部 中断位 写1 来清除所有中断
                                    }; // 写入数据

                                    SUB_STATE <= STATE_TCP_SERVER_SETUP_REG_S0_MR; // 跳至下一子状态
                                end else begin // spi 非空闲, 抬高片选信号
                                    spi_start_sta <= 1'b0;
                                end
                            end
                            STATE_TCP_SERVER_SETUP_REG_S0_MR: begin
                                if (~spi_busy && ~spi_lock_int) begin // spi 空闲, 可进行下一次寄存器数据的写入
                                    spi_start_sta <= 1'b1;
                                    spi_wr_sta <= 1'b1;
                                    spi_data_in_sta <= {
                                            16'd65535 & W5100S_SOCKET_REG_S0_MR_ADDR,
                                            8'd255    & W5100S_SOCKET_REG_S0_MR_DATA
                                    }; // 写入数据

                                    SUB_STATE <= STATE_TCP_SERVER_SETUP_REG_S0_IMR; // 跳至下一子状态
                                end else begin // spi 非空闲, 抬高片选信号
                                    spi_start_sta <= 1'b0;
                                end
                            end
                            STATE_TCP_SERVER_SETUP_REG_S0_IMR: begin
                                if (~spi_busy && ~spi_lock_int) begin // spi 空闲, 可进行下一次寄存器数据的写入
                                    spi_start_sta <= 1'b1;
                                    spi_wr_sta <= 1'b1;
                                    spi_data_in_sta <= {
                                            16'd65535 & W5100S_SOCKET_REG_S0_IMR_ADDR,
                                            8'd255    & W5100S_SOCKET_REG_S0_IMR_DATA
                                    }; // 写入数据

                                    SUB_STATE <= STATE_TCP_SERVER_SETUP_REG_S0_PORTR0; // 跳至下一子状态
                                end else begin // spi 非空闲, 抬高片选信号
                                    spi_start_sta <= 1'b0;
                                end
                            end
                            STATE_TCP_SERVER_SETUP_REG_S0_PORTR0: begin
                                if (~spi_busy && ~spi_lock_int) begin // spi 空闲, 可进行下一次寄存器数据的写入
                                    spi_start_sta <= 1'b1;
                                    spi_wr_sta <= 1'b1;
                                    spi_data_in_sta <= {
                                            16'd65535 & W5100S_SOCKET_REG_S0_PORTR0_ADDR,
                                            8'd255    & W5100S_SOCKET_REG_S0_PORTR0_DATA
                                    }; // 写入数据
                                    
                                    SUB_STATE <= STATE_TCP_SERVER_SETUP_REG_S0_PORTR1; // 跳至下一子状态
                                end else begin // spi 非空闲, 抬高片选信号
                                    spi_start_sta <= 1'b0;
                                end
                            end
                            STATE_TCP_SERVER_SETUP_REG_S0_PORTR1: begin
                                if (~spi_busy && ~spi_lock_int) begin // spi 空闲, 可进行下一次寄存器数据的写入
                                    spi_start_sta <= 1'b1;
                                    spi_wr_sta <= 1'b1;
                                    spi_data_in_sta <= {
                                            16'd65535 & W5100S_SOCKET_REG_S0_PORTR1_ADDR,
                                            8'd255    & W5100S_SOCKET_REG_S0_PORTR1_DATA
                                    }; // 写入数据
                                    
                                    SUB_STATE <= STATE_TCP_SERVER_SETUP_REG_S0_CR_CMD_OPEN; // 跳至下一子状态
                                end else begin // spi 非空闲, 抬高片选信号
                                    spi_start_sta <= 1'b0;
                                end
                            end
                            STATE_TCP_SERVER_SETUP_REG_S0_CR_CMD_OPEN: begin
                                if (~spi_busy && ~spi_lock_int) begin // spi 空闲, 可进行下一次寄存器数据的写入
                                    spi_start_sta <= 1'b1;
                                    spi_wr_sta <= 1'b1;
                                    spi_data_in_sta <= {
                                            16'd65535 & W5100S_SOCKET_REG_S0_CR_ADDR,
                                            8'd255    & W5100S_SOCKET_REG_S0_CR_DATA_CMD_OPEN // Command: OPEN
                                    }; // 写入数据
                                    
                                    // reg_data_chk_flag <= 4'd0; //////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////// 删除后无法正常连接

                                    SUB_STATE <= STATE_TCP_SERVER_SETUP_REG_S0_CR_CMD_OPEN_WAIT_CLR; // 跳至下一子状态
                                end else begin // spi 非空闲, 抬高片选信号
                                    spi_start_sta <= 1'b0;
                                end
                            end
                            STATE_TCP_SERVER_SETUP_REG_S0_CR_CMD_OPEN_WAIT_CLR: begin ////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
                                if (~spi_busy && ~spi_lock_int) begin // spi 空闲, 判断寄存器数据查询状态, 并继续; idle 信号常态不变, 即信号维持时间长, 故不需要同步时钟域
                                    if (reg_data_chk_flag == 4'd0) begin // 尚未进行寄存器读取的操作; 此时 spi 空闲, 可进行一次寄存器数据的读取
                                        spi_start_sta <= 1'b1;
                                        spi_wr_sta <= 1'b0;
                                        spi_data_in_sta <= {
                                                16'd65535 & W5100S_SOCKET_REG_S0_CR_ADDR,
                                                // 16'd65535 & W5100S_COMMON_REG_IMR_ADDR, //////////////////////////////////////////////////////////////////////////////////////////////////////////// 验证数据是否正确读取 (已验证出现问题: 可以正常发送读取指令但无法正确接收; 更新: 问题接近已解决)
                                                8'd255    & 8'h0 // 读取寄存器时数据段为任意即可, 此处 8bit 全0
                                        }; // 读出数据
                                        
                                        reg_data_chk_flag <= 4'd1; // 表示 已发送 查询寄存器值命令 的标志位
                                    end else begin // 已进行寄存器读取的操作
                                        if (spi_data_ready) begin
                                            reg_data_chk_flag <= 4'd0;

                                            // if (spi_data_out[7:0] == W5100S_COMMON_REG_IMR_DATA) begin // S0_CR 寄存器已 clear, 可跳至下一状态 ////////////////////////////////////////////////////////////////// 用于验证数据是否正确读取
                                            if (spi_data_out[7:0] == W5100S_SOCKET_REG_S0_CR_DATA_CLR) begin // S0_CR 寄存器已 clear, 可跳至下一状态
                                                SUB_STATE <= STATE_TCP_SERVER_SETUP_REG_S0_SR_STA_SOCK_INIT; // 跳至下一子状态
                                            end else begin // S0_CR 寄存器尚未 clear, 需再次进行读取操作, 直至寄存器 clear
                                                // left intentionally blank
                                            end
                                        end
                                    end
                                end else begin // spi 非空闲, 抬高片选信号
                                    spi_start_sta <= 1'b0;
                                end
                            end
                            STATE_TCP_SERVER_SETUP_REG_S0_SR_STA_SOCK_INIT: begin // 状态检查 (SOCK_INIT)
                                if (~spi_busy && ~spi_lock_int) begin // spi 空闲, 判断寄存器数据查询状态, 并继续; idle 信号常态不变, 即信号维持时间长, 故不需要同步时钟域
                                    if (reg_data_chk_flag == 4'd0) begin // 尚未进行寄存器读取的操作; 此时 spi 空闲, 可进行一次寄存器数据的读取
                                        spi_start_sta <= 1'b1;
                                        spi_wr_sta <= 1'b0;
                                        spi_data_in_sta <= {
                                                16'd65535 & W5100S_SOCKET_REG_S0_SR_ADDR,
                                                8'd255    & 8'h0 // 读取寄存器时数据段为任意即可, 此处 8bit 全0
                                        }; // 读出数据
                                        
                                        reg_data_chk_flag <= 4'd1; // 表示 已发送 查询寄存器值命令 的标志位
                                    end else begin // 已进行寄存器读取的操作
                                        if (spi_data_ready) begin
                                            reg_data_chk_flag <= 4'd0;

                                            if (spi_data_out[7:0] == W5100S_SOCKET_REG_S0_SR_DATA_CHK_SOCK_INIT || spi_data_out[7:0] == W5100S_SOCKET_REG_S0_SR_DATA_CHK_SOCK_ESTABLISHED) begin // S0_SR 寄存器通过检查状态(INIT/ESTABLISHED), 可跳至下一状态
                                                SUB_STATE <= STATE_TCP_SERVER_SETUP_REG_S0_CR_CMD_LISTEN; // 跳至下一子状态
                                            end else begin // S0_CR 寄存器尚未 clear, 需再次进行读取操作, 直至寄存器 clear
                                                // left intentionally blank
                                            end
                                        end
                                    end
                                end else begin // spi 非空闲, 抬高片选信号
                                    spi_start_sta <= 1'b0;
                                end
                            end
                            STATE_TCP_SERVER_SETUP_REG_S0_CR_CMD_LISTEN: begin
                                if (~spi_busy && ~spi_lock_int) begin // spi 空闲, 可进行下一次寄存器数据的写入
                                    spi_start_sta <= 1'b1;
                                    spi_wr_sta <= 1'b1;
                                    spi_data_in_sta <= {
                                            16'd65535 & W5100S_SOCKET_REG_S0_CR_ADDR,
                                            8'd255    & W5100S_SOCKET_REG_S0_CR_DATA_CMD_LISTEN // Command: LISTEN
                                    }; // 写入数据
                                    
                                    SUB_STATE <= STATE_TCP_SERVER_SETUP_REG_S0_CR_CMD_LISTEN_WAIT_CLR; // 跳至下一子状态
                                end else begin // spi 非空闲, 抬高片选信号
                                    spi_start_sta <= 1'b0;
                                end
                            end
                            STATE_TCP_SERVER_SETUP_REG_S0_CR_CMD_LISTEN_WAIT_CLR: begin
                                if (~spi_busy && ~spi_lock_int) begin // spi 空闲, 判断寄存器数据查询状态, 并继续; idle 信号常态不变, 即信号维持时间长, 故不需要同步时钟域
                                    if (reg_data_chk_flag == 4'd0) begin // 尚未进行寄存器读取的操作; 此时 spi 空闲, 可进行一次寄存器数据的读取
                                        spi_start_sta <= 1'b1;
                                        spi_wr_sta <= 1'b0;
                                        spi_data_in_sta <= {
                                                16'd65535 & W5100S_SOCKET_REG_S0_CR_ADDR,
                                                8'd255    & 8'h0 // 读取寄存器时数据段为任意即可, 此处 8bit 全0
                                        }; // 读出数据
                                        
                                        reg_data_chk_flag <= 4'd1; // 表示 已发送 查询寄存器值命令 的标志位
                                    end else begin // 已进行寄存器读取的操作
                                        if (spi_data_ready) begin
                                            reg_data_chk_flag <= 4'd0;

                                            if (spi_data_out[7:0] == W5100S_SOCKET_REG_S0_CR_DATA_CLR) begin // S0_CR 寄存器已 clear, 可跳至下一状态
                                                SUB_STATE <= STATE_TCP_SERVER_SETUP_REG_S0_SR_STA_SOCK_LISTEN; // 跳至下一子状态
                                            end else begin // S0_CR 寄存器尚未 clear, 需再次进行读取操作, 直至寄存器 clear
                                                // left intentionally blank
                                            end
                                        end
                                    end
                                end else begin // spi 非空闲, 抬高片选信号
                                    spi_start_sta <= 1'b0;
                                end
                            end
                            STATE_TCP_SERVER_SETUP_REG_S0_SR_STA_SOCK_LISTEN: begin // 状态检查 (SOCK_LISTEN)
                                if (~spi_busy && ~spi_lock_int) begin // spi 空闲, 判断寄存器数据查询状态, 并继续; idle 信号常态不变, 即信号维持时间长, 故不需要同步时钟域
                                    if (reg_data_chk_flag == 4'd0) begin // 尚未进行寄存器读取的操作; 此时 spi 空闲, 可进行一次寄存器数据的读取
                                        spi_start_sta <= 1'b1;
                                        spi_wr_sta <= 1'b0;
                                        spi_data_in_sta <= {
                                                16'd65535 & W5100S_SOCKET_REG_S0_SR_ADDR,
                                                8'd255    & 8'h0 // 读取寄存器时数据段为任意即可, 此处 8bit 全0
                                        }; // 读出数据
                                        
                                        reg_data_chk_flag <= 4'd1; // 表示 已发送 查询寄存器值命令 的标志位
                                    end else begin // 已进行寄存器读取的操作
                                        if (spi_data_ready) begin
                                            reg_data_chk_flag <= 4'd0;
                                            
                                            if (spi_data_out[7:0] == W5100S_SOCKET_REG_S0_SR_DATA_CHK_SOCK_LISTEN) begin // S0_SR 寄存器通过检查状态(LISTEN), 可跳至下一状态
                                                SUB_STATE <= STATE_POST; // 跳至下一子状态
                                            end else begin // S0_CR 寄存器尚未 clear, 需再次进行读取操作, 直至寄存器 clear
                                                // left intentionally blank
                                            end
                                        end
                                    end
                                end else begin // spi 非空闲, 抬高片选信号
                                    spi_start_sta <= 1'b0;
                                end
                            end

                            STATE_POST: begin
                                CORE_STATE <= STATE_TCP_SERVER_STAND_BY;
                                SUB_STATE <= STATE_PRE;
                            end

                            default: begin
                                SUB_STATE <= STATE_PRE;
                            end
                        endcase

                    end

                    STATE_TCP_SERVER_STAND_BY: begin

                        case (SUB_STATE)

                            STATE_PRE: begin
                                SUB_STATE <= STATE_TCP_SERVER_STAND_BY_WAIT_CONNECTION;
                            end

                            STATE_TCP_SERVER_STAND_BY_WAIT_CONNECTION: begin // 等待客户端连接
                                if (res_int_n_flag) begin // 接收到中断信号, 查询中断寄存器 连接成功对应位 (CON) 是否为 1
                                        
                                    if (res_int_reg[7:0] & W5100S_SOCKET_REG_S0_IR_DATA_CHK_INT_CON) begin // 存在连接中断 CON, 可跳至下一状态
                                        // SUB_STATE <= STATE_TCP_SERVER_STAND_BY_CLR_INT_CON; // 跳至下一子状态
                                        SUB_STATE <= STATE_POST; // 跳至下一子状态
                                    end else begin // 不存在连接中断 CON, 需再次进行读取操作
                                        // left intentionally blank
                                    end

                                end
                            end
                            STATE_TCP_SERVER_STAND_BY_CLR_INT_CON: begin
                                if (~spi_busy && ~spi_lock_int) begin // spi 空闲, 可进行下一次寄存器数据的写入
                                    spi_start_sta <= 1'b1;
                                    spi_wr_sta <= 1'b1;
                                    spi_data_in_sta <= {
                                            16'd65535 & W5100S_SOCKET_REG_S0_IR_ADDR,
                                            8'd255    & W5100S_SOCKET_REG_S0_IR_DATA_CHK_INT_CON // 向对应位 写1 来清除中断
                                    }; // 写入数据

                                    delay_cnter <= 32'd0;

                                    SUB_STATE <= STATE_TCP_SERVER_STAND_BY_CLR_INT_CON_WAIT; // 跳至下一子状态
                                end else begin // spi 非空闲, 抬高片选信号
                                    spi_start_sta <= 1'b0;
                                end
                            end
                            STATE_TCP_SERVER_STAND_BY_CLR_INT_CON_WAIT: begin
                                if (delay_cnter <= 32'd100) begin // 间隔一定时间后再切换到下一个状态
                                    delay_cnter <= delay_cnter + 32'd1;
                                end else begin
                                    if (~spi_busy && ~spi_lock_int) begin // spi 空闲, 可跳到下一状态
                                        delay_cnter <= 32'd0;

                                        SUB_STATE <= STATE_POST;
                                    end else begin // spi 非空闲, 抬高片选信号
                                        spi_start_sta <= 1'b0;
                                    end
                                end
                            end

                            STATE_POST: begin
                                CORE_STATE <= STATE_TCP_CONNECTION_ESTABLISHED; ///////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
                                // CORE_STATE <= STATE_TCP_SERVER_SEND_DATA;
                                SUB_STATE <= STATE_PRE;
                            end
                            
                            default: begin
                                SUB_STATE <= STATE_PRE;
                            end

                        endcase

                    end

                    STATE_TCP_CONNECTION_ESTABLISHED: begin

                        if (res_int_n_flag) begin // 接收到中断信号, 查询中断寄存器 断开连接对应位 (DISCON) 是否为 1

                            // 下面根据优先级处理中断, 注意中断优先级顺序!
                            if (res_int_reg[7:0] & W5100S_SOCKET_REG_S0_IR_DATA_CHK_INT_DISCON) begin // 存在 断开连接中断 DISCON
                                
                                CORE_STATE <= STATE_TCP_SERVER_DISCONNECT; // 跳至 被动断开连接初始序列 状态
                                SUB_STATE <= STATE_TCP_SERVER_DISCONNECT_PASSIVE_INIT;

                            end else if (res_int_reg[7:0] & W5100S_SOCKET_REG_S0_IR_DATA_CHK_INT_RECV) begin // 存在 接收中断 RECV
                                
                                CORE_STATE <= STATE_TCP_SERVER_RECEIVE_DATA; // 跳至 接收数据 状态
                                SUB_STATE <= STATE_PRE;

                            end else begin // 不存在 目的中断, 重新等待中断信号
                                // left intentionally blank
                            end
                        end

                    end

                    STATE_TCP_SERVER_SEND_DATA: begin

                        case (SUB_STATE)

                            STATE_PRE: begin
                                SUB_STATE <= STATE_TCP_SERVER_SEND_DATA_INIT;
                            end

                            STATE_TCP_SERVER_SEND_DATA_INIT: begin
                                send_done <= 1'b0; // 复位发送完成信号

                                if (!send_en_n) begin // 使能发送时才允许进入数据发送状态
                                    SUB_STATE <= STATE_TCP_SERVER_SEND_DATA_INIT_PREPARE_SEND_BUF_RD_PROC1;
                                end else begin
                                    SUB_STATE <= STATE_POST;
                                end
                            end

                            STATE_TCP_SERVER_SEND_DATA_INIT_PREPARE_SEND_BUF_RD_PROC1: begin
                                send_buf_rd_en <= 1'b1; // 开启 FIFO 读请求

                                SUB_STATE <= STATE_TCP_SERVER_SEND_DATA_INIT_PREPARE_SEND_BUF_RD_PROC2;
                            end
                            STATE_TCP_SERVER_SEND_DATA_INIT_PREPARE_SEND_BUF_RD_PROC2: begin
                                send_buf_rd_clk <= 1'b1; // 提前读 FIFO, 防止读空信号无法复位

                                SUB_STATE <= STATE_TCP_SERVER_SEND_DATA_INIT_PREPARE_SEND_BUF_RD_PROC3;
                            end
                            STATE_TCP_SERVER_SEND_DATA_INIT_PREPARE_SEND_BUF_RD_PROC3: begin
                                send_buf_rd_clk <= 1'b0; // 复位 读时钟

                                SUB_STATE <= STATE_TCP_SERVER_SEND_DATA_INIT_PREPARE_SEND_BUF_RD_PROC4;
                            end
                            STATE_TCP_SERVER_SEND_DATA_INIT_PREPARE_SEND_BUF_RD_PROC4: begin
                                send_buf_rd_clk <= 1'b1; // 提前读 FIFO, 准备好待传数据

                                SUB_STATE <= STATE_TCP_SERVER_SEND_DATA_INIT_PREPARE_SEND_BUF_RD_PROC5;
                            end
                            STATE_TCP_SERVER_SEND_DATA_INIT_PREPARE_SEND_BUF_RD_PROC5: begin
                                send_buf_rd_clk <= 1'b0; // 复位 读时钟

                                SUB_STATE <= STATE_TCP_SERVER_SEND_DATA_INIT_REG_S0_TX_WR0;
                            end

                            STATE_TCP_SERVER_SEND_DATA_INIT_REG_S0_TX_WR0: begin
                                if (~spi_busy && ~spi_lock_int) begin // spi 空闲, 判断寄存器数据查询状态, 并继续; idle 信号常态不变, 即信号维持时间长, 故不需要同步时钟域
                                    if (reg_data_chk_flag == 4'd0) begin // 尚未进行寄存器读取的操作; 此时 spi 空闲, 可进行一次寄存器数据的读取
                                        spi_start_sta <= 1'b1;
                                        spi_wr_sta <= 1'b0;
                                        spi_data_in_sta <= {
                                                16'd65535 & W5100S_SOCKET_REG_S0_TX_WR0_ADDR,
                                                8'd255    & 8'h0 // 读取寄存器时数据段为任意即可, 此处 8bit 全0
                                        }; // 读出数据
                                        
                                        reg_data_chk_flag <= 4'd1; // 表示 已发送 查询寄存器值命令 的标志位
                                    end else begin // 已进行寄存器读取的操作
                                        if (spi_data_ready) begin
                                            reg_data_chk_flag <= 4'd0;

                                            reg_s0_tx_wr[15:8] <= spi_data_out[7:0];

                                            SUB_STATE <= STATE_TCP_SERVER_SEND_DATA_INIT_REG_S0_TX_WR1; // 跳至下一子状态
                                        end
                                    end
                                end else begin // spi 非空闲, 抬高片选信号
                                    spi_start_sta <= 1'b0;
                                end
                            end
                            STATE_TCP_SERVER_SEND_DATA_INIT_REG_S0_TX_WR1: begin
                                if (~spi_busy && ~spi_lock_int) begin // spi 空闲, 判断寄存器数据查询状态, 并继续; idle 信号常态不变, 即信号维持时间长, 故不需要同步时钟域
                                    if (reg_data_chk_flag == 4'd0) begin // 尚未进行寄存器读取的操作; 此时 spi 空闲, 可进行一次寄存器数据的读取
                                        spi_start_sta <= 1'b1;
                                        spi_wr_sta <= 1'b0;
                                        spi_data_in_sta <= {
                                                16'd65535 & W5100S_SOCKET_REG_S0_TX_WR1_ADDR,
                                                8'd255    & 8'h0 // 读取寄存器时数据段为任意即可, 此处 8bit 全0
                                        }; // 读出数据
                                        
                                        reg_data_chk_flag <= 4'd1; // 表示 已发送 查询寄存器值命令 的标志位
                                    end else begin // 已进行寄存器读取的操作
                                        if (spi_data_ready) begin
                                            reg_data_chk_flag <= 4'd0;

                                            reg_s0_tx_wr[7:0] <= spi_data_out[7:0];

                                            SUB_STATE <= STATE_TCP_SERVER_SEND_DATA_INIT_REG_S0_TX_FSR0; // 跳至下一子状态
                                        end
                                    end
                                end else begin // spi 非空闲, 抬高片选信号
                                    spi_start_sta <= 1'b0;
                                end
                            end
                            STATE_TCP_SERVER_SEND_DATA_INIT_REG_S0_TX_FSR0: begin
                                if (~spi_busy && ~spi_lock_int) begin // spi 空闲, 判断寄存器数据查询状态, 并继续; idle 信号常态不变, 即信号维持时间长, 故不需要同步时钟域
                                    if (reg_data_chk_flag == 4'd0) begin // 尚未进行寄存器读取的操作; 此时 spi 空闲, 可进行一次寄存器数据的读取
                                        spi_start_sta <= 1'b1;
                                        spi_wr_sta <= 1'b0;
                                        spi_data_in_sta <= {
                                                16'd65535 & W5100S_SOCKET_REG_S0_TX_FSR0_ADDR,
                                                8'd255    & 8'h0 // 读取寄存器时数据段为任意即可, 此处 8bit 全0
                                        }; // 读出数据
                                        
                                        reg_data_chk_flag <= 4'd1; // 表示 已发送 查询寄存器值命令 的标志位
                                    end else begin // 已进行寄存器读取的操作
                                        if (spi_data_ready) begin
                                            reg_data_chk_flag <= 4'd0;

                                            reg_s0_tx_fsr[15:8] <= spi_data_out[7:0];

                                            SUB_STATE <= STATE_TCP_SERVER_SEND_DATA_INIT_REG_S0_TX_FSR1; // 跳至下一子状态
                                        end
                                    end
                                end else begin // spi 非空闲, 抬高片选信号
                                    spi_start_sta <= 1'b0;
                                end
                            end
                            STATE_TCP_SERVER_SEND_DATA_INIT_REG_S0_TX_FSR1: begin
                                if (~spi_busy && ~spi_lock_int) begin // spi 空闲, 判断寄存器数据查询状态, 并继续; idle 信号常态不变, 即信号维持时间长, 故不需要同步时钟域
                                    if (reg_data_chk_flag == 4'd0) begin // 尚未进行寄存器读取的操作; 此时 spi 空闲, 可进行一次寄存器数据的读取
                                        spi_start_sta <= 1'b1;
                                        spi_wr_sta <= 1'b0;
                                        spi_data_in_sta <= {
                                                16'd65535 & W5100S_SOCKET_REG_S0_TX_FSR1_ADDR,
                                                8'd255    & 8'h0 // 读取寄存器时数据段为任意即可, 此处 8bit 全0
                                        }; // 读出数据
                                        
                                        reg_data_chk_flag <= 4'd1; // 表示 已发送 查询寄存器值命令 的标志位
                                    end else begin // 已进行寄存器读取的操作
                                        if (spi_data_ready) begin
                                            reg_data_chk_flag <= 4'd0;

                                            reg_s0_tx_fsr[7:0] <= spi_data_out[7:0];

                                            SUB_STATE <= STATE_TCP_SERVER_SEND_DATA_PROC_VAR_OFFSET; // 跳至下一子状态
                                        end
                                    end
                                end else begin // spi 非空闲, 抬高片选信号
                                    spi_start_sta <= 1'b0;
                                end
                            end

                            STATE_TCP_SERVER_SEND_DATA_PROC_VAR_OFFSET: begin
                                var_tx_wr_offset <= reg_s0_tx_wr & W5100S_SOCKET_VAR_S0_TX_MASK;
                                var_txrx_break_flag <= 1'b0; // 提前复位标志位

                                SUB_STATE <= STATE_TCP_SERVER_SEND_DATA_PROC_SPLIT_DATA;
                            end
                            STATE_TCP_SERVER_SEND_DATA_PROC_SPLIT_DATA: begin
                                var_tx_wr_addr <= W5100S_SOCKET_VAR_S0_TX_BASE_ADDR + var_tx_wr_offset;
                                var_send_cnt <= 16'd0;

                                if (var_tx_wr_offset + var_send_size > W5100S_SOCKET_VAR_MAX_TX_BUF_SIZE) begin // 发送段越 循环缓冲区 边界了, 先切割后发送; 第一段先发送 upper 部分
                                    var_tx_wr_addr <= W5100S_SOCKET_VAR_S0_TX_BASE_ADDR + var_tx_wr_offset;
                                    var_send_size <= W5100S_SOCKET_VAR_MAX_TX_BUF_SIZE - var_tx_wr_offset;

                                    var_txrx_break_flag <= 1'b1;
                                end else begin
                                    var_tx_wr_addr <= W5100S_SOCKET_VAR_S0_TX_BASE_ADDR + var_tx_wr_offset;
                                    // var_send_size <= W5100S_SOCKET_VAR_SEND_SIZE; //////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
                                    var_send_size <= send_size; //////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
                                end

                                SUB_STATE <= STATE_TCP_SERVER_SEND_DATA_PROC_TRANSMIT_PRE;
                            end
                            STATE_TCP_SERVER_SEND_DATA_PROC_TRANSMIT_PRE: begin                                
                                send_buf_rd_en <= 1'b1; // 开启 FIFO 读请求需要提前一个时钟周期, 以便于在下一个状态中进行数据的读取

                                SUB_STATE <= STATE_TCP_SERVER_SEND_DATA_PROC_TRANSMIT;
                            end
                            STATE_TCP_SERVER_SEND_DATA_PROC_TRANSMIT: begin

                                if ((var_send_cnt < var_send_size) && !(send_buf_rd_empty && send_buf_rd_empty_d0)) begin // 循环此状态来发送所有数据
                                // if (var_send_cnt < var_send_size) begin // 循环此状态来发送所有数据

                                    if (~spi_busy && ~spi_lock_int) begin // spi 空闲, 可进行下一个字的缓冲区数据的写入
                                        spi_start_sta <= 1'b1; // 写入
                                        spi_wr_sta <= 1'b1;
                                        spi_data_in_sta <= {
                                                16'd65535 & var_tx_wr_addr,
                                                8'd255    & send_buf_rd_data[7:0] // 从 FIFO 取出数据
                                        }; // 写入数据

                                        var_tx_wr_addr <= var_tx_wr_addr + 16'd1; // 下一个字节地址
                                        var_send_cnt <= var_send_cnt + 16'd1;

                                        send_buf_rd_empty_d0 <= send_buf_rd_empty; // 延迟写空信号一个时钟周期, 用于准确判断发送缓冲区是否为空
                                        send_buf_rd_clk <= 1'b1; // FIFO 读请求
                                    end else begin // spi 非空闲, 抬高片选信号
                                        spi_start_sta <= 1'b0;

                                        send_buf_rd_clk <= 1'b0;
                                    end
                                end else begin // 发送完成, 转移至下一个状态
                                    // reg_s0_tx_wr <= reg_s0_tx_wr + var_send_size; // 更新 发送缓冲区写指针
                                    reg_s0_tx_wr <= reg_s0_tx_wr + var_send_cnt; // 更新 发送缓冲区写指针, 按实际发送量来更新写指针寄存器, 以保证当 发送 FIFO 读空时, 不会发送多余数据

                                    var_send_cnt <= 16'd0;

                                    if (var_txrx_break_flag) begin // 发送数据段 为 切割数据段, 应继续当前状态继续完成下半段发送
                                        var_tx_wr_addr <= W5100S_SOCKET_VAR_S0_TX_BASE_ADDR;
                                        var_send_size <= var_send_size - (W5100S_SOCKET_VAR_MAX_TX_BUF_SIZE - var_tx_wr_offset);

                                        var_txrx_break_flag <= 1'b0;
                                    end else begin
                                        SUB_STATE <= STATE_TCP_SERVER_SEND_DATA_PROC_TRANSMIT_POST;
                                    end

                                    send_buf_rd_clk <= 1'b0;
                                    send_buf_rd_en <= 1'b0; // 关闭 FIFO 读请求
                                end

                            end
                            STATE_TCP_SERVER_SEND_DATA_PROC_TRANSMIT_POST: begin

                                SUB_STATE <= STATE_TCP_SERVER_SEND_DATA_PROC_REG_S0_TX_WR0;
                            end
                            STATE_TCP_SERVER_SEND_DATA_PROC_REG_S0_TX_WR0: begin
                                if (~spi_busy && ~spi_lock_int) begin // spi 空闲, 判断寄存器数据查询状态, 并继续; idle 信号常态不变, 即信号维持时间长, 故不需要同步时钟域
                                    spi_start_sta <= 1'b1;
                                    spi_wr_sta <= 1'b1;
                                    spi_data_in_sta <= {
                                            16'd65535 & W5100S_SOCKET_REG_S0_TX_WR0_ADDR,
                                            8'd255    & reg_s0_tx_wr[15:8] // 写入数据
                                    }; // 写入数据

                                    SUB_STATE <= STATE_TCP_SERVER_SEND_DATA_PROC_REG_S0_TX_WR1; // 跳至下一子状态
                                end else begin // spi 非空闲, 抬高片选信号
                                    spi_start_sta <= 1'b0;
                                end
                            end
                            STATE_TCP_SERVER_SEND_DATA_PROC_REG_S0_TX_WR1: begin
                                if (~spi_busy && ~spi_lock_int) begin // spi 空闲, 判断寄存器数据查询状态, 并继续; idle 信号常态不变, 即信号维持时间长, 故不需要同步时钟域
                                    spi_start_sta <= 1'b1;
                                    spi_wr_sta <= 1'b1;
                                    spi_data_in_sta <= {
                                            16'd65535 & W5100S_SOCKET_REG_S0_TX_WR1_ADDR,
                                            8'd255    & reg_s0_tx_wr[7:0] // 写入数据
                                    }; // 写入数据

                                    SUB_STATE <= STATE_TCP_SERVER_SEND_DATA_PROC_REG_S0_CR_CMD_SEND; // 跳至下一子状态
                                end else begin // spi 非空闲, 抬高片选信号
                                    spi_start_sta <= 1'b0;
                                end
                            end
                            STATE_TCP_SERVER_SEND_DATA_PROC_REG_S0_CR_CMD_SEND: begin
                                if (~spi_busy && ~spi_lock_int) begin // spi 空闲, 可进行下一次寄存器数据的写入
                                    spi_start_sta <= 1'b1;
                                    spi_wr_sta <= 1'b1;
                                    spi_data_in_sta <= {
                                            16'd65535 & W5100S_SOCKET_REG_S0_CR_ADDR,
                                            8'd255    & W5100S_SOCKET_REG_S0_CR_DATA_CMD_SEND // Command: SEND
                                    }; // 写入数据
                                    
                                    // reg_data_chk_flag <= 4'd0;

                                    SUB_STATE <= STATE_TCP_SERVER_SEND_DATA_PROC_REG_S0_CR_CMD_SEND_WAIT_CLR; // 跳至下一子状态
                                end else begin // spi 非空闲, 抬高片选信号
                                    spi_start_sta <= 1'b0;
                                end
                            end
                            STATE_TCP_SERVER_SEND_DATA_PROC_REG_S0_CR_CMD_SEND_WAIT_CLR: begin
                                if (~spi_busy && ~spi_lock_int) begin // spi 空闲, 判断寄存器数据查询状态, 并继续; idle 信号常态不变, 即信号维持时间长, 故不需要同步时钟域
                                    if (reg_data_chk_flag == 4'd0) begin // 尚未进行寄存器读取的操作; 此时 spi 空闲, 可进行一次寄存器数据的读取
                                        spi_start_sta <= 1'b1;
                                        spi_wr_sta <= 1'b0;
                                        spi_data_in_sta <= {
                                                16'd65535 & W5100S_SOCKET_REG_S0_CR_ADDR,
                                                8'd255    & 8'h0 // 读取寄存器时数据段为任意即可, 此处 8bit 全0
                                        }; // 读出数据
                                        
                                        reg_data_chk_flag <= 4'd1; // 表示 已发送 查询寄存器值命令 的标志位
                                    end else begin // 已进行寄存器读取的操作
                                        if (spi_data_ready) begin
                                            reg_data_chk_flag <= 4'd0;

                                            if (spi_data_out[7:0] == W5100S_SOCKET_REG_S0_CR_DATA_CLR) begin // S0_CR 寄存器已 clear, 可跳至下一状态
                                                // int_chk_wait_flag <= 4'd0;
                                                SUB_STATE <= STATE_TCP_SERVER_SEND_DATA_PROC_INT_WAIT; // 跳至下一子状态
                                                // SUB_STATE <= STATE_TCP_SERVER_SEND_DATA_PROC_INT_CLR; // 跳至下一子状态
                                            end else begin // S0_CR 寄存器尚未 clear, 需再次进行读取操作, 直至寄存器 clear
                                                // left intentionally blank
                                            end
                                        end
                                    end
                                end else begin // spi 非空闲, 抬高片选信号
                                    spi_start_sta <= 1'b0;
                                end
                            end
                            STATE_TCP_SERVER_SEND_DATA_PROC_INT_WAIT: begin
                                if (res_int_n_flag) begin // 接收到中断信号, 查询中断寄存器 发送成功对应位 (SENDOK) 或 超时中断 (TIMEOUT) 是否为 1

                                    if (res_int_reg[7:0] & W5100S_SOCKET_REG_S0_IR_DATA_CHK_INT_SENDOK ||
                                        res_int_reg[7:0] & W5100S_SOCKET_REG_S0_IR_DATA_CHK_INT_TIMEOUT) begin // 存在发送成功中断 SENDOK 或超时中断 TIMEOUT, 可跳至下一状态
                                        // SUB_STATE <= STATE_TCP_SERVER_SEND_DATA_PROC_INT_CLR; // 跳至下一子状态
                                        SUB_STATE <= STATE_TCP_SERVER_SEND_DATA_PROC_POST; // 跳至下一子状态
                                    end else begin // 不存在中断, 需再次进行读取操作
                                        // left intentionally blank
                                    end

                                end
                            end
                            STATE_TCP_SERVER_SEND_DATA_PROC_INT_CLR: begin
                                if (~spi_busy && ~spi_lock_int) begin // spi 空闲, 判断寄存器数据查询状态, 并继续; idle 信号常态不变, 即信号维持时间长, 故不需要同步时钟域
                                    spi_start_sta <= 1'b1;
                                    spi_wr_sta <= 1'b1;
                                    spi_data_in_sta <= {
                                            16'd65535 & W5100S_SOCKET_REG_S0_IR_ADDR,
                                            8'd255    & (W5100S_SOCKET_REG_S0_IR_DATA_CHK_INT_SENDOK | W5100S_SOCKET_REG_S0_IR_DATA_CHK_INT_TIMEOUT) // 向 SENDOK|TIMEOUT 中断位 写1 来清除两个中断
                                    }; // 写入数据

                                    SUB_STATE <= STATE_TCP_SERVER_SEND_DATA_PROC_POST; // 跳至下一子状态
                                end else begin // spi 非空闲, 抬高片选信号
                                    spi_start_sta <= 1'b0;
                                end
                            end
                            STATE_TCP_SERVER_SEND_DATA_PROC_POST: begin
                                if (send_buf_rd_empty) begin
                                    send_done <= 1'b1; // 发送完成信号

                                    SUB_STATE <= STATE_POST; // 跳至下一子状态
                                end else begin
                                    SUB_STATE <= STATE_TCP_SERVER_SEND_DATA_INIT_REG_S0_TX_WR0; // 继续数据发送
                                end
                            end

                            STATE_POST: begin
                                send_done <= 1'b0; // 复位 发送完成信号

                                CORE_STATE <= STATE_TCP_CONNECTION_ESTABLISHED;
                                SUB_STATE <= STATE_PRE;
                            end

                            default: begin
                                SUB_STATE <= STATE_PRE;
                            end

                        endcase

                    end

                    STATE_TCP_SERVER_RECEIVE_DATA: begin

                        case (SUB_STATE)

                            STATE_PRE: begin
                                recv_done <= 1'b0; // 复位接收完成信号

                                SUB_STATE <= STATE_TCP_SERVER_RECEIVE_DATA_INIT_REG_S0_RX_RD0;
                            end

                            STATE_TCP_SERVER_RECEIVE_DATA_INIT_REG_S0_RX_RD0: begin
                                if (~spi_busy && ~spi_lock_int) begin // spi 空闲, 判断寄存器数据查询状态, 并继续; idle 信号常态不变, 即信号维持时间长, 故不需要同步时钟域
                                    if (reg_data_chk_flag == 4'd0) begin // 尚未进行寄存器读取的操作; 此时 spi 空闲, 可进行一次寄存器数据的读取
                                        spi_start_sta <= 1'b1;
                                        spi_wr_sta <= 1'b0;
                                        spi_data_in_sta <= {
                                                16'd65535 & W5100S_SOCKET_REG_S0_RX_RD0_ADDR,
                                                8'd255    & 8'h0 // 读取寄存器时数据段为任意即可, 此处 8bit 全0
                                        }; // 读出数据
                                        
                                        reg_data_chk_flag <= 4'd1; // 表示 已发送 查询寄存器值命令 的标志位
                                    end else begin // 已进行寄存器读取的操作
                                        if (spi_data_ready) begin
                                            reg_data_chk_flag <= 4'd0;

                                            reg_s0_rx_rd[15:8] <= spi_data_out[7:0];

                                            SUB_STATE <= STATE_TCP_SERVER_RECEIVE_DATA_INIT_REG_S0_RX_RD1; // 跳至下一子状态
                                        end
                                    end
                                end else begin // spi 非空闲, 抬高片选信号
                                    spi_start_sta <= 1'b0;
                                end
                            end
                            STATE_TCP_SERVER_RECEIVE_DATA_INIT_REG_S0_RX_RD1: begin
                                if (~spi_busy && ~spi_lock_int) begin // spi 空闲, 判断寄存器数据查询状态, 并继续; idle 信号常态不变, 即信号维持时间长, 故不需要同步时钟域
                                    if (reg_data_chk_flag == 4'd0) begin // 尚未进行寄存器读取的操作; 此时 spi 空闲, 可进行一次寄存器数据的读取
                                        spi_start_sta <= 1'b1;
                                        spi_wr_sta <= 1'b0;
                                        spi_data_in_sta <= {
                                                16'd65535 & W5100S_SOCKET_REG_S0_RX_RD1_ADDR,
                                                8'd255    & 8'h0 // 读取寄存器时数据段为任意即可, 此处 8bit 全0
                                        }; // 读出数据
                                        
                                        reg_data_chk_flag <= 4'd1; // 表示 已发送 查询寄存器值命令 的标志位
                                    end else begin // 已进行寄存器读取的操作
                                        if (spi_data_ready) begin
                                            reg_data_chk_flag <= 4'd0;

                                            reg_s0_rx_rd[7:0] <= spi_data_out[7:0];

                                            SUB_STATE <= STATE_TCP_SERVER_RECEIVE_DATA_INIT_REG_S0_RX_RSR0; // 跳至下一子状态
                                        end
                                    end
                                end else begin // spi 非空闲, 抬高片选信号
                                    spi_start_sta <= 1'b0;
                                end
                            end
                            STATE_TCP_SERVER_RECEIVE_DATA_INIT_REG_S0_RX_RSR0: begin
                                if (~spi_busy && ~spi_lock_int) begin // spi 空闲, 判断寄存器数据查询状态, 并继续; idle 信号常态不变, 即信号维持时间长, 故不需要同步时钟域
                                    if (reg_data_chk_flag == 4'd0) begin // 尚未进行寄存器读取的操作; 此时 spi 空闲, 可进行一次寄存器数据的读取
                                        spi_start_sta <= 1'b1;
                                        spi_wr_sta <= 1'b0;
                                        spi_data_in_sta <= {
                                                16'd65535 & W5100S_SOCKET_REG_S0_RX_RSR0_ADDR,
                                                8'd255    & 8'h0 // 读取寄存器时数据段为任意即可, 此处 8bit 全0
                                        }; // 读出数据
                                        
                                        reg_data_chk_flag <= 4'd1; // 表示 已发送 查询寄存器值命令 的标志位
                                    end else begin // 已进行寄存器读取的操作
                                        if (spi_data_ready) begin
                                            reg_data_chk_flag <= 4'd0;

                                            reg_s0_rx_rsr[15:8] <= spi_data_out[7:0];
                                            var_recv_size[15:8] <= spi_data_out[7:0];

                                            SUB_STATE <= STATE_TCP_SERVER_RECEIVE_DATA_INIT_REG_S0_RX_RSR1; // 跳至下一子状态
                                        end
                                    end
                                end else begin // spi 非空闲, 抬高片选信号
                                    spi_start_sta <= 1'b0;
                                end
                            end
                            STATE_TCP_SERVER_RECEIVE_DATA_INIT_REG_S0_RX_RSR1: begin
                                if (~spi_busy && ~spi_lock_int) begin // spi 空闲, 判断寄存器数据查询状态, 并继续; idle 信号常态不变, 即信号维持时间长, 故不需要同步时钟域
                                    if (reg_data_chk_flag == 4'd0) begin // 尚未进行寄存器读取的操作; 此时 spi 空闲, 可进行一次寄存器数据的读取
                                        spi_start_sta <= 1'b1;
                                        spi_wr_sta <= 1'b0;
                                        spi_data_in_sta <= {
                                                16'd65535 & W5100S_SOCKET_REG_S0_RX_RSR1_ADDR,
                                                8'd255    & 8'h0 // 读取寄存器时数据段为任意即可, 此处 8bit 全0
                                        }; // 读出数据
                                        
                                        reg_data_chk_flag <= 4'd1; // 表示 已发送 查询寄存器值命令 的标志位
                                    end else begin // 已进行寄存器读取的操作
                                        if (spi_data_ready) begin
                                            reg_data_chk_flag <= 4'd0;

                                            reg_s0_rx_rsr[7:0] <= spi_data_out[7:0];
                                            var_recv_size[7:0] <= spi_data_out[7:0];

                                            SUB_STATE <= STATE_TCP_SERVER_RECEIVE_DATA_PROC_VAR_OFFSET; // 跳至下一子状态
                                        end
                                    end
                                end else begin // spi 非空闲, 抬高片选信号
                                    spi_start_sta <= 1'b0;
                                end
                            end
                            STATE_TCP_SERVER_RECEIVE_DATA_PROC_VAR_OFFSET: begin
                                var_rx_rd_offset <= reg_s0_rx_rd & W5100S_SOCKET_VAR_S0_RX_MASK;
                                var_txrx_break_flag <= 1'b0; // 提前复位标志位

                                SUB_STATE <= STATE_TCP_SERVER_RECEIVE_DATA_PROC_MERGE_DATA;
                            end
                            STATE_TCP_SERVER_RECEIVE_DATA_PROC_MERGE_DATA: begin
                                var_rx_rd_addr <= W5100S_SOCKET_VAR_S0_RX_BASE_ADDR + var_rx_rd_offset;

                                if (var_rx_rd_offset + var_recv_size > W5100S_SOCKET_VAR_MAX_RX_BUF_SIZE) begin // 接收段越 循环缓冲区 边界了, 先切割后发送; 第一段先接收 upper 部分
                                    var_rx_rd_addr <= W5100S_SOCKET_VAR_S0_RX_BASE_ADDR + var_rx_rd_offset;
                                    var_recv_size <= W5100S_SOCKET_VAR_MAX_RX_BUF_SIZE - var_rx_rd_offset;

                                    var_txrx_break_flag <= 1'b1;
                                end else begin
                                    var_rx_rd_addr <= W5100S_SOCKET_VAR_S0_RX_BASE_ADDR + var_rx_rd_offset;
                                end

                                SUB_STATE <= STATE_TCP_SERVER_RECEIVE_DATA_PROC_VAR_RECV_SIZE;
                            end
                            STATE_TCP_SERVER_RECEIVE_DATA_PROC_VAR_RECV_SIZE: begin
                                reg_s0_rx_rd <= reg_s0_rx_rd + var_recv_size; // 更新 接收缓冲区写指针
                                recv_size <= var_recv_size; // 更新 接收数据大小

                                if (!recv_en_n) begin // 使能接收 且 接收数据量小于指定大小 时才进行数据的接收与写入
                                    recv_buf_wr_en <= 1'b1; // 开启 RAM 写请求需要提前一个时钟周期, 以便于在下一个状态中进行数据的写入
                                    recv_buf_wr_addr <= 10'h3_FF; // 初始化写入地址, 下一次 +1 时即复位为 0

                                    SUB_STATE <= STATE_TCP_SERVER_RECEIVE_DATA_PROC_TRANSMIT;
                                end else begin
                                    SUB_STATE <= STATE_TCP_SERVER_RECEIVE_DATA_PROC_TRANSMIT_POST; // 接收使能未开启, 跳过接收过程
                                end
                            end
                            STATE_TCP_SERVER_RECEIVE_DATA_PROC_TRANSMIT: begin

                                if (var_recv_cnt < var_recv_size + 1) begin // 循环此状态来接收所有数据; 多循环一次以获取完所有数据

                                    if (~spi_busy && ~spi_lock_int) begin // spi 空闲, 判断寄存器数据查询状态, 并继续; idle 信号常态不变, 即信号维持时间长, 故不需要同步时钟域

                                        var_rx_rd_addr <= var_rx_rd_addr + 16'd1; // 下一个字节地址
                                        var_recv_cnt <= var_recv_cnt + 16'd1;

                                        if (var_recv_cnt < var_recv_size) begin // 最后一次不发 SPI 帧
                                            spi_start_sta <= 1'b1;
                                            spi_wr_sta <= 1'b0;
                                            spi_data_in_sta <= {
                                                    16'd65535 & var_rx_rd_addr,
                                                    8'd255    & 8'h0 // 读取寄存器时数据段为任意即可, 此处 8bit 全0
                                            }; // 读出数据
                                        end
                                        if (var_recv_cnt > 16'd0) begin // 第一次不写 RAM
                                            recv_buf_wr_clk <= 1'b1; // RAM 写请求
                                            recv_buf_wr_addr <= recv_buf_wr_addr + 10'h1; // 下一个字节地址
                                            recv_buf_wr_data <= spi_data_out[7:0]; // 读取上次 SPI 读出的数据
                                        end

                                    end else begin // spi 非空闲, 抬高片选信号
                                        spi_start_sta <= 1'b0;
                                        
                                        recv_buf_wr_clk <= 1'b0;
                                    end

                                end else begin // 接收完成, 转移至下一个状态
                                    var_recv_cnt <= 16'd0;

                                    if (var_txrx_break_flag) begin // 接收数据段 为 切割数据段, 应继续当前状态继续完成下半段接收
                                        var_rx_rd_addr <= W5100S_SOCKET_VAR_S0_RX_BASE_ADDR;
                                        var_recv_size <= var_recv_size - (W5100S_SOCKET_VAR_MAX_RX_BUF_SIZE - var_rx_rd_offset);

                                        var_txrx_break_flag <= 1'b0;
                                    end else begin
                                        SUB_STATE <= STATE_TCP_SERVER_RECEIVE_DATA_PROC_TRANSMIT_POST;
                                    end

                                    recv_buf_wr_clk <= 1'b0;
                                    recv_buf_wr_en <= 1'b0; // 关闭 RAM 写请求
                                end

                            end
                            STATE_TCP_SERVER_RECEIVE_DATA_PROC_TRANSMIT_POST: begin

                                SUB_STATE <= STATE_TCP_SERVER_RECEIVE_DATA_PROC_REG_S0_RX_RD0;
                            end
                            STATE_TCP_SERVER_RECEIVE_DATA_PROC_REG_S0_RX_RD0: begin
                                if (~spi_busy && ~spi_lock_int) begin // spi 空闲, 判断寄存器数据查询状态, 并继续; idle 信号常态不变, 即信号维持时间长, 故不需要同步时钟域
                                    spi_start_sta <= 1'b1;
                                    spi_wr_sta <= 1'b1;
                                    spi_data_in_sta <= {
                                            16'd65535 & W5100S_SOCKET_REG_S0_RX_RD0_ADDR,
                                            8'd255    & reg_s0_rx_rd[15:8] // 写入数据
                                    }; // 写入数据

                                    SUB_STATE <= STATE_TCP_SERVER_RECEIVE_DATA_PROC_REG_S0_RX_RD1; // 跳至下一子状态
                                end else begin // spi 非空闲, 抬高片选信号
                                    spi_start_sta <= 1'b0;
                                end
                            end
                            STATE_TCP_SERVER_RECEIVE_DATA_PROC_REG_S0_RX_RD1: begin
                                if (~spi_busy && ~spi_lock_int) begin // spi 空闲, 判断寄存器数据查询状态, 并继续; idle 信号常态不变, 即信号维持时间长, 故不需要同步时钟域
                                    spi_start_sta <= 1'b1;
                                    spi_wr_sta <= 1'b1;
                                    spi_data_in_sta <= {
                                            16'd65535 & W5100S_SOCKET_REG_S0_RX_RD1_ADDR,
                                            8'd255    & reg_s0_rx_rd[7:0] // 写入数据
                                    }; // 写入数据

                                    SUB_STATE <= STATE_TCP_SERVER_RECEIVE_DATA_PROC_REG_S0_CR_CMD_RECV; // 跳至下一子状态
                                end else begin // spi 非空闲, 抬高片选信号
                                    spi_start_sta <= 1'b0;
                                end
                            end
                            STATE_TCP_SERVER_RECEIVE_DATA_PROC_REG_S0_CR_CMD_RECV: begin
                                if (~spi_busy && ~spi_lock_int) begin // spi 空闲, 可进行下一次寄存器数据的写入
                                    spi_start_sta <= 1'b1;
                                    spi_wr_sta <= 1'b1;
                                    spi_data_in_sta <= {
                                            16'd65535 & W5100S_SOCKET_REG_S0_CR_ADDR,
                                            8'd255    & W5100S_SOCKET_REG_S0_CR_DATA_CMD_RECV // Command: SEND
                                    }; // 写入数据
                                    
                                    // reg_data_chk_flag <= 4'd0;

                                    SUB_STATE <= STATE_TCP_SERVER_RECEIVE_DATA_PROC_REG_S0_CR_CMD_RECV_WAIT_CLR; // 跳至下一子状态
                                end else begin // spi 非空闲, 抬高片选信号
                                    spi_start_sta <= 1'b0;
                                end
                            end
                            STATE_TCP_SERVER_RECEIVE_DATA_PROC_REG_S0_CR_CMD_RECV_WAIT_CLR: begin
                                if (~spi_busy && ~spi_lock_int) begin // spi 空闲, 判断寄存器数据查询状态, 并继续; idle 信号常态不变, 即信号维持时间长, 故不需要同步时钟域
                                    if (reg_data_chk_flag == 4'd0) begin // 尚未进行寄存器读取的操作; 此时 spi 空闲, 可进行一次寄存器数据的读取
                                        spi_start_sta <= 1'b1;
                                        spi_wr_sta <= 1'b0;
                                        spi_data_in_sta <= {
                                                16'd65535 & W5100S_SOCKET_REG_S0_CR_ADDR,
                                                8'd255    & 8'h0 // 读取寄存器时数据段为任意即可, 此处 8bit 全0
                                        }; // 读出数据
                                        
                                        reg_data_chk_flag <= 4'd1; // 表示 已发送 查询寄存器值命令 的标志位
                                    end else begin // 已进行寄存器读取的操作
                                        if (spi_data_ready) begin
                                            reg_data_chk_flag <= 4'd0;

                                            if (spi_data_out[7:0] == W5100S_SOCKET_REG_S0_CR_DATA_CLR) begin // S0_CR 寄存器已 clear, 可跳至下一状态
                                                // int_chk_wait_flag <= 4'd0;
                                                // SUB_STATE <= STATE_TCP_SERVER_RECEIVE_DATA_PROC_INT_CLR; // 跳至下一子状态
                                                SUB_STATE <= STATE_TCP_SERVER_RECEIVE_DATA_PROC_POST; // 跳至下一子状态
                                            end else begin // S0_CR 寄存器尚未 clear, 需再次进行读取操作, 直至寄存器 clear
                                                // left intentionally blank
                                            end
                                        end
                                    end
                                end else begin // spi 非空闲, 抬高片选信号
                                    spi_start_sta <= 1'b0;
                                end
                            end
                            STATE_TCP_SERVER_RECEIVE_DATA_PROC_INT_CLR: begin
                                if (~spi_busy && ~spi_lock_int) begin // spi 空闲, 判断寄存器数据查询状态, 并继续; idle 信号常态不变, 即信号维持时间长, 故不需要同步时钟域
                                    spi_start_sta <= 1'b1;
                                    spi_wr_sta <= 1'b1;
                                    spi_data_in_sta <= {
                                            16'd65535 & W5100S_SOCKET_REG_S0_IR_ADDR,
                                            8'd255    & W5100S_SOCKET_REG_S0_IR_DATA_CHK_INT_RECV // 向 RECV 中断位 写1 来清除接收中断
                                    }; // 写入数据

                                    SUB_STATE <= STATE_TCP_SERVER_RECEIVE_DATA_PROC_POST; // 跳至下一子状态
                                end else begin // spi 非空闲, 抬高片选信号
                                    spi_start_sta <= 1'b0;
                                end
                            end
                            STATE_TCP_SERVER_RECEIVE_DATA_PROC_POST: begin
                                recv_done <= 1'b1; // 接收完成信号

                                SUB_STATE <= STATE_POST; // 跳至下一子状态
                            end

                            STATE_POST: begin
                                recv_done <= 1'b0; // 复位 接收完成信号

                                CORE_STATE <= STATE_TCP_CONNECTION_ESTABLISHED;
                                SUB_STATE <= STATE_PRE;
                            end

                            default: begin
                                SUB_STATE <= STATE_PRE;
                            end

                        endcase

                    end

                    STATE_TCP_SERVER_DISCONNECT: begin

                        case (SUB_STATE)

                            STATE_PRE: begin
                                spi_start_sta <= 1'b0;

                                SUB_STATE <= STATE_TCP_SERVER_DISCONNECT_PASSIVE_INIT;
                            end

                            STATE_TCP_SERVER_DISCONNECT_PASSIVE_INIT: begin
                                SUB_STATE <= STATE_TCP_SERVER_DISCONNECT_PASSIVE_INIT_REG_S0_CR_CMD_DISCON;
                            end
                            STATE_TCP_SERVER_DISCONNECT_PASSIVE_INIT_REG_S0_CR_CMD_DISCON: begin
                                if (~spi_busy && ~spi_lock_int) begin // spi 空闲, 可进行下一次寄存器数据的写入
                                    spi_start_sta <= 1'b1;
                                    spi_wr_sta <= 1'b1;
                                    spi_data_in_sta <= {
                                            16'd65535 & W5100S_SOCKET_REG_S0_CR_ADDR,
                                            8'd255    & W5100S_SOCKET_REG_S0_CR_DATA_CMD_DISCON // Command: DISCON
                                    }; // 写入数据
                                    

                                    SUB_STATE <= STATE_TCP_SERVER_DISCONNECT_PASSIVE_INIT_REG_S0_CR_CMD_DISCON_WAIT_CLR; // 跳至下一子状态
                                end else begin // spi 非空闲, 抬高片选信号
                                    spi_start_sta <= 1'b0;
                                end
                            end
                            STATE_TCP_SERVER_DISCONNECT_PASSIVE_INIT_REG_S0_CR_CMD_DISCON_WAIT_CLR: begin
                                if (~spi_busy && ~spi_lock_int) begin // spi 空闲, 判断寄存器数据查询状态, 并继续; idle 信号常态不变, 即信号维持时间长, 故不需要同步时钟域
                                    if (reg_data_chk_flag == 4'd0) begin // 尚未进行寄存器读取的操作; 此时 spi 空闲, 可进行一次寄存器数据的读取
                                        spi_start_sta <= 1'b1;
                                        spi_wr_sta <= 1'b0;
                                        spi_data_in_sta <= {
                                                16'd65535 & W5100S_SOCKET_REG_S0_CR_ADDR,
                                                8'd255    & 8'h0 // 读取寄存器时数据段为任意即可, 此处 8bit 全0
                                        }; // 读出数据
                                        
                                        reg_data_chk_flag <= 4'd1; // 表示 已发送 查询寄存器值命令 的标志位
                                    end else begin // 已进行寄存器读取的操作
                                        if (spi_data_ready) begin
                                            reg_data_chk_flag <= 4'd0;
                                            
                                            if (spi_data_out[7:0] == W5100S_SOCKET_REG_S0_CR_DATA_CLR) begin // S0_CR 寄存器已 clear, 可跳至下一状态
                                                SUB_STATE <= STATE_TCP_SERVER_DISCONNECT_PROC; // 跳至下一子状态
                                            end else begin // S0_CR 寄存器尚未 clear, 需再次进行读取操作, 直至寄存器 clear
                                                // left intentionally blank
                                            end
                                        end
                                    end
                                end else begin // spi 非空闲, 抬高片选信号
                                    spi_start_sta <= 1'b0;
                                end
                            end

                            STATE_TCP_SERVER_DISCONNECT_ACTIVE_INIT: begin
                                SUB_STATE <= STATE_TCP_SERVER_DISCONNECT_ACTIVE_INIT_REG_S0_CR_CMD_DISCON;
                            end
                            STATE_TCP_SERVER_DISCONNECT_ACTIVE_INIT_REG_S0_CR_CMD_DISCON: begin
                                if (~spi_busy && ~spi_lock_int) begin // spi 空闲, 可进行下一次寄存器数据的写入
                                    spi_start_sta <= 1'b1;
                                    spi_wr_sta <= 1'b1;
                                    spi_data_in_sta <= {
                                            16'd65535 & W5100S_SOCKET_REG_S0_CR_ADDR,
                                            8'd255    & W5100S_SOCKET_REG_S0_CR_DATA_CMD_DISCON // Command: DISCON
                                    }; // 写入数据
                                    

                                    SUB_STATE <= STATE_TCP_SERVER_DISCONNECT_ACTIVE_INIT_REG_S0_CR_CMD_DISCON_WAIT_CLR; // 跳至下一子状态
                                end else begin // spi 非空闲, 抬高片选信号
                                    spi_start_sta <= 1'b0;
                                end
                            end
                            STATE_TCP_SERVER_DISCONNECT_ACTIVE_INIT_REG_S0_CR_CMD_DISCON_WAIT_CLR: begin
                                if (~spi_busy && ~spi_lock_int) begin // spi 空闲, 判断寄存器数据查询状态, 并继续; idle 信号常态不变, 即信号维持时间长, 故不需要同步时钟域
                                    if (reg_data_chk_flag == 4'd0) begin // 尚未进行寄存器读取的操作; 此时 spi 空闲, 可进行一次寄存器数据的读取
                                        spi_start_sta <= 1'b1;
                                        spi_wr_sta <= 1'b0;
                                        spi_data_in_sta <= {
                                                16'd65535 & W5100S_SOCKET_REG_S0_CR_ADDR,
                                                8'd255    & 8'h0 // 读取寄存器时数据段为任意即可, 此处 8bit 全0
                                        }; // 读出数据
                                        
                                        reg_data_chk_flag <= 4'd1; // 表示 已发送 查询寄存器值命令 的标志位
                                    end else begin // 已进行寄存器读取的操作
                                        if (spi_data_ready) begin
                                            reg_data_chk_flag <= 4'd0;
                                            
                                            if (spi_data_out[7:0] == W5100S_SOCKET_REG_S0_CR_DATA_CLR) begin // S0_CR 寄存器已 clear, 可跳至下一状态
                                                SUB_STATE <= STATE_TCP_SERVER_DISCONNECT_PROC; // 跳至下一子状态
                                            end else begin // S0_CR 寄存器尚未 clear, 需再次进行读取操作, 直至寄存器 clear
                                                // left intentionally blank
                                            end
                                        end
                                    end
                                end else begin // spi 非空闲, 抬高片选信号
                                    spi_start_sta <= 1'b0;
                                end
                            end

                            STATE_TCP_SERVER_DISCONNECT_PROC: begin
                                if (~spi_busy && ~spi_lock_int) begin // spi 空闲, 判断寄存器数据查询状态, 并继续; idle 信号常态不变, 即信号维持时间长, 故不需要同步时钟域
                                    spi_start_sta <= 1'b1;
                                    spi_wr_sta <= 1'b1;
                                    spi_data_in_sta <= {
                                            16'd65535 & W5100S_SOCKET_REG_S0_IR_ADDR,
                                            8'd255    & W5100S_SOCKET_REG_S0_IR_DATA_CHK_INT_DISCON // 向对应位 写1 来清除中断
                                    }; // 写入数据


                                    SUB_STATE <= STATE_POST; // 跳至下一子状态
                                end else begin // spi 非空闲, 抬高片选信号
                                    spi_start_sta <= 1'b0;
                                end
                            end
                            STATE_TCP_SERVER_DISCONNECT_PROC_WAIT_ACK: begin
                                if (~spi_busy && ~spi_lock_int) begin // spi 空闲, 判断寄存器数据查询状态, 并继续; idle 信号常态不变, 即信号维持时间长, 故不需要同步时钟域
                                    if (reg_data_chk_flag == 4'd0) begin // 尚未进行寄存器读取的操作; 此时 spi 空闲, 可进行一次寄存器数据的读取
                                        spi_start_sta <= 1'b1;
                                        spi_wr_sta <= 1'b0;
                                        spi_data_in_sta <= {
                                                16'd65535 & W5100S_SOCKET_REG_S0_IR_ADDR,
                                                8'd255    & 8'h0 // 读取寄存器时数据段为任意即可, 此处 8bit 全0
                                        }; // 读出数据
                                        
                                        reg_data_chk_flag <= 4'd1; // 表示 已发送 查询寄存器值命令 的标志位
                                    end else begin // 已进行寄存器读取的操作
                                        if (spi_data_ready) begin
                                            reg_data_chk_flag <= 4'd0;
                                            
                                            if ((spi_data_out[7:0] & W5100S_SOCKET_REG_S0_IR_DATA_CHK_INT_DISCON) == W5100S_SOCKET_REG_S0_IR_DATA_CHK_INT_DISCON) begin // 已接收到客户端发来的 ACK 包, 可跳至下一状态
                                                // SUB_STATE <= STATE_TCP_SERVER_DISCONNECT_PROC_CLR_INT_ALL; // 跳至下一子状态
                                                SUB_STATE <= STATE_POST; // 跳至下一子状态
                                            end else begin // S0_CR 寄存器尚未 clear, 需再次进行读取操作, 直至寄存器 clear
                                                // left intentionally blank
                                            end
                                        end
                                    end
                                end else begin // spi 非空闲, 抬高片选信号
                                    spi_start_sta <= 1'b0;
                                end
                            end
                            STATE_TCP_SERVER_DISCONNECT_PROC_CLR_INT_ALL: begin
                                if (~spi_busy && ~spi_lock_int) begin // spi 空闲, 判断寄存器数据查询状态, 并继续; idle 信号常态不变, 即信号维持时间长, 故不需要同步时钟域
                                    spi_start_sta <= 1'b1;
                                    spi_wr_sta <= 1'b1;
                                    spi_data_in_sta <= {
                                            16'd65535 & W5100S_SOCKET_REG_S0_IR_ADDR,
                                            8'd255    & W5100S_SOCKET_REG_S0_IR_DATA_CHK_INT_ALL // 向所有位 写1 来清除所有中断
                                    }; // 写入数据

                                    SUB_STATE <= STATE_POST; // 跳至下一子状态
                                end else begin // spi 非空闲, 抬高片选信号
                                    spi_start_sta <= 1'b0;
                                end
                            end

                            STATE_POST: begin
                                spi_start_sta <= 1'b0;

                                CORE_STATE <= STATE_TCP_SERVER_SETUP; // 回到 重新建立 TCP 服务器 状态
                                SUB_STATE <= STATE_PRE;
                            end

                            default: begin
                                SUB_STATE <= STATE_PRE;
                            end

                        endcase

                    end

                    default: begin
                        // left intentionally blank
                    end
                endcase

            end
        end
    end
end  

endmodule
