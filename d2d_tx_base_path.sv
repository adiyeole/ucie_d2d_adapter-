module d2d_tx_base_path (
    input  logic         clk,
    input  logic         rst_n,

    // FDI (Protocol Layer to Adapter)
    input  logic         fdi_lp_valid,
    input  logic         fdi_lp_irdy,
    output logic         fdi_pl_trdy,
    input  logic [511:0] fdi_lp_data,
    input  logic [7:0]   fdi_lp_stream,

    // RDI (Adapter to Physical Layer)
    output logic         rdi_lp_valid,
    output logic         rdi_lp_irdy,
    input  logic         rdi_pl_trdy,
    output logic [511:0] rdi_lp_data
);

 logic [1023:0] acc_data_q, acc_data_d;
    logic [1023:0] acc_data_d_pre_push;
    
    logic [7:0]    acc_bytes_q, acc_bytes_d;
    logic [7:0]    acc_bytes_d_pre_push;
    
    logic [1:0]    rdi_chunk_cnt_q, rdi_chunk_cnt_d; // Counts 0..3 for 256B boundary



    // -------------------------------------------------------------------------
    // 1. Flit Header Assembly (Format 2 - No Retry)
    // -------------------------------------------------------------------------
    logic [15:0] regular_header;
    logic        stack_id;

    // Stream 0x14 indicates Stack 1, 0x04 indicates Stack 0
    assign stack_id = (fdi_lp_stream == 8'h14) ? 1'b1 : 1'b0;

    // Byte 0: [7:6]=01b (Protocol Flit), [1]=Stack ID, [2]=0 (Regular), [3:0]=0
    assign regular_header[7:0]  = {2'b01, stack_id, 1'b0, 4'b0};
    // Byte 1: [3]=0 (Regular), [6:0]=0
    assign regular_header[15:8] = 8'b0;

    // -------------------------------------------------------------------------
    // 2. CRC Integration
    // -------------------------------------------------------------------------
    // The CRC payload spans Byte 0 to Byte 65 (2B Header + 64B Payload)
    logic [527:0] crc_data_in;
    logic [15:0]  crc_out;
    
    assign crc_data_in = {fdi_lp_data, regular_header};

    crc_16_comb crc_inst (
        .data (crc_data_in),
        .crc_out (crc_out)
    );

    // 68-Byte Flit assembled
    logic [543:0] flit_data;
    assign flit_data = {crc_out, fdi_lp_data, regular_header};

    // -------------------------------------------------------------------------
    // 3. States & Handshake Logic 
    // -------------------------------------------------------------------------
    typedef enum logic [2:0] {
        NORMAL,       // Normal operation processing protocol flits
        PDS_HDR,      // Inject PDS Header and pad to 64B boundary
        PDS_PAD1,     // Force padding chunk 1
        PDS_PAD2,     // Force padding chunk 2
        PDS_ALIGN,    // Output padding chunks until 256B aligned
        FLUSH,        // Wait for RDI to consume remaining bytes
        IDLE          // Await next valid FDI input
    } state_t;

    state_t state_q, state_d;

    logic push_flit, push_pds, push_pad, pop_rdi;
    
    assign rdi_lp_valid = (acc_bytes_q >= 8'd64);
    assign rdi_lp_irdy  = rdi_lp_valid;
    assign pop_rdi      = rdi_lp_valid && rdi_lp_irdy && rdi_pl_trdy;

    // Accept data from Protocol Layer only in NORMAL state with enough buffer space
    assign fdi_pl_trdy  = (state_q  == NORMAL) && ((acc_bytes_q <= 8'd60) || pop_rdi);
    assign push_flit    = fdi_lp_valid && fdi_lp_irdy && fdi_pl_trdy;

    // -------------------------------------------------------------------------
    // 4. Barrel Shifter & PDS Injection Controller
    // -------------------------------------------------------------------------
    // 1024-bit (128-Byte) shift register to handle 4B sliding accumulation
   
    
    assign rdi_lp_data = acc_data_q[511:0];

    // Pre-calculate shift state based purely on RDI consumption this cycle
    assign acc_data_d_pre_push  = pop_rdi ? (acc_data_q >> 512) : acc_data_q;
    assign acc_bytes_d_pre_push = pop_rdi ? (acc_bytes_q - 8'd64) : acc_bytes_q;
    initial begin 
        $monitor("mon acc_bytes_d = %0d, acc_bytes_q =%0d , acc_bytes_d_pre_push = %0d, state_d = %0d, state_q=%0d, time = %0t ",
              acc_bytes_d, acc_bytes_q,acc_bytes_d_pre_push,state_d, state_q, $time);
    end
    always_comb begin
        state_d         = state_q;
        push_pds        = 1'b0;
        push_pad        = 1'b0;
        acc_data_d      = acc_data_d_pre_push;
        acc_bytes_d     = acc_bytes_d_pre_push;
        rdi_chunk_cnt_d = rdi_chunk_cnt_q;

        if (pop_rdi) rdi_chunk_cnt_d = rdi_chunk_cnt_q + 2'd1;
        if (push_flit) begin
            acc_data_d  = acc_data_d | ({512'b0, flit_data} << (acc_bytes_d * 8));
            acc_bytes_d = acc_bytes_d + 8'd68;
        end

        // FSM Next-State Logic & Push commands
        case (state_q)
            NORMAL: begin
                if (fdi_lp_valid) state_d = NORMAL;
                else if (acc_bytes_d!='0 ) state_d = PDS_HDR; // Immediately begin termination
            end
            PDS_HDR: begin
                $display(" outside loop %0t, state_d = %0d, state_q = %0d, acc_bytes_d_pre_push = %0d ", $time,
                                             state_d, state_q, acc_bytes_d_pre_push );
                // Wait for buffer space so padding fits easily in 128B accumulator
                if (acc_bytes_d_pre_push <= 8'd126) begin
                    
                    push_pds = 1'b1;
                    state_d  = PDS_PAD1;
                    $display(" inside loop %0t, state_d = %0d, state_q = %0d, acc_bytes_d_pre_push = %0d ", $time,
                                             state_d, state_q, acc_bytes_d_pre_push );
                end
            end
            PDS_PAD1: begin
                if (acc_bytes_d_pre_push <= 8'd64) begin
                    push_pad = 1'b1;
                    state_d  = PDS_PAD2;
                end
            end
            PDS_PAD2: begin
                if (acc_bytes_d_pre_push <= 8'd64) begin
                    push_pad = 1'b1;
                    state_d  = PDS_ALIGN;
                end
            end
            PDS_ALIGN: begin
                // Predict total chunks that will be emitted including what is buffered
                // acc_bytes is always a multiple of 64 here, so [7:6] serves as buffered count
                if ((rdi_chunk_cnt_d + acc_bytes_d_pre_push[7:6]) % 4 != 0) begin
                    if (acc_bytes_d_pre_push <= 8'd64) push_pad = 1'b1;
                end else begin
                    state_d = FLUSH;
                end
            end
            FLUSH: begin
                //if (acc_bytes_q == 8'd0 && !pop_rdi) state_d = IDLE;
                if (acc_bytes_q == 8'd0 && !pop_rdi) state_d = NORMAL;
            end
            /*IDLE: begin
                if (fdi_lp_valid) state_d = NORMAL;
            end */
            default:  state_d = NORMAL;
        endcase
        $display( " push_flit = %0d, push_pds = %0d, push_pad = %0d , t = %0t", push_flit,push_pds,push_pds, $time);
        // Execute Push operations on the accumulator
        if (push_flit) begin
            $display("beffl bytes_d = %0d, bytes_q =%0d , bytesdprepush = %0d, stated = %0d, stateq=%0d, time = %0t ",
            acc_bytes_d, acc_bytes_q,acc_bytes_d_pre_push,state_d, state_q, $time);
            acc_data_d  = acc_data_d | ({512'b0, flit_data} << (acc_bytes_d * 8));
            acc_bytes_d = acc_bytes_d + 8'd68;
            $display("affl bytes_d = %0d, bytes_q =%0d , bytesdprepush = %0d, stated = %0d, stateq=%0d, time = %0t ",
              acc_bytes_d, acc_bytes_q,acc_bytes_d_pre_push,state_d, state_q, $time);
        end 
        else if (push_pds) begin
            logic [1023:0] pds_mask;
            $display("afdpds bytes_d = %0d, bytes_q =%0d , bytesdprepush = %0d, stated = %0d, stateq=%0d, time = %0t ",
              acc_bytes_d, acc_bytes_q,acc_bytes_d_pre_push,state_d, state_q, $time);
            // Insert 16'h8010 PDS Header. Mask out stale upper bits & pad to 64B bound.
            
            pds_mask    = (1024'b1 << (acc_bytes_d * 8)) - 1;
            acc_data_d  = acc_data_d  | ({1008'b0, 16'h8010} << (acc_bytes_d * 8));
                acc_data_d  = (acc_data_d & pds_mask) | ({1008'b0, 16'h8010} << (acc_bytes_d * 8));
            //acc_bytes_d = (acc_bytes_d + 8'd2 + 8'd63) & ~8'd63; // Align to 64B block
            $display("afdpds bytes_d = %0d, bytes_q =%0d , bytesdprepush = %0d, stated = %0d, stateq=%0d, time = %0t ",
              acc_bytes_d, acc_bytes_q,acc_bytes_d_pre_push,state_d, state_q, $time);
        end 
        else if (push_pad) begin
            logic [1023:0] pad_mask;
            pad_mask    = (1024'b1 << (acc_bytes_d * 8)) - 1;
            acc_data_d  = acc_data_d & pad_mask; // Ensure explicitly padded with 0's
            acc_bytes_d = acc_bytes_d + 8'd64;
        end
    end

    // Sequential Blocks
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state_q         <= NORMAL;
            acc_data_q      <= 1024'b0;
            acc_bytes_q     <= 8'd0;
            rdi_chunk_cnt_q <= 2'd0;
        end else begin
            state_q         <= state_d;
            acc_data_q      <= acc_data_d;
            acc_bytes_q     <= acc_bytes_d;
            rdi_chunk_cnt_q <= rdi_chunk_cnt_d;
        end
    end

endmodule

// -----------------------------------------------------------------------------
// UCIe D2D Adapter Combinational CRC Generator Logic (From Consortium Sources)
// -----------------------------------------------------------------------------

module crc_16_comb (
  input logic [527:0] data,
  output logic [15:0]  crc_out
);
logic [1023:0] data_in;
assign data_in = {496'b0,data};
always_comb begin
   crc_out[ 0] = ^(data_in & 1024'hfffdfff3ffd7ff0ffddff33fd57f00fdfdf3f3d7d70f0dddd33315558002fff1ffdbff27fd2ff11fd9bf2a7d02f1f1dbdb27252d211139996aa8800cffd5ff03fdf7f3cfd75f0c3dd7730cd5d50301f5fbc3e777acce155b8026ff29fd0bf1c7db6f249d24b1245926292b0905c9e34bb446466a6a8280f0fdddf333d557000d);
   crc_out[ 1] = ^(data_in & 1024'h7ffefff9ffebff87feeff99feabf807efef9f9ebeb8786eee9998aaac0017ff8ffedff93fe97f88fecdf953e8178f8eded93929690889cccb55440067feaff81fefbf9e7ebaf861eebb9866aea8180fafde1f3bbd6670aadc0137f94fe85f8e3edb7924e9258922c9314958482e4f1a5da232335354140787eeef999eaab8006);
   crc_out[ 2] = ^(data_in & 1024'hc002800f002200cc02a80ff02020c0c2828f0f2222ccceaaa7ffd000e002400d802d00ee02640d582fd0e0e2424d8dad2deeec66695577ff3002a00fc02080c3028a0f3c2288cf32a2afcfe0a043c18885331eaa47fd900d602f40e382490db62db4edba6d9d6d4f6fa361cb44bb9b995957d7f0f02220ccc2aa8fff2002c00e);
   crc_out[ 3] = ^(data_in & 1024'h6001400780110066015407f810106061414787911166675553ffe80070012006c0168077013206ac17e870712126c6d696f7763334aabbff98015007e01040618145079e114467995157e7f05021e0c442998f5523fec806b017a071c12486db16da76dd36ceb6a7b7d1b0e5a25dcdccacabebf878111066615547ff90016007);
   crc_out[ 4] = ^(data_in & 1024'h3000a003c008803300aa03fc08083030a0a3c3c888b333aaa9fff40038009003600b403b809903560bf438389093636b4b7bbb199a555dffcc00a803f0082030c0a283cf08a233cca8abf3f82810f062214cc7aa91ff6403580bd038e092436d8b6d3b6e9b675b53dbe8d872d12ee6e65655f5fc3c08883330aaa3ffc800b003);
   crc_out[ 5] = ^(data_in & 1024'h18005001e0044019805501fe040418185051e1e4445999d554fffa001c004801b005a01dc04c81ab05fa1c1c4849b1b5a5bddd8ccd2aaeffe6005401f8041018605141e7845119e65455f9fc1408783110a663d548ffb201ac05e81c704921b6c5b69db74db3ada9edf46c39689773732b2afafe1e044419985551ffe4005801);
   crc_out[ 6] = ^(data_in & 1024'h0c002800f002200cc02a80ff02020c0c2828f0f2222ccceaaa7ffd000e002400d802d00ee02640d582fd0e0e2424d8dad2deeec66695577ff3002a00fc02080c3028a0f3c2288cf32a2afcfe0a043c18885331eaa47fd900d602f40e382490db62db4edba6d9d6d4f6fa361cb44bb9b995957d7f0f02220ccc2aa8fff2002c00);
   crc_out[ 7] = ^(data_in & 1024'h06001400780110066015407f810106061414787911166675553ffe80070012006c0168077013206ac17e870712126c6d696f7763334aabbff98015007e01040618145079e114467995157e7f05021e0c442998f5523fec806b017a071c12486db16da76dd36ceb6a7b7d1b0e5a25dcdccacabebf878111066615547ff9001600);
   crc_out[ 8] = ^(data_in & 1024'h03000a003c008803300aa03fc08083030a0a3c3c888b333aaa9fff40038009003600b403b809903560bf438389093636b4b7bbb199a555dffcc00a803f0082030c0a283cf08a233cca8abf3f82810f062214cc7aa91ff6403580bd038e092436d8b6d3b6e9b675b53dbe8d872d12ee6e65655f5fc3c08883330aaa3ffc800b00);
   crc_out[ 9] = ^(data_in & 1024'h018005001e0044019805501fe040418185051e1e4445999d554fffa001c004801b005a01dc04c81ab05fa1c1c4849b1b5a5bddd8ccd2aaeffe6005401f8041018605141e7845119e65455f9fc1408783110a663d548ffb201ac05e81c704921b6c5b69db74db3ada9edf46c39689773732b2afafe1e044419985551ffe400580);
   crc_out[10] = ^(data_in & 1024'h00c002800f002200cc02a80ff02020c0c2828f0f2222ccceaaa7ffd000e002400d802d00ee02640d582fd0e0e2424d8dad2deeec66695577ff3002a00fc02080c3028a0f3c2288cf32a2afcfe0a043c18885331eaa47fd900d602f40e382490db62db4edba6d9d6d4f6fa361cb44bb9b995957d7f0f02220ccc2aa8fff2002c0);
   crc_out[11] = ^(data_in & 1024'h006001400780110066015407f810106061414787911166675553ffe80070012006c0168077013206ac17e870712126c6d696f7763334aabbff98015007e01040618145079e114467995157e7f05021e0c442998f5523fec806b017a071c12486db16da76dd36ceb6a7b7d1b0e5a25dcdccacabebf878111066615547ff900160);
   crc_out[12] = ^(data_in & 1024'h003000a003c008803300aa03fc08083030a0a3c3c888b333aaa9fff40038009003600b403b809903560bf438389093636b4b7bbb199a555dffcc00a803f0082030c0a283cf08a233cca8abf3f82810f062214cc7aa91ff6403580bd038e092436d8b6d3b6e9b675b53dbe8d872d12ee6e65655f5fc3c08883330aaa3ffc800b0);
   crc_out[13] = ^(data_in & 1024'h0018005001e0044019805501fe040418185051e1e4445999d554fffa001c004801b005a01dc04c81ab05fa1c1c4849b1b5a5bddd8ccd2aaeffe6005401f8041018605141e7845119e65455f9fc1408783110a663d548ffb201ac05e81c704921b6c5b69db74db3ada9edf46c39689773732b2afafe1e044419985551ffe40058);
   crc_out[14] = ^(data_in & 1024'h000c002800f002200cc02a80ff02020c0c2828f0f2222ccceaaa7ffd000e002400d802d00ee02640d582fd0e0e2424d8dad2deeec66695577ff3002a00fc02080c3028a0f3c2288cf32a2afcfe0a043c18885331eaa47fd900d602f40e382490db62db4edba6d9d6d4f6fa361cb44bb9b995957d7f0f02220ccc2aa8fff2002c);
   crc_out[15] = ^(data_in & 1024'hfffbffe7ffaffe1ffbbfe67faafe01fbfbe7e7afae1e1bbba6662aab0005ffe3ffb7fe4ffa5fe23fb37e54fa05e3e3b7b64e4a5a42227332d5510019ffabfe07fbefe79faebe187baee619abaa0603ebf787ceef599c2ab7004dfe53fa17e38fb6de493a496248b24c5256120b93c697688c8cd4d50501e1fbbbe667aaae001b);
 
end // always_comb
endmodule