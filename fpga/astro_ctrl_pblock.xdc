# astro_ctrl_pblock.xdc -- placement template for the Astronova controller
# on the PYNQ-Z2 (XC7Z020-1CLG400C). Add as a constraints file after the block
# design is generated; adjust the cell filter if your instance names differ.
#
# Why: the controller's "own vulnerability is measured rather than assumed".
# Confining it to a known Pblock gives a known set of configuration frames, so
# the SEM IP campaign can target the controller's essential bits separately
# from the payload's (filter the essential-bits list by frame address range).

# ---------------------------------------------------------------------------
# Whole controller (protected core, voters, diagnostics, AXI adaptor)
# ---------------------------------------------------------------------------
create_pblock pblock_astro_ctrl
add_cells_to_pblock [get_pblocks pblock_astro_ctrl] \
    [get_cells -hierarchical -filter {NAME =~ */astro_ctrl_axil_0/inst && IS_PRIMITIVE == 0}]
# One clock-region-sized area; the TMR build needs roughly 5k LUTs / 2k FFs.
resize_pblock [get_pblocks pblock_astro_ctrl] -add {SLICE_X0Y100:SLICE_X31Y149}
set_property CONTAIN_ROUTING true [get_pblocks pblock_astro_ctrl]
set_property EXCLUDE_PLACEMENT true [get_pblocks pblock_astro_ctrl]

# ---------------------------------------------------------------------------
# Optional (hypothesis H4): one Pblock per TMR domain, so that a single
# shared-resource fault cannot reach two replicas. Uncomment to use; the three
# areas must sit inside pblock_astro_ctrl.
# ---------------------------------------------------------------------------
# foreach d {0 1 2} {
#     create_pblock pblock_astro_dom$d
#     add_cells_to_pblock [get_pblocks pblock_astro_dom$d] \
#         [get_cells -hierarchical -filter "NAME =~ */u_ctrl/g_tmr.g_dom\[$d\].* && IS_PRIMITIVE == 0"]
#     set_property PARENT pblock_astro_ctrl [get_pblocks pblock_astro_dom$d]
# }
# resize_pblock [get_pblocks pblock_astro_dom0] -add {SLICE_X0Y100:SLICE_X9Y149}
# resize_pblock [get_pblocks pblock_astro_dom1] -add {SLICE_X10Y100:SLICE_X19Y149}
# resize_pblock [get_pblocks pblock_astro_dom2] -add {SLICE_X20Y100:SLICE_X31Y149}
