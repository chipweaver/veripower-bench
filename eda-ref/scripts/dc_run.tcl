# ==============================================================================
# dc_run.tcl — Design Compiler synthesis (bare, manual-level).
#   dc_shell -f scripts/dc_run.tcl | tee run.log
# Env (from env.sh): TOP, LIB_DB, WIRE_LOAD_MODEL. RTL files: analyze the paths in FILELIST
# (default ./filelist.f), one -format sverilog per line (skip blank/#).
# ==============================================================================
foreach _v {TOP LIB_DB WIRE_LOAD_MODEL} {
    if {![info exists ::env($_v)] || $::env($_v) eq ""} {
        puts stderr "ERROR: env var $_v not set (source env.sh)"; exit 1
    }
}
set top    $::env(TOP)
set lib_db $::env(LIB_DB)
set wlm    $::env(WIRE_LOAD_MODEL)
set filelist [expr {[info exists ::env(FILELIST)] ? $::env(FILELIST) : "filelist.f"}]

file mkdir out reports work
set_app_var target_library [list $lib_db]
set_app_var link_library   [list "*" $lib_db]
set_app_var search_path    [concat [list "."] [get_app_var search_path]]
define_design_lib WORK -path ./work

# Analyze each RTL file listed in FILELIST (ignore blanks, comments, -f/+incdir).
set fh [open $filelist r]
foreach line [split [read $fh] "\n"] {
    set line [string trim $line]
    if {$line eq "" || [string match "#*" $line] || [string match "-*" $line] \
        || [string match "+*" $line]} { continue }
    analyze -format sverilog $line
}
close $fh

elaborate $top
current_design $top
link
check_design > reports/check_design.rpt

# Synthesis input (timing-intent) SDC — distinct from env.sh's SDC (output netlist SDC read by STA).
set sdc_in [expr {[info exists ::env(SDC_IN)] ? $::env(SDC_IN) : "constraints/example.sdc"}]
source $sdc_in
# Interconnect estimate: the model named by WIRE_LOAD_MODEL, or none. Set before compile —
# the optimizer buffers for the load it is told to expect, so this moves area, not just reports.
if {$wlm ne "none"} {
    set_wire_load_model -name $wlm
    set_wire_load_mode top
}
# compile_ultra: standard high-effort QoR (what an engineer uses for real timing
# closure). Fall back to basic compile only if compile_ultra is unavailable —
# plain compile under-optimizes and would fail otherwise-closeable timing.
if {![compile_ultra]} {
    if {![compile]} { puts stderr "ERROR: compile failed"; exit 1 }
}

report_qor                                       > reports/qor.rpt
report_area   -hierarchy                         > reports/area.rpt

# The area report is the only reliable signal of what took: set_wire_load_model returns success
# for a name the library does not have, and the design attribute is unset either way. Both
# directions, because a run whose reports disagree with what was asked for is not that run.
set _afh [open reports/area.rpt r]; set _area [read $_afh]; close $_afh
set _unset [regexp {No wire load specified} $_area]
if {$wlm ne "none" && $_unset} {
    puts stderr "ERROR: WIRE_LOAD_MODEL='$wlm' is not in $lib_db (report_lib lists what is)"; exit 1
}
if {$wlm eq "none" && !$_unset} {
    puts stderr "ERROR: WIRE_LOAD_MODEL=none but reports/area.rpt shows an interconnect estimate"; exit 1
}
report_timing -max_paths 20 -nworst 1            > reports/timing_setup.rpt
report_timing -delay min -max_paths 20 -nworst 1 > reports/timing_hold.rpt
report_power                                     > reports/power.rpt

change_names -rules verilog -hierarchy
write -format verilog -hierarchy -output out/${top}_syn.v
write_sdc                                out/${top}_syn.sdc
write_sdf -version 3.0                   out/${top}_syn.sdf
puts "INFO: synthesis done — out/${top}_syn.v"
quit
