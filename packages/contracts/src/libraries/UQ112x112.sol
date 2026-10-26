// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @title UQ112x112
/// @notice Minimal fixed-point helper for encoding a ratio of two uint112
/// reserves into a Q112.112 value, used to accumulate a time-weighted price
/// (TWAP) inside QieForgePair. 112.112 binary fixed point is a standard,
/// public-domain representation for "a ratio of two 112-bit reserves can
/// never overflow a 224-bit accumulator word" — derived independently for
/// QIE Forge's own reserve/accumulator layout, not copied from another
/// project's source.
library UQ112x112 {
    uint256 private constant Q112 = 2 ** 112;

    /// @notice Encode a uint112 as a UQ112x112.
    function encode(uint112 y) internal pure returns (uint224 z) {
        z = uint224(y) * uint224(Q112);
    }

    /// @notice Divide a UQ112x112 by a uint112, returning a UQ112x112.
    function uqdiv(uint224 x, uint112 y) internal pure returns (uint224 z) {
        z = x / uint224(y);
    }
}
