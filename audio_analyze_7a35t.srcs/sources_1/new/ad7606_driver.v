`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: 
// Engineer: 
// 
// Create Date: 2025/11/29 15:03:48
// Design Name: 
// Module Name: ad7606_driver
// Project Name: 
// Target Devices: 
// Tool Versions: 
// Description: 
// 
// Dependencies: 
// 
// Revision:
// Revision 0.01 - File Created
// Additional Comments:
// 
//////////////////////////////////////////////////////////////////////////////////


module ad7606_driver #(
    parameter CLK_FREQ    = 50_000_000, // 系统时钟频率 50MHz
    parameter SAMPLE_RATE = 48_000      // 目标采样�? 48kHz
)(
    input             clk,        // 系统时钟 50MHz
    input             rst_n,

    // AD7606 物理接口
    input             ad_busy,      // AD7606 BUSY信号
    (* mark_debug = "true" *)input      [15:0] ad_data_in,   // AD7606 DB[15:0] 数据总线
    (* mark_debug = "true" *)output reg        ad_cs,        // AD7606 片�?? (低有�?)
    (* mark_debug = "true" *)output reg        ad_rd,        // AD7606 读使�? (低有�?)
    output reg        ad_reset,     // AD7606 复位 (高有�?)
    output reg        ad_convst,    // AD7606 转换�?�? (CONV A/B 连在�?�?)
    
    // 用户接口
    (* mark_debug = "true" *)output reg        sample_valid,     // 输出高电平时，数据有�?
    (* mark_debug = "true" *)output reg [15:0] sample_data_out   // 采集到的音频数据 (补码格式)
    );

//================================================================
    // 1. 参数计算与状态定�?
    //================================================================
    localparam CNT_MAX = CLK_FREQ / SAMPLE_RATE; // 采样计数器最大�??
    
    // 状�?�机状�?�定�?
    localparam S_IDLE       = 4'd0;
    localparam S_RESET_AD   = 4'd1; // 上电复位AD7606
    localparam S_WAIT_TRIG  = 4'd2; // 等待48kHz触发
    localparam S_CONV_START = 4'd3; // 拉高CONVST
    localparam S_WAIT_BUSY  = 4'd4; // 等待转换完成(BUSY下降�?)
    localparam S_READ_SETUP = 4'd5; // 准备读取(CS拉低)
    localparam S_READ_LOW   = 4'd6; // RD拉低
    localparam S_READ_LATCH = 4'd7; // 锁存数据
    localparam S_READ_HIGH  = 4'd8; // RD拉高
    localparam S_DONE       = 4'd9; // 完成
    (* mark_debug = "true" *) reg [3:0] state;
    reg [31:0] trig_cnt;     // 采样率分频计数器
    reg [15:0] reset_cnt;    // AD复位保持计数�?

    //================================================================
    // 2. 状�?�机逻辑
    //================================================================
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state           <= S_IDLE;
            ad_cs           <= 1'b1;
            ad_rd           <= 1'b1;
            ad_reset        <= 1'b0;
            ad_convst       <= 1'b1; // 空闲时�?�常保持�?
            sample_valid    <= 1'b0;
            sample_data_out <= 16'd0;
            trig_cnt        <= 0;
            reset_cnt       <= 0;
        end else begin
            // 默认信号状�??
            sample_valid <= 1'b0; 

            // 采样率计数器 (产生48kHz基准)
            if (trig_cnt < CNT_MAX - 1)
                trig_cnt <= trig_cnt + 1;
            else
                trig_cnt <= 0;

            case (state)
                // --- 初始上电复位状�?? ---
                S_IDLE: begin
                    state <= S_RESET_AD;
                    reset_cnt <= 0;
                end

                // AD7606 上电后需要一个复位脉�?
                S_RESET_AD: begin
                    ad_reset <= 1'b1;
                    reset_cnt <= reset_cnt + 1;
                    if (reset_cnt > 16'd100) begin // 保持 Reset �?小段时间
                        ad_reset <= 1'b0;
                        state <= S_WAIT_TRIG;
                    end
                end

                // --- 等待采样时刻 ---
                S_WAIT_TRIG: begin
                    // 当计数器归零时触发一次采�?
                    if (trig_cnt == 0) 
                        state <= S_CONV_START;
                end

                // --- 启动转换 ---
                S_CONV_START: begin
                    ad_convst <= 1'b0; // 拉低启动 (上升沿或低脉冲触发，AD7606是上升沿触发也可以，这里模拟负脉�?)
                    // 保持低电平几个周期以确保触发
                    if (trig_cnt == 5) begin 
                         ad_convst <= 1'b1; // 拉高，产生上升沿，AD�?始转�?
                         state <= S_WAIT_BUSY;
                    end
                end

                // --- 等待转换结束 ---
                S_WAIT_BUSY: begin
                    // AD7606转换时BUSY为高。等待BUSY变回低电平表示转换结束�??
                    // 注意：CONVST后BUSY不会立刻变高，这里加�?个简单延时保护，或�?�直接检�?
                    // 实际应用中，稍微延时再检测BUSY=0比较稳妥，防止BUSY还没起来就误判为0
                    if (trig_cnt > 20 && ad_busy == 1'b0) begin
                        state <= S_READ_SETUP;
                    end
                end

                // --- 读取数据 (只读通道1) ---
                S_READ_SETUP: begin
                    ad_cs <= 1'b0; // 选中芯片
                    state <= S_READ_LOW;
                end

                S_READ_LOW: begin
                    ad_rd <= 1'b0; // RD拉低，数据输出到总线
                    state <= S_READ_LATCH;
                end

                S_READ_LATCH: begin
                    // 在RD低电平期间读取数据，通常保持�?个周期即�?
                    sample_data_out <= ad_data_in; 
                    state <= S_READ_HIGH;
                end

                S_READ_HIGH: begin
                    ad_rd <= 1'b1; // RD拉高
                    ad_cs <= 1'b1; // 取消片�??
                    state <= S_DONE;
                end
                
                // 如果�?要读取�?�道2，需再次重复 READ_LOW -> LATCH -> HIGH 的过�?

                // --- 完成并输�? ---
                S_DONE: begin
                    sample_valid <= 1'b1; // 发出�?个脉冲告诉后级模块数据好�?
                    state <= S_WAIT_TRIG; // 回到等待状�??
                end
                
                default: state <= S_IDLE;
            endcase
        end
    end
    
endmodule
