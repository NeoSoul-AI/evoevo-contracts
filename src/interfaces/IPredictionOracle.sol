// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title IPredictionOracle
/// @notice Minimal prediction oracle read interface consumed by the current
/// committee oracle integration and downstream tooling.
interface IPredictionOracle {
    function getPredictionOutcome(uint256 predictionId) external view returns (bool resolved, uint8 outcome);

    function getPredictionResolution(uint256 predictionId)
        external
        view
        returns (bool resolved, uint8 resolutionKind, uint8 winningOptionIndex);
}
