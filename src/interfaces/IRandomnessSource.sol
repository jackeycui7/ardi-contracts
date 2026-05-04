// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title Randomness source abstraction.
/// @notice Lets us swap a Mock for tests with a real Chainlink VRF
///         adapter on Base mainnet without changing ArdiEpochDraw.
interface IRandomnessSource {
    /// @notice Request randomness. Caller must implement the callback.
    /// @return requestId The request identifier.
    function requestRandomness() external returns (uint256 requestId);
}

/// @title Receiver of randomness via callback.
interface IRandomnessReceiver {
    /// @notice Called by the randomness source when the value is ready.
    /// @param  requestId  The id returned from `requestRandomness`.
    /// @param  randomness Pseudorandom 256-bit word.
    function onRandomness(uint256 requestId, uint256 randomness) external;
}
