// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {FeeVaultSplitter} from "../src/FeeVaultSplitter.sol";

contract DeployFeeVaultSplitterScript is Script {
    function run() external returns (FeeVaultSplitter deployed) {
        uint256 privateKey = uint256(vm.envBytes32("PRIVATE_KEY"));

        address[] memory payees = new address[](2);
        uint256[] memory shares = new uint256[](2);

        /// @notice Replace with actual payee addresses
        payees[0] = 0x1234567890123456789012345678901234567890;
        payees[1] = 0x1234567890123456789012345678901234567891;

        /// @notice Replace with actual share amounts
        shares[0] = 50;
        shares[1] = 50;

        vm.startBroadcast(privateKey);
        deployed = new FeeVaultSplitter(payees, shares);
        vm.stopBroadcast();

        console.log("FeeVaultSplitter deployed at:", address(deployed));
        console.log("Payee 1:", payees[0], "Shares:", shares[0]);
        console.log("Payee 2:", payees[1], "Shares:", shares[1]);
    }
}
