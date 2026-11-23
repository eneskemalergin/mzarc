# Vendored wthecksum crc32

This directory is a copy of wthecksum `crc32` 0.1.0, a Zig CRC-32/ISO-HDLC library by the author of mzarc. mzarc computes its block and source-document checksums with it. The files are exactly the package files that its `build.zig.zon` lists, with one change: `src/arm_crc.zig` passes the 8-byte `crc32x` operand through `"{x2}"` instead of `"{w2}"`, so the AArch64 CRC path reads all eight bytes of each word. This README is the only addition.

The copy ships under mzarc's MIT license (`../../LICENSE`). Once the library's own repository is published, mzarc replaces this directory with a URL and hash dependency.

The library selects PCLMUL or VEX.128 PCLMUL at run time on x86-64, AArch64 CRC or PMULL where present, and keeps a portable slicing-by-16 path for every other processor.
