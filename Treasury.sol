// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/**
 * @title Treasury
 * @dev Secure treasury vault for COSMORYN NETWORK fees, ecosystem fund management, and buyback & burn mechanics on Ethereum.
 * Designed to be controlled by Gnosis Safe multi-signature wallet or DAO timelock.
 */
contract Treasury is AccessControl, Pausable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    bytes32 public constant PROPOSER_ROLE = keccak256("PROPOSER_ROLE");
    bytes32 public constant EXECUTOR_ROLE = keccak256("EXECUTOR_ROLE");
    bytes32 public constant PAUSER_ROLE = keccak256("PAUSER_ROLE");

    IERC20 public immutable cmrToken;

    struct ProposedTx {
        uint256 id;
        address target;
        uint256 value;
        bytes data;
        string description;
        bool executed;
        uint256 proposedAt;
    }

    uint256 public nextTxId = 1;
    mapping(uint256 => ProposedTx) public proposedTxs;
    uint256 public executionDelay = 1 days;
    uint256 public maxTxValue = 50 ether;
    uint256 public maxTokenTxValue = 5_000_000 ether;
    mapping(address => bool) public callTargetAllowlist;

    event FundsDeposited(address indexed sender, uint256 amount);
    event TokenDeposited(address indexed token, address indexed sender, uint256 amount);
    event TokenWithdrawn(address indexed token, address indexed recipient, uint256 amount);
    event TransactionProposed(uint256 indexed txId, address indexed target, uint256 value, string description);
    event TransactionExecuted(uint256 indexed txId, address indexed target, uint256 value);
    event BuybackBurnExecuted(uint256 cmrAmountBurned);
    event EthWithdrawn(address indexed recipient, uint256 amount);
    event TargetAllowlistUpdated(address indexed target, bool allowed);
    event TreasuryLimitsUpdated(uint256 executionDelay, uint256 maxTxValue);
    event TreasuryTokenLimitsUpdated(uint256 maxTokenTxValue);

    constructor(IERC20 _cmrToken, address admin) {
        require(address(_cmrToken) != address(0), "Invalid token");
        require(admin != address(0), "Invalid admin");

        cmrToken = _cmrToken;
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(PROPOSER_ROLE, admin);
        _grantRole(EXECUTOR_ROLE, admin);
        _grantRole(PAUSER_ROLE, admin);
    }

    receive() external payable {
        emit FundsDeposited(msg.sender, msg.value);
    }

    function proposeTransaction(
        address target,
        uint256 value,
        bytes calldata data,
        string calldata description
    ) external onlyRole(PROPOSER_ROLE) returns (uint256) {
        require(target != address(0), "Invalid target");
        require(callTargetAllowlist[target], "Target not allowlisted");
        require(value <= maxTxValue, "Value exceeds cap");
        require(value <= address(this).balance, "Insufficient treasury balance");

        uint256 txId = nextTxId++;
        proposedTxs[txId] = ProposedTx({
            id: txId,
            target: target,
            value: value,
            data: data,
            description: description,
            executed: false,
            proposedAt: block.timestamp
        });

        emit TransactionProposed(txId, target, value, description);
        return txId;
    }

    function executeTransaction(uint256 txId) external onlyRole(EXECUTOR_ROLE) whenNotPaused nonReentrant {
        ProposedTx storage pTx = proposedTxs[txId];
        require(pTx.id != 0, "Transaction does not exist");
        require(!pTx.executed, "Transaction already executed");
        require(block.timestamp >= pTx.proposedAt + executionDelay, "Timelock not elapsed");
        require(callTargetAllowlist[pTx.target], "Target not allowlisted");
        require(pTx.value <= maxTxValue && pTx.value <= address(this).balance, "Value exceeds cap");

        pTx.executed = true;

        (bool success, ) = pTx.target.call{ value: pTx.value }(pTx.data);
        require(success, "Treasury call failed");

        emit TransactionExecuted(txId, pTx.target, pTx.value);
    }

    function executeBuybackAndBurn(uint256 cmrAmount) external onlyRole(EXECUTOR_ROLE) whenNotPaused nonReentrant {
        require(cmrAmount > 0, "Amount must be > 0");
        require(cmrToken.balanceOf(address(this)) >= cmrAmount, "Insufficient CMR in treasury");

        ERC20Burnable(address(cmrToken)).burn(cmrAmount);

        emit BuybackBurnExecuted(cmrAmount);
    }

    function withdrawToken(
        IERC20 token,
        address recipient,
        uint256 amount
    ) external onlyRole(EXECUTOR_ROLE) whenNotPaused nonReentrant {
        require(address(token) != address(0), "Invalid token");
        require(recipient != address(0), "Invalid recipient");
        require(callTargetAllowlist[recipient], "Recipient not allowlisted");
        require(amount > 0, "Amount must be > 0");
        require(amount <= maxTokenTxValue, "Amount exceeds token cap");
        require(token.balanceOf(address(this)) >= amount, "Insufficient token balance");
        token.safeTransfer(recipient, amount);
        emit TokenWithdrawn(address(token), recipient, amount);
    }

    function withdrawEth(
        address payable recipient,
        uint256 amount
    ) external onlyRole(EXECUTOR_ROLE) whenNotPaused nonReentrant {
        require(recipient != address(0), "Invalid recipient");
        require(callTargetAllowlist[recipient], "Recipient not allowlisted");
        require(amount > 0, "Amount must be > 0");
        require(amount <= maxTxValue, "Amount exceeds cap");
        require(address(this).balance >= amount, "Insufficient ETH balance");

        (bool success, ) = recipient.call{ value: amount }("");
        require(success, "ETH withdrawal failed");

        emit EthWithdrawn(recipient, amount);
    }

    function getEthBalance() public view returns (uint256) {
        return address(this).balance;
    }

    function getCmrBalance() external view returns (uint256) {
        return cmrToken.balanceOf(address(this));
    }

    function setCallTargetAllowlist(address target, bool allowed) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(target != address(0), "Invalid target");
        callTargetAllowlist[target] = allowed;
        emit TargetAllowlistUpdated(target, allowed);
    }

    function setTreasuryLimits(uint256 _delay, uint256 _maxValue) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(_delay <= 14 days, "Delay too long");
        executionDelay = _delay;
        maxTxValue = _maxValue;
        emit TreasuryLimitsUpdated(_delay, _maxValue);
    }

    function setMaxTokenTxValue(uint256 _maxTokenValue) external onlyRole(DEFAULT_ADMIN_ROLE) {
        maxTokenTxValue = _maxTokenValue;
        emit TreasuryTokenLimitsUpdated(_maxTokenValue);
    }

    function pause() external onlyRole(PAUSER_ROLE) {
        _pause();
    }

    function unpause() external onlyRole(PAUSER_ROLE) {
        _unpause();
    }
}
