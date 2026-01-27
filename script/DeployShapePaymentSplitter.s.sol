// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {ShapePaymentSplitter} from "../src/ShapePaymentSplitter.sol";

contract DeployShapePaymentSplitterScript is Script {
    function run() external returns (ShapePaymentSplitter deployed) {
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
        deployed = new ShapePaymentSplitter(payees, shares);
        vm.stopBroadcast();

        console.log("ShapePaymentSplitter deployed at:", address(deployed));
        console.log("Payee 1:", payees[0], "Shares:", shares[0]);
        console.log("Payee 2:", payees[1], "Shares:", shares[1]);
    }
}
