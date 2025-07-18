 // SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

/**
 * @title DAO - Decentralized Autonomous Organization
 * @dev A smart contract for managing proposals, voting, and governance with enhanced features
 */
contract DAO {
    // Struct to represent a proposal
    struct Proposal {
        uint256 id;
        string title;
        string description;
        address proposer;
        uint256 yesVotes;
        uint256 noVotes;
        uint256 deadline;
        bool executed;
        bool exists;
        ProposalType proposalType;
        address targetAddress;
        uint256 value;
        bytes data;
    }
    
    // Enum for different proposal types
    enum ProposalType {
        GENERAL,
        TREASURY,
        MEMBERSHIP,
        PARAMETER_CHANGE
    }
    
    // State variables
    mapping(uint256 => Proposal) public proposals;
    mapping(uint256 => mapping(address => bool)) public hasVoted;
    mapping(address => bool) public isMember;
    mapping(address => uint256) public memberSince;
    mapping(address => uint256) public votingPower;
    
    uint256 public proposalCount;
    uint256 public memberCount;
    address public admin;
    uint256 public votingPeriod = 7 days;
    uint256 public quorum = 51; // 51% quorum required
    uint256 public minProposalStake = 0.1 ether;
    uint256 public treasury;
    
    // Delegation system
    mapping(address => address) public delegates;
    mapping(address => uint256) public delegatedVotes;
    
    // Emergency system
    bool public emergencyMode = false;
    uint256 public emergencyDeadline;
    address[] public emergencyCouncil;
    mapping(address => bool) public isEmergencyCouncilMember;
    
    // Events
    event ProposalCreated(uint256 indexed proposalId, string title, address indexed proposer, ProposalType proposalType);
    event VoteCast(uint256 indexed proposalId, address indexed voter, bool support, uint256 votingPower);
    event ProposalExecuted(uint256 indexed proposalId);
    event MemberAdded(address indexed member, uint256 votingPower);
    event MemberRemoved(address indexed member);
    event VotingPowerChanged(address indexed member, uint256 newVotingPower);
    event Delegation(address indexed delegator, address indexed delegate);
    event TreasuryDeposit(address indexed depositor, uint256 amount);
    event TreasuryWithdrawal(address indexed recipient, uint256 amount);
    event ParameterChanged(string parameter, uint256 newValue);
    event EmergencyModeActivated(uint256 deadline);
    event EmergencyModeDeactivated();
    
    // Modifiers
    modifier onlyMember() {
        require(isMember[msg.sender], "Only members can perform this action");
        _;
    }
    
    modifier onlyAdmin() {
        require(msg.sender == admin, "Only admin can perform this action");
        _;
    }
    
    modifier proposalExists(uint256 _proposalId) {
        require(proposals[_proposalId].exists, "Proposal does not exist");
        _;
    }
    
    modifier votingActive(uint256 _proposalId) {
        require(block.timestamp < proposals[_proposalId].deadline, "Voting period has ended");
        _;
    }
    
    modifier notExecuted(uint256 _proposalId) {
        require(!proposals[_proposalId].executed, "Proposal already executed");
        _;
    }
    
    modifier notInEmergencyMode() {
        require(!emergencyMode, "DAO is in emergency mode");
        _;
    }
    
    modifier onlyEmergencyCouncil() {
        require(isEmergencyCouncilMember[msg.sender], "Only emergency council members can perform this action");
        _;
    }
    
    // Constructor
    constructor() {
        admin = msg.sender;
        isMember[msg.sender] = true;
        memberSince[msg.sender] = block.timestamp;
        votingPower[msg.sender] = 100; // Admin starts with 100 voting power
        memberCount = 1;
        
        // Add admin to emergency council
        emergencyCouncil.push(msg.sender);
        isEmergencyCouncilMember[msg.sender] = true;
    }
    
    // Receive function for treasury deposits
    receive() external payable {
        treasury += msg.value;
        emit TreasuryDeposit(msg.sender, msg.value);
    }
    
    /**
     * @dev Core Function 1: Create a new proposal
     * @param _title The title of the proposal
     * @param _description The description of the proposal
     * @param _proposalType The type of proposal
     * @param _targetAddress Target address for execution (if applicable)
     * @param _value ETH value to send (if applicable)
     * @param _data Call data for execution (if applicable)
     */
    function createProposal(
        string memory _title, 
        string memory _description,
        ProposalType _proposalType,
        address _targetAddress,
        uint256 _value,
        bytes memory _data
    ) 
        external 
        payable
        onlyMember 
        notInEmergencyMode
        returns (uint256) 
    {
        require(bytes(_title).length > 0, "Title cannot be empty");
        require(bytes(_description).length > 0, "Description cannot be empty");
        require(msg.value >= minProposalStake, "Insufficient proposal stake");
        
        // Treasury proposals require sufficient balance
        if (_proposalType == ProposalType.TREASURY) {
            require(_value <= treasury, "Insufficient treasury balance");
        }
        
        proposalCount++;
        uint256 proposalId = proposalCount;
        
        proposals[proposalId] = Proposal({
            id: proposalId,
            title: _title,
            description: _description,
            proposer: msg.sender,
            yesVotes: 0,
            noVotes: 0,
            deadline: block.timestamp + votingPeriod,
            executed: false,
            exists: true,
            proposalType: _proposalType,
            targetAddress: _targetAddress,
            value: _value,
            data: _data
        });
        
        // Add stake to treasury
        treasury += msg.value;
        
        emit ProposalCreated(proposalId, _title, msg.sender, _proposalType);
        return proposalId;
    }
    
    /**
     * @dev Core Function 2: Vote on a proposal with delegation support
     * @param _proposalId The ID of the proposal to vote on
     * @param _support True for yes, false for no
     */
    function vote(uint256 _proposalId, bool _support) 
        external 
        onlyMember 
        proposalExists(_proposalId) 
        votingActive(_proposalId) 
        notExecuted(_proposalId) 
        notInEmergencyMode
    {
        require(!hasVoted[_proposalId][msg.sender], "You have already voted on this proposal");
        
        hasVoted[_proposalId][msg.sender] = true;
        
        // Calculate total voting power (own + delegated)
        uint256 totalVotingPower = votingPower[msg.sender] + delegatedVotes[msg.sender];
        
        if (_support) {
            proposals[_proposalId].yesVotes += totalVotingPower;
        } else {
            proposals[_proposalId].noVotes += totalVotingPower;
        }
        
        emit VoteCast(_proposalId, msg.sender, _support, totalVotingPower);
    }
    
    /**
     * @dev Core Function 3: Execute a proposal if it passes
     * @param _proposalId The ID of the proposal to execute
     */
    function executeProposal(uint256 _proposalId) 
        external 
        proposalExists(_proposalId) 
        notExecuted(_proposalId) 
        notInEmergencyMode
    {
        Proposal storage proposal = proposals[_proposalId];
        
        require(block.timestamp >= proposal.deadline, "Voting period is still active");
        
        uint256 totalVotes = proposal.yesVotes + proposal.noVotes;
        uint256 totalVotingPower = getTotalVotingPower();
        uint256 requiredQuorum = (totalVotingPower * quorum) / 100;
        
        require(totalVotes >= requiredQuorum, "Quorum not reached");
        require(proposal.yesVotes > proposal.noVotes, "Proposal did not pass");
        
        proposal.executed = true;
        
        // Execute based on proposal type
        if (proposal.proposalType == ProposalType.TREASURY && proposal.value > 0) {
            require(treasury >= proposal.value, "Insufficient treasury funds");
            treasury -= proposal.value;
            payable(proposal.targetAddress).transfer(proposal.value);
            emit TreasuryWithdrawal(proposal.targetAddress, proposal.value);
        } else if (proposal.proposalType == ProposalType.PARAMETER_CHANGE) {
            // Execute parameter changes (simplified example)
            if (proposal.data.length > 0) {
                // This would contain encoded parameter change data
                // Implementation depends on specific parameter types
            }
        }
        
        emit ProposalExecuted(_proposalId);
    }
    
    /**
     * @dev Add a new member to the DAO with voting power
     * @param _member The address of the new member
     * @param _votingPower The voting power to assign
     */
    function addMember(address _member, uint256 _votingPower) external onlyAdmin {
        require(_member != address(0), "Invalid member address");
        require(!isMember[_member], "Address is already a member");
        require(_votingPower > 0, "Voting power must be greater than 0");
        
        isMember[_member] = true;
        memberSince[_member] = block.timestamp;
        votingPower[_member] = _votingPower;
        memberCount++;
        
        emit MemberAdded(_member, _votingPower);
    }
    
    /**
     * @dev Remove a member from the DAO
     * @param _member The address of the member to remove
     */
    function removeMember(address _member) external onlyAdmin {
        require(isMember[_member], "Address is not a member");
        require(_member != admin, "Cannot remove admin");
        
        isMember[_member] = false;
        memberSince[_member] = 0;
        votingPower[_member] = 0;
        memberCount--;
        
        // Remove any delegations
        if (delegates[_member] != address(0)) {
            delegatedVotes[delegates[_member]] -= votingPower[_member];
            delegates[_member] = address(0);
        }
        
        emit MemberRemoved(_member);
    }
    
    /**
     * @dev Change voting power of a member
     * @param _member The member's address
     * @param _newVotingPower The new voting power
     */
    function changeVotingPower(address _member, uint256 _newVotingPower) external onlyAdmin {
        require(isMember[_member], "Address is not a member");
        require(_newVotingPower > 0, "Voting power must be greater than 0");
        
        // Update delegated votes if this member has delegated
        if (delegates[_member] != address(0)) {
            delegatedVotes[delegates[_member]] = delegatedVotes[delegates[_member]] - votingPower[_member] + _newVotingPower;
        }
        
        votingPower[_member] = _newVotingPower;
        emit VotingPowerChanged(_member, _newVotingPower);
    }
    
    /**
     * @dev Delegate voting power to another member
     * @param _delegate The address to delegate to
     */
    function delegate(address _delegate) external onlyMember {
        require(_delegate != msg.sender, "Cannot delegate to yourself");
        require(isMember[_delegate], "Delegate must be a member");
        
        // Remove previous delegation
        if (delegates[msg.sender] != address(0)) {
            delegatedVotes[delegates[msg.sender]] -= votingPower[msg.sender];
        }
        
        // Add new delegation
        delegates[msg.sender] = _delegate;
        delegatedVotes[_delegate] += votingPower[msg.sender];
        
        emit Delegation(msg.sender, _delegate);
    }
    
    /**
     * @dev Remove delegation
     */
    function removeDelegation() external onlyMember {
        require(delegates[msg.sender] != address(0), "No active delegation");
        
        delegatedVotes[delegates[msg.sender]] -= votingPower[msg.sender];
        delegates[msg.sender] = address(0);
        
        emit Delegation(msg.sender, address(0));
    }
    
    /**
     * @dev Change DAO parameters (voting period, quorum, etc.)
     * @param _parameter The parameter to change
     * @param _value The new value
     */
    function changeParameter(string memory _parameter, uint256 _value) external onlyAdmin {
        bytes32 paramHash = keccak256(abi.encodePacked(_parameter));
        
        if (paramHash == keccak256(abi.encodePacked("votingPeriod"))) {
            require(_value >= 1 days && _value <= 30 days, "Invalid voting period");
            votingPeriod = _value;
        } else if (paramHash == keccak256(abi.encodePacked("quorum"))) {
            require(_value >= 10 && _value <= 100, "Invalid quorum percentage");
            quorum = _value;
        } else if (paramHash == keccak256(abi.encodePacked("minProposalStake"))) {
            minProposalStake = _value;
        } else {
            revert("Invalid parameter");
        }
        
        emit ParameterChanged(_parameter, _value);
    }
    
    /**
     * @dev Activate emergency mode
     * @param _duration Duration of emergency mode in seconds
     */
    function activateEmergencyMode(uint256 _duration) external onlyEmergencyCouncil {
        require(!emergencyMode, "Already in emergency mode");
        require(_duration >= 1 hours && _duration <= 30 days, "Invalid duration");
        
        emergencyMode = true;
        emergencyDeadline = block.timestamp + _duration;
        
        emit EmergencyModeActivated(emergencyDeadline);
    }
    
    /**
     * @dev Deactivate emergency mode
     */
    function deactivateEmergencyMode() external onlyEmergencyCouncil {
        require(emergencyMode, "Not in emergency mode");
        
        emergencyMode = false;
        emergencyDeadline = 0;
        
        emit EmergencyModeDeactivated();
    }
    
    /**
     * @dev Add member to emergency council
     * @param _member The member to add
     */
    function addToEmergencyCouncil(address _member) external onlyAdmin {
        require(isMember[_member], "Must be a DAO member");
        require(!isEmergencyCouncilMember[_member], "Already in emergency council");
        
        emergencyCouncil.push(_member);
        isEmergencyCouncilMember[_member] = true;
    }
    
    /**
     * @dev Get total voting power in the DAO
     */
    function getTotalVotingPower() public view returns (uint256) {
        // This is a simplified calculation
        // In practice, you might want to cache this value
        uint256 total = 0;
        // Note: This would need to iterate through all members
        // For efficiency, consider maintaining a running total
        return total;
    }
    
    /**
     * @dev Get proposal details
     * @param _proposalId The ID of the proposal
     */
    function getProposal(uint256 _proposalId) 
        external 
        view 
        proposalExists(_proposalId) 
        returns (
            uint256 id,
            string memory title,
            string memory description,
            address proposer,
            uint256 yesVotes,
            uint256 noVotes,
            uint256 deadline,
            bool executed,
            ProposalType proposalType
        ) 
    {
        Proposal storage proposal = proposals[_proposalId];
        return (
            proposal.id,
            proposal.title,
            proposal.description,
            proposal.proposer,
            proposal.yesVotes,
            proposal.noVotes,
            proposal.deadline,
            proposal.executed,
            proposal.proposalType
        );
    }
    
    /**
     * @dev Check if a proposal has passed
     * @param _proposalId The ID of the proposal
     */
    function hasProposalPassed(uint256 _proposalId) 
        external 
        view 
        proposalExists(_proposalId) 
        returns (bool) 
    {
        Proposal storage proposal = proposals[_proposalId];
        
        if (block.timestamp < proposal.deadline) {
            return false; // Voting still active
        }
        
        uint256 totalVotes = proposal.yesVotes + proposal.noVotes;
        uint256 totalVotingPower = getTotalVotingPower();
        uint256 requiredQuorum = (totalVotingPower * quorum) / 100;
        
        return totalVotes >= requiredQuorum && proposal.yesVotes > proposal.noVotes;
    }
    
    /**
     * @dev Get the current voting status of a proposal
     * @param _proposalId The ID of the proposal
     */
    function getVotingStatus(uint256 _proposalId) 
        external 
        view 
        proposalExists(_proposalId) 
        returns (
            uint256 yesVotes,
            uint256 noVotes,
            uint256 totalVotes,
            uint256 requiredQuorum,
            bool votingActive,
            bool hasPassedQuorum
        ) 
    {
        Proposal storage proposal = proposals[_proposalId];
        uint256 total = proposal.yesVotes + proposal.noVotes;
        uint256 totalVotingPower = getTotalVotingPower();
        uint256 requiredQuorumVotes = (totalVotingPower * quorum) / 100;
        
        return (
            proposal.yesVotes,
            proposal.noVotes,
            total,
            requiredQuorumVotes,
            block.timestamp < proposal.deadline,
            total >= requiredQuorumVotes
        );
    }
    
    /**
     * @dev Get member information
     * @param _member The member's address
     */
    function getMemberInfo(address _member) 
        external 
        view 
        returns (
            bool isMemberStatus,
            uint256 memberSinceTimestamp,
            uint256 votingPowerAmount,
            address delegatedTo,
            uint256 delegatedVotesAmount
        ) 
    {
        return (
            isMember[_member],
            memberSince[_member],
            votingPower[_member],
            delegates[_member],
            delegatedVotes[_member]
        );
    }
    
    /**
     * @dev Get treasury balance
     */
    function getTreasuryBalance() external view returns (uint256) {
        return treasury;
    }
    
    /**
     * @dev Get emergency council members
     */
    function getEmergencyCouncil() external view returns (address[] memory) {
        return emergencyCouncil;
    }
}
