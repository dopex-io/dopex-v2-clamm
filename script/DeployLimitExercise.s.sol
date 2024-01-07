// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import "forge-std/Script.sol";
import {LimitExercise} from "../src/periphery/LimitExercise.sol";

contract DeployAutoExercise is Script {
    function run() public {
        vm.startBroadcast();
        LimitExercise aetb = new LimitExercise();
        console.log(address(aetb));
        vm.stopBroadcast();
    }
}
