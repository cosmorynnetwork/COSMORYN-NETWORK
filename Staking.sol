// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import "./interfaces/IPriceOracleAdapter.sol";

interface IGamingPower {
    function getPlayerMultiplier(address player) external view returns (uint256);
}

/**
 * @title Staking
 * @dev Staking contract for CMR token holders on Ethereum with lock-up tiers, gaming power yield multipliers,
 * oracle USD minimums, discrete daily auto-compounding, early exit penalties, and gift credit staking.
 */
contract Staking is AccessControl, Pausable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    bytes32 public constant STAKING_MANAGER_ROLE = keccak256("STAKING_MANAGER_ROLE");
    bytes32 public constant CREDIT_ISSUER_ROLE   = keccak256("CREDIT_ISSUER_ROLE");
    bytes32 public constant PAUSER_ROLE          = keccak256("PAUSER_ROLE");

    bytes32 private constant CREDIT_STAKE_TYPEHASH = keccak256(
        "CreditStake(address player,uint256 amount,uint256 tierIndex,bool autoCompound,bytes32 creditRefId,uint256 deadline)"
    );
    bytes32 public immutable DOMAIN_SEPARATOR;

    IERC20 public immutable cmrToken;
    IGamingPower public powerContract;
    IPriceOracleAdapter public priceOracle;

    // On-chain USD minimum config (18 decimals: 10 ether = $10 USD)
    uint256 public minStakeUsd = 10 ether;
    uint256 public fallbackCmrUsdRate = 0.10 ether; // $0.10 per CMR
    uint256 public constant SLIPPAGE_TOLERANCE_BPS = 100; // 1%
    uint256 public constant MAX_APY_BPS = 10000;          // 100% max APY
    uint256 public constant MAX_REF_TOTAL_BPS = 2500;     // 25% max sum across 3 lines
    uint256 public constant MAX_EARLY_PENALTY_BPS = 5000; // 50% max penalty cap

    address public penaltyReceiver;
    bool public emergencyModeActive;

    struct LockTier {
        string name;
        uint256 durationDays;
        uint256 apyBps;
        bool active;
        uint256[3] immediateRefBps;       // [line1, line2, line3]
        uint256[3] dailyRefBps;           // [line1, line2, line3]
        bool earlyUnstakeAllowed;
        uint256 earlyUnstakeMinHoldingDays;
        uint256 earlyUnstakePenaltyBps;   // Deducted from initialPrincipal
        bool compoundingAllowed;
        uint256 tierMinStakeUsd;          // 0 = use global minStakeUsd
    }

    struct StakePosition {
        uint256 id;
        address player;
        uint256 initialPrincipal;
        uint256 amount;
        uint256 tierIndex;
        uint256 startTime;
        uint256 unlocksAt;
        uint256 lastClaimTime;
        uint256 apyBps;
        uint256 powerMultiplierBps;
        bool autoCompound;
        bool isGiftCreditFunded;
        bool active;
    }

    LockTier[] public lockTiers;
    uint256 public nextPositionId = 1;
    mapping(uint256 => StakePosition) public positions;
    mapping(address => uint256[]) public playerPositionIds;
    mapping(bytes32 => bool) public usedCreditRefs;

    uint256 public totalStakedAmount;
    uint256 public totalRewardPool;
    uint256 public totalGiftCreditBackingPool;

    // ── Global 90-Day 50% Staking Discount Config ────────────────────
    bool public discountPromoEnabled;
    uint256 public discountPromoBps = 5000; // Default 50%
    uint256 public discountPromoStartTime;
    uint256 public discountPromoEndTime;

    // ── Global 30-Day 2X System Asset Doubler & Mandatory 90-Day Staking ──
    bool public doublerPromoEnabled;
    uint256 public doublerMultiplierBps = 20000; // Default 2.0x (200%)
    uint256 public doublerPromoStartTime;
    uint256 public doublerPromoEndTime;
    uint256 public doublerMandatoryTierIndex = 2; // Default Tier 2 = 90 Days
    bool public releaseMatchedPrincipalAtMaturity = true;

    mapping(uint256 => bool) public isPromoLockedPosition;
    mapping(uint256 => uint256) public positionMatchedBonus;
    mapping(uint256 => uint256) public positionBaseContributed;

    bytes32 private constant DOUBLER_SWEEP_TYPEHASH = keccak256(
        "DoublerSweep(address player,uint256 baseEarnedAmount,uint256 tierIndex,bool autoCompound,bytes32 sweepRefId,uint256 deadline)"
    );

    event Staked(
        uint256 indexed positionId,
        address indexed player,
        uint256 amount,
        uint256 tierIndex,
        uint256 unlocksAt,
        uint256 apyBps,
        bool autoCompound,
        bool isGiftCreditFunded
    );
    event Unstaked(uint256 indexed positionId, address indexed player, uint256 amount, uint256 rewardAmount);
    event EarlyUnstaked(
        uint256 indexed positionId,
        address indexed player,
        uint256 grossPrincipal,
        uint256 penaltyDeducted,
        uint256 netPrincipalReturned,
        uint256 daysRemaining
    );
    event RewardsClaimed(uint256 indexed positionId, address indexed player, uint256 rewardAmount);
    event RewardsFunded(address indexed funder, uint256 amount);
    event TierConfigUpdated(
        uint256 indexed tierIndex,
        string name,
        uint256 durationDays,
        uint256 apyBps,
        bool active,
        uint256[3] immediateRefBps,
        uint256[3] dailyRefBps,
        bool earlyUnstakeAllowed,
        uint256 earlyUnstakeMinHoldingDays,
        uint256 earlyUnstakePenaltyBps,
        bool compoundingAllowed,
        uint256 tierMinStakeUsd
    );
    event PowerContractUpdated(address indexed newPowerContract);
    event EmergencyModeToggled(bool active);
    event MinStakeUsdUpdated(uint256 oldMinStakeUsd, uint256 newMinStakeUsd);
    event PriceOracleUpdated(address indexed newOracle);
    event PenaltyReceiverUpdated(address indexed newReceiver);
    event GiftCreditPoolFunded(address indexed funder, uint256 amount);
    event GiftCreditStaked(bytes32 indexed creditRefId, uint256 indexed positionId, address indexed player, uint256 amount);
    event StakingDiscountPromoUpdated(bool enabled, uint256 discountBps, uint256 startTime, uint256 endTime);
    event SystemAssetDoublerPromoUpdated(
        bool enabled,
        uint256 multiplierBps,
        uint256 startTime,
        uint256 endTime,
        uint256 mandatoryTierIndex,
        bool releaseMatchedPrincipalAtMaturity
    );
    event PromoDiscountStaked(
        uint256 indexed positionId,
        address indexed player,
        uint256 userPaidAmount,
        uint256 matchedBonusAmount,
        uint256 totalStakedAmount,
        uint256 tierIndex
    );
    event SystemAssetsDoubledAndStaked(
        bytes32 indexed sweepRefId,
        uint256 indexed positionId,
        address indexed player,
        uint256 baseEarnedAmount,
        uint256 matchedBonusAmount,
        uint256 totalStakedAmount,
        uint256 tierIndex
    );

    constructor(IERC20 _cmrToken, address admin) {
        require(address(_cmrToken) != address(0), "Invalid token");
        require(admin != address(0), "Invalid admin");

        cmrToken = _cmrToken;
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(STAKING_MANAGER_ROLE, admin);
        _grantRole(CREDIT_ISSUER_ROLE, admin);
        _grantRole(PAUSER_ROLE, admin);

        DOMAIN_SEPARATOR = keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256(bytes("CMR Staking")),
                keccak256(bytes("1")),
                block.chainid,
                address(this)
            )
        );

        // Seed 5 Lock Tiers (Flexible, 30d, 90d, 180d, 365d)
        lockTiers.push(LockTier({
            name: "Flexible",
            durationDays: 0,
            apyBps: 500,
            active: true,
            immediateRefBps: [uint256(500), 300, 100],
            dailyRefBps: [uint256(500), 400, 200],
            earlyUnstakeAllowed: false,
            earlyUnstakeMinHoldingDays: 0,
            earlyUnstakePenaltyBps: 0,
            compoundingAllowed: true,
            tierMinStakeUsd: 0
        }));

        lockTiers.push(LockTier({
            name: "30 Days",
            durationDays: 30,
            apyBps: 1500,
            active: true,
            immediateRefBps: [uint256(500), 300, 100],
            dailyRefBps: [uint256(500), 400, 200],
            earlyUnstakeAllowed: true,
            earlyUnstakeMinHoldingDays: 7,
            earlyUnstakePenaltyBps: 1500,
            compoundingAllowed: true,
            tierMinStakeUsd: 0
        }));

        lockTiers.push(LockTier({
            name: "90 Days",
            durationDays: 90,
            apyBps: 2500,
            active: true,
            immediateRefBps: [uint256(500), 300, 100],
            dailyRefBps: [uint256(500), 400, 200],
            earlyUnstakeAllowed: true,
            earlyUnstakeMinHoldingDays: 14,
            earlyUnstakePenaltyBps: 1500,
            compoundingAllowed: true,
            tierMinStakeUsd: 0
        }));

        lockTiers.push(LockTier({
            name: "180 Days",
            durationDays: 180,
            apyBps: 4000,
            active: true,
            immediateRefBps: [uint256(500), 300, 100],
            dailyRefBps: [uint256(500), 400, 200],
            earlyUnstakeAllowed: true,
            earlyUnstakeMinHoldingDays: 21,
            earlyUnstakePenaltyBps: 2000,
            compoundingAllowed: true,
            tierMinStakeUsd: 0
        }));

        lockTiers.push(LockTier({
            name: "365 Days",
            durationDays: 365,
            apyBps: 7500,
            active: true,
            immediateRefBps: [uint256(500), 300, 100],
            dailyRefBps: [uint256(500), 400, 200],
            earlyUnstakeAllowed: true,
            earlyUnstakeMinHoldingDays: 30,
            earlyUnstakePenaltyBps: 2500,
            compoundingAllowed: true,
            tierMinStakeUsd: 0
        }));
    }

    function setPowerContract(address _powerContract) external onlyRole(STAKING_MANAGER_ROLE) {
        require(_powerContract != address(0), "Invalid power contract");
        uint256 size;
        assembly { size := extcodesize(_powerContract) }
        require(size > 0, "Power contract must be a contract");
        powerContract = IGamingPower(_powerContract);
        emit PowerContractUpdated(_powerContract);
    }

    function setMinStakeUsd(uint256 _minStakeUsd) external onlyRole(DEFAULT_ADMIN_ROLE) {
        uint256 oldMin = minStakeUsd;
        minStakeUsd = _minStakeUsd;
        emit MinStakeUsdUpdated(oldMin, _minStakeUsd);
    }

    function setPriceOracle(address _oracle) external onlyRole(DEFAULT_ADMIN_ROLE) {
        priceOracle = IPriceOracleAdapter(_oracle);
        emit PriceOracleUpdated(_oracle);
    }

    function setPenaltyReceiver(address _receiver) external onlyRole(DEFAULT_ADMIN_ROLE) {
        penaltyReceiver = _receiver;
        emit PenaltyReceiverUpdated(_receiver);
    }

    function setFallbackCmrUsdRate(uint256 _rate) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(_rate > 0, "Rate must be > 0");
        fallbackCmrUsdRate = _rate;
    }

    function getCmrUsdPrice() public view returns (uint256) {
        if (address(priceOracle) != address(0)) {
            try priceOracle.getCmrUsdPrice() returns (uint256 price) {
                if (price > 0) return price;
            } catch {}
        }
        return fallbackCmrUsdRate;
    }

    function isDiscountPromoActive() public view returns (bool) {
        if (!discountPromoEnabled || discountPromoBps == 0) return false;
        if (discountPromoStartTime > 0 && block.timestamp < discountPromoStartTime) return false;
        if (discountPromoEndTime > 0 && block.timestamp > discountPromoEndTime) return false;
        return true;
    }

    function isDoublerPromoActive() public view returns (bool) {
        if (!doublerPromoEnabled || doublerMultiplierBps < 10000) return false;
        if (doublerPromoStartTime > 0 && block.timestamp < doublerPromoStartTime) return false;
        if (doublerPromoEndTime > 0 && block.timestamp > doublerPromoEndTime) return false;
        return true;
    }

    function getEffectiveMinStakeUsd(uint256 tierIndex) public view returns (uint256) {
        require(tierIndex < lockTiers.length, "Invalid tier index");
        uint256 baseMinUsd = lockTiers[tierIndex].tierMinStakeUsd > 0
            ? lockTiers[tierIndex].tierMinStakeUsd
            : minStakeUsd;
        if (isDiscountPromoActive() && discountPromoBps < 10000) {
            return (baseMinUsd * (10000 - discountPromoBps)) / 10000;
        }
        return baseMinUsd;
    }

    function getMinStakeCmr(uint256 tierIndex) public view returns (uint256) {
        uint256 effectiveMinUsd = getEffectiveMinStakeUsd(tierIndex);
        uint256 price = getCmrUsdPrice();
        require(price > 0, "Invalid oracle price");
        return (effectiveMinUsd * 1e18) / price;
    }

    function setStakingDiscountPromo(
        bool _enabled,
        uint256 _discountBps,
        uint256 _startTime,
        uint256 _endTime
    ) external onlyRole(STAKING_MANAGER_ROLE) {
        require(_discountBps <= 9000, "Discount cannot exceed 90%");
        discountPromoEnabled = _enabled;
        discountPromoBps = _discountBps;
        discountPromoStartTime = _startTime;
        discountPromoEndTime = _endTime;
        emit StakingDiscountPromoUpdated(_enabled, _discountBps, _startTime, _endTime);
    }

    function setSystemAssetDoublerPromo(
        bool _enabled,
        uint256 _multiplierBps,
        uint256 _startTime,
        uint256 _endTime,
        uint256 _mandatoryTierIndex,
        bool _releaseMatchedAtMaturity
    ) external onlyRole(STAKING_MANAGER_ROLE) {
        require(_multiplierBps >= 10000 && _multiplierBps <= 50000, "Multiplier must be 1.0x to 5.0x");
        require(_mandatoryTierIndex < lockTiers.length, "Invalid mandatory tier index");
        require(lockTiers[_mandatoryTierIndex].durationDays > 0, "Mandatory tier must have lock duration");
        doublerPromoEnabled = _enabled;
        doublerMultiplierBps = _multiplierBps;
        doublerPromoStartTime = _startTime;
        doublerPromoEndTime = _endTime;
        doublerMandatoryTierIndex = _mandatoryTierIndex;
        releaseMatchedPrincipalAtMaturity = _releaseMatchedAtMaturity;
        emit SystemAssetDoublerPromoUpdated(
            _enabled,
            _multiplierBps,
            _startTime,
            _endTime,
            _mandatoryTierIndex,
            _releaseMatchedAtMaturity
        );
    }

    function fundRewardPool(uint256 amount) external {
        require(amount > 0, "Amount must be > 0");
        cmrToken.safeTransferFrom(msg.sender, address(this), amount);
        totalRewardPool += amount;
        emit RewardsFunded(msg.sender, amount);
    }

    function fundGiftCreditPool(uint256 amount) external nonReentrant {
        require(amount > 0, "Amount must be > 0");
        cmrToken.safeTransferFrom(msg.sender, address(this), amount);
        totalGiftCreditBackingPool += amount;
        emit GiftCreditPoolFunded(msg.sender, amount);
    }

    function stake(uint256 amount, uint256 tierIndex) external whenNotPaused nonReentrant returns (uint256) {
        return _createStake(msg.sender, amount, tierIndex, false, false);
    }

    function stakeWithOptions(
        uint256 amount,
        uint256 tierIndex,
        bool autoCompound
    ) external whenNotPaused nonReentrant returns (uint256) {
        return _createStake(msg.sender, amount, tierIndex, autoCompound, false);
    }

    function stakeForPlayerFromCredit(
        uint256 amount,
        uint256 tierIndex,
        bool autoCompound,
        bytes32 creditRefId,
        uint256 deadline,
        bytes calldata signature
    ) external whenNotPaused nonReentrant returns (uint256) {
        return _stakeFromCredit(msg.sender, amount, tierIndex, autoCompound, creditRefId, deadline, signature);
    }

    function stakeForPlayerFromCredit(
        address player,
        uint256 amount,
        uint256 tierIndex,
        bool autoCompound,
        bytes32 creditRefId,
        uint256 deadline,
        bytes calldata signature
    ) external whenNotPaused nonReentrant returns (uint256) {
        return _stakeFromCredit(player, amount, tierIndex, autoCompound, creditRefId, deadline, signature);
    }

    function _stakeFromCredit(
        address player,
        uint256 amount,
        uint256 tierIndex,
        bool autoCompound,
        bytes32 creditRefId,
        uint256 deadline,
        bytes calldata signature
    ) internal returns (uint256) {
        require(player != address(0), "Invalid player");
        require(block.timestamp <= deadline, "Credit voucher expired");
        require(!usedCreditRefs[creditRefId], "Credit ref already used");
        require(amount > 0, "Amount must be > 0");
        require(totalGiftCreditBackingPool >= amount, "Insufficient credit pool");
        require(tierIndex < lockTiers.length, "Invalid tier index");

        LockTier memory tier = lockTiers[tierIndex];
        require(tier.active, "Tier inactive");
        require(tier.durationDays > 0, "Gift-funded stake must use locked tier");

        bytes32 structHash = keccak256(
            abi.encode(CREDIT_STAKE_TYPEHASH, player, amount, tierIndex, autoCompound, creditRefId, deadline)
        );
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", DOMAIN_SEPARATOR, structHash));
        address signer = ECDSA.recover(digest, signature);
        require(hasRole(CREDIT_ISSUER_ROLE, signer), "Invalid credit issuer signature");

        usedCreditRefs[creditRefId] = true;
        totalGiftCreditBackingPool -= amount;

        uint256 posId = _createStake(player, amount, tierIndex, autoCompound, true);
        emit GiftCreditStaked(creditRefId, posId, player, amount);
        return posId;
    }

    function stakeWithPromoDiscount(
        uint256 userPayAmount,
        uint256 tierIndex,
        bool autoCompound
    ) external whenNotPaused nonReentrant returns (uint256) {
        require(isDiscountPromoActive(), "Staking discount promo is not active");
        require(userPayAmount > 0, "Amount must be > 0");
        require(tierIndex < lockTiers.length, "Invalid tier index");
        LockTier memory tier = lockTiers[tierIndex];
        require(tier.active, "Tier inactive");
        require(tier.durationDays > 0, "Discounted stake must use locked tier");

        uint256 totalAmount = (userPayAmount * 10000) / (10000 - discountPromoBps);
        uint256 matchedBonus = totalAmount - userPayAmount;
        require(totalGiftCreditBackingPool >= matchedBonus, "Insufficient promo backing pool");

        totalGiftCreditBackingPool -= matchedBonus;
        cmrToken.safeTransferFrom(msg.sender, address(this), userPayAmount);

        uint256 posId = _createStake(msg.sender, totalAmount, tierIndex, autoCompound, true);
        isPromoLockedPosition[posId] = true;
        positionMatchedBonus[posId] = matchedBonus;
        positionBaseContributed[posId] = userPayAmount;

        emit PromoDiscountStaked(posId, msg.sender, userPayAmount, matchedBonus, totalAmount, tierIndex);
        return posId;
    }

    function stakeDoubledSystemAssets(
        address player,
        uint256 baseEarnedAmount,
        bool autoCompound,
        bytes32 sweepRefId,
        uint256 deadline,
        bytes calldata signature
    ) external whenNotPaused nonReentrant returns (uint256) {
        require(doublerPromoEnabled, "System asset doubler promo disabled");
        require(player != address(0), "Invalid player");
        require(block.timestamp <= deadline, "Sweep voucher expired");
        require(!usedCreditRefs[sweepRefId], "Sweep ref already used");
        require(baseEarnedAmount > 0, "Base amount must be > 0");

        uint256 tierIndex = doublerMandatoryTierIndex;
        require(tierIndex < lockTiers.length, "Invalid mandatory tier");
        LockTier memory tier = lockTiers[tierIndex];
        require(tier.active && tier.durationDays > 0, "Mandatory tier inactive");

        if (!hasRole(CREDIT_ISSUER_ROLE, msg.sender)) {
            bytes32 structHash = keccak256(
                abi.encode(DOUBLER_SWEEP_TYPEHASH, player, baseEarnedAmount, tierIndex, autoCompound, sweepRefId, deadline)
            );
            bytes32 digest = keccak256(abi.encodePacked("\x19\x01", DOMAIN_SEPARATOR, structHash));
            address signer = ECDSA.recover(digest, signature);
            require(hasRole(CREDIT_ISSUER_ROLE, signer), "Invalid sweep issuer signature");
        }

        uint256 totalDoubledAmount = (baseEarnedAmount * doublerMultiplierBps) / 10000;
        uint256 matchedBonus = totalDoubledAmount - baseEarnedAmount;
        require(totalGiftCreditBackingPool >= totalDoubledAmount, "Insufficient backing pool for doubled assets");

        usedCreditRefs[sweepRefId] = true;
        totalGiftCreditBackingPool -= totalDoubledAmount;

        uint256 posId = _createStakeInternal(player, totalDoubledAmount, tierIndex, autoCompound, true, true);
        isPromoLockedPosition[posId] = true;
        positionMatchedBonus[posId] = matchedBonus;
        positionBaseContributed[posId] = baseEarnedAmount;

        emit SystemAssetsDoubledAndStaked(
            sweepRefId,
            posId,
            player,
            baseEarnedAmount,
            matchedBonus,
            totalDoubledAmount,
            tierIndex
        );
        return posId;
    }

    function _createStake(
        address player,
        uint256 amount,
        uint256 tierIndex,
        bool autoCompound,
        bool isGiftCreditFunded
    ) internal returns (uint256) {
        return _createStakeInternal(player, amount, tierIndex, autoCompound, isGiftCreditFunded, false);
    }

    function _createStakeInternal(
        address player,
        uint256 amount,
        uint256 tierIndex,
        bool autoCompound,
        bool isGiftCreditFunded,
        bool skipMinUsdCheck
    ) internal returns (uint256) {
        require(amount > 0, "Amount must be > 0");
        require(tierIndex < lockTiers.length, "Invalid tier index");
        LockTier memory tier = lockTiers[tierIndex];
        require(tier.active, "Tier inactive");

        if (autoCompound) {
            require(tier.compoundingAllowed, "Compounding disabled for tier");
        }

        // USD minimum enforcement with 1% slippage margin
        uint256 effectiveMinUsd = getEffectiveMinStakeUsd(tierIndex);
        if (!skipMinUsdCheck && effectiveMinUsd > 0) {
            uint256 price = getCmrUsdPrice();
            uint256 stakeUsdValue = (amount * price) / 1e18;
            require(
                stakeUsdValue * 10000 >= effectiveMinUsd * (10000 - SLIPPAGE_TOLERANCE_BPS),
                "Amount below min stake USD"
            );
        }

        uint256 powerMultiplier = 10000;
        if (address(powerContract) != address(0)) {
            powerMultiplier = powerContract.getPlayerMultiplier(player);
            if (powerMultiplier > 50000) powerMultiplier = 50000;
        }

        uint256 positionId = nextPositionId++;
        uint256 unlockTimestamp = tier.durationDays > 0
            ? block.timestamp + (tier.durationDays * 1 days)
            : block.timestamp;

        positions[positionId] = StakePosition({
            id: positionId,
            player: player,
            initialPrincipal: amount,
            amount: amount,
            tierIndex: tierIndex,
            startTime: block.timestamp,
            unlocksAt: unlockTimestamp,
            lastClaimTime: block.timestamp,
            apyBps: tier.apyBps,
            powerMultiplierBps: powerMultiplier,
            autoCompound: autoCompound,
            isGiftCreditFunded: isGiftCreditFunded,
            active: true
        });

        playerPositionIds[player].push(positionId);
        totalStakedAmount += amount;

        if (!isGiftCreditFunded) {
            cmrToken.safeTransferFrom(msg.sender, address(this), amount);
        }

        emit Staked(
            positionId,
            player,
            amount,
            tierIndex,
            unlockTimestamp,
            tier.apyBps,
            autoCompound,
            isGiftCreditFunded
        );
        return positionId;
    }

    function _powRay(uint256 baseRay, uint256 exp) internal pure returns (uint256) {
        uint256 result = 1e27;
        uint256 base = baseRay;
        while (exp > 0) {
            if (exp % 2 == 1) {
                result = (result * base) / 1e27;
            }
            base = (base * base) / 1e27;
            exp /= 2;
        }
        return result;
    }

    function calculateRewards(uint256 positionId) public view returns (uint256) {
        StakePosition memory pos = positions[positionId];
        if (!pos.active || pos.amount == 0) return 0;

        uint256 accrualEnd = pos.unlocksAt > pos.startTime
            ? (block.timestamp > pos.unlocksAt ? pos.unlocksAt : block.timestamp)
            : block.timestamp;
        if (accrualEnd <= pos.lastClaimTime) return 0;

        uint256 effectiveApyBps = (pos.apyBps * pos.powerMultiplierBps) / 10000;

        if (!pos.autoCompound) {
            uint256 timeElapsed = accrualEnd - pos.lastClaimTime;
            uint256 baseReward = (pos.amount * pos.apyBps * timeElapsed) / (365 days * 10000);
            return (baseReward * pos.powerMultiplierBps) / 10000;
        } else {
            uint256 timeElapsed = accrualEnd - pos.lastClaimTime;
            uint256 fullDays = timeElapsed / 1 days;
            uint256 remSec = timeElapsed % 1 days;

            // Daily rate in 27-decimal Ray precision
            uint256 dailyRateRay = (effectiveApyBps * 1e27) / (365 * 10000);
            uint256 compoundedAmount = (pos.amount * _powRay(1e27 + dailyRateRay, fullDays)) / 1e27;
            if (remSec > 0) {
                compoundedAmount += (compoundedAmount * effectiveApyBps * remSec) / (365 days * 10000);
            }
            if (compoundedAmount <= pos.amount) return 0;
            return compoundedAmount - pos.amount;
        }
    }

    function claimRewards(uint256 positionId) public whenNotPaused nonReentrant {
        StakePosition storage pos = positions[positionId];
        require(pos.player == msg.sender, "Not position owner");
        require(pos.active, "Position inactive");

        if (pos.autoCompound) {
            require(
                pos.unlocksAt <= pos.startTime || block.timestamp >= pos.unlocksAt,
                "Auto-compounding active until unlock"
            );
        }

        uint256 reward = calculateRewards(positionId);
        require(reward > 0, "No rewards accrued");
        require(totalRewardPool >= reward, "Insufficient reward pool");

        pos.lastClaimTime = block.timestamp;
        totalRewardPool -= reward;
        cmrToken.safeTransfer(msg.sender, reward);

        emit RewardsClaimed(positionId, msg.sender, reward);
    }

    function unstake(uint256 positionId) external nonReentrant {
        StakePosition storage pos = positions[positionId];
        require(pos.player == msg.sender, "Not position owner");
        require(pos.active, "Position inactive");
        require(block.timestamp >= pos.unlocksAt || emergencyModeActive, "Tokens still locked");

        uint256 reward = calculateRewards(positionId);
        uint256 stakedAmount = pos.amount;
        require(totalRewardPool >= reward, "Insufficient reward pool");

        pos.active = false;
        pos.amount = 0;
        pos.lastClaimTime = block.timestamp;
        totalStakedAmount -= stakedAmount;
        totalRewardPool -= reward;

        uint256 principalToRelease = stakedAmount;
        uint256 matchedBonus = positionMatchedBonus[positionId];
        if (!releaseMatchedPrincipalAtMaturity && matchedBonus > 0 && stakedAmount >= matchedBonus) {
            principalToRelease = stakedAmount - matchedBonus;
            totalGiftCreditBackingPool += matchedBonus;
        }

        cmrToken.safeTransfer(msg.sender, principalToRelease + reward);

        emit Unstaked(positionId, msg.sender, principalToRelease, reward);
    }

    function earlyUnstake(uint256 positionId) external nonReentrant {
        StakePosition storage pos = positions[positionId];
        require(pos.player == msg.sender, "Not position owner");
        require(pos.active, "Position inactive");
        require(!pos.isGiftCreditFunded && !isPromoLockedPosition[positionId], "Gift-funded stake must complete lock period");
        require(block.timestamp < pos.unlocksAt, "Use regular unstake after unlock");

        LockTier memory tier = lockTiers[pos.tierIndex];
        require(tier.earlyUnstakeAllowed, "Early unstake not allowed for tier");
        require(
            block.timestamp >= pos.startTime + (tier.earlyUnstakeMinHoldingDays * 1 days),
            "Min holding period not met"
        );

        uint256 penalty = (pos.initialPrincipal * tier.earlyUnstakePenaltyBps) / 10000;
        uint256 netPrincipal = pos.initialPrincipal - penalty;
        uint256 daysRemaining = (pos.unlocksAt - block.timestamp) / 1 days;

        pos.active = false;
        pos.amount = 0;
        pos.lastClaimTime = block.timestamp;
        totalStakedAmount -= pos.initialPrincipal;

        cmrToken.safeTransfer(msg.sender, netPrincipal);

        if (penalty > 0) {
            if (penaltyReceiver != address(0)) {
                cmrToken.safeTransfer(penaltyReceiver, penalty);
            } else {
                totalRewardPool += penalty;
            }
        }

        emit EarlyUnstaked(positionId, msg.sender, pos.initialPrincipal, penalty, netPrincipal, daysRemaining);
    }

    function emergencyUnstake(uint256 positionId) external nonReentrant {
        StakePosition storage pos = positions[positionId];
        require(pos.player == msg.sender, "Not position owner");
        require(pos.active, "Position inactive");
        require(block.timestamp >= pos.unlocksAt || emergencyModeActive, "Tokens still locked");

        uint256 stakedAmount = pos.amount;
        pos.active = false;
        pos.amount = 0;
        pos.lastClaimTime = block.timestamp;
        totalStakedAmount -= stakedAmount;

        cmrToken.safeTransfer(msg.sender, stakedAmount);

        emit Unstaked(positionId, msg.sender, stakedAmount, 0);
    }

    function getPlayerPositions(address player, uint256 offset, uint256 limit) external view returns (StakePosition[] memory) {
        uint256[] memory ids = playerPositionIds[player];
        if (offset >= ids.length) return new StakePosition[](0);
        uint256 end = offset + limit;
        if (end > ids.length || limit == 0) end = ids.length;
        StakePosition[] memory playerPos = new StakePosition[](end - offset);
        for (uint256 i = offset; i < end; i++) {
            playerPos[i - offset] = positions[ids[i]];
        }
        return playerPos;
    }

    function getTierCount() external view returns (uint256) {
        return lockTiers.length;
    }

    function addTier(
        string calldata name,
        uint256 durationDays,
        uint256 apyBps
    ) external onlyRole(STAKING_MANAGER_ROLE) returns (uint256) {
        require(apyBps <= MAX_APY_BPS, "APY exceeds maximum (100%)");
        lockTiers.push(LockTier({
            name: name,
            durationDays: durationDays,
            apyBps: apyBps,
            active: true,
            immediateRefBps: [uint256(500), 300, 100],
            dailyRefBps: [uint256(500), 400, 200],
            earlyUnstakeAllowed: durationDays > 0,
            earlyUnstakeMinHoldingDays: durationDays > 0 ? 7 : 0,
            earlyUnstakePenaltyBps: durationDays > 0 ? 1500 : 0,
            compoundingAllowed: true,
            tierMinStakeUsd: 0
        }));
        uint256 newTierIndex = lockTiers.length - 1;
        emit TierConfigUpdated(
            newTierIndex,
            name,
            durationDays,
            apyBps,
            true,
            [uint256(500), 300, 100],
            [uint256(500), 400, 200],
            durationDays > 0,
            durationDays > 0 ? 7 : 0,
            durationDays > 0 ? 1500 : 0,
            true,
            0
        );
        return newTierIndex;
    }

    function addTierExtended(
        string calldata name,
        uint256 durationDays,
        uint256 apyBps,
        uint256[3] calldata immediateRefBps,
        uint256[3] calldata dailyRefBps,
        bool earlyUnstakeAllowed,
        uint256 earlyUnstakeMinHoldingDays,
        uint256 earlyUnstakePenaltyBps,
        bool compoundingAllowed,
        uint256 tierMinStakeUsd
    ) external onlyRole(STAKING_MANAGER_ROLE) returns (uint256) {
        require(apyBps <= MAX_APY_BPS, "APY exceeds maximum (100%)");
        require(earlyUnstakePenaltyBps <= MAX_EARLY_PENALTY_BPS, "Penalty exceeds max 50%");
        require(
            immediateRefBps[0] + immediateRefBps[1] + immediateRefBps[2] <= MAX_REF_TOTAL_BPS,
            "Immediate ref exceeds max"
        );
        require(
            dailyRefBps[0] + dailyRefBps[1] + dailyRefBps[2] <= MAX_REF_TOTAL_BPS,
            "Daily ref exceeds max"
        );

        lockTiers.push(LockTier({
            name: name,
            durationDays: durationDays,
            apyBps: apyBps,
            active: true,
            immediateRefBps: immediateRefBps,
            dailyRefBps: dailyRefBps,
            earlyUnstakeAllowed: earlyUnstakeAllowed,
            earlyUnstakeMinHoldingDays: earlyUnstakeMinHoldingDays,
            earlyUnstakePenaltyBps: earlyUnstakePenaltyBps,
            compoundingAllowed: compoundingAllowed,
            tierMinStakeUsd: tierMinStakeUsd
        }));

        uint256 newTierIndex = lockTiers.length - 1;
        emit TierConfigUpdated(
            newTierIndex,
            name,
            durationDays,
            apyBps,
            true,
            immediateRefBps,
            dailyRefBps,
            earlyUnstakeAllowed,
            earlyUnstakeMinHoldingDays,
            earlyUnstakePenaltyBps,
            compoundingAllowed,
            tierMinStakeUsd
        );
        return newTierIndex;
    }

    function setTierConfig(
        uint256 tierIndex,
        string calldata name,
        uint256 durationDays,
        uint256 apyBps,
        bool active
    ) external onlyRole(STAKING_MANAGER_ROLE) {
        require(tierIndex < lockTiers.length, "Invalid tier");
        require(apyBps <= MAX_APY_BPS, "APY exceeds maximum (100%)");
        LockTier storage t = lockTiers[tierIndex];
        t.name = name;
        t.durationDays = durationDays;
        t.apyBps = apyBps;
        t.active = active;
        emit TierConfigUpdated(
            tierIndex,
            name,
            durationDays,
            apyBps,
            active,
            t.immediateRefBps,
            t.dailyRefBps,
            t.earlyUnstakeAllowed,
            t.earlyUnstakeMinHoldingDays,
            t.earlyUnstakePenaltyBps,
            t.compoundingAllowed,
            t.tierMinStakeUsd
        );
    }

    function setTierConfigExtended(
        uint256 tierIndex,
        string calldata name,
        uint256 durationDays,
        uint256 apyBps,
        bool active,
        uint256[3] calldata immediateRefBps,
        uint256[3] calldata dailyRefBps,
        bool earlyUnstakeAllowed,
        uint256 earlyUnstakeMinHoldingDays,
        uint256 earlyUnstakePenaltyBps,
        bool compoundingAllowed,
        uint256 tierMinStakeUsd
    ) external onlyRole(STAKING_MANAGER_ROLE) {
        require(tierIndex < lockTiers.length, "Invalid tier");
        require(apyBps <= MAX_APY_BPS, "APY exceeds maximum (100%)");
        require(earlyUnstakePenaltyBps <= MAX_EARLY_PENALTY_BPS, "Penalty exceeds max 50%");
        require(
            immediateRefBps[0] + immediateRefBps[1] + immediateRefBps[2] <= MAX_REF_TOTAL_BPS,
            "Immediate ref exceeds max"
        );
        require(
            dailyRefBps[0] + dailyRefBps[1] + dailyRefBps[2] <= MAX_REF_TOTAL_BPS,
            "Daily ref exceeds max"
        );

        lockTiers[tierIndex] = LockTier({
            name: name,
            durationDays: durationDays,
            apyBps: apyBps,
            active: active,
            immediateRefBps: immediateRefBps,
            dailyRefBps: dailyRefBps,
            earlyUnstakeAllowed: earlyUnstakeAllowed,
            earlyUnstakeMinHoldingDays: earlyUnstakeMinHoldingDays,
            earlyUnstakePenaltyBps: earlyUnstakePenaltyBps,
            compoundingAllowed: compoundingAllowed,
            tierMinStakeUsd: tierMinStakeUsd
        });

        emit TierConfigUpdated(
            tierIndex,
            name,
            durationDays,
            apyBps,
            active,
            immediateRefBps,
            dailyRefBps,
            earlyUnstakeAllowed,
            earlyUnstakeMinHoldingDays,
            earlyUnstakePenaltyBps,
            compoundingAllowed,
            tierMinStakeUsd
        );
    }

    function pause() external onlyRole(PAUSER_ROLE) {
        _pause();
    }

    function unpause() external onlyRole(PAUSER_ROLE) {
        _unpause();
    }

    function toggleEmergencyMode(bool _active) external onlyRole(DEFAULT_ADMIN_ROLE) {
        emergencyModeActive = _active;
        emit EmergencyModeToggled(_active);
    }
}
