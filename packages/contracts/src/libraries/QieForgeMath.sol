// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @title QieForgeMath
/// @notice Small, self-contained math helpers for the AMM core. Written from
/// first principles for QIE Forge (integer sqrt via the standard Babylonian
/// method, which is public-domain numerical-methods material, not protocol
/// code copied from any existing DEX).
library QieForgeMath {
    /// @notice Babylonian-method integer square root, rounded down.
    function sqrt(uint256 y) internal pure returns (uint256 z) {
        if (y > 3) {
            z = y;
            uint256 x = y / 2 + 1;
            while (x < z) {
                z = x;
                x = (y / x + x) / 2;
            }
        } else if (y != 0) {
            z = 1;
        }
    }

    function min(uint256 a, uint256 b) internal pure returns (uint256) {
        return a < b ? a : b;
    }
}
