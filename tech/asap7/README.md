# asap7 cell library for the synthesis benchmarks

`asap7-rvt-ff.lib.gz` is the ASAP7 (7 nm predictive PDK, BSD-3 license) standard-cell library, RVT, FF corner, as one
Liberty file (time unit 1 ps, capacitance 1 fF). The synthesis benchmarks (`bench/synth.sh`, `bench/matrix.sh`) map to it
and time with it; the per-core SDC files (`<core>/synth/*.sdc`) give their numbers in its units (ps).

How it was made: the OpenROAD-flow-scripts asap7 platform (`flow/platforms/asap7/lib/NLDM`, ORFS 55a18b4), the five
files of ORFS's BC (FF, RVT) `LIB_FILES`

    asap7sc7p5t_AO_RVT_FF_nldm_211120.lib.gz
    asap7sc7p5t_INVBUF_RVT_FF_nldm_220122.lib.gz
    asap7sc7p5t_OA_RVT_FF_nldm_211120.lib.gz
    asap7sc7p5t_SIMPLE_RVT_FF_nldm_211120.lib.gz
    asap7sc7p5t_SEQ_RVT_FF_nldm_220123.lib

merged with HighTide's `tools/vslivehd/merge_liberty.py`, with ORFS's `DONT_USE_CELLS` marked dont_use
(`*x1p*_ASAP7*`, `*xp*_ASAP7*`, `SDF*`, `ICG*`). It is the library of the HighTide LiveHD flow
(`HighTide/artifacts/lhd_route/run.py`, `merged_liberty()`).

`lhd` does not read gzipped Liberty: `bench/common.sh` (`require_tech_dir`) decompresses it once per test into the work
dir and records `asap7-rvt-ff-<sha256 prefix>` as the PDK version.
