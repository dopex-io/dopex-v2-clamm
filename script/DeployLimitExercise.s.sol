// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import "forge-std/Script.sol";
import {LimitExercise} from "../src/periphery/LimitExercise.sol";

contract DeployLimitExercise is Script {
    function run() public {
        vm.startBroadcast();

        address keeper = 0x662026937ae0dc84C0Ff32F8f7035d777A4f3CeB;

        require(keeper != address(0), "keeper address zero in deploy script");

        LimitExercise limitExercise = new LimitExercise();
        
        limitExercise.grantRole(limitExercise.KEEPER_ROLE(), keeper);
        
        console.log(address(limitExercise));

        vm.stopBroadcast();
    }
}
