// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IQieForgeFactory} from "./interfaces/IQieForgeFactory.sol";
import {QieForgePair} from "./QieForgePair.sol";

/// @title QieForgeFactory
/// @notice Deploys one QieForgePair per unordered token pair via CREATE2 so
/// a pair's address is deterministically predictable off-chain (any
/// constant-product DEX design arrives at this independently — it is the
/// only way to let a router compute pool addresses without an extra
/// storage read per hop).
contract QieForgeFactory is IQieForgeFactory {
    address public override feeTo;
    address public override feeToSetter;

    mapping(address => mapping(address => address)) public override getPair;
    address[] public override allPairs;

    error IdenticalAddresses();
    error ZeroAddress();
    error PairExists();
    error Forbidden();

    constructor(address _feeToSetter) {
        if (_feeToSetter == address(0)) revert ZeroAddress();
        feeToSetter = _feeToSetter;
    }

    function allPairsLength() external view override returns (uint256) {
        return allPairs.length;
    }

    function createPair(address tokenA, address tokenB) external override returns (address pair) {
        if (tokenA == tokenB) revert IdenticalAddresses();
        (address token0, address token1) = tokenA < tokenB ? (tokenA, tokenB) : (tokenB, tokenA);
        if (token0 == address(0)) revert ZeroAddress();
        if (getPair[token0][token1] != address(0)) revert PairExists();

        bytes32 salt = keccak256(abi.encodePacked(token0, token1));
        pair = address(new QieForgePair{salt: salt}());
        QieForgePair(pair).initialize(token0, token1);

        getPair[token0][token1] = pair;
        getPair[token1][token0] = pair;
        allPairs.push(pair);
        emit PairCreated(token0, token1, pair, allPairs.length);
    }

    function setFeeTo(address _feeTo) external override {
        if (msg.sender != feeToSetter) revert Forbidden();
        feeTo = _feeTo;
    }

    function setFeeToSetter(address _feeToSetter) external override {
        if (msg.sender != feeToSetter) revert Forbidden();
        if (_feeToSetter == address(0)) revert ZeroAddress();
        feeToSetter = _feeToSetter;
    }

    /// @notice Predicts a pair's CREATE2 address without deploying it, for
    /// off-chain routing (mirrors the salt/init-code-hash scheme used in
    /// `createPair`).
    function pairFor(address tokenA, address tokenB) external view returns (address predicted) {
        (address token0, address token1) = tokenA < tokenB ? (tokenA, tokenB) : (tokenB, tokenA);
        bytes32 salt = keccak256(abi.encodePacked(token0, token1));
        bytes32 initCodeHash = keccak256(type(QieForgePair).creationCode);
        predicted = address(
            uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), address(this), salt, initCodeHash))))
        );
    }
}
