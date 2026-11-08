// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";

interface AggregatorV3Interface {
    function latestRoundData() external view returns (
        uint80 roundId,
        int256 answer,
        uint256 startedAt,
        uint256 updatedAt,
        uint80 answeredInRound
    );
    function decimals() external view returns (uint8);
}

interface IUniswapV3Pool {
    function observe(uint32[] calldata secondsAgos)
        external view returns (
            int56[] memory tickCumulatives,
            uint160[] memory secondsPerLiquidityCumulativeX128s
        );
    function token0() external view returns (address);
    function token1() external view returns (address);
}

interface IGamingPowerUpgrade {
    function setRates(uint256 cmrUsdRate, uint256 ethUsdRate) external;
    function cmrUsdRate() external view returns (uint256);
    function ethUsdRate() external view returns (uint256);
}

/**
 * @title PriceOracleAdapter
 * @dev Reads from Chainlink (ETH/USD) + optional Uniswap V3 TWAP (CMR/ETH).
 *      Can auto-sync prices into GamingPowerUpgrade contract.
 *      Keeps both manual and auto modes — admin chooses which to use.
 */
contract PriceOracleAdapter is AccessControl, Pausable {
    bytes32 public constant OPERATOR_ROLE = keccak256("OPERATOR_ROLE");
    bytes32 public constant PAUSER_ROLE = keccak256("PAUSER_ROLE");

    // ── Chainlink ETH/USD Feed ────────────────────────────────────
    AggregatorV3Interface public chainlinkEthUsdFeed;
    uint256 public chainlinkStalenessThreshold; // max age in seconds

    // ── Uniswap V3 TWAP (CMR/ETH or CMR/WETH) ────────────────────
    IUniswapV3Pool public uniswapCmrPool;
    uint32 public twapPeriod; // TWAP window in seconds (e.g., 1800 = 30 min)
    bool public twapEnabled; // false by default until sufficient liquidity
    bool public isCmrToken0; // true if CMR is token0 in the pool

    // ── Fallback Manual Prices ────────────────────────────────────
    uint256 public manualCmrUsdRate; // admin-set fallback (18 decimals)
    uint256 public manualEthUsdRate; // admin-set fallback (18 decimals)
    uint256 public lastManualUpdate;

    // ── Target Contract ───────────────────────────────────────────
    IGamingPowerUpgrade public gamingPowerUpgrade;

    // ── Safety Bounds ─────────────────────────────────────────────
    uint256 public maxDeviationBps; // max allowed deviation from previous price (e.g., 2000 = 20%)
    uint256 public lastSyncedEthUsd;
    uint256 public lastSyncedCmrUsd;
    uint256 public lastSyncTime;
    uint256 public constant MIN_SYNC_INTERVAL = 1 hours;

    event OracleSynced(uint256 ethUsdRate, uint256 cmrUsdRate, string source);
    event ManualRateSet(uint256 cmrUsdRate, uint256 ethUsdRate);
    event ChainlinkFeedUpdated(address indexed feed, uint256 staleness);
    event UniswapPoolUpdated(address indexed pool, bool enabled);
    event DeviationBoundsUpdated(uint256 maxDeviationBps);
    event GamingPowerUpgradeSet(address indexed target);

    constructor(
        address admin,
        address _chainlinkEthUsd,
        uint256 _stalenessThreshold,
        uint256 _maxDeviationBps,
        uint256 _initialCmrUsdRate,
        uint256 _initialEthUsdRate
    ) {
        require(admin != address(0), "Invalid admin");
        require(_chainlinkEthUsd != address(0), "Invalid Chainlink feed");

        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(OPERATOR_ROLE, admin);
        _grantRole(PAUSER_ROLE, admin);

        chainlinkEthUsdFeed = AggregatorV3Interface(_chainlinkEthUsd);
        chainlinkStalenessThreshold = _stalenessThreshold;
        maxDeviationBps = _maxDeviationBps;

        manualCmrUsdRate = _initialCmrUsdRate;
        manualEthUsdRate = _initialEthUsdRate;
        lastSyncedCmrUsd = _initialCmrUsdRate;
        lastSyncedEthUsd = _initialEthUsdRate;
        lastManualUpdate = block.timestamp;

        twapPeriod = 1800; // 30 minutes default
        require(twapPeriod > 0, "PriceOracle: invalid TWAP period");
        twapEnabled = false; // disabled until pool setup
    }

    // ═══════════════════════════════════════════════════════════════
    //  CHAINLINK — ETH/USD (always available on Ethereum)
    // ═══════════════════════════════════════════════════════════════

    function getChainlinkEthUsd() public view returns (uint256, bool) {
        try chainlinkEthUsdFeed.latestRoundData() returns (
            uint80 roundId, int256 answer, uint256, uint256 updatedAt, uint80 answeredInRound
        ) {
            if (answer <= 0) return (0, false);
            if (updatedAt == 0 || updatedAt > block.timestamp) return (0, false);
            if (block.timestamp - updatedAt > chainlinkStalenessThreshold) return (0, false);
            if (answeredInRound < roundId) return (0, false);

            // Chainlink ETH/USD typically uses 8 decimals, convert to 18
            uint8 feedDecimals = chainlinkEthUsdFeed.decimals();
            if (feedDecimals > 18) return (0, false);
            uint256 price18 = uint256(answer) * (10 ** (18 - feedDecimals));
            return (price18, true);
        } catch {
            return (0, false);
        }
    }

    // ═══════════════════════════════════════════════════════════════
    //  UNISWAP V3 TWAP — CMR/ETH (available when pool exists)
    // ═══════════════════════════════════════════════════════════════

    function getUniswapCmrEthTwap() public view returns (uint256, bool) {
        if (!twapEnabled || address(uniswapCmrPool) == address(0) || twapPeriod == 0) {
            return (0, false);
        }

        uint32[] memory secondsAgos = new uint32[](2);
        secondsAgos[0] = twapPeriod;
        secondsAgos[1] = 0;

        try uniswapCmrPool.observe(secondsAgos) returns (
            int56[] memory tickCumulatives, uint160[] memory
        ) {
            int56 tickDelta = tickCumulatives[1] - tickCumulatives[0];
            int56 period = int56(int32(twapPeriod));
            int24 avgTick = int24(tickDelta / period);
            if (tickDelta < 0 && (tickDelta % period != 0)) {
                avgTick--;
            }

            if (avgTick < -887272 || avgTick > 887272) {
                return (0, false);
            }

            uint256 sqrtRatio = _getSqrtRatioAtTick(avgTick);
            uint256 price18;
            if (isCmrToken0) {
                uint256 ratioX128 = Math.mulDiv(sqrtRatio, sqrtRatio, 1 << 64);
                price18 = Math.mulDiv(ratioX128, 1e18, 1 << 128);
            } else {
                uint256 ratioX128 = Math.mulDiv(sqrtRatio, sqrtRatio, 1 << 64);
                if (ratioX128 == 0) return (0, false);
                price18 = Math.mulDiv(1e18, 1 << 128, ratioX128);
            }

            return (price18, price18 > 0);
        } catch {
            return (0, false);
        }
    }

    function getLatestPrices() public view returns (
        uint256 ethUsd,
        uint256 cmrUsd,
        string memory ethSource,
        string memory cmrSource
    ) {
        (uint256 chainlinkEth, bool chainlinkOk) = getChainlinkEthUsd();
        if (chainlinkOk) {
            ethUsd = chainlinkEth;
            ethSource = "chainlink";
        } else {
            ethUsd = manualEthUsdRate;
            ethSource = "manual";
        }

        (uint256 cmrEth, bool twapOk) = getUniswapCmrEthTwap();
        if (twapOk && ethUsd > 0) {
            cmrUsd = (cmrEth * ethUsd) / 1e18;
            cmrSource = "uniswap_twap";
        } else {
            cmrUsd = manualCmrUsdRate;
            cmrSource = "manual";
        }
    }

    function getCmrUsdPrice() public view returns (uint256) {
        (, uint256 cmrUsd, , ) = getLatestPrices();
        return cmrUsd;
    }

    function getEthUsdPrice() public view returns (uint256) {
        (uint256 ethUsd, , , ) = getLatestPrices();
        return ethUsd;
    }

    /**
     * @notice Pulls latest prices from Chainlink/TWAP and syncs to GamingPowerUpgrade.
     * @dev Can be called by OPERATOR_ROLE or by a backend scheduler.
     *      Falls back to manual rates if oracle feeds are stale/unavailable.
     */
    function syncRatesToGamingPower() external onlyRole(OPERATOR_ROLE) whenNotPaused {
        _syncRates(false);
    }

    /**
     * @notice Admin force-sync override to resolve unexpected >20% market swings without bricking the oracle.
     */
    function forceSyncRates() external onlyRole(DEFAULT_ADMIN_ROLE) whenNotPaused {
        _syncRates(true);
    }

    function _syncRates(bool ignoreDeviation) internal {
        require(block.timestamp >= lastSyncTime + MIN_SYNC_INTERVAL || ignoreDeviation, "Too frequent");
        require(address(gamingPowerUpgrade) != address(0), "Target not set");

        uint256 ethUsd;
        string memory source;

        // 1. Try Chainlink for ETH/USD
        (uint256 chainlinkEth, bool chainlinkOk) = getChainlinkEthUsd();
        if (chainlinkOk) {
            ethUsd = chainlinkEth;
            source = "chainlink";
        } else {
            ethUsd = manualEthUsdRate;
            source = "manual_fallback";
        }

        // 2. Try TWAP for CMR/USD (CMR/ETH * ETH/USD)
        uint256 cmrUsd;
        (uint256 cmrEth, bool twapOk) = getUniswapCmrEthTwap();
        if (twapOk && ethUsd > 0) {
            cmrUsd = (cmrEth * ethUsd) / 1e18;
            source = string.concat(source, "+twap");
        } else {
            cmrUsd = manualCmrUsdRate;
            source = string.concat(source, "+manual_cmr");
        }

        // 3. Deviation safety check (unless overridden by DEFAULT_ADMIN_ROLE force sync)
        if (!ignoreDeviation) {
            if (lastSyncedEthUsd > 0) {
                uint256 ethDelta = ethUsd > lastSyncedEthUsd
                    ? ethUsd - lastSyncedEthUsd
                    : lastSyncedEthUsd - ethUsd;
                require((ethDelta * 10000) / lastSyncedEthUsd <= maxDeviationBps, "ETH deviation too large");
            }
            if (lastSyncedCmrUsd > 0) {
                uint256 cmrDelta = cmrUsd > lastSyncedCmrUsd
                    ? cmrUsd - lastSyncedCmrUsd
                    : lastSyncedCmrUsd - cmrUsd;
                require((cmrDelta * 10000) / lastSyncedCmrUsd <= maxDeviationBps, "CMR deviation too large");
            }
        }

        // 4. Sync to GamingPowerUpgrade
        gamingPowerUpgrade.setRates(cmrUsd, ethUsd);

        lastSyncedEthUsd = ethUsd;
        lastSyncedCmrUsd = cmrUsd;
        lastSyncTime = block.timestamp;

        emit OracleSynced(ethUsd, cmrUsd, source);
    }

    // ═══════════════════════════════════════════════════════════════
    //  ADMIN — Manual rates + configuration
    // ═══════════════════════════════════════════════════════════════

    function setManualRates(uint256 _cmrUsd, uint256 _ethUsd) external onlyRole(OPERATOR_ROLE) {
        require(_cmrUsd > 0 && _ethUsd > 0, "Invalid rates");
        manualCmrUsdRate = _cmrUsd;
        manualEthUsdRate = _ethUsd;
        lastSyncedCmrUsd = _cmrUsd;
        lastSyncedEthUsd = _ethUsd;
        lastManualUpdate = block.timestamp;
        emit ManualRateSet(_cmrUsd, _ethUsd);
    }

    function setGamingPowerUpgrade(address _target) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(_target != address(0), "Invalid target");
        gamingPowerUpgrade = IGamingPowerUpgrade(_target);
        emit GamingPowerUpgradeSet(_target);
    }

    function setChainlinkFeed(address _feed, uint256 _staleness) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(_feed != address(0), "Invalid feed");
        chainlinkEthUsdFeed = AggregatorV3Interface(_feed);
        chainlinkStalenessThreshold = _staleness;
        emit ChainlinkFeedUpdated(_feed, _staleness);
    }

    function setUniswapPool(address _pool, bool _isCmrToken0, uint32 _twapPeriod, bool _enabled)
        external onlyRole(DEFAULT_ADMIN_ROLE)
    {
        require(_twapPeriod > 0, "PriceOracle: invalid TWAP period");
        uniswapCmrPool = IUniswapV3Pool(_pool);
        isCmrToken0 = _isCmrToken0;
        twapPeriod = _twapPeriod;
        twapEnabled = _enabled;
        emit UniswapPoolUpdated(_pool, _enabled);
    }

    function setMaxDeviation(uint256 _bps) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(_bps >= 100 && _bps <= 5000, "Deviation 1-50% only");
        maxDeviationBps = _bps;
        emit DeviationBoundsUpdated(_bps);
    }

    function pause() external onlyRole(PAUSER_ROLE) { _pause(); }
    function unpause() external onlyRole(PAUSER_ROLE) { _unpause(); }

    // ── Tick math helper (full Uniswap V3 TickMath range) ─────────
    function _getSqrtRatioAtTick(int24 tick) internal pure returns (uint256) {
        uint256 absTick = tick < 0 ? uint256(uint24(-tick)) : uint256(uint24(tick));
        require(absTick <= 887272, "PriceOracle: tick out of bounds");

        uint256 ratio = absTick & 0x1 != 0
            ? 0xfffcb933bd6fad37aa2d162d1a594001
            : 0x100000000000000000000000000000000;
        if (absTick & 0x2 != 0) ratio = (ratio * 0xfff97272373d413259a46990580e213a) >> 128;
        if (absTick & 0x4 != 0) ratio = (ratio * 0xfff2e50f5f656932ef12357cf3c7fdcc) >> 128;
        if (absTick & 0x8 != 0) ratio = (ratio * 0xffe5caca7e10e4e61c3624eaa0941cd0) >> 128;
        if (absTick & 0x10 != 0) ratio = (ratio * 0xffcb9843d60f6159c9db58835c926644) >> 128;
        if (absTick & 0x20 != 0) ratio = (ratio * 0xff973b41fa98c081472e6896dfb254c0) >> 128;
        if (absTick & 0x40 != 0) ratio = (ratio * 0xff2ea16466c96a3843ec78b326b52861) >> 128;
        if (absTick & 0x80 != 0) ratio = (ratio * 0xfe5dee046a99a2a811c461f1969c3053) >> 128;
        if (absTick & 0x100 != 0) ratio = (ratio * 0xfcbe86c7900a88aedcffc83b479aa3a4) >> 128;
        if (absTick & 0x200 != 0) ratio = (ratio * 0xf987a7253ac413176f2b074cf7815e54) >> 128;
        if (absTick & 0x400 != 0) ratio = (ratio * 0xf3392b0822b70005940c7a398e4b70f3) >> 128;
        if (absTick & 0x800 != 0) ratio = (ratio * 0xe7159475a2c29b7443b29c7fa6e889d9) >> 128;
        if (absTick & 0x1000 != 0) ratio = (ratio * 0xd097f3bdfd2022b8845ad8f792aa5825) >> 128;
        if (absTick & 0x2000 != 0) ratio = (ratio * 0xa9f746462d870fdf8a65dc1f90e061e5) >> 128;
        if (absTick & 0x4000 != 0) ratio = (ratio * 0x70d869a156d2a1b890bb3df62baf32f7) >> 128;
        if (absTick & 0x8000 != 0) ratio = (ratio * 0x31be135f97d08fd981231505542fcfa6) >> 128;
        if (absTick & 0x10000 != 0) ratio = (ratio * 0x9aa508b5b7a84e1c677de54f3e99bc9) >> 128;
        if (absTick & 0x20000 != 0) ratio = (ratio * 0x5d6af8dedb81196699c329225ee604) >> 128;
        if (absTick & 0x40000 != 0) ratio = (ratio * 0x2216e584f5fa1ea926041bedfe98) >> 128;
        if (absTick & 0x80000 != 0) ratio = (ratio * 0x48a170391f7dc42444e8fa2) >> 128;

        if (tick > 0) ratio = type(uint256).max / ratio;
        return (ratio >> 32) + (ratio % (1 << 32) == 0 ? 0 : 1);
    }
}
