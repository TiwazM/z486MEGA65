# Vivado pre-synthesis hook (CORE-R6.xpr, synth_1). Runs in CORE/CORE-R6.runs/synth_1.
#  1. rebuild the QNICE firmware (and keep a copy of its images in the run directory)
#  2. refresh the Vivado 2022.2 copies of the z486 sources (CORE/gen, tools/z486_sources.py)
#  3. copy the CPU's memory images into the run directory: z486 reads them with $readmemh by
#     bare file name
set cur_dir [exec pwd]
cd ../../../CORE/m2m-rom/
exec ./make_rom.sh <@stdin >@stdout 2>@stderr
cd $cur_dir
# the images this netlist is made of: build_r6.sh keeps them next to the routed checkpoint, the
# reference of a firmware patch (build_r6.sh patch)
file copy -force ../../../CORE/m2m-rom/m2m-rom.rom ../../../CORE/m2m-rom/m2m-banks.rom $cur_dir
exec python3 ../../../tools/z486_sources.py >@stdout 2>@stderr
foreach image {z486/ucode.hex z486/pla_entry_rom.hex z486/pla_group_entry.hex z486/x87/x87_ucode.mem} {
    file copy -force ../../../$image $cur_dir
}
