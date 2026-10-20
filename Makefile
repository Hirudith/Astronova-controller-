# Astronova protection controller -- verification and resource estimates.
#
#   make all        lint + python tests + directed + co-simulation + injection
#   make synth      Yosys 7-series resource estimates (controller, payload variants)
#   make analysis   Blocks 1/2/5 pipeline (V1, placeholder inputs) -> build/analysis/
#
# Tools: iverilog (>= 11), verilator (>= 5, for --timing), yosys, python3.

BUILD   := build
RTL_DIR := rtl
CORE    := $(RTL_DIR)/astro_ctrl_tmr.v $(RTL_DIR)/tmr_voter.v $(RTL_DIR)/astro_ctrl_core.v
RTL     := $(RTL_DIR)/astro_ctrl_axil.v $(RTL_DIR)/axil_slave.v $(CORE) $(RTL_DIR)/astro_ctrl_diag.v
PAYLOAD := $(RTL_DIR)/payload/pl_axil.v $(RTL_DIR)/payload/pl_switchable.v \
           $(RTL_DIR)/payload/pl_workload.v $(RTL_DIR)/axil_slave.v $(RTL_DIR)/tmr_voter.v
SYSTEM  := $(RTL_DIR)/astro_ctrl_axil.v $(RTL_DIR)/astro_ctrl_tmr.v $(RTL_DIR)/astro_ctrl_core.v \
           $(RTL_DIR)/astro_ctrl_diag.v $(PAYLOAD)
GOLDEN  := python3 python/astronova/payload.py --n 8000
SEEDS   := 1 2 3
CYCLES  := 300000
VFLAGS  := --binary --timing -Wno-fatal -Wno-WIDTH -Wno-STMTDLY -Wno-INITIALDLY -I$(RTL_DIR) -j 0

.PHONY: all lint pytest directed cosim inject system synth analysis clean

all: lint pytest directed cosim inject system
	@echo "== all checks passed"

$(BUILD):
	mkdir -p $(BUILD)

lint:
	verilator --lint-only -Wall -I$(RTL_DIR) -GTMR=1 --top-module astro_ctrl_axil $(RTL)
	verilator --lint-only -Wall -I$(RTL_DIR) -GTMR=0 --top-module astro_ctrl_axil $(RTL)
	@for v in 0 1 2; do verilator --lint-only -Wall -I$(RTL_DIR) "-GVARIANT=8'd$$v" --top-module pl_axil $(PAYLOAD) || exit 1; done
	@echo "== lint clean (controller TMR=1/0, payload variants 0/1/2)"

pytest:
	cd python && python3 -m unittest discover -s tests

directed: | $(BUILD)
	iverilog -g2005 -I$(RTL_DIR) -o $(BUILD)/directed.vvp tb/tb_directed.v $(RTL)
	vvp -n $(BUILD)/directed.vvp | tee $(BUILD)/directed.log
	@grep -q "^PASS" $(BUILD)/directed.log

# Long randomised runs on Verilator, both builds, several seeds
cosim: | $(BUILD)
	verilator $(VFLAGS) --top-module tb_cosim -GTMR=1 -Mdir $(BUILD)/vc1 -o vcosim tb/tb_cosim.v $(CORE) > $(BUILD)/vc1.log 2>&1
	verilator $(VFLAGS) --top-module tb_cosim -GTMR=0 -Mdir $(BUILD)/vc0 -o vcosim tb/tb_cosim.v $(CORE) > $(BUILD)/vc0.log 2>&1
	@set -e; for s in $(SEEDS); do \
	  python3 python/gen_cosim.py --cycles $(CYCLES) --seed $$s --out $(BUILD)/trace_$$s.hex; \
	  for t in 1 0; do \
	    $(BUILD)/vc$$t/vcosim +TRACE=$(BUILD)/trace_$$s.hex | tee $(BUILD)/cosim_$${t}_$$s.log | grep -E "PASS|FAIL"; \
	    grep -q "^PASS" $(BUILD)/cosim_$${t}_$$s.log; \
	  done; \
	done

# Upset injection into the state registers (Icarus: honours hierarchical writes)
inject: | $(BUILD)
	python3 python/gen_cosim.py --cycles 20000 --seed 11 --out $(BUILD)/trace_inj.hex > /dev/null
	iverilog -g2005 -I$(RTL_DIR) -DINJECT -o $(BUILD)/cosim_inj.vvp tb/tb_cosim.v $(CORE)
	vvp -n $(BUILD)/cosim_inj.vvp +TRACE=$(BUILD)/trace_inj.hex +INJECT=500 | tee $(BUILD)/inject_single.log | grep -E "inject|PASS|FAIL"
	@grep -q "^PASS" $(BUILD)/inject_single.log
	@echo "-- negative control: the same bit in two replicas must be caught as a mismatch"
	vvp -n $(BUILD)/cosim_inj.vvp +TRACE=$(BUILD)/trace_inj.hex +INJECT=5 +DOUBLE | tee $(BUILD)/inject_double.log | grep -E "inject|PASS|FAIL"
	@grep -q "^FAIL" $(BUILD)/inject_double.log && echo "== negative control behaved as expected"

# Controller + payload, every payload variant: switching never corrupts the
# workload, upsets are hidden where they must be, negative controls are caught
system: | $(BUILD)
	@set -e; for v in SWITCH STATIC BASE; do \
	  iverilog -g2005 -I$(RTL_DIR) -DVAR_$$v -o $(BUILD)/system_$$v.vvp tb/tb_system.v $(SYSTEM); \
	  vvp -n $(BUILD)/system_$$v.vvp $$($(GOLDEN) --seed 0x1234abcd --plusargs A) \
	      $$($(GOLDEN) --seed 0x0badf00d --plusargs B) | tee $(BUILD)/system_$$v.log | grep -E "switch|mode [0-3]|upsets|PASS|FAIL"; \
	  grep -q "^PASS" $(BUILD)/system_$$v.log; \
	done

# Blocks 1, 2, 5: break-even table, alert-quality sweep, RQ1 check (V1, placeholder inputs)
analysis: | $(BUILD)
	cd python && python3 run_analysis.py --samples 100 --out ../$(BUILD)/analysis

synth: | $(BUILD)
	@for t in 1 0; do \
	  yosys -q -l $(BUILD)/synth_tmr$$t.log -p "read_verilog -I$(RTL_DIR) $(RTL); \
	    chparam -set TMR $$t astro_ctrl_axil; synth_xilinx -family xc7 -top astro_ctrl_axil; \
	    tee -o $(BUILD)/synth_tmr$$t.txt stat -top astro_ctrl_axil" > /dev/null; \
	  echo "TMR=$$t: $$(python3 python/synth_summary.py $(BUILD)/synth_tmr$$t.txt)"; \
	done
	@for v in 0 1 2; do \
	  yosys -q -l $(BUILD)/synth_pl$$v.log -p "read_verilog -I$(RTL_DIR) $(PAYLOAD); \
	    chparam -set VARIANT $$v pl_axil; synth_xilinx -family xc7 -top pl_axil; \
	    tee -o $(BUILD)/synth_pl$$v.txt stat -top pl_axil" > /dev/null; \
	  echo "payload VARIANT=$$v: $$(python3 python/synth_summary.py $(BUILD)/synth_pl$$v.txt)"; \
	done

clean:
	rm -rf $(BUILD)
