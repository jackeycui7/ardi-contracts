// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title ICoordinator — interface declaring the data Coordinator signs off-chain
/// @notice The Coordinator service runs riddle epochs, verifies submissions, and
///         signs mint / fusion authorizations. The on-chain contracts verify those
///         signatures via ECDSA against a registered Coordinator public key. This
///         interface documents the canonical hash structures.
/// @dev    No on-chain implementation is required for this interface — it exists
///         purely to anchor the off-chain protocol in code review.
interface ICoordinator {
    /// @dev Authorization payload signed by Coordinator for ArdiNFT.inscribe.
    ///      hash = keccak256(abi.encodePacked(
    ///          "ARDI_INSCRIBE_V1", chainId, contract, wordId, word,
    ///          power, languageId, agent, epochId
    ///      ))
    struct InscribeAuth {
        uint256 wordId;
        string word;
        uint8 power;
        uint8 languageId;
        address agent;
        uint64 epochId;
    }

    /// @dev Authorization payload signed by Coordinator for ArdiNFT.fuse.
    ///      v3 layout (per-holder nonce; binds the holder explicitly):
    ///      hash = keccak256(abi.encodePacked(
    ///          "ARDI_FUSE_V3", chainId, contract, holder, tokenIdA, tokenIdB,
    ///          newWord, newPower, newLanguageId, success, holderNonce
    ///      ))
    ///      where holderNonce = ArdiNFT.fusionNonceOf(holder).
    struct FuseAuth {
        address holder;
        uint256 tokenIdA;
        uint256 tokenIdB;
        string newWord;
        uint16 newPower;
        uint8 newLanguageId;
        bool success;
        uint256 holderNonce;
    }
}
