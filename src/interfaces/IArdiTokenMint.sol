// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface IArdiTokenMint {
    function mint(address to, uint256 amount) external;
    function totalSupply() external view returns (uint256);
}
