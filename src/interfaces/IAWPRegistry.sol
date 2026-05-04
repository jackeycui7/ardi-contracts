// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title IAWPRegistry — minimal read interface for Ardi eligibility checks.
/// @notice Mirrors AWPRegistry.getAgentInfo from the AWP RootNet protocol.
///         Ardi is a consumer; it only reads. The full AWPRegistry has many
///         more methods (bind / register / delegate / setRecipient) that
///         we don't depend on here.
///
/// Eligibility model:
///   * Each agent address is bound (via AWPRegistry.bind) to a "root"
///     staker — the address that physically holds the locked AWP.
///     If self-bound or not bound, root == agent itself.
///   * `getAgentStake(root, agent, worknetId)` on AWPAllocator returns
///     how much of root's staked AWP has been allocated to (agent, WN).
///   * `getAgentInfo` walks the binding chain and returns the canonical
///     stake for that agent on a given WN, regardless of who staked it.
interface IAWPRegistry {
    struct AgentInfo {
        /// @dev The resolved root staker for this agent (binding chain
        ///      head). If agent is self-bound, root == agent.
        address root;
        /// @dev True iff the agent has either been bound to a root via
        ///      AWPRegistry.bind() OR set their reward recipient via
        ///      setRecipient(). Used by Ardi to require explicit AWP
        ///      registration before participation.
        bool isValid;
        /// @dev The amount root has allocated to (agent, worknetId)
        ///      via AWPAllocator.allocate.
        uint256 stake;
        /// @dev The configured reward recipient for the root (or root
        ///      itself if no override).
        address rewardRecipient;
    }

    function getAgentInfo(address agent, uint256 worknetId)
        external
        view
        returns (AgentInfo memory);
}
