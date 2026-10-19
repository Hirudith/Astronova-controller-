# Integrating the controller on the PYNQ-Z2

These steps have not yet been run on hardware. Treat them as the starting point
for gate G1's on-board items. They use the standard Vivado block-design flow for
Zynq-7000.

## Block design

1. Add the RTL sources: `rtl/*.v` and the include `rtl/astro_ctrl_defs.vh` (set
   it as a global include or add `rtl/` to the include path).
2. Right-click the canvas and choose **Add Module…**, then pick `astro_ctrl_axil`.
   Vivado infers the `s_axi` AXI4-Lite interface and its clock/reset from the
   port names.
3. Connect:

| Controller port            | Connect to                                                      |
|----------------------------|-----------------------------------------------------------------|
| `s_axi_aclk`               | `FCLK_CLK0` (100 MHz — the default timer values assume this)     |
| `s_axi_aresetn`            | `proc_sys_reset_0/peripheral_aresetn`                           |
| `s_axi`                    | `M_AXI_GP0` via AXI SmartConnect / Interconnect                 |
| `sw_req`, `sw_target`      | payload mode adapter (Block 4)                                  |
| `sw_ack`, `pl_mode`        | payload mode adapter (Block 4)                                  |
| `fault`                    | `IRQ_F2P` (through `xlconcat`)                                  |
| `sw_window`                | EMIO GPIO or the injection controller, to time switch-window campaigns (RQ4) |
| `mode_cmd`, `fallback`, `threat_level` | LEDs / ILA (optional)                               |

4. In the Address Editor, give the controller a 4 KB segment (it decodes 256 B).
5. Parameters: keep `TMR = 1` for the protected build. Build `TMR = 0` as well
   if you want the protected/unprotected vulnerability comparison.
6. Add `astro_ctrl_pblock.xdc` once the instance name is known (check the
   `get_cells` filter).

The RTL carries `DONT_TOUCH` / `KEEP` on the three domains and voters. Check in
the post-synthesis utilisation report that `g_dom[0..2]` all survive. If
`opt_design` has merged them, the TMR is gone even though the design still works.

## Clocking and reset assumptions

* `sw_ack` and `pl_mode` must be synchronous to `s_axi_aclk`. If the payload runs
  on another clock, put a 2-FF synchroniser on `sw_ack` and only sample
  `pl_mode` when it is stable (the 4-phase handshake allows this).
* `s_axi_aresetn` is used as a synchronous reset. After reset the controller is
  in fallback and drives the payload to the fallback mode (TMR by default)
  without any software involvement.

## Software

```python
import sys; sys.path.append("/home/xilinx/astronova_controller/python")
from pynq import Overlay
from astronova.driver import AstroCtrl
from astronova import regs as R

ol = Overlay("astronova.bit")
ctrl = AstroCtrl.from_overlay(ol.astro_ctrl_axil_0)
ctrl.configure(tick_s=1e-3, fresh_to_s=180, dwell_dn_s=600,
               elevated=(R.q88(1.5), R.q88(1.25)), extreme=(R.q88(4.0), R.q88(3.0)),
               modes=(R.M_BASELINE, R.M_TMR, R.M_TMR, R.M_TMR))
ctrl.send(R.q88(1.0))             # one telemetry message (call at the feed cadence)
print(ctrl.status(), ctrl.counters())
```

To replay time-compressed alert timelines on the board, scale `tick_s`,
`fresh_to_s` and the dwell times by the same factor as the timeline.
