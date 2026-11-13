// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "./interfaces/IPriceOracleAdapter.sol";

/**
 * @title ManagedTradingVault
 * @dev Manages capital intake for Managed Forex Trading with on-chain USD minimums,
 * 3-line team bonus configuration, direct reserve forwarding, and audited principal return.
 */
contract ManagedTradingVault is AccessControl, Pausable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    bytes32 public constant TRADING_MANAGER_ROLE   = keccak256("TRADING_MANAGER_ROLE");
    bytes32 public constant PRINCIPAL_SETTLER_ROLE = keccak256("PRINCIPAL_SETTLER_ROLE");
    bytes32 public constant PAUSER_ROLE            = keccak256("PAUSER_ROLE");

    IERC20 public immutable cmrToken;
    IERC20 public usdtToken;
    IPriceOracleAdapter public priceOracle;
    address public reserveTreasury;

    enum AssetType {
        CMR,
        USDT,
        ETH
    }

    // Team bonus basis points across 3 lines: [Line 1, Line 2, Line 3]
    // Default: 800, 400, 300 (8%, 4%, 3% = 15% total)
    uint256[3] public teamBonusBps = [800, 400, 300];
    uint256 public constant MAX_TEAM_BONUS_BPS = 2500; // 25% max total

    uint256 public minTradingDepositUsd = 50 ether; // $50 USD
    uint256 public fallbackCmrUsdRate = 0.10 ether; // $0.10 USD
    uint256 public fallbackEthUsdRate = 3500 ether; // $3,500 USD per ETH
    uint256 public constant SLIPPAGE_TOLERANCE_BPS = 100; // 1%
    uint256 public statementExtraCheckFeeCmr = 5 ether; // 5 CMR

    struct TradingPosition {
        uint256 id;
        address player;
        uint256 principalCmr;
        uint256 principalUsdAtDeposit;
        uint256 depositedAt;
        uint256 principalReturnedCmr;
        uint256 lastReturnedAt;
        bool withdrawalRequested;
        bool active;
    }

    uint256 public nextPositionId = 1;
    mapping(uint256 => TradingPosition) public positions;
    mapping(address => uint256[]) public playerPositions;
    mapping(bytes32 => bool) public processedReturnRequestIds;
    mapping(uint256 => AssetType) public positionAssetType;
    mapping(uint256 => uint256) public positionNativePrincipal;
    mapping(uint256 => uint256) public positionNativeReturned;

    uint256 public totalActivePrincipalCmr;
    uint256 public totalPrincipalReturnedCmr;
    uint256 public totalActivePrincipalUsdt;
    uint256 public totalActivePrincipalEth;

    event TradingCapitalDeposited(
        uint256 indexed positionId,
        address indexed player,
        uint256 amountCmr,
        uint256 amountUsd,
        uint256 timestamp
    );
    event TradingCapitalDepositedAsset(
        uint256 indexed positionId,
        address indexed player,
        AssetType indexed assetType,
        uint256 nativeAmount,
        uint256 amountUsd,
        uint256 timestamp
    );
    event UsdtTokenUpdated(address indexed newUsdtToken);
    event FallbackEthUsdRateUpdated(uint256 newRate);
    event TradingPrincipalReturnRequested(
        uint256 indexed positionId,
        address indexed player,
        uint256 requestedAmountCmr,
        uint256 timestamp
    );
    event TradingPrincipalReturned(
        bytes32 indexed requestId,
        uint256 indexed positionId,
        address indexed player,
        uint256 amountCmr,
        uint256 amountUsdAtReturn,
        address processedBy,
        uint256 timestamp
    );
    event TeamBonusConfigUpdated(uint256[3] newTeamBonusBps);
    event MinTradingDepositUsdUpdated(uint256 oldMinUsd, uint256 newMinUsd);
    event ReserveTreasuryUpdated(address indexed newTreasury);
    event PriceOracleUpdated(address indexed newOracle);
    event StatementExtraCheckFeeUpdated(uint256 oldFeeCmr, uint256 newFeeCmr);

    constructor(IERC20 _cmrToken, address _reserveTreasury, address admin) {
        require(address(_cmrToken) != address(0), "Invalid token");
        require(admin != address(0), "Invalid admin");

        cmrToken = _cmrToken;
        reserveTreasury = _reserveTreasury;

        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(TRADING_MANAGER_ROLE, admin);
        _grantRole(PRINCIPAL_SETTLER_ROLE, admin);
        _grantRole(PAUSER_ROLE, admin);
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

    function getMinTradingDepositCmr() public view returns (uint256) {
        return usdToCmr(minTradingDepositUsd);
    }

    function getTeamBonusBps() external view returns (uint256[3] memory) {
        return teamBonusBps;
    }

    function depositCapital(uint256 cmrAmount) external whenNotPaused nonReentrant returns (uint256) {
        require(reserveTreasury != address(0), "Reserve treasury not configured");
        require(cmrAmount > 0, "Amount must be > 0");

        uint256 price = getCmrUsdPrice();
        uint256 usdValue = (cmrAmount * price) / 1e18;
        require(
            usdValue * 10000 >= minTradingDepositUsd * (10000 - SLIPPAGE_TOLERANCE_BPS),
            "Deposit below minimum USD"
        );

        // Immediate direct forwarding to reserve treasury: zero idle custody in vault
        cmrToken.safeTransferFrom(msg.sender, reserveTreasury, cmrAmount);

        uint256 positionId = nextPositionId++;
        positions[positionId] = TradingPosition({
            id: positionId,
            player: msg.sender,
            principalCmr: cmrAmount,
            principalUsdAtDeposit: usdValue,
            depositedAt: block.timestamp,
            principalReturnedCmr: 0,
            lastReturnedAt: 0,
            withdrawalRequested: false,
            active: true
        });

        playerPositions[msg.sender].push(positionId);
        positionAssetType[positionId] = AssetType.CMR;
        positionNativePrincipal[positionId] = cmrAmount;
        totalActivePrincipalCmr += cmrAmount;

        emit TradingCapitalDeposited(positionId, msg.sender, cmrAmount, usdValue, block.timestamp);
        emit TradingCapitalDepositedAsset(positionId, msg.sender, AssetType.CMR, cmrAmount, usdValue, block.timestamp);
        return positionId;
    }

    function depositCapitalUsdt(uint256 usdtAmount) external whenNotPaused nonReentrant returns (uint256) {
        require(reserveTreasury != address(0), "Reserve treasury not configured");
        require(address(usdtToken) != address(0), "USDT token not configured");
        require(usdtAmount > 0, "Amount must be > 0");

        // USDT is 6 decimals; convert to 18-decimal USD value
        uint256 usdValue = usdtAmount * 1e12;
        require(
            usdValue * 10000 >= minTradingDepositUsd * (10000 - SLIPPAGE_TOLERANCE_BPS),
            "Deposit below minimum USD"
        );

        usdtToken.safeTransferFrom(msg.sender, reserveTreasury, usdtAmount);

        uint256 cmrEquiv = usdToCmr(usdValue);
        uint256 positionId = nextPositionId++;
        positions[positionId] = TradingPosition({
            id: positionId,
            player: msg.sender,
            principalCmr: cmrEquiv,
            principalUsdAtDeposit: usdValue,
            depositedAt: block.timestamp,
            principalReturnedCmr: 0,
            lastReturnedAt: 0,
            withdrawalRequested: false,
            active: true
        });

        playerPositions[msg.sender].push(positionId);
        positionAssetType[positionId] = AssetType.USDT;
        positionNativePrincipal[positionId] = usdtAmount;
        totalActivePrincipalUsdt += usdtAmount;

        emit TradingCapitalDeposited(positionId, msg.sender, cmrEquiv, usdValue, block.timestamp);
        emit TradingCapitalDepositedAsset(positionId, msg.sender, AssetType.USDT, usdtAmount, usdValue, block.timestamp);
        return positionId;
    }

    function depositCapitalEth() external payable whenNotPaused nonReentrant returns (uint256) {
        require(reserveTreasury != address(0), "Reserve treasury not configured");
        require(msg.value > 0, "ETH amount must be > 0");

        uint256 usdValue = (msg.value * fallbackEthUsdRate) / 1e18;
        require(
            usdValue * 10000 >= minTradingDepositUsd * (10000 - SLIPPAGE_TOLERANCE_BPS),
            "Deposit below minimum USD"
        );

        (bool sent, ) = payable(reserveTreasury).call{ value: msg.value }("");
        require(sent, "ETH forwarding to reserve treasury failed");

        uint256 cmrEquiv = usdToCmr(usdValue);
        uint256 positionId = nextPositionId++;
        positions[positionId] = TradingPosition({
            id: positionId,
            player: msg.sender,
            principalCmr: cmrEquiv,
            principalUsdAtDeposit: usdValue,
            depositedAt: block.timestamp,
            principalReturnedCmr: 0,
            lastReturnedAt: 0,
            withdrawalRequested: false,
            active: true
        });

        playerPositions[msg.sender].push(positionId);
        positionAssetType[positionId] = AssetType.ETH;
        positionNativePrincipal[positionId] = msg.value;
        totalActivePrincipalEth += msg.value;

        emit TradingCapitalDeposited(positionId, msg.sender, cmrEquiv, usdValue, block.timestamp);
        emit TradingCapitalDepositedAsset(positionId, msg.sender, AssetType.ETH, msg.value, usdValue, block.timestamp);
        return positionId;
    }

    function setUsdtToken(IERC20 _usdtToken) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(address(_usdtToken) != address(0), "Invalid USDT token");
        usdtToken = _usdtToken;
        emit UsdtTokenUpdated(address(_usdtToken));
    }

    function setFallbackEthUsdRate(uint256 _rate) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(_rate > 0, "Rate must be > 0");
        fallbackEthUsdRate = _rate;
        emit FallbackEthUsdRateUpdated(_rate);
    }

    function requestPrincipalReturn(uint256 positionId) external whenNotPaused nonReentrant {
        TradingPosition storage pos = positions[positionId];
        require(pos.player == msg.sender, "Not position owner");
        require(pos.active, "Position inactive");
        require(!pos.withdrawalRequested, "Withdrawal already requested");

        pos.withdrawalRequested = true;
        uint256 remainingPrincipal = pos.principalCmr - pos.principalReturnedCmr;

        emit TradingPrincipalReturnRequested(positionId, msg.sender, remainingPrincipal, block.timestamp);
    }

    function returnPrincipalToUser(
        bytes32 requestId,
        uint256 positionId,
        uint256 amountCmr
    ) external onlyRole(PRINCIPAL_SETTLER_ROLE) nonReentrant {
        require(!processedReturnRequestIds[requestId], "Return request already processed");
        require(positionId > 0 && positionId < nextPositionId, "Invalid position id");

        TradingPosition storage pos = positions[positionId];
        require(pos.active, "Position inactive");

        uint256 unreturned = pos.principalCmr - pos.principalReturnedCmr;
        require(amountCmr > 0 && amountCmr <= unreturned, "Invalid return amount");

        processedReturnRequestIds[requestId] = true;
        pos.principalReturnedCmr += amountCmr;
        pos.lastReturnedAt = block.timestamp;

        if (pos.principalReturnedCmr == pos.principalCmr) {
            pos.active = false;
        }

        totalActivePrincipalCmr -= amountCmr;
        totalPrincipalReturnedCmr += amountCmr;

        // Payout to player: if vault holds balance, transfer directly; else transferFrom caller
        uint256 vaultBal = cmrToken.balanceOf(address(this));
        if (vaultBal >= amountCmr) {
            cmrToken.safeTransfer(pos.player, amountCmr);
        } else {
            cmrToken.safeTransferFrom(msg.sender, pos.player, amountCmr);
        }

        uint256 usdAtReturn = cmrToUsd(amountCmr);
        emit TradingPrincipalReturned(
            requestId,
            positionId,
            pos.player,
            amountCmr,
            usdAtReturn,
            msg.sender,
            block.timestamp
        );
    }

    function setTeamBonusConfig(uint256[3] calldata newTeamBonusBps) external {
        require(
            hasRole(DEFAULT_ADMIN_ROLE, msg.sender) || hasRole(TRADING_MANAGER_ROLE, msg.sender),
            "Unauthorized team bonus update"
        );
        require(
            newTeamBonusBps[0] + newTeamBonusBps[1] + newTeamBonusBps[2] <= MAX_TEAM_BONUS_BPS,
            "Team bonus exceeds max cap"
        );
        teamBonusBps = newTeamBonusBps;
        emit TeamBonusConfigUpdated(newTeamBonusBps);
    }

    function setMinTradingDepositUsd(uint256 _minUsd) external onlyRole(DEFAULT_ADMIN_ROLE) {
        uint256 oldMin = minTradingDepositUsd;
        minTradingDepositUsd = _minUsd;
        emit MinTradingDepositUsdUpdated(oldMin, _minUsd);
    }

    function setReserveTreasury(address _treasury) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(_treasury != address(0), "Invalid treasury address");
        reserveTreasury = _treasury;
        emit ReserveTreasuryUpdated(_treasury);
    }

    function setPriceOracle(address _oracle) external onlyRole(DEFAULT_ADMIN_ROLE) {
        priceOracle = IPriceOracleAdapter(_oracle);
        emit PriceOracleUpdated(_oracle);
    }

    function setStatementExtraCheckFeeCmr(uint256 _feeCmr) external onlyRole(DEFAULT_ADMIN_ROLE) {
        uint256 oldFee = statementExtraCheckFeeCmr;
        statementExtraCheckFeeCmr = _feeCmr;
        emit StatementExtraCheckFeeUpdated(oldFee, _feeCmr);
    }

    function setFallbackCmrUsdRate(uint256 _rate) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(_rate > 0, "Rate must be > 0");
        fallbackCmrUsdRate = _rate;
    }

    function getPlayerPositions(
        address player,
        uint256 offset,
        uint256 limit
    ) external view returns (TradingPosition[] memory) {
        uint256[] memory ids = playerPositions[player];
        if (offset >= ids.length) return new TradingPosition[](0);
        uint256 end = offset + limit;
        if (end > ids.length || limit == 0) end = ids.length;

        TradingPosition[] memory result = new TradingPosition[](end - offset);
        for (uint256 i = offset; i < end; i++) {
            result[i - offset] = positions[ids[i]];
        }
        return result;
    }

    function pause() external onlyRole(PAUSER_ROLE) {
        _pause();
    }

    function unpause() external onlyRole(PAUSER_ROLE) {
        _unpause();
    }
}
