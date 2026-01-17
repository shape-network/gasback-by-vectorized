// SPDX-License-Identifier: MIT
pragma solidity ^0.8.7;

import {Script} from "forge-std/Script.sol";
import {Gasback} from "../src/Gasback.sol";

contract DeployGasbackScript is Script {
    function run() external returns (Gasback deployed) {
        uint256 privateKey = uint256(vm.envBytes32("PRIVATE_KEY"));

        vm.startBroadcast(privateKey);
        deployed = new Gasback();
        vm.stopBroadcast();
    }
}
