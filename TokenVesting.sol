// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/**
 * @title TokenVesting
 * @dev Enforces 5-year and custom linear vesting schedules across CMR token distribution pools on Ethereum.
 */
contract TokenVesting is AccessControl, Pausable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    bytes32 public constant VESTING_MANAGER_ROLE = keccak256("VESTING_MANAGER_ROLE");
    bytes32 public constant PAUSER_ROLE = keccak256("PAUSER_ROLE");

    IERC20 public immutable token;

    struct VestingSchedule {
        address beneficiary;
        address funder;
        uint256 start;
        uint256 cliff;
        uint256 duration;
        uint256 totalAmount;
        uint256 releasedAmount;
        bool revocable;
        bool revoked;
        string poolCategory;
    }

    bytes32[] private _scheduleIds;
    mapping(bytes32 => VestingSchedule) private _schedules;
    mapping(address => uint256) private _holdersScheduleCount;

    event ScheduleCreated(
        bytes32 indexed scheduleId,
        address indexed beneficiary,
        uint256 totalAmount,
        uint256 start,
        uint256 cliff,
        uint256 duration,
        string poolCategory
    );
    event TokensReleased(bytes32 indexed scheduleId, address indexed beneficiary, uint256 amount);
    event ScheduleRevoked(bytes32 indexed scheduleId, uint256 unreleasedRefund);

    constructor(IERC20 _token, address admin) {
        require(address(_token) != address(0), "Invalid token");
        require(admin != address(0), "Invalid admin");

        token = _token;
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(VESTING_MANAGER_ROLE, admin);
        _grantRole(PAUSER_ROLE, admin);
    }

    function createVestingSchedule(
        address beneficiary,
        uint256 start,
        uint256 cliffDuration,
        uint256 duration,
        uint256 totalAmount,
        bool revocable,
        string calldata poolCategory
    ) external onlyRole(VESTING_MANAGER_ROLE) whenNotPaused returns (bytes32) {
        require(beneficiary != address(0), "Invalid beneficiary");
        require(duration > 0, "Duration must be > 0");
        require(totalAmount > 0, "Amount must be > 0");
        require(cliffDuration <= duration, "Cliff > duration");
        require(start >= block.timestamp, "Start must not be in the past");

        bytes32 scheduleId = keccak256(
            abi.encodePacked(beneficiary, start, totalAmount, _holdersScheduleCount[beneficiary], block.timestamp)
        );

        _schedules[scheduleId] = VestingSchedule({
            beneficiary: beneficiary,
            funder: msg.sender,
            start: start,
            cliff: start + cliffDuration,
            duration: duration,
            totalAmount: totalAmount,
            releasedAmount: 0,
            revocable: revocable,
            revoked: false,
            poolCategory: poolCategory
        });

        _scheduleIds.push(scheduleId);
        _holdersScheduleCount[beneficiary]++;

        token.safeTransferFrom(msg.sender, address(this), totalAmount);

        emit ScheduleCreated(scheduleId, beneficiary, totalAmount, start, start + cliffDuration, duration, poolCategory);
        return scheduleId;
    }

    function release(bytes32 scheduleId) external whenNotPaused nonReentrant {
        VestingSchedule storage schedule = _schedules[scheduleId];
        require(schedule.beneficiary != address(0), "Schedule not found");
        require(!schedule.revoked, "Schedule is revoked");

        uint256 releasable = computeReleasableAmount(scheduleId);
        require(releasable > 0, "No releasable tokens");

        // Checks-Effects-Interactions (CEI): update releasedAmount before transfer
        schedule.releasedAmount += releasable;
        token.safeTransfer(schedule.beneficiary, releasable);

        emit TokensReleased(scheduleId, schedule.beneficiary, releasable);
    }

    function revoke(bytes32 scheduleId) external onlyRole(VESTING_MANAGER_ROLE) whenNotPaused nonReentrant {
        VestingSchedule storage schedule = _schedules[scheduleId];
        require(schedule.beneficiary != address(0), "Schedule not found");
        require(schedule.revocable, "Schedule not revocable");
        require(!schedule.revoked, "Already revoked");

        uint256 releasable = computeReleasableAmount(scheduleId);
        uint256 unreleased = schedule.totalAmount - schedule.releasedAmount - releasable;

        // Checks-Effects-Interactions (CEI): mutate state before external transfers
        schedule.revoked = true;
        if (releasable > 0) {
            schedule.releasedAmount += releasable;
        }

        emit ScheduleRevoked(scheduleId, unreleased);

        // Execute external transfers
        if (releasable > 0) {
            token.safeTransfer(schedule.beneficiary, releasable);
            emit TokensReleased(scheduleId, schedule.beneficiary, releasable);
        }

        if (unreleased > 0) {
            address refundTo = schedule.funder != address(0) ? schedule.funder : msg.sender;
            token.safeTransfer(refundTo, unreleased);
        }
    }

    function computeReleasableAmount(bytes32 scheduleId) public view returns (uint256) {
        VestingSchedule storage schedule = _schedules[scheduleId];
        if (schedule.revoked || block.timestamp < schedule.cliff) {
            return 0;
        }

        if (block.timestamp >= schedule.start + schedule.duration) {
            return schedule.totalAmount - schedule.releasedAmount;
        }

        uint256 timeFromStart = block.timestamp - schedule.start;
        uint256 vestedAmount = (schedule.totalAmount * timeFromStart) / schedule.duration;
        if (vestedAmount <= schedule.releasedAmount) {
            return 0;
        }
        return vestedAmount - schedule.releasedAmount;
    }

    function getVestingSchedule(bytes32 scheduleId) external view returns (VestingSchedule memory) {
        return _schedules[scheduleId];
    }

    function getScheduleCount() external view returns (uint256) {
        return _scheduleIds.length;
    }

    function scheduleCount() external view returns (uint256) {
        return _scheduleIds.length;
    }

    function getScheduleIdAtIndex(uint256 index) external view returns (bytes32) {
        require(index < _scheduleIds.length, "Index out of bounds");
        return _scheduleIds[index];
    }

    function getSchedulesPaginated(uint256 offset, uint256 limit) external view returns (bytes32[] memory) {
        if (offset >= _scheduleIds.length) return new bytes32[](0);
        uint256 end = offset + limit;
        if (end > _scheduleIds.length || limit == 0) end = _scheduleIds.length;
        bytes32[] memory out = new bytes32[](end - offset);
        for (uint256 i = offset; i < end; i++) {
            out[i - offset] = _scheduleIds[i];
        }
        return out;
    }

    function rescueStrayTokens(IERC20 strayToken, address to, uint256 amount) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(address(strayToken) != address(token), "Cannot rescue vested token");
        require(to != address(0), "Invalid recipient");
        strayToken.safeTransfer(to, amount);
    }

    function pause() external onlyRole(PAUSER_ROLE) {
        _pause();
    }

    function unpause() external onlyRole(PAUSER_ROLE) {
        _unpause();
    }
}
