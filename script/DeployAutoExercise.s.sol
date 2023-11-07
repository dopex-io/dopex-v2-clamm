// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import "forge-std/Script.sol";

import {AutoExerciseTimeBased} from "../src/periphery/AutoExerciseTimeBased.sol";

contract AutoExerciseScript is Script {
    function run() public {
        vm.startBroadcast();
        AutoExerciseTimeBased aetb = new AutoExerciseTimeBased();
        console.log(address(aetb));
        vm.stopBroadcast();
    }
}
