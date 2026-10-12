# Extract the worst setup paths from the fitted database so failing
# endpoints can be inspected (run inside the Quartus Docker image:
#   quartus_sta -c SNES -t scripts/tq_failures.tcl
project_open SNES
create_timing_netlist
read_sdc
update_timing_netlist
derive_pll_clocks
derive_clock_uncertainty
update_timing_netlist
report_timing -setup -npaths 12 -detail full_path -file output_files/tq_failures.rpt
report_timing -setup -npaths 40 -detail summary -file output_files/tq_top40.rpt

# HD-only violations: clk_sys and HDMI PLL clocks pass in stock and fail with
# M7_2X_ENABLE — isolate their worst paths (clk_mem CPU->sdram fails in stock
# too and is tracked separately as an upstream issue).
set CLKSYS {emu|pll|pll_inst|altera_pll_i|cyclonev_pll|counter[2].output_counter|divclk}
set CLKHDMI {pll_hdmi|pll_hdmi_inst|altera_pll_i|cyclonev_pll|counter[0].output_counter|divclk}
# clk_mem (DDRAM_CLK, feeds the f2sdram hard-IP inputs): violated -1.93 ns in
# the 2026-10-12 rung-1 fit; extract its worst paths.
set CLKMEM {emu|pll|pll_inst|altera_pll_i|cyclonev_pll|counter[0].output_counter|divclk}
report_timing -setup -npaths 15 -detail full_path -to_clock $CLKSYS -file output_files/tq_clksys.rpt
report_timing -setup -npaths 10 -detail full_path -to_clock $CLKHDMI -file output_files/tq_hdmi.rpt
report_timing -setup -npaths 25 -detail full_path -to_clock $CLKMEM -file output_files/tq_clkmem.rpt
project_close
