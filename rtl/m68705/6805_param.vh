/* SPDX-FileCopyrightText: 2026 Jose Tejada Gomez
 * SPDX-License-Identifier: GPL-3.0-or-later
 * Date: 12-09-2026 */

// Control signals
localparam [3:0] // ALU
         ADD_ALU = 4'd1,
         AND_ALU = 4'd2,
        BCLR_ALU = 4'd3,
        BSET_ALU = 4'd4,
         EOR_ALU = 4'd5,
         LSL_ALU = 4'd6,
         LSR_ALU = 4'd7,
          OR_ALU = 4'd8,
         SUB_ALU = 4'd9;

localparam [1:0] // BRT
         CLR_BRT = 2'd1,
         SET_BRT = 2'd2;

localparam [1:0] // CARRY
       CIN_CARRY = 2'd1,
       MSB_CARRY = 2'd2;

localparam [3:0] // CC
            C_CC = 4'd1,
           C0_CC = 4'd2,
           C1_CC = 4'd3,
         HNZC_CC = 4'd4,
           I0_CC = 4'd5,
           I1_CC = 4'd6,
         N0Z1_CC = 4'd7,
           NZ_CC = 4'd8,
          NZC_CC = 4'd9,
         NZC1_CC = 4'd10;

localparam [1:0] // EA
            M_EA = 2'd1,
            S_EA = 2'd2;

localparam [4:0] // JSR
         DIR_JSR = 5'd1,
        DIRA_JSR = 5'd2,
         EXT_JSR = 5'd3,
        EXTA_JSR = 5'd4,
       IDLE6_JSR = 5'd5,
         IDX_JSR = 5'd6,
       IDX16_JSR = 5'd7,
      IDX16A_JSR = 5'd8,
        IDX8_JSR = 5'd9,
       IDX8A_JSR = 5'd10,
         IMM_JSR = 5'd11,
        IVRD_JSR = 5'd12,
       PSH16_JSR = 5'd13,
        PSH8_JSR = 5'd14,
         RET_JSR = 5'd15,
        RTI8_JSR = 5'd16;

localparam [2:0] // LD
            A_LD = 3'd1,
           CC_LD = 3'd2,
           EA_LD = 3'd3,
           MD_LD = 3'd4,
           PC_LD = 3'd5,
            S_LD = 3'd6,
            X_LD = 3'd7;

localparam [3:0] // RMUX
          A_RMUX = 4'd1,
         CC_RMUX = 4'd2,
         EA_RMUX = 4'd3,
         IV_RMUX = 4'd4,
         MD_RMUX = 4'd5,
        ONE_RMUX = 4'd6,
         PC_RMUX = 4'd7,
          S_RMUX = 4'd8,
          X_RMUX = 4'd9,
       ZERO_RMUX = 4'd10;

localparam [1:0] // OPND
        LD0_OPND = 2'd1,
        LD1_OPND = 2'd2;

// entry points for ucode procedures
localparam DIR_SEQA             = 12'h910;
localparam DIRA_SEQA            = 12'h870;
localparam EXT_SEQA             = 12'h920;
localparam EXTA_SEQA            = 12'h840;
localparam IDLE6_SEQA           = 12'hAF0;
localparam IDX_SEQA             = 12'h930;
localparam IDX16_SEQA           = 12'h950;
localparam IDX16A_SEQA          = 12'h960;
localparam IDX8_SEQA            = 12'h940;
localparam IDX8A_SEQA           = 12'h850;
localparam IMM_SEQA             = 12'h900;
localparam ISRV_SEQA            = 12'h9E0;
localparam IVRD_SEQA            = 12'h820;
localparam PSH16_SEQA           = 12'h4B0;
localparam PSH8_SEQA            = 12'h3B0;
localparam RTI8_SEQA            = 12'h7B0;