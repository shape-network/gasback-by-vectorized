// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {GasbackTestCaller} from "../src/test/GasbackTestCaller.sol";

contract DeployGasbackTestCallerScript is Script {
    error WrongChain(uint256 chainId);

    uint256 internal constant SHAPE_SEPOLIA_CHAIN_ID = 11011;

    function run() external returns (GasbackTestCaller deployed) {
        if (block.chainid != SHAPE_SEPOLIA_CHAIN_ID) revert WrongChain(block.chainid);

        uint256 privateKey = uint256(vm.envBytes32("PRIVATE_KEY"));
        address gasback = vm.envAddress("GASBACK_ADDRESS");

        vm.startBroadcast(privateKey);
        deployed = new GasbackTestCaller(gasback);
        vm.stopBroadcast();

        console.log("GasbackTestCaller deployed at:", address(deployed));
        console.log("Gasback target:", gasback);
    }
}
