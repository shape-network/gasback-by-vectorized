// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Script, console2} from "forge-std/Script.sol";
import {Gasback} from "../src/Gasback.sol";
import {ShapePaymentSplitter} from "../src/ShapePaymentSplitter.sol";
import {GasbackTestCaller} from "../src/test/GasbackTestCaller.sol";

contract DeployGasbackStackScript is Script {
    error MissingExtraShares();
    error MissingExtraPayees();
    error ExtraPayeesAndSharesLengthMismatch(uint256 payeesLength, uint256 sharesLength);
    error GasbackShareIsZero();

    function run()
        external
        returns (Gasback gasback, ShapePaymentSplitter splitter, GasbackTestCaller caller)
    {
        uint256 privateKey = uint256(vm.envBytes32("PRIVATE_KEY"));
        uint256 gasbackShare = vm.envOr("GASBACK_SPLITTER_SHARE", uint256(1));

        if (gasbackShare == 0) revert GasbackShareIsZero();

        bool hasExtraPayees = vm.envExists("EXTRA_SPLITTER_PAYEES");
        bool hasExtraShares = vm.envExists("EXTRA_SPLITTER_SHARES");
        if (hasExtraPayees != hasExtraShares) {
            if (hasExtraPayees) revert MissingExtraShares();
            revert MissingExtraPayees();
        }

        address[] memory extraPayees;
        uint256[] memory extraShares;
        if (hasExtraPayees) {
            extraPayees = vm.envAddress("EXTRA_SPLITTER_PAYEES", ",");
            extraShares = vm.envUint("EXTRA_SPLITTER_SHARES", ",");
            if (extraPayees.length != extraShares.length) {
                revert ExtraPayeesAndSharesLengthMismatch(extraPayees.length, extraShares.length);
            }
        }

        vm.startBroadcast(privateKey);

        gasback = new Gasback();

        address[] memory payees = new address[](extraPayees.length + 1);
        uint256[] memory shares = new uint256[](extraShares.length + 1);
        payees[0] = address(gasback);
        shares[0] = gasbackShare;

        for (uint256 i = 0; i < extraPayees.length; i++) {
            payees[i + 1] = extraPayees[i];
            shares[i + 1] = extraShares[i];
        }

        splitter = new ShapePaymentSplitter(payees, shares);
        caller = new GasbackTestCaller(address(gasback));

        vm.stopBroadcast();

        console2.log("Gasback:", address(gasback));
        console2.log("ShapePaymentSplitter:", address(splitter));
        console2.log("GasbackTestCaller:", address(caller));
    }
}
