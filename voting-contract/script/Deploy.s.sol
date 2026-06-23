// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "forge-std/Script.sol";
import "../src/VotingSystem.sol";

contract DeployVotingSystem is Script {
    function run() external {
        uint256 deployerKey = vm.envUint("DEPLOYER_PRIVATE_KEY");

        vm.startBroadcast(deployerKey);
        VotingSystem voting = new VotingSystem(3);
        vm.stopBroadcast();

        console.log("VotingSystem deployed at:", address(voting));
    }
}
