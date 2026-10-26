// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @title QieForgeERC20
/// @notice LP share token minted/burned by a QieForgePair. Thin wrapper
/// around OpenZeppelin's audited ERC20 (standard library dependency, same
/// category as using viem/web3 off-chain — not protocol logic copied from
/// a competing DEX).
abstract contract QieForgeERC20 is ERC20 {
    constructor() ERC20("QIE Forge LP", "QFLP") {}

    function _mintShares(address to, uint256 amount) internal {
        _mint(to, amount);
    }

    function _burnShares(address from, uint256 amount) internal {
        _burn(from, amount);
    }
}
