# Changelog

## 0.1.0 (unreleased)

- Add a Zig package manifest, explicit source archive, standard optimization options, and a build option that disables every accelerated CRC path.
- Expose `hash`, `update`, `combine`, `Stream`, `Backend`, and `backendFor` with finalized CRC-32/ISO-HDLC words. Combining accepts a 64-bit byte length.
- Replace the repeated-work benchmark command with `zig-crc32`, bounded streaming reads, memory mode, hexadecimal checksum lines, filename escaping, and explicit exit statuses.
- Remove benchmark report exports and the deleted kernel runner's build dependency.
- Correct two PMULL reduction products to use the low register half with the high stored key. A compile-time arithmetic test fails with the previous selections and passes with the corrected selections; native Arm execution remains unverified.
- Preserve discovery of the other Arm feature when one feature is guaranteed by the compile target.
- Skip x86 CPU feature lookup below 16 bytes and cache the selected x86 update function. Process portable tails with existing 8-byte and 4-byte table slices.
- Use VEX.128 PCLMUL with SSSE3 and OS-enabled AVX state without requiring the wide VPCLMUL feature. Keep a separately checked legacy PCLMUL/SSSE3 path.
- Add vector handling of partial x86 blocks, a three-product polynomial reduction, and the Chorba block-elimination loop for inputs of at least 1,024 bytes.
- Coalesce short stream updates in a fixed 256-byte pending array, process remaining slices of at least 64 bytes directly, and include pending bytes in nonconsuming finalization.
- Retain the 64 KiB default command buffer and omit the alternate signal stack when the standard debug segmentation-fault handler is disabled.
- Add public API, direct-backend, protected-page, bounded fuzz, PMULL arithmetic, and executable tests, plus package and development guides.

This version number identifies the initial package. No published release or cross-target speed result is claimed.
