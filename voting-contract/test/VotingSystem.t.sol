// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "forge-std/Test.sol";
import "../src/VotingSystem.sol";

contract VotingSystemTest is Test {

    VotingSystem voting;
    address admin   = address(0x1);
    address voter1  = address(0x2);
    address voter2  = address(0x3);
    address stranger = address(0x4);

    function setUp() public {
        vm.prank(admin);
        voting = new VotingSystem(3);
    }

    // -- registration --

    function test_RegisterVoter() public {
        vm.prank(admin);
        voting.registerVoter(voter1);
        assertTrue(voting.registeredVoters(voter1));
    }

    function test_CannotRegisterTwice() public {
        vm.prank(admin);
        voting.registerVoter(voter1);
        vm.prank(admin);
        vm.expectRevert("Already registered");
        voting.registerVoter(voter1);
    }

    function test_OnlyAdminCanRegister() public {
        vm.prank(stranger);
        vm.expectRevert("Not admin");
        voting.registerVoter(voter1);
    }

    // -- voting --

    function test_CastVote() public {
        vm.prank(admin);
        voting.registerVoter(voter1);
        vm.prank(admin);
        voting.openVoting();

        vm.prank(voter1);
        voting.castVote(0);

        assertEq(voting.getTally(0), 1);
        assertEq(
            uint(voting.getVoterState(voter1)),
            uint(VotingSystem.VoterState.Voted)
        );
    }

    function test_DoubleVotePrevented() public {
        vm.prank(admin);
        voting.registerVoter(voter1);
        vm.prank(admin);
        voting.openVoting();

        vm.prank(voter1);
        voting.castVote(0);

        vm.prank(voter1);
        vm.expectRevert("Already voted");
        voting.castVote(1);

        assertEq(voting.getTally(0), 1);
        assertEq(voting.getTally(1), 0);
    }

    function test_UnregisteredVoterRejected() public {
        vm.prank(admin);
        voting.openVoting();

        vm.prank(stranger);
        vm.expectRevert("Not registered");
        voting.castVote(0);
    }

    function test_CannotVoteWhenClosed() public {
        vm.prank(admin);
        voting.registerVoter(voter1);

        vm.prank(voter1);
        vm.expectRevert("Voting not open");
        voting.castVote(0);
    }

    function test_CannotVoteAfterClose() public {
        vm.prank(admin);
        voting.registerVoter(voter1);
        vm.prank(admin);
        voting.openVoting();
        vm.prank(admin);
        voting.closeVoting();

        vm.prank(voter1);
        vm.expectRevert("Voting not open");
        voting.castVote(0);
    }

    function test_InvalidCandidateRejected() public {
        vm.prank(admin);
        voting.registerVoter(voter1);
        vm.prank(admin);
        voting.openVoting();

        vm.prank(voter1);
        vm.expectRevert("Invalid candidate");
        voting.castVote(99);
    }

    function test_MultipleVotersTally() public {
        vm.prank(admin);
        voting.registerVoter(voter1);
        vm.prank(admin);
        voting.registerVoter(voter2);
        vm.prank(admin);
        voting.openVoting();

        vm.prank(voter1);
        voting.castVote(0);
        vm.prank(voter2);
        voting.castVote(0);

        assertEq(voting.getTally(0), 2);
    }
}
