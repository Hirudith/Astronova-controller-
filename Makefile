# Astronova protection controller -- verification and resource estimates.
#
#   make all        lint + python tests + directed + co-simulation + injection
#   make synth      Yosys 7-series resource estimate (TMR=1 and TMR=0)
#
# Tools: iverilog (>= 11), verilator (>= 5, for --timing), yosys, python3.

BUILD   := build
RTL_DIR := rtl
CORE    := $(RTL_DIR)/astro_ctrl_tmr.v $(RTL_DIR)/tmr_voter.v $(RTL_DIR)/astro_ctrl_core.v
RTL     := $(RTL_DIR)/astro_ctrl_axil.v $(CORE) $(RTL_DIR)/astro_ctrl_diag.v
SEEDS   := 1 2 3
CYCLES  := 300000
VFLAGS  := --binary --timing -Wno-fatal -Wno-WIDTH -Wno-STMTDLY -Wno-INITIALDLY -I$(RTL_DIR) -j 0

.PHONY: all lint pytest directed cosim inject synth clean

all: lint pytest directed cosim inject
	@echo "== all checks passed"

$(BUILD):
	mkdir -p $(BUILD)

lint:
	verilator --lint-only -Wall -I$(RTL_DIR) -GTMR=1 --top-module astro_ctrl_axil $(RTL)
	verilator --lint-only -Wall -I$(RTL_DIR) -GTMR=0 --top-module astro_ctrl_axil $(RTL)
	@echo "== lint clean (TMR=1, TMR=0)"

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

synth: | $(BUILD)
	@for t in 1 0; do \
	  yosys -q -l $(BUILD)/synth_tmr$$t.log -p "read_verilog -I$(RTL_DIR) $(RTL); \
	    chparam -set TMR $$t astro_ctrl_axil; synth_xilinx -family xc7 -top astro_ctrl_axil; \
	    tee -o $(BUILD)/synth_tmr$$t.txt stat -top astro_ctrl_axil" > /dev/null; \
	  echo "TMR=$$t: $$(python3 python/synth_summary.py $(BUILD)/synth_tmr$$t.txt)"; \
	done

clean:
	rm -rf $(BUILD)
