// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import "forge-std/Script.sol";
import "../src/ReputationSystem.sol";
import "../src/WorldCupBetting.sol";

contract Deploy is Script {
    function run() external {
        uint256 deployerKey = vm.envUint("PRIVATE_KEY");
        vm.startBroadcast(deployerKey);

        ReputationSystem reputation = new ReputationSystem();
        console.log("ReputationSystem:", address(reputation));

        WorldCupBetting betting = new WorldCupBetting(address(reputation));
        console.log("WorldCupBetting:", address(betting));

        reputation.setPredictionMarket(address(betting));
        console.log("Contracts linked.");

        vm.stopBroadcast();
    }
}
