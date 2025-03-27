// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

contract MatchContract {
    // Match states
    enum MatchStatus { Commit, Reveal, Dispute, Completed }
    
    // Player reputation
    struct Player {
        int256 reputation;
        uint256 totalMatches;
        bool isBanned;
    }
    
    // Match data
    struct Match {
        address player1;
        address player2;
        bytes32 player1Commit;
        bytes32 player2Commit;
        string player1Result;
        string player2Result;
        bytes32 player1Salt;
        bytes32 player2Salt;
        MatchStatus status;
        uint256 stakeAmount;
        address[] juryPool;
        mapping(address => uint256) juryVotes; // 1 = player1, 2 = player2
        uint256 revealDeadline;
    }

    // Constants
    uint256 public constant JURY_STAKE = 0.1 ether;
    uint256 public constant JURY_REWARD = 0.05 ether;
    uint256 public constant REVEAL_PERIOD = 2 days;
    
    // Reputation points
    int256 public constant REP_WIN = 15;
    int256 public constant REP_TRUTHFUL = 10;
    int256 public constant REP_NO_REVEAL = -25;
    int256 public constant REP_LIED = -50;
    int256 public constant REP_JURY_VOTE = 5;

    // Storage
    mapping(uint256 => Match) public matches;
    mapping(address => Player) public players;
    uint256 public matchCounter;
    
    // Events
    event MatchCreated(uint256 indexed matchId, address player1, address player2);
    event ResultRevealed(uint256 indexed matchId, address player);
    event DisputeInitiated(uint256 indexed matchId);
    event JuryVoted(uint256 indexed matchId, address juror, uint256 vote);
    event MatchResolved(uint256 indexed matchId, address winner);

    // Modifiers
    modifier onlyPlayers(uint256 matchId) {
        require(
            msg.sender == matches[matchId].player1 || 
            msg.sender == matches[matchId].player2,
            "Not a player"
        );
        _;
    }

    // Match creation
    function createMatch(address opponent) external payable {
        require(!players[msg.sender].isBanned, "You are banned");
        require(!players[opponent].isBanned, "Opponent is banned");
        
        uint256 stake = getStakeAmount(msg.sender);
        require(msg.value == stake, "Incorrect stake amount");

        uint256 matchId = matchCounter++;
        Match storage m = matches[matchId];
        
        m.player1 = msg.sender;
        m.player2 = opponent;
        m.stakeAmount = stake;
        m.revealDeadline = block.timestamp + REVEAL_PERIOD;
        
        emit MatchCreated(matchId, msg.sender, opponent);
    }

    // Commit phase
    function commitResult(uint256 matchId, bytes32 hashedCommitment) external onlyPlayers(matchId) {
        Match storage m = matches[matchId];
        require(m.status == MatchStatus.Commit, "Not in commit phase");
        
        if (msg.sender == m.player1) {
            m.player1Commit = hashedCommitment;
        } else {
            m.player2Commit = hashedCommitment;
        }
        
        // Advance to reveal if both committed
        if (m.player1Commit != bytes32(0) && m.player2Commit != bytes32(0)) {
            m.status = MatchStatus.Reveal;
        }
    }

    // Reveal phase
    function revealResult(uint256 matchId, bytes32 salt, string memory result) external onlyPlayers(matchId) {
        Match storage m = matches[matchId];
        require(m.status == MatchStatus.Reveal, "Not in reveal phase");
        require(block.timestamp <= m.revealDeadline, "Reveal period expired");
        
        bytes32 commitment = keccak256(abi.encodePacked("I_report_truth", salt));
        
        if (msg.sender == m.player1) {
            require(commitment == m.player1Commit, "Invalid reveal");
            m.player1Result = result;
            m.player1Salt = salt;
        } else {
            require(commitment == m.player2Commit, "Invalid reveal");
            m.player2Result = result;
            m.player2Salt = salt;
        }
        
        emit ResultRevealed(matchId, msg.sender);
        
        // Check if both revealed
        if (m.player1Salt != bytes32(0) && m.player2Salt != bytes32(0)) {
            if (keccak256(abi.encodePacked(m.player1Result)) == keccak256(abi.encodePacked(m.player2Result))) {
                _resolveMatch(matchId, msg.sender); // Same result
            } else {
                m.status = MatchStatus.Dispute;
                emit DisputeInitiated(matchId);
            }
        }
    }

    // Jury system
    function joinJury(uint256 matchId) external payable {
        require(!players[msg.sender].isBanned, "You are banned");
        require(msg.value == JURY_STAKE, "Incorrect jury stake");
        
        Match storage m = matches[matchId];
        require(m.status == MatchStatus.Dispute, "No active dispute");
        m.juryPool.push(msg.sender);
    }

    function voteAsJuror(uint256 matchId, uint256 vote) external {
        Match storage m = matches[matchId];
        require(m.status == MatchStatus.Dispute, "No active dispute");
        
        bool isJuror = false;
        for (uint i = 0; i < m.juryPool.length; i++) {
            if (m.juryPool[i] == msg.sender) {
                isJuror = true;
                break;
            }
        }
        require(isJuror, "Not a juror");
        
        m.juryVotes[msg.sender] = vote;
        emit JuryVoted(matchId, msg.sender, vote);
        
        // Tally votes if all jurors voted
        if (m.juryPool.length >= 3) { // Minimum 3 jurors
            uint256 player1Votes;
            uint256 player2Votes;
            
            for (uint i = 0; i < m.juryPool.length; i++) {
                if (m.juryVotes[m.juryPool[i]] == 1) player1Votes++;
                else player2Votes++;
            }
            
            address winner = player1Votes > player2Votes ? m.player1 : m.player2;
            _resolveDispute(matchId, winner);
        }
    }

    // Internal resolution functions
    function _resolveMatch(uint256 matchId, address winner) private {
        Match storage m = matches[matchId];
        m.status = MatchStatus.Completed;
        
        // Update reputations
        players[winner].reputation += REP_WIN;
        players[winner == m.player1 ? m.player2 : m.player1].reputation += REP_TRUTHFUL;
        
        // Payout
        payable(winner).transfer(m.stakeAmount * 2);
        emit MatchResolved(matchId, winner);
    }

    function _resolveDispute(uint256 matchId, address winner) private {
        Match storage m = matches[matchId];
        m.status = MatchStatus.Completed;
        
        // Penalize liar
        address liar = winner == m.player1 ? m.player2 : m.player1;
        players[liar].reputation += REP_LIED;
        
        // Reward jurors
        for (uint i = 0; i < m.juryPool.length; i++) {
            payable(m.juryPool[i]).transfer(JURY_REWARD);
            players[m.juryPool[i]].reputation += REP_JURY_VOTE;
        }
        
        // Payout
        payable(winner).transfer(m.stakeAmount * 2 - (JURY_REWARD * m.juryPool.length));
        emit MatchResolved(matchId, winner);
    }

    // Reputation utilities
    function getStakeAmount(address player) public view returns (uint256) {
        if (players[player].reputation >= 50) return 0.5 ether;
        if (players[player].reputation < 0) return 2 ether;
        return 1 ether;
    }

    function banCheater(address player) external {
        require(players[player].reputation <= -100, "Not ban-worthy");
        players[player].isBanned = true;
    }
}