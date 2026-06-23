// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

contract VotingSystem {

    // ---- types ----
    enum VoterState { NotVoted, Processing, Voted }

    // ---- state ----
    address public admin;
    uint8   public numCandidates;
    bool    public votingOpen;

    mapping(address => bool)       public registeredVoters;
    mapping(address => VoterState) public voterState;
    mapping(uint8   => uint256)    public voteCount;

    // ---- events ----
    event VoterRegistered(address indexed voter);
    event VoteCast(address indexed voter, uint8 candidateId);
    event VotingOpened();
    event VotingClosed();

    // ---- modifiers ----
    modifier onlyAdmin() {
        require(msg.sender == admin, "Not admin");
        _;
    }

    modifier whenOpen() {
        require(votingOpen, "Voting not open");
        _;
    }

    // ---- constructor ----
    constructor(uint8 _numCandidates) {
        admin         = msg.sender;
        numCandidates = _numCandidates;
        votingOpen    = false;
    }

    // ---- admin functions ----
    function registerVoter(address voter) external onlyAdmin {
        require(!registeredVoters[voter], "Already registered");
        registeredVoters[voter] = true;
        voterState[voter]       = VoterState.NotVoted;
        emit VoterRegistered(voter);
    }

    function openVoting() external onlyAdmin {
        votingOpen = true;
        emit VotingOpened();
    }

    function closeVoting() external onlyAdmin {
        votingOpen = false;
        emit VotingClosed();
    }

    // ---- voter function ----
    function castVote(uint8 candidateId) external whenOpen {
        require(registeredVoters[msg.sender],                    "Not registered");
        require(voterState[msg.sender] == VoterState.NotVoted,   "Already voted");
        require(candidateId < numCandidates,                     "Invalid candidate");

        voterState[msg.sender] = VoterState.Processing;
        voteCount[candidateId]++;
        voterState[msg.sender] = VoterState.Voted;

        emit VoteCast(msg.sender, candidateId);
    }

    // ---- view functions ----
    function getTally(uint8 candidateId) external view returns (uint256) {
        require(candidateId < numCandidates, "Invalid candidate");
        return voteCount[candidateId];
    }

    function getVoterState(address voter) external view returns (VoterState) {
        return voterState[voter];
    }
}
