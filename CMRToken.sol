// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/ERC20Pausable.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/ERC20Votes.sol";
import "@openzeppelin/contracts/utils/Nonces.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";

/**
 * @title CMRToken
 * @dev Main governance and utility token of the COSMORYN NETWORK on Ethereum.
 * Fixed maximum supply of 5,000,000,000 CMR (5 Billion).
 * Includes EIP-2612 permit functionality for gasless approvals on Ethereum,
 * plus ERC20Votes checkpoints so DAO voting power is historical
 * (flash-loan / transfer-and-revote resistant).
 */
contract CMRToken is ERC20, ERC20Burnable, ERC20Pausable, ERC20Permit, ERC20Votes, AccessControl {
    bytes32 public constant MINTER_ROLE = keccak256("MINTER_ROLE");
    bytes32 public constant PAUSER_ROLE = keccak256("PAUSER_ROLE");

    uint256 public constant MAX_SUPPLY = 5_000_000_000 * 10 ** 18; // 5 Billion CMR

    constructor(
        address admin,
        address initialRecipient,
        uint256 initialMintAmount
    ) ERC20("COSMORYN NETWORK Token", "CMR") ERC20Permit("COSMORYN NETWORK Token") {
        require(admin != address(0), "Invalid admin address");
        require(initialRecipient != address(0), "Invalid recipient address");
        require(initialMintAmount <= MAX_SUPPLY, "Exceeds max supply");

        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(PAUSER_ROLE, admin);
        _grantRole(MINTER_ROLE, admin);

        if (initialMintAmount > 0) {
            _mint(initialRecipient, initialMintAmount);
        }
    }

    /**
     * @dev Mint new CMR tokens. Only accounts with MINTER_ROLE can mint.
     * Capped strictly at MAX_SUPPLY (5 Billion CMR).
     */
    function mint(address to, uint256 amount) external onlyRole(MINTER_ROLE) {
        require(totalSupply() + amount <= MAX_SUPPLY, "Cap exceeded: max 5B CMR");
        _mint(to, amount);
    }

    /**
     * @dev Pause token transfers in case of emergency.
     */
    function pause() external onlyRole(PAUSER_ROLE) {
        _pause();
    }

    /**
     * @dev Unpause token transfers.
     */
    function unpause() external onlyRole(PAUSER_ROLE) {
        _unpause();
    }

    // The following functions are overrides required by Solidity.
    function _update(
        address from,
        address to,
        uint256 value
    ) internal override(ERC20, ERC20Pausable, ERC20Votes) {
        super._update(from, to, value);
    }

    function nonces(address owner)
        public
        view
        override(ERC20Permit, Nonces)
        returns (uint256)
    {
        return super.nonces(owner);
    }
}
