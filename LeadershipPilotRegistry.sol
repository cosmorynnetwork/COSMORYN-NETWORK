// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/access/AccessControl.sol";

/**
 * @title LeadershipPilotRegistry
 * @dev On-chain registry for Leadership Pilot tiers, qualification rules, and monthly audit attestations.
 */
contract LeadershipPilotRegistry is AccessControl {
    bytes32 public constant AUDITOR_ROLE = keccak256("AUDITOR_ROLE");

    struct PilotTier {
        string name;
        uint256 requiredMonthlyTurnoverUsd;
        uint256 monthlyBonusUsd;
        uint256 maxSingleLegShareBps;
        uint256 minActiveFirstLineDirects;
        bool active;
    }

    struct MonthlyQualification {
        bool qualified;
        uint256 tierIndex;
        uint256 totalTurnoverUsd;
        uint256 bonusUsd;
        uint256 activeFirstLineDirects;
        uint256 attestedAt;
        address attestedBy;
    }

    PilotTier[] public pilotTiers;
    mapping(bytes32 => mapping(address => MonthlyQualification)) public qualifications;

    event PilotTierConfigured(
        uint256 indexed tierIndex,
        string name,
        uint256 requiredTurnoverUsd,
        uint256 monthlyBonusUsd,
        uint256 maxSingleLegShareBps,
        uint256 minDirects,
        bool active
    );

    event QualificationAttested(
        bytes32 indexed monthKey,
        address indexed leader,
        uint256 indexed tierIndex,
        uint256 totalTurnoverUsd,
        uint256 bonusUsd,
        address attestedBy
    );

    constructor(address admin) {
        require(admin != address(0), "Invalid admin");
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(AUDITOR_ROLE, admin);

        // Tier 0: Cadet Pilot ($25k turnover, $700 bonus, 50% max leg share, 2 min active directs)
        pilotTiers.push(PilotTier({
            name: "Cadet Pilot",
            requiredMonthlyTurnoverUsd: 25000 ether,
            monthlyBonusUsd: 700 ether,
            maxSingleLegShareBps: 5000,
            minActiveFirstLineDirects: 2,
            active: true
        }));

        // Tier 1: Co-Pilot ($60k turnover, $1500 bonus, 50% max leg share, 3 min active directs)
        pilotTiers.push(PilotTier({
            name: "Co-Pilot",
            requiredMonthlyTurnoverUsd: 60000 ether,
            monthlyBonusUsd: 1500 ether,
            maxSingleLegShareBps: 5000,
            minActiveFirstLineDirects: 3,
            active: true
        }));

        // Tier 2: Captain ($150k turnover, $3000 bonus, 50% max leg share, 5 min active directs)
        pilotTiers.push(PilotTier({
            name: "Captain",
            requiredMonthlyTurnoverUsd: 150000 ether,
            monthlyBonusUsd: 3000 ether,
            maxSingleLegShareBps: 5000,
            minActiveFirstLineDirects: 5,
            active: true
        }));
    }

    function getTierCount() external view returns (uint256) {
        return pilotTiers.length;
    }

    function getPilotTier(uint256 tierIndex) external view returns (PilotTier memory) {
        require(tierIndex < pilotTiers.length, "Invalid tier index");
        return pilotTiers[tierIndex];
    }

    function setPilotTier(
        uint256 tierIndex,
        string calldata name,
        uint256 requiredMonthlyTurnoverUsd,
        uint256 monthlyBonusUsd,
        uint256 maxSingleLegShareBps,
        uint256 minActiveFirstLineDirects,
        bool active
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(maxSingleLegShareBps <= 10000, "Max leg share exceeds 10000 bps");

        PilotTier memory tier = PilotTier({
            name: name,
            requiredMonthlyTurnoverUsd: requiredMonthlyTurnoverUsd,
            monthlyBonusUsd: monthlyBonusUsd,
            maxSingleLegShareBps: maxSingleLegShareBps,
            minActiveFirstLineDirects: minActiveFirstLineDirects,
            active: active
        });

        if (tierIndex == pilotTiers.length) {
            pilotTiers.push(tier);
        } else if (tierIndex < pilotTiers.length) {
            pilotTiers[tierIndex] = tier;
        } else {
            revert("Tier index out of bounds");
        }

        emit PilotTierConfigured(
            tierIndex,
            name,
            requiredMonthlyTurnoverUsd,
            monthlyBonusUsd,
            maxSingleLegShareBps,
            minActiveFirstLineDirects,
            active
        );
    }

    function attestQualification(
        bytes32 monthKey,
        address leader,
        uint256 tierIndex,
        uint256 totalTurnoverUsd,
        uint256 bonusUsd,
        uint256 activeDirects
    ) external onlyRole(AUDITOR_ROLE) {
        require(leader != address(0), "Invalid leader");
        require(tierIndex < pilotTiers.length, "Invalid tier");

        qualifications[monthKey][leader] = MonthlyQualification({
            qualified: true,
            tierIndex: tierIndex,
            totalTurnoverUsd: totalTurnoverUsd,
            bonusUsd: bonusUsd,
            activeFirstLineDirects: activeDirects,
            attestedAt: block.timestamp,
            attestedBy: msg.sender
        });

        emit QualificationAttested(monthKey, leader, tierIndex, totalTurnoverUsd, bonusUsd, msg.sender);
    }

    function getQualification(bytes32 monthKey, address leader) external view returns (MonthlyQualification memory) {
        return qualifications[monthKey][leader];
    }
}
