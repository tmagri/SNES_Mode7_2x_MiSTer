# Probe the fitted netlist: do the DDR3 client handshake registers exist,
# and are there timing paths from the clk_sys clients into ddram's FSM?
project_open SNES
create_timing_netlist
read_sdc
update_timing_netlist
derive_pll_clocks
derive_clock_uncertainty
update_timing_netlist

# 1) Do the registers exist?
foreach r {*mb_we_req* *ddram|state* *ddram|ram_write* *ddram|we_ack* *active_client*} {
    post_message "==== registers matching $r ===="
    foreach_in_collection reg [get_registers -nowarn $r] {
        post_message "  [get_register_info $reg -name]"
    }
}

# 2) Timing from the mailbox we_req register into ddram (any clock pair)
post_message "==== paths FROM *mb_we_req* ===="
report_timing -from {*mb_we_req*} -setup -npaths 5 -detail summary \
    -panel_name "tqprobe:req" -file output_files/tq_ddram_from_wereq.rpt
post_message "==== paths TO ddram|state ===="
report_timing -to {ddram|state} -setup -npaths 8 -detail summary \
    -panel_name "tqprobe:state" -file output_files/tq_ddram_to_state.rpt
post_message "==== paths TO ddram|ram_write ===="
report_timing -to {ddram|ram_write} -setup -npaths 8 -detail summary \
    -panel_name "tqprobe:rw" -file output_files/tq_ddram_to_ramwrite.rpt

project_close
