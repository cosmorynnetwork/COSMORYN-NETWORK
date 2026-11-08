// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/token/ERC20/extensions/ERC20Votes.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/**
 * @title DAOGovernance
 * @dev On-chain decentralized governance for COSMORYN NETWORK ecosystem proposals on Ethereum.
 * Voting power is historical (ERC20Votes checkpoints at proposal snapshot block):
 * flash-loan and transfer-and-revote attacks cannot inflate weight.
 * Enforces 1 CMR = 1 vote, quorum threshold, voting periods, and proposal execution.
 */
contract DAOGovernance is AccessControl, Pausable, ReentrancyGuard {
    bytes32 public constant GOVERNANCE_ADMIN_ROLE = keccak256("GOVERNANCE_ADMIN_ROLE");
    bytes32 public constant PAUSER_ROLE = keccak256("PAUSER_ROLE");

    ERC20Votes public immutable cmrToken;

    enum ProposalState {
        Pending,
        Active,
        Canceled,
        Defeated,
        Succeeded,
        Executed
    }

    enum VoteType {
        Against, // 0
        For,     // 1
        Abstain  // 2
    }

    struct Proposal {
        uint256 id;
        address proposer;
        string title;
        string description;
        uint256 startTime;
        uint256 endTime;
        uint256 snapshotBlock;
        uint256 forVotes;
        uint256 againstVotes;
        uint256 abstainVotes;
        bool executed;
        bool canceled;
        address target;
        uint256 value;
        bytes data;
    }

    uint256 public proposalThreshold = 10_000 * 10 ** 18; // 10,000 CMR needed to propose
    uint256 public votingDelay = 1 days;
    uint256 public votingPeriod = 3 days;
    uint256 public quorumVotes = 1_000_000 * 10 ** 18; // 1,000,000 CMR quorum
    uint256 public maxProposalValue = 10 ether;
    uint256 public executionTimelock = 1 days;

    uint256 public nextProposalId = 1;
    mapping(uint256 => Proposal) public proposals;
    mapping(uint256 => mapping(address => bool)) public hasVoted;
    mapping(uint256 => mapping(address => uint256)) public votesCast;
    mapping(address => bool) public callTargetAllowlist;
    mapping(uint256 => uint256) public proposalQuorum;
    mapping(uint256 => uint256) public proposalTimelock;
    mapping(uint256 => bool) public proposalEthUnlocked;
    uint256 public lockedProposalEth;

    event ProposalCreated(
        uint256 indexed proposalId,
        address indexed proposer,
        string title,
        uint256 startTime,
        uint256 endTime,
        address target,
        uint256 value
    );
    event VoteCast(
        address indexed voter,
        uint256 indexed proposalId,
        uint8 support,
        uint256 weight
    );
    event ProposalExecuted(uint256 indexed proposalId);
    event ProposalCanceled(uint256 indexed proposalId);
    event ProposalEthUnlocked(uint256 indexed proposalId, uint256 amount);
    event GovernanceParamsUpdated(uint256 threshold, uint256 period, uint256 quorum);
    event GovernanceTimingUpdated(uint256 votingDelay, uint256 executionTimelock);
    event MaxProposalValueUpdated(uint256 maxValue);
    event TargetAllowlistUpdated(address indexed target, bool allowed);
    event FundsReceived(address indexed sender, uint256 amount);
    event FundsWithdrawn(address indexed recipient, uint256 amount);

    constructor(ERC20Votes _cmrToken, address admin) {
        require(address(_cmrToken) != address(0), "Invalid token");
        require(admin != address(0), "Invalid admin");

        cmrToken = _cmrToken;
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(GOVERNANCE_ADMIN_ROLE, admin);
        _grantRole(PAUSER_ROLE, admin);
    }

    receive() external payable {
        emit FundsReceived(msg.sender, msg.value);
    }

    function createProposal(
        string calldata title,
        string calldata description,
        address target,
        uint256 value,
        bytes calldata data
    ) external whenNotPaused returns (uint256) {
        uint256 snapshot = block.number - 1;
        require(cmrToken.getPastVotes(msg.sender, snapshot) >= proposalThreshold, "Below proposal threshold");
        require(target == address(0) || callTargetAllowlist[target], "Target not allowlisted");
        require(target != address(0) || value == 0, "Zero target cannot transfer value");
        require(value <= maxProposalValue, "Value exceeds cap");
        require(value <= address(this).balance - lockedProposalEth, "Insufficient governance balance");

        uint256 proposalId = nextProposalId++;
        uint256 start = block.timestamp + votingDelay;
        uint256 end = start + votingPeriod;

        proposalQuorum[proposalId] = quorumVotes;
        proposalTimelock[proposalId] = executionTimelock;
        lockedProposalEth += value;

        proposals[proposalId] = Proposal({
            id: proposalId,
            proposer: msg.sender,
            title: title,
            description: description,
            startTime: start,
            endTime: end,
            snapshotBlock: snapshot,
            forVotes: 0,
            againstVotes: 0,
            abstainVotes: 0,
            executed: false,
            canceled: false,
            target: target,
            value: value,
            data: data
        });

        emit ProposalCreated(proposalId, msg.sender, title, start, end, target, value);
        return proposalId;
    }

    function castVote(uint256 proposalId, VoteType support) external whenNotPaused nonReentrant {
        require(state(proposalId) == ProposalState.Active, "Voting closed");
        require(!hasVoted[proposalId][msg.sender], "Already voted");

        // Historical weight at proposal snapshot block: immune to flash-loans
        // and transfer-and-revote (tokens must be held AND delegated before creation).
        Proposal storage p = proposals[proposalId];
        uint256 weight = cmrToken.getPastVotes(msg.sender, p.snapshotBlock);
        require(weight > 0, "No voting weight at snapshot");

        hasVoted[proposalId][msg.sender] = true;
        votesCast[proposalId][msg.sender] = weight;

        if (support == VoteType.For) {
            p.forVotes += weight;
        } else if (support == VoteType.Against) {
            p.againstVotes += weight;
        } else if (support == VoteType.Abstain) {
            p.abstainVotes += weight;
        }

        emit VoteCast(msg.sender, proposalId, uint8(support), weight);
    }

    function executeProposal(uint256 proposalId) external whenNotPaused nonReentrant {
        require(state(proposalId) == ProposalState.Succeeded, "Proposal not succeeded");
        Proposal storage p = proposals[proposalId];
        uint256 requiredTimelock = proposalTimelock[proposalId] > 0 ? proposalTimelock[proposalId] : executionTimelock;
        require(block.timestamp >= p.endTime + requiredTimelock, "Execution timelock not elapsed");
        require(p.target == address(0) || callTargetAllowlist[p.target], "Target not allowlisted");
        require(p.value <= maxProposalValue && p.value <= address(this).balance, "Value exceeds cap");
        p.executed = true;
        if (lockedProposalEth >= p.value) {
            lockedProposalEth -= p.value;
        } else {
            lockedProposalEth = 0;
        }

        if (p.target != address(0)) {
            (bool success, ) = p.target.call{ value: p.value }(p.data);
            require(success, "Proposal call execution failed");
        }

        emit ProposalExecuted(proposalId);
    }

    function cancelProposal(uint256 proposalId) external whenNotPaused {
        Proposal storage p = proposals[proposalId];
        require(msg.sender == p.proposer || hasRole(GOVERNANCE_ADMIN_ROLE, msg.sender), "Not authorized to cancel");
        ProposalState s = state(proposalId);
        require(s == ProposalState.Pending || s == ProposalState.Active, "Cannot cancel after vote closes");

        p.canceled = true;
        if (lockedProposalEth >= p.value) {
            lockedProposalEth -= p.value;
        } else {
            lockedProposalEth = 0;
        }
        emit ProposalCanceled(proposalId);
    }

    function cancelFailedProposal(uint256 proposalId) external whenNotPaused {
        Proposal storage p = proposals[proposalId];
        require(hasRole(GOVERNANCE_ADMIN_ROLE, msg.sender) || msg.sender == p.proposer, "Not authorized");
        require(state(proposalId) == ProposalState.Succeeded, "Proposal not succeeded");
        require(!p.executed, "Already executed");
        uint256 requiredTimelock = proposalTimelock[proposalId] > 0 ? proposalTimelock[proposalId] : executionTimelock;
        require(block.timestamp >= p.endTime + requiredTimelock, "Execution timelock not elapsed");

        p.canceled = true;
        if (lockedProposalEth >= p.value) {
            lockedProposalEth -= p.value;
        } else {
            lockedProposalEth = 0;
        }
        emit ProposalCanceled(proposalId);
    }

    function unlockDefeatedProposalEth(uint256 proposalId) external whenNotPaused {
        require(state(proposalId) == ProposalState.Defeated, "Proposal not defeated");
        Proposal storage p = proposals[proposalId];
        require(!proposalEthUnlocked[proposalId], "Already unlocked");
        require(p.value > 0, "No ETH to unlock");

        proposalEthUnlocked[proposalId] = true;
        if (lockedProposalEth >= p.value) {
            lockedProposalEth -= p.value;
        } else {
            lockedProposalEth = 0;
        }

        emit ProposalEthUnlocked(proposalId, p.value);
    }

    function state(uint256 proposalId) public view returns (ProposalState) {
        Proposal memory p = proposals[proposalId];
        require(p.id != 0, "Proposal does not exist");

        if (p.canceled) return ProposalState.Canceled;
        if (p.executed) return ProposalState.Executed;
        if (block.timestamp < p.startTime) return ProposalState.Pending;
        if (block.timestamp <= p.endTime) return ProposalState.Active;

        uint256 requiredQuorum = proposalQuorum[proposalId] > 0 ? proposalQuorum[proposalId] : quorumVotes;
        uint256 totalVotes = p.forVotes + p.againstVotes + p.abstainVotes;
        if (totalVotes < requiredQuorum || p.forVotes <= p.againstVotes) {
            return ProposalState.Defeated;
        }

        return ProposalState.Succeeded;
    }

    function setGovernanceParams(
        uint256 _threshold,
        uint256 _period,
        uint256 _quorum
    ) external onlyRole(GOVERNANCE_ADMIN_ROLE) {
        require(_threshold > 0, "Threshold must be > 0");
        require(_period >= 1 days && _period <= 14 days, "Invalid voting period");
        require(_quorum > 0, "Quorum must be > 0");
        proposalThreshold = _threshold;
        votingPeriod = _period;
        quorumVotes = _quorum;
        emit GovernanceParamsUpdated(_threshold, _period, _quorum);
    }

    function setVotingDelay(uint256 _delay) external onlyRole(GOVERNANCE_ADMIN_ROLE) {
        require(_delay <= 7 days, "Delay too long");
        votingDelay = _delay;
        emit GovernanceTimingUpdated(_delay, executionTimelock);
    }

    function setExecutionTimelock(uint256 _timelock) external onlyRole(GOVERNANCE_ADMIN_ROLE) {
        require(_timelock <= 14 days, "Timelock too long");
        executionTimelock = _timelock;
        emit GovernanceTimingUpdated(votingDelay, _timelock);
    }

    function setCallTargetAllowlist(address target, bool allowed) external onlyRole(GOVERNANCE_ADMIN_ROLE) {
        require(target != address(0), "Invalid target");
        callTargetAllowlist[target] = allowed;
        emit TargetAllowlistUpdated(target, allowed);
    }

    function setMaxProposalValue(uint256 _maxValue) external onlyRole(GOVERNANCE_ADMIN_ROLE) {
        maxProposalValue = _maxValue;
        emit MaxProposalValueUpdated(_maxValue);
    }

    function withdrawFunds(address payable recipient, uint256 amount) external onlyRole(GOVERNANCE_ADMIN_ROLE) whenNotPaused nonReentrant {
        require(recipient != address(0), "Invalid recipient");
        require(callTargetAllowlist[recipient], "Recipient not allowlisted");
        require(amount > 0, "Amount must be > 0");
        require(amount <= maxProposalValue, "Amount exceeds cap");
        require(amount <= address(this).balance - lockedProposalEth, "Insufficient balance");
        (bool ok, ) = recipient.call{ value: amount }("");
        require(ok, "Withdraw failed");
        emit FundsWithdrawn(recipient, amount);
    }

    function pause() external onlyRole(PAUSER_ROLE) {
        _pause();
    }

    function unpause() external onlyRole(PAUSER_ROLE) {
        _unpause();
    }
}
