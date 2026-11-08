// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import "./interfaces/IPriceOracleAdapter.sol";

/**
 * @title RewardsDistributor
 * @dev Manages play-to-earn, tournament, mission, achievement, referral, and bonus rewards on Ethereum.
 * Enforces dynamic oracle USD-denominated caps, velocity limits, and dual-signature verification for high-value claims.
 */
contract RewardsDistributor is AccessControl, Pausable, ReentrancyGuard {
    using SafeERC20 for IERC20;
    using ECDSA for bytes32;
    using MessageHashUtils for bytes32;

    bytes32 public constant DISTRIBUTOR_ROLE  = keccak256("DISTRIBUTOR_ROLE");
    bytes32 public constant ADMIN_SIGNER_ROLE = keccak256("ADMIN_SIGNER_ROLE");
    bytes32 public constant PAUSER_ROLE       = keccak256("PAUSER_ROLE");

    IERC20 public immutable cmrToken;
    IPriceOracleAdapter public priceOracle;

    enum RewardCategory {
        DailyGameplay,        // 0
        Tournaments,          // 1
        Achievements,         // 2
        CommunityMissions,    // 3
        SpecialEvents,        // 4
        ImmediateReferral,    // 5
        DailyYieldReferral,   // 6
        ManagedTradingBonus,  // 7
        LeadershipPilot,      // 8
        TournamentGiftDrip    // 9
    }

    struct CategoryConfig {
        uint256 weightBps;
        uint256 totalDistributed;
        bool active;
    }

    // On-chain USD Limits (18 decimals)
    uint256 public minClaimUsd = 5 ether; // $5.00 min claim
    uint256 public maxUserDailyClaimUsd = 500 ether; // $500.00 max daily per user
    uint256 public maxGlobalDailyClaimUsd = 10000 ether; // $10,000.00 global daily cap
    uint256 public highValueAdminSigThresholdUsd = 250 ether; // $250.00 threshold requiring hardware co-sig
    uint256 public fallbackCmrUsdRate = 0.10 ether; // $0.10 per CMR
    uint256 public constant SLIPPAGE_TOLERANCE_BPS = 100; // 1%

    mapping(RewardCategory => CategoryConfig) public categoryConfigs;
    mapping(address => mapping(RewardCategory => mapping(uint256 => bool))) public claimedNonces;
    mapping(address => uint256) public playerTotalClaimed;
    mapping(address => mapping(RewardCategory => uint256)) public playerCategoryClaimed;

    // Legacy CMR caps (retained for backward compatibility)
    mapping(RewardCategory => uint256) public categoryEpochCap;
    mapping(RewardCategory => uint256) public categoryEpochSpent;
    mapping(RewardCategory => mapping(uint256 => uint256)) public categoryDailySpent;

    // On-chain USD daily tracking
    mapping(RewardCategory => uint256) public categoryDailyCapUsd;
    mapping(address => mapping(uint256 => uint256)) public userDailyClaimedUsd;
    mapping(uint256 => uint256) public globalDailyClaimedUsd;
    mapping(RewardCategory => mapping(uint256 => uint256)) public categoryDailyClaimedUsd;

    event RewardClaimed(
        address indexed player,
        RewardCategory indexed category,
        uint256 amount,
        uint256 nonce,
        uint256 timestamp
    );
    event HighValueRewardClaimed(
        address indexed player,
        RewardCategory indexed category,
        uint256 amount,
        uint256 nonce,
        address distributorSigner,
        address adminSigner,
        uint256 timestamp
    );
    event DirectRewardDistributed(
        address indexed player,
        RewardCategory indexed category,
        uint256 amount,
        string reason
    );
    event RewardsFunded(address indexed funder, uint256 amount);
    event CategoryConfigUpdated(RewardCategory indexed category, uint256 weightBps, bool active);
    event CategoryCapUpdated(RewardCategory indexed category, uint256 cap);
    event CategoryDailyCapUsdUpdated(RewardCategory indexed category, uint256 capUsd);
    event ClaimUsdLimitsUpdated(
        uint256 minClaimUsd,
        uint256 maxUserDailyUsd,
        uint256 maxGlobalDailyUsd,
        uint256 highValueThresholdUsd
    );
    event PriceOracleUpdated(address indexed newOracle);

    bytes32 private constant CLAIM_TYPEHASH = keccak256(
        "Claim(address player,uint8 category,uint256 amount,uint256 nonce,uint256 deadline)"
    );
    bytes32 public immutable DOMAIN_SEPARATOR;

    constructor(IERC20 _cmrToken, address admin) {
        require(address(_cmrToken) != address(0), "Invalid token");
        require(admin != address(0), "Invalid admin");

        cmrToken = _cmrToken;
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(DISTRIBUTOR_ROLE, admin);
        _grantRole(ADMIN_SIGNER_ROLE, admin);
        _grantRole(PAUSER_ROLE, admin);

        // Initial category distribution weights
        categoryConfigs[RewardCategory.DailyGameplay]       = CategoryConfig({ weightBps: 4000, totalDistributed: 0, active: true });
        categoryConfigs[RewardCategory.Tournaments]         = CategoryConfig({ weightBps: 2500, totalDistributed: 0, active: true });
        categoryConfigs[RewardCategory.Achievements]        = CategoryConfig({ weightBps: 1500, totalDistributed: 0, active: true });
        categoryConfigs[RewardCategory.CommunityMissions]   = CategoryConfig({ weightBps: 1000, totalDistributed: 0, active: true });
        categoryConfigs[RewardCategory.SpecialEvents]       = CategoryConfig({ weightBps: 1000, totalDistributed: 0, active: true });
        categoryConfigs[RewardCategory.ImmediateReferral]   = CategoryConfig({ weightBps: 1000, totalDistributed: 0, active: true });
        categoryConfigs[RewardCategory.DailyYieldReferral]  = CategoryConfig({ weightBps: 1000, totalDistributed: 0, active: true });
        categoryConfigs[RewardCategory.ManagedTradingBonus] = CategoryConfig({ weightBps: 1000, totalDistributed: 0, active: true });
        categoryConfigs[RewardCategory.LeadershipPilot]     = CategoryConfig({ weightBps: 1000, totalDistributed: 0, active: true });
        categoryConfigs[RewardCategory.TournamentGiftDrip]  = CategoryConfig({ weightBps: 1000, totalDistributed: 0, active: true });

        DOMAIN_SEPARATOR = keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256(bytes("CMR Rewards")),
                keccak256(bytes("1")),
                block.chainid,
                address(this)
            )
        );
    }

    function getCmrUsdPrice() public view returns (uint256) {
        if (address(priceOracle) != address(0)) {
            try priceOracle.getCmrUsdPrice() returns (uint256 price) {
                if (price > 0) return price;
            } catch {}
        }
        return fallbackCmrUsdRate;
    }

    function usdToCmr(uint256 usdAmount18) public view returns (uint256) {
        uint256 price = getCmrUsdPrice();
        require(price > 0, "Invalid oracle price");
        return (usdAmount18 * 1e18) / price;
    }

    function cmrToUsd(uint256 cmrAmount18) public view returns (uint256) {
        uint256 price = getCmrUsdPrice();
        return (cmrAmount18 * price) / 1e18;
    }

    function getPlayerDailyAllowance(address player) external view returns (
        uint256 usedUsd,
        uint256 remainingUsd,
        uint256 remainingCmr,
        uint256 minClaimCmr
    ) {
        uint256 currentDay = block.timestamp / 1 days;
        usedUsd = userDailyClaimedUsd[player][currentDay];
        remainingUsd = usedUsd >= maxUserDailyClaimUsd ? 0 : maxUserDailyClaimUsd - usedUsd;
        remainingCmr = usdToCmr(remainingUsd);
        minClaimCmr = usdToCmr(minClaimUsd);
    }

    function fundRewardPool(uint256 amount) external {
        require(amount > 0, "Amount must be > 0");
        cmrToken.safeTransferFrom(msg.sender, address(this), amount);
        emit RewardsFunded(msg.sender, amount);
    }

    function claimReward(
        RewardCategory category,
        uint256 amount,
        uint256 nonce,
        uint256 deadline,
        bytes calldata signature
    ) external whenNotPaused nonReentrant {
        require(block.timestamp <= deadline, "Claim voucher expired");
        require(!claimedNonces[msg.sender][category][nonce], "Nonce already used");
        require(categoryConfigs[category].active, "Category inactive");
        require(amount > 0, "Amount must be > 0");
        require(cmrToken.balanceOf(address(this)) >= amount, "Insufficient reward pool");

        uint256 claimUsd = cmrToUsd(amount);
        require(
            claimUsd * 10000 >= minClaimUsd * (10000 - SLIPPAGE_TOLERANCE_BPS),
            "Claim below USD minimum"
        );
        require(
            claimUsd <= highValueAdminSigThresholdUsd,
            "Exceeds high value threshold; requires dual signature"
        );

        uint256 currentDay = block.timestamp / 1 days;
        require(
            userDailyClaimedUsd[msg.sender][currentDay] + claimUsd <= maxUserDailyClaimUsd,
            "User daily USD cap exceeded"
        );
        require(
            globalDailyClaimedUsd[currentDay] + claimUsd <= maxGlobalDailyClaimUsd,
            "Global daily USD cap exceeded"
        );
        if (categoryDailyCapUsd[category] > 0) {
            require(
                categoryDailyClaimedUsd[category][currentDay] + claimUsd <= categoryDailyCapUsd[category],
                "Category daily USD cap exceeded"
            );
        }

        // Legacy CMR epoch cap support
        uint256 cap = categoryEpochCap[category];
        if (cap > 0) {
            require(categoryDailySpent[category][currentDay] + amount <= cap, "Category daily cap exceeded");
        }

        bytes32 structHash = keccak256(
            abi.encode(CLAIM_TYPEHASH, msg.sender, uint8(category), amount, nonce, deadline)
        );
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", DOMAIN_SEPARATOR, structHash));
        address signer = ECDSA.recover(digest, signature);
        require(hasRole(DISTRIBUTOR_ROLE, signer), "Invalid distributor signature");

        // Checks-Effects-Interactions (CEI)
        claimedNonces[msg.sender][category][nonce] = true;
        categoryConfigs[category].totalDistributed += amount;
        playerTotalClaimed[msg.sender] += amount;
        playerCategoryClaimed[msg.sender][category] += amount;

        userDailyClaimedUsd[msg.sender][currentDay] += claimUsd;
        globalDailyClaimedUsd[currentDay] += claimUsd;
        if (categoryDailyCapUsd[category] > 0) {
            categoryDailyClaimedUsd[category][currentDay] += claimUsd;
        }

        if (cap > 0) {
            categoryDailySpent[category][currentDay] += amount;
            categoryEpochSpent[category] += amount;
        }

        cmrToken.safeTransfer(msg.sender, amount);
        emit RewardClaimed(msg.sender, category, amount, nonce, block.timestamp);
    }

    function claimHighValueReward(
        RewardCategory category,
        uint256 amount,
        uint256 nonce,
        uint256 deadline,
        bytes calldata distributorSig,
        bytes calldata adminSig
    ) external whenNotPaused nonReentrant {
        require(block.timestamp <= deadline, "Claim voucher expired");
        require(!claimedNonces[msg.sender][category][nonce], "Nonce already used");
        require(categoryConfigs[category].active, "Category inactive");
        require(amount > 0, "Amount must be > 0");
        require(cmrToken.balanceOf(address(this)) >= amount, "Insufficient reward pool");

        uint256 claimUsd = cmrToUsd(amount);
        require(
            claimUsd * 10000 >= minClaimUsd * (10000 - SLIPPAGE_TOLERANCE_BPS),
            "Claim below USD minimum"
        );

        uint256 currentDay = block.timestamp / 1 days;
        require(
            globalDailyClaimedUsd[currentDay] + claimUsd <= maxGlobalDailyClaimUsd,
            "Global daily USD cap exceeded"
        );
        if (categoryDailyCapUsd[category] > 0) {
            require(
                categoryDailyClaimedUsd[category][currentDay] + claimUsd <= categoryDailyCapUsd[category],
                "Category daily USD cap exceeded"
            );
        }

        bytes32 structHash = keccak256(
            abi.encode(CLAIM_TYPEHASH, msg.sender, uint8(category), amount, nonce, deadline)
        );
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", DOMAIN_SEPARATOR, structHash));

        address distSigner = ECDSA.recover(digest, distributorSig);
        require(hasRole(DISTRIBUTOR_ROLE, distSigner), "Invalid distributor signature");

        address adminSigner = ECDSA.recover(digest, adminSig);
        require(hasRole(ADMIN_SIGNER_ROLE, adminSigner), "Invalid admin signature");
        require(distSigner != adminSigner, "Signers must be distinct");

        claimedNonces[msg.sender][category][nonce] = true;
        categoryConfigs[category].totalDistributed += amount;
        playerTotalClaimed[msg.sender] += amount;
        playerCategoryClaimed[msg.sender][category] += amount;

        userDailyClaimedUsd[msg.sender][currentDay] += claimUsd;
        globalDailyClaimedUsd[currentDay] += claimUsd;
        if (categoryDailyCapUsd[category] > 0) {
            categoryDailyClaimedUsd[category][currentDay] += claimUsd;
        }

        uint256 cap = categoryEpochCap[category];
        if (cap > 0) {
            categoryDailySpent[category][currentDay] += amount;
            categoryEpochSpent[category] += amount;
        }

        cmrToken.safeTransfer(msg.sender, amount);

        emit HighValueRewardClaimed(msg.sender, category, amount, nonce, distSigner, adminSigner, block.timestamp);
        emit RewardClaimed(msg.sender, category, amount, nonce, block.timestamp);
    }

    function claimRewardLegacy(
        RewardCategory category,
        uint256 amount,
        uint256 nonce,
        uint256 deadline,
        bytes calldata signature
    ) external whenNotPaused nonReentrant {
        require(block.timestamp <= deadline, "Claim voucher expired");
        require(!claimedNonces[msg.sender][category][nonce], "Nonce already used");
        require(categoryConfigs[category].active, "Category inactive");
        require(amount > 0, "Amount must be > 0");
        require(cmrToken.balanceOf(address(this)) >= amount, "Insufficient reward pool");

        uint256 claimUsd = cmrToUsd(amount);
        require(
            claimUsd * 10000 >= minClaimUsd * (10000 - SLIPPAGE_TOLERANCE_BPS),
            "Claim below USD minimum"
        );
        require(
            claimUsd <= highValueAdminSigThresholdUsd,
            "Exceeds high value threshold; requires dual signature"
        );

        uint256 currentDay = block.timestamp / 1 days;
        require(
            userDailyClaimedUsd[msg.sender][currentDay] + claimUsd <= maxUserDailyClaimUsd,
            "User daily USD cap exceeded"
        );
        require(
            globalDailyClaimedUsd[currentDay] + claimUsd <= maxGlobalDailyClaimUsd,
            "Global daily USD cap exceeded"
        );

        bytes32 structHash = keccak256(
            abi.encodePacked(
                "\x19CMR Claim:\n",
                block.chainid,
                address(this),
                msg.sender,
                uint8(category),
                amount,
                nonce,
                deadline
            )
        );
        bytes32 ethSignedMessageHash = structHash.toEthSignedMessageHash();
        address signer = ethSignedMessageHash.recover(signature);
        require(hasRole(DISTRIBUTOR_ROLE, signer), "Invalid distributor signature");

        claimedNonces[msg.sender][category][nonce] = true;
        categoryConfigs[category].totalDistributed += amount;
        playerTotalClaimed[msg.sender] += amount;
        playerCategoryClaimed[msg.sender][category] += amount;

        userDailyClaimedUsd[msg.sender][currentDay] += claimUsd;
        globalDailyClaimedUsd[currentDay] += claimUsd;

        uint256 cap = categoryEpochCap[category];
        if (cap > 0) {
            categoryDailySpent[category][currentDay] += amount;
            categoryEpochSpent[category] += amount;
        }

        cmrToken.safeTransfer(msg.sender, amount);
        emit RewardClaimed(msg.sender, category, amount, nonce, block.timestamp);
    }

    function directDistribute(
        address player,
        RewardCategory category,
        uint256 amount,
        string calldata reason
    ) external onlyRole(DISTRIBUTOR_ROLE) whenNotPaused nonReentrant {
        require(player != address(0), "Invalid recipient");
        require(amount > 0, "Amount must be > 0");
        require(categoryConfigs[category].active, "Category inactive");
        require(cmrToken.balanceOf(address(this)) >= amount, "Insufficient reward pool");

        uint256 cap = categoryEpochCap[category];
        if (cap > 0) {
            require(categoryEpochSpent[category] + amount <= cap, "Category cap exceeded");
        }

        categoryConfigs[category].totalDistributed += amount;
        playerTotalClaimed[player] += amount;
        playerCategoryClaimed[player][category] += amount;
        if (cap > 0) categoryEpochSpent[category] += amount;

        cmrToken.safeTransfer(player, amount);
        emit DirectRewardDistributed(player, category, amount, reason);
    }

    function setClaimUsdLimits(
        uint256 _minClaimUsd,
        uint256 _maxUserDailyUsd,
        uint256 _maxGlobalDailyUsd,
        uint256 _highValueThresholdUsd
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        minClaimUsd = _minClaimUsd;
        maxUserDailyClaimUsd = _maxUserDailyUsd;
        maxGlobalDailyClaimUsd = _maxGlobalDailyUsd;
        highValueAdminSigThresholdUsd = _highValueThresholdUsd;
        emit ClaimUsdLimitsUpdated(_minClaimUsd, _maxUserDailyUsd, _maxGlobalDailyUsd, _highValueThresholdUsd);
    }

    function setCategoryDailyCapUsd(RewardCategory category, uint256 capUsd) external onlyRole(DEFAULT_ADMIN_ROLE) {
        categoryDailyCapUsd[category] = capUsd;
        emit CategoryDailyCapUsdUpdated(category, capUsd);
    }

    function setPriceOracle(address _oracle) external onlyRole(DEFAULT_ADMIN_ROLE) {
        priceOracle = IPriceOracleAdapter(_oracle);
        emit PriceOracleUpdated(_oracle);
    }

    function setFallbackCmrUsdRate(uint256 _rate) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(_rate > 0, "Rate must be > 0");
        fallbackCmrUsdRate = _rate;
    }

    function setCategoryConfig(RewardCategory category, uint256 weightBps, bool active) external onlyRole(DEFAULT_ADMIN_ROLE) {
        categoryConfigs[category].weightBps = weightBps;
        categoryConfigs[category].active = active;
        emit CategoryConfigUpdated(category, weightBps, active);
    }

    function setCategoryCap(RewardCategory category, uint256 cap) external onlyRole(DEFAULT_ADMIN_ROLE) {
        categoryEpochCap[category] = cap;
        emit CategoryCapUpdated(category, cap);
    }

    function resetCategoryEpoch(RewardCategory category) external onlyRole(DEFAULT_ADMIN_ROLE) {
        categoryEpochSpent[category] = 0;
        emit CategoryCapUpdated(category, categoryEpochCap[category]);
    }

    function claimedNonce(address player, RewardCategory category, uint256 nonce) external view returns (bool) {
        return claimedNonces[player][category][nonce];
    }

    function pause() external onlyRole(PAUSER_ROLE) {
        _pause();
    }

    function unpause() external onlyRole(PAUSER_ROLE) {
        _unpause();
    }
}
