// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/**
 * @title GamingPowerUpgrade
 * @dev Manages player gaming power tiers and multiplier boosts on Ethereum.
 * Supports upgrade purchases via CMR token or native ETH, routing proceeds to Treasury.
 */
contract GamingPowerUpgrade is AccessControl, Pausable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    bytes32 public constant OPERATOR_ROLE = keccak256("OPERATOR_ROLE");
    bytes32 public constant PAUSER_ROLE = keccak256("PAUSER_ROLE");

    IERC20 public immutable cmrToken;
    IERC20 public usdtToken;
    address public treasury;

    // Rate: 1 CMR = X USD (in 18 decimals, e.g., 0.10 USD = 10^17)
    uint256 public cmrUsdRate;

    // Rate: 1 ETH = X USD (in 18 decimals, e.g., 3500 USD = 3500 * 10^18)
    uint256 public ethUsdRate;

    // Rate change safeguards: max 50% deviation per update, 1-hour cooldown
    uint256 public constant MAX_RATE_DEVIATION_BPS = 5000; // 50%
    uint256 public constant RATE_COOLDOWN = 1 hours;
    uint256 public lastRateUpdate;

    enum PowerTier {
        Bronze,   // 0: Free / Default (1.0x)
        Silver,   // 1: $20 (1.25x)
        Gold,     // 2: $50 (1.50x)
        Platinum, // 3: $100 (2.00x)
        Diamond,  // 4: $250 (3.00x)
        Master    // 5: $500 (5.00x)
    }

    struct TierConfig {
        uint256 priceUsd;     // in 18 decimals (e.g. $20 = 20 * 10^18)
        uint256 multiplierBps; // basis points: 10000 = 1.0x, 12500 = 1.25x, 20000 = 2.0x
        bool active;
    }

    struct PlayerPower {
        PowerTier tier;
        uint256 multiplierBps;
        uint256 upgradedAt;
    }

    mapping(PowerTier => TierConfig) public tierConfigs;
    mapping(address => PlayerPower) public playerPowers;

    event PowerUpgraded(
        address indexed player,
        PowerTier indexed tier,
        uint256 multiplierBps,
        uint256 costPaid,
        address paymentToken,
        uint256 timestamp
    );
    event TierConfigUpdated(PowerTier indexed tier, uint256 priceUsd, uint256 multiplierBps, bool active);
    event RatesUpdated(uint256 cmrUsdRate, uint256 ethUsdRate);
    event TreasuryUpdated(address indexed newTreasury);
    event UsdtTokenUpdated(address indexed newUsdtToken);

    constructor(
        IERC20 _cmrToken,
        address _treasury,
        address admin,
        uint256 _cmrUsdRate,
        uint256 _ethUsdRate
    ) {
        require(address(_cmrToken) != address(0), "Invalid token");
        require(_treasury != address(0), "Invalid treasury");
        require(admin != address(0), "Invalid admin");
        require(_cmrUsdRate > 0 && _ethUsdRate > 0, "Invalid rates");

        cmrToken = _cmrToken;
        treasury = _treasury;
        cmrUsdRate = _cmrUsdRate; // e.g. 0.10 USD (1e17)
        ethUsdRate = _ethUsdRate; // e.g. 3500 USD (3500e18)

        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(OPERATOR_ROLE, admin);
        _grantRole(PAUSER_ROLE, admin);

        // Initial Tier Configuration
        tierConfigs[PowerTier.Bronze] = TierConfig({ priceUsd: 0, multiplierBps: 10000, active: true });
        tierConfigs[PowerTier.Silver] = TierConfig({ priceUsd: 20 ether, multiplierBps: 12500, active: true });
        tierConfigs[PowerTier.Gold] = TierConfig({ priceUsd: 50 ether, multiplierBps: 15000, active: true });
        tierConfigs[PowerTier.Platinum] = TierConfig({ priceUsd: 100 ether, multiplierBps: 20000, active: true });
        tierConfigs[PowerTier.Diamond] = TierConfig({ priceUsd: 250 ether, multiplierBps: 30000, active: true });
        tierConfigs[PowerTier.Master] = TierConfig({ priceUsd: 500 ether, multiplierBps: 50000, active: true });
    }

    function upgradeTierWithCMR(PowerTier targetTier) external whenNotPaused nonReentrant {
        require(uint8(targetTier) > uint8(playerPowers[msg.sender].tier), "Target tier must be higher");
        TierConfig memory config = tierConfigs[targetTier];
        require(config.active, "Tier is inactive");

        uint256 costCmr = (config.priceUsd * 1e18) / cmrUsdRate;
        require(costCmr > 0, "Invalid calculation");

        // Checks-Effects-Interactions (CEI): update state before external transfer
        playerPowers[msg.sender] = PlayerPower({
            tier: targetTier,
            multiplierBps: config.multiplierBps,
            upgradedAt: block.timestamp
        });

        cmrToken.safeTransferFrom(msg.sender, treasury, costCmr);

        emit PowerUpgraded(msg.sender, targetTier, config.multiplierBps, costCmr, address(cmrToken), block.timestamp);
    }

    function upgradeTierWithUSDT(PowerTier targetTier) external whenNotPaused nonReentrant {
        require(address(usdtToken) != address(0), "USDT token not configured");
        require(uint8(targetTier) > uint8(playerPowers[msg.sender].tier), "Target tier must be higher");
        TierConfig memory config = tierConfigs[targetTier];
        require(config.active, "Tier is inactive");

        // priceUsd is 18 decimals; USDT is 6 decimals (1 USD = 1e6 units)
        uint256 costUsdt = config.priceUsd / 1e12;
        require(costUsdt > 0, "Invalid USDT calculation");

        playerPowers[msg.sender] = PlayerPower({
            tier: targetTier,
            multiplierBps: config.multiplierBps,
            upgradedAt: block.timestamp
        });

        usdtToken.safeTransferFrom(msg.sender, treasury, costUsdt);

        emit PowerUpgraded(msg.sender, targetTier, config.multiplierBps, costUsdt, address(usdtToken), block.timestamp);
    }

    function setUsdtToken(IERC20 _usdtToken) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(address(_usdtToken) != address(0), "Invalid USDT token");
        usdtToken = _usdtToken;
        emit UsdtTokenUpdated(address(_usdtToken));
    }

    function upgradeTierWithETH(PowerTier targetTier) public payable whenNotPaused nonReentrant {
        require(uint8(targetTier) > uint8(playerPowers[msg.sender].tier), "Target tier must be higher");
        TierConfig memory config = tierConfigs[targetTier];
        require(config.active, "Tier is inactive");

        uint256 costEth = (config.priceUsd * 1e18) / ethUsdRate;
        require(msg.value >= costEth, "Insufficient ETH sent");

        // Checks-Effects-Interactions (CEI): update state before external calls
        playerPowers[msg.sender] = PlayerPower({
            tier: targetTier,
            multiplierBps: config.multiplierBps,
            upgradedAt: block.timestamp
        });

        emit PowerUpgraded(msg.sender, targetTier, config.multiplierBps, costEth, address(0), block.timestamp);

        // Send payment to treasury
        (bool sent, ) = payable(treasury).call{ value: costEth }("");
        require(sent, "ETH transfer failed");

        // Refund any excess ETH
        if (msg.value > costEth) {
            (bool refundSent, ) = payable(msg.sender).call{ value: msg.value - costEth }("");
            require(refundSent, "Refund failed");
        }
    }

    function adminSetPlayerTier(address player, PowerTier tier) external onlyRole(OPERATOR_ROLE) {
        TierConfig memory config = tierConfigs[tier];
        playerPowers[player] = PlayerPower({
            tier: tier,
            multiplierBps: config.multiplierBps,
            upgradedAt: block.timestamp
        });
        emit PowerUpgraded(player, tier, config.multiplierBps, 0, address(0), block.timestamp);
    }

    function getPlayerMultiplier(address player) external view returns (uint256) {
        uint256 bps = playerPowers[player].multiplierBps;
        return bps > 0 ? bps : 10000;
    }

    function getPlayerTier(address player) external view returns (PowerTier, uint256, uint256) {
        PlayerPower memory p = playerPowers[player];
        if (p.multiplierBps == 0) {
            return (PowerTier.Bronze, 10000, 0);
        }
        return (p.tier, p.multiplierBps, p.upgradedAt);
    }

    function setTierConfig(PowerTier tier, uint256 priceUsd, uint256 multiplierBps, bool active) external onlyRole(OPERATOR_ROLE) {
        require(multiplierBps <= 50000, "Max 5x multiplier");
        tierConfigs[tier] = TierConfig({ priceUsd: priceUsd, multiplierBps: multiplierBps, active: active });
        emit TierConfigUpdated(tier, priceUsd, multiplierBps, active);
    }

    function setRates(uint256 _cmrUsdRate, uint256 _ethUsdRate) external onlyRole(OPERATOR_ROLE) {
        require(_cmrUsdRate > 0 && _ethUsdRate > 0, "Invalid rates");

        // Rate change safeguard: cooldown (skip on first update)
        if (lastRateUpdate > 0) {
            require(block.timestamp >= lastRateUpdate + RATE_COOLDOWN, "Rate cooldown active");
        }

        // Rate change safeguard: max deviation cap (skip on first update)
        if (cmrUsdRate > 0) {
            uint256 cmrDelta = _cmrUsdRate > cmrUsdRate
                ? _cmrUsdRate - cmrUsdRate
                : cmrUsdRate - _cmrUsdRate;
            require(
                cmrDelta * 10000 / cmrUsdRate <= MAX_RATE_DEVIATION_BPS,
                "CMR rate deviation exceeds 50%"
            );
        }
        if (ethUsdRate > 0) {
            uint256 ethDelta = _ethUsdRate > ethUsdRate
                ? _ethUsdRate - ethUsdRate
                : ethUsdRate - _ethUsdRate;
            require(
                ethDelta * 10000 / ethUsdRate <= MAX_RATE_DEVIATION_BPS,
                "ETH rate deviation exceeds 50%"
            );
        }

        cmrUsdRate = _cmrUsdRate;
        ethUsdRate = _ethUsdRate;
        lastRateUpdate = block.timestamp;
        emit RatesUpdated(_cmrUsdRate, _ethUsdRate);
    }

    function forceSetRates(uint256 _cmrUsdRate, uint256 _ethUsdRate) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(_cmrUsdRate > 0 && _ethUsdRate > 0, "Invalid rates");
        cmrUsdRate = _cmrUsdRate;
        ethUsdRate = _ethUsdRate;
        lastRateUpdate = block.timestamp;
        emit RatesUpdated(_cmrUsdRate, _ethUsdRate);
    }

    function setTreasury(address _treasury) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(_treasury != address(0), "Invalid treasury");
        treasury = _treasury;
        emit TreasuryUpdated(_treasury);
    }

    function pause() external onlyRole(PAUSER_ROLE) {
        _pause();
    }

    function unpause() external onlyRole(PAUSER_ROLE) {
        _unpause();
    }
}
