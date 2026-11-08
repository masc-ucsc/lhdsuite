// bitcoin miner, leaves first. Paths are relative to this file (slang -F).
//
// The three sha256_* files are secworks/sha256 (BSD-2-Clause, see
// ../LICENSE.sha256); the four bitcoin*.v files are LogikBench (MIT, see
// ../LICENSE); bitcoin_top.v is the suite's NENGINES-pinning wrapper. secworks'
// register-bus top (sha256.v) is NOT vendored: nothing here instantiates it.
sha256_k_constants.v
sha256_w_mem.v
sha256_core.v
bitcoin_compare.v
bitcoin_sha256d.v
bitcoin_engine.v
bitcoin.v
bitcoin_top.v
