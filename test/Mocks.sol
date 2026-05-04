// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IAWPRegistry} from "../src/interfaces/IAWPRegistry.sol";

/// @notice Mock ERC-20 used in tests as $AWP. burn() / mint() let tests
///         exercise the controller's reserve / claim accounting.
contract MockAWP is ERC20 {
    constructor() ERC20("AWP-mock", "AWP") {
        _mint(msg.sender, 100_000_000 ether);
    }

    function burn(uint256 amount) external {
        _burn(msg.sender, amount);
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/// @notice Mock ArdiEpochDraw for ArdiNFT/inscribe unit tests. Lets a test
///         arbitrarily declare "agent X won (epoch, wordId) with answer (hash,
///         power, lang)". The real ArdiEpochDraw is exercised separately in
///         ArdiEpochDraw.t.sol.
contract MockEpochDraw {
    struct Ans {
        bytes32 wordHash;
        uint16 power;
        uint8 languageId;
        bool published;
    }

    mapping(uint256 => mapping(uint256 => address)) public winners;
    mapping(uint256 => mapping(uint256 => Ans)) private _answers;
    mapping(address => uint8) public agentWinCount;

    function setWinner(uint256 epochId, uint256 wordId, address w) external {
        winners[epochId][wordId] = w;
    }

    function setAnswer(uint256 epochId, uint256 wordId, string calldata word, uint16 power, uint8 languageId)
        external
    {
        _answers[epochId][wordId] = Ans(keccak256(bytes(word)), power, languageId, true);
    }

    function setAnswerHash(uint256 epochId, uint256 wordId, bytes32 wordHash, uint16 power, uint8 languageId)
        external
    {
        _answers[epochId][wordId] = Ans(wordHash, power, languageId, true);
    }

    function setAgentWinCount(address a, uint8 n) external {
        agentWinCount[a] = n;
    }

    function getAnswer(uint256 epochId, uint256 wordId)
        external
        view
        returns (bytes32 wordHash, uint16 power, uint8 languageId, bool published)
    {
        Ans memory a = _answers[epochId][wordId];
        return (a.wordHash, a.power, a.languageId, a.published);
    }
}

/// @notice Mock AWPRegistry for tests + local deploy. Lets test code set
///         (agent, worknetId) → (isValid, stake, root, recipient).
///         Real AWPRegistry on rootnet does this via bind() + setRecipient()
///         + AWPAllocator.allocate(). Mock is just storage + setters.
contract MockAWPRegistry is IAWPRegistry {
    struct Entry {
        address root;
        bool isValid;
        uint256 stake;
        address rewardRecipient;
    }
    mapping(address => mapping(uint256 => Entry)) private _entries;

    /// @notice Test helper: set everything for one (agent, worknet) cell.
    function setAgent(
        address agent,
        uint256 worknetId,
        address root,
        bool isValid,
        uint256 stake,
        address rewardRecipient
    ) external {
        _entries[agent][worknetId] = Entry(root, isValid, stake, rewardRecipient);
    }

    /// @notice Common case: agent self-stakes, valid, with given amount.
    function selfStake(address agent, uint256 worknetId, uint256 amount) external {
        _entries[agent][worknetId] = Entry(agent, true, amount, agent);
    }

    function getAgentInfo(address agent, uint256 worknetId)
        external
        view
        override
        returns (AgentInfo memory)
    {
        Entry storage e = _entries[agent][worknetId];
        return AgentInfo(e.root, e.isValid, e.stake, e.rewardRecipient);
    }
}
