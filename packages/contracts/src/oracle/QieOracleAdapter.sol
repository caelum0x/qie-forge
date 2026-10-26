// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IQieOracleAggregator} from "../interfaces/IQieOracleAggregator.sol";

/// @title QieOracleAdapter
/// @notice Normalizes QIE's real, verified oracle contracts (see
/// IQieOracleAggregator — reverse-engineered from live bytecode, NOT the
/// broken `getPrice(string)` signature docs.qie.digital publishes) into an
/// 18-decimal USD price QieForgeVault can use directly, with an explicit
/// staleness check. Fails closed (reverts) for any asset that has no feed
/// configured, rather than guessing — same posture as `OracleClient` in
/// `packages/core` and `QusdcClient`'s env-gated design.
contract QieOracleAdapter is Ownable {
    /// @notice asset => aggregator address. address(0) means "not configured".
    mapping(address => address) public feeds;
    uint256 public maxStalenessSeconds;

    event FeedSet(address indexed asset, address indexed feed);
    event MaxStalenessSet(uint256 seconds_);

    error NoFeedConfigured(address asset);
    error NonPositiveAnswer(address asset, int256 answer);
    error StalePrice(address asset, uint256 updatedAt, uint256 nowTimestamp, uint256 maxStaleness);
    error DecimalsTooLarge(uint8 decimals);

    constructor(address initialOwner, uint256 _maxStalenessSeconds) Ownable(initialOwner) {
        maxStalenessSeconds = _maxStalenessSeconds;
    }

    function setFeed(address asset, address feed) external onlyOwner {
        feeds[asset] = feed;
        emit FeedSet(asset, feed);
    }

    function setMaxStaleness(uint256 seconds_) external onlyOwner {
        maxStalenessSeconds = seconds_;
        emit MaxStalenessSet(seconds_);
    }

    function hasFeed(address asset) external view returns (bool) {
        return feeds[asset] != address(0);
    }

    /// @notice USD price scaled to 1e18, reverting if unconfigured, non-positive, or stale.
    function getPriceUsd18(address asset) public view returns (uint256 price18) {
        address feed = feeds[asset];
        if (feed == address(0)) revert NoFeedConfigured(asset);

        IQieOracleAggregator agg = IQieOracleAggregator(feed);
        (, int256 answer,, uint256 updatedAt,) = agg.latestRoundData();
        if (answer <= 0) revert NonPositiveAnswer(asset, answer);

        if (maxStalenessSeconds > 0 && block.timestamp > updatedAt + maxStalenessSeconds) {
            revert StalePrice(asset, updatedAt, block.timestamp, maxStalenessSeconds);
        }

        uint8 feedDecimals = agg.decimals();
        if (feedDecimals > 18) revert DecimalsTooLarge(feedDecimals);

        price18 = uint256(answer) * (10 ** (18 - feedDecimals));
    }
}
