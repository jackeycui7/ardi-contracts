// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice Subset of AWPAllocator we use for v3 eligibility.
///         The KYA-delegated staking flow allocates without binding the agent
///         to the provider in AWPRegistry; this view exposes the allocation
///         directly and is the canonical query per AWP dev (2026-04-30).
interface IAWPAllocator {
    function getAgentStake(address staker, address agent, uint256 worknetId)
        external
        view
        returns (uint256);
}
