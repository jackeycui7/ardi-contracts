// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice Subset of EpochDraw v3 that ArdiNFT consumes. Adds element to the
///         answer payload (Q13: element revealed at publishAnswers time, in vault
///         leaf, so EpochDraw publishes it alongside power+lang).
interface IArdiEpochDrawV3 {
    function winners(uint256 epochId, uint256 wordId) external view returns (address);

    function getAnswer(uint256 epochId, uint256 wordId)
        external
        view
        returns (
            bytes32 wordHash,
            uint16 power,
            uint8 languageId,
            uint8 maxDurability,
            uint8 element,
            bool published
        );

    function agentWinCount(address agent) external view returns (uint8);
}
