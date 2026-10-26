// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IQieOracleAggregator} from "../../src/interfaces/IQieOracleAggregator.sol";

/// @notice Mirrors the REAL deployed QIE oracle's interface (see
/// IQieOracleAggregator) so tests exercise the same shape QieOracleAdapter
/// consumes live on Mainnet, without needing network access.
contract MockAggregatorV3 is IQieOracleAggregator {
    uint8 private immutable _decimals;
    string private _description;
    int256 private _answer;
    uint256 private _updatedAt;
    uint80 private _roundId = 1;

    constructor(uint8 decimals_, string memory description_, int256 initialAnswer) {
        _decimals = decimals_;
        _description = description_;
        _answer = initialAnswer;
        _updatedAt = block.timestamp;
    }

    function decimals() external view override returns (uint8) {
        return _decimals;
    }

    function description() external view override returns (string memory) {
        return _description;
    }

    function setAnswer(int256 newAnswer) external {
        _answer = newAnswer;
        _updatedAt = block.timestamp;
        _roundId += 1;
    }

    function setUpdatedAt(uint256 ts) external {
        _updatedAt = ts;
    }

    function latestRoundData()
        external
        view
        override
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound)
    {
        return (_roundId, _answer, _updatedAt, _updatedAt, _roundId);
    }
}
