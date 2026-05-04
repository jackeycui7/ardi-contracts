// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC20Burnable} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IArdiTokenMint} from "./interfaces/IArdiTokenMint.sol";

/// @title ArdiToken — $ardi
/// @notice ERC-20 with hard 10B cap. Mint authority is delegated to a single minter
///         contract (ArdiMintController) which emits per the two-phase halving
///         schedule defined in the design spec.
/// @dev    Total supply convention:
///         - 1,000,000,000 (1B) minted at deployment to the LP locker (initial LP).
///         - 9,000,000,000 (9B) minted gradually by ArdiMintController per emission curve.
///         The hard cap of 10B is enforced in _update.
contract ArdiToken is ERC20, ERC20Burnable, Ownable2Step, IArdiTokenMint {
    uint256 public constant MAX_SUPPLY = 10_000_000_000 ether;

    /// @notice The controller authorized to mint on the emission schedule.
    /// @dev    Set once via setMinter() and then locked by renouncing ownership.
    address public minter;
    bool public minterLocked;

    /// @notice True after the one-shot LP mint has been performed.
    bool public lpMinted;

    error NotMinter();
    error MinterAlreadySet();
    error MinterLocked();
    error CapExceeded();
    error ZeroAddress();
    error LpAlreadyMinted();

    event MinterSet(address indexed minter);
    event MinterPermanentlyLocked();

    /// @dev Symbol uses the AWP-standard `a` prefix for worknet tokens
    ///      (e.g. `aMine`, `aPRED`, `aBench`). On mainnet this contract is
    ///      not deployed by us — the AWP framework auto-deploys an
    ///      equivalent worknet token at Guardian activation. This stays in
    ///      the repo for local Anvil testing + e2e fixtures.
    constructor(address initialOwner) ERC20("Ardinal", "aArdi") Ownable(initialOwner) {}

    // --- minter management (one-shot, then locked forever) ---

    /// @notice Designate the sole minter. Callable only by owner, only once.
    function setMinter(address minter_) external onlyOwner {
        if (minterLocked) revert MinterLocked();
        if (minter != address(0)) revert MinterAlreadySet();
        if (minter_ == address(0)) revert ZeroAddress();
        minter = minter_;
        emit MinterSet(minter_);
    }

    /// @notice Permanently lock the minter address. After this call, the minter
    ///         cannot be changed even by owner — and an owner renouncement makes
    ///         the contract maximally trustless.
    function lockMinter() external onlyOwner {
        if (minter == address(0)) revert MinterAlreadySet();
        minterLocked = true;
        emit MinterPermanentlyLocked();
    }

    // --- minting ---

    /// @notice One-shot LP mint. Called by deployment script to seed Uniswap V4 pool.
    /// @dev    Owner-only and **strictly one-shot** — once `lpMinted == true`,
    ///         no further LP mints are possible, even by owner. This is the
    ///         only way (besides emission via the controller) to inflate
    ///         supply, so locking it is critical to a verifiable hard cap.
    function mintLp(address to, uint256 amount) external onlyOwner {
        if (lpMinted) revert LpAlreadyMinted();
        if (totalSupply() + amount > MAX_SUPPLY) revert CapExceeded();
        lpMinted = true;
        _mint(to, amount);
    }

    /// @notice Mint by emission controller per the daily schedule.
    function mint(address to, uint256 amount) external override {
        if (msg.sender != minter) revert NotMinter();
        if (totalSupply() + amount > MAX_SUPPLY) revert CapExceeded();
        _mint(to, amount);
    }

    /// @dev Required to disambiguate between ERC20 and IArdiTokenMint, both of
    ///      which declare totalSupply(). The body just defers to ERC20.
    function totalSupply() public view override(ERC20, IArdiTokenMint) returns (uint256) {
        return ERC20.totalSupply();
    }
}
