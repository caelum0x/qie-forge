// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @notice The REAL interface implemented by QIE's deployed oracle
/// contracts (0x9E596d... BTC, 0x3Bc617cF... QIE, etc). docs.qie.digital
/// documents a different, incorrect `getPrice(string)` signature that
/// reverts on-chain — this interface is reverse-engineered from the actual
/// deployed bytecode's function selectors and confirmed via live eth_call
/// (see packages/core/src/oracle.ts for the full verification notes and
/// packages/contracts/test/QieOracleAdapter.t.sol for the on-chain
/// consumer's tests). It matches the widely-used Chainlink
/// AggregatorV3Interface shape.
interface IQieOracleAggregator {
    function decimals() external view returns (uint8);
    function description() external view returns (string memory);
    function latestRoundData()
        external
        view
        returns (
            uint80 roundId,
            int256 answer,
            uint256 startedAt,
            uint256 updatedAt,
            uint80 answeredInRound
        );
}
