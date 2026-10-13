// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {Test} from "forge-std/Test.sol";
import {MutableFeeVaultSplitter} from "../src/MutableFeeVaultSplitter.sol";
import {Gasback} from "../src/Gasback.sol";
import {SplitterAuditVault} from "./MutableFeeVaultSplitterAdversarial.t.sol";

interface SplitterSafe {
    function setup(
        address[] calldata owners,
        uint256 threshold,
        address to,
        bytes calldata data,
        address fallbackHandler,
        address paymentToken,
        uint256 payment,
        address payable paymentReceiver
    ) external;
    function VERSION() external view returns (string memory);
    function masterCopy() external view returns (address);
    function getOwners() external view returns (address[] memory);
    function getThreshold() external view returns (uint256);
    function nonce() external view returns (uint256);
}

contract SplitterRejectingFallback {
    fallback() external {
        revert("Fallback must not handle ETH receipts");
    }
}

contract MutableFeeVaultSplitterSafeTest is Test {
    address private constant SINGLETON = 0xfb1bffC9d739B8D520DaF37dF666da4C687191EA;
    address private constant SAFE_OWNER = address(0x5151);
    address private constant GOVERNANCE = address(0x600D);
    address private constant SYSTEM = 0xffffFFFfFFffffffffffffffFfFFFfffFFFfFFfE;
    SplitterSafe private safe;
    Gasback private gasback;

    function setUp() public {
        string memory fixture = vm.readFile("test/fixtures/safe-shape-v1.3.0.json");
        bytes memory runtime = vm.parseJsonBytes(fixture, ".singletonRuntimeCode");
        assertEq(sha256(runtime), vm.parseJsonBytes32(fixture, ".singletonRuntimeCodeSha256"));
        vm.etch(SINGLETON, runtime);
        bytes memory creationCode = vm.parseJsonBytes(fixture, ".proxyCreationCode");
        assertEq(sha256(creationCode), vm.parseJsonBytes32(fixture, ".proxyCreationCodeSha256"));
        bytes memory initCode = abi.encodePacked(creationCode, abi.encode(SINGLETON));
        address proxy;
        assembly ("memory-safe") {
            proxy := create(0, add(initCode, 0x20), mload(initCode))
        }
        assertTrue(proxy != address(0));
        assertEq(proxy.code, vm.parseJsonBytes(fixture, ".proxyRuntimeCode"));
        safe = SplitterSafe(proxy);
        address[] memory owners = new address[](1);
        owners[0] = SAFE_OWNER;
        safe.setup(
            owners,
            1,
            address(0),
            "",
            address(new SplitterRejectingFallback()),
            address(0),
            0,
            payable(address(0))
        );
        assertEq(safe.VERSION(), "1.3.0");
        assertEq(safe.masterCopy(), SINGLETON);
        assertEq(safe.getOwners(), owners);
        assertEq(safe.getThreshold(), 1);
        gasback = new Gasback();
        vm.deal(address(this), 20 ether);
    }

    function test_automaticPayoutsAndShareChangeSafeFirst() public {
        _assertAutomaticPayouts(false);
    }

    function test_automaticPayoutsAndShareChangeGasbackFirst() public {
        _assertAutomaticPayouts(true);
    }

    function _assertAutomaticPayouts(bool gasbackFirst) private {
        MutableFeeVaultSplitter splitter = _deploySplitter(gasbackFirst);
        assertEq(splitter.AUTO_RELEASE_GAS_LIMIT(), 100_000);
        vm.cool(address(safe));
        vm.cool(SINGLETON);
        vm.cool(address(gasback));
        (bool success,) = address(splitter).call{value: 10 ether}("");
        assertTrue(success);
        assertEq(address(safe).balance, 4 ether);
        assertEq(address(gasback).balance, 6 ether);

        uint256[] memory weights = new uint256[](2);
        weights[0] = 80;
        weights[1] = 20;
        if (gasbackFirst) {
            weights[0] = 20;
            weights[1] = 80;
        }
        vm.prank(GOVERNANCE);
        splitter.setShares(weights);
        (success,) = address(splitter).call{value: 10 ether}("");
        assertTrue(success);
        assertEq(address(safe).balance, 12 ether);
        assertEq(address(gasback).balance, 8 ether);
        assertEq(splitter.released(address(safe)), 12 ether);
        assertEq(splitter.released(address(gasback)), 8 ether);
        assertEq(splitter.totalReleased(), 20 ether);
        assertEq(address(splitter).balance, 0);
        assertEq(splitter.releasable(address(safe)), 0);
        assertEq(splitter.releasable(address(gasback)), 0);
        assertEq(safe.nonce(), 0);
    }

    function test_coldRecipientsAccept100000GasWithoutInvokingFallbackHandler() public {
        (bool fallbackSuccess,) = address(safe).call(hex"deadbeef");
        assertFalse(fallbackSuccess);
        vm.cool(address(safe));
        vm.cool(SINGLETON);
        (bool safeSuccess,) = address(safe).call{value: 1 ether, gas: 100_000}("");
        assertTrue(safeSuccess);
        vm.cool(address(gasback));
        (bool gasbackSuccess,) = address(gasback).call{value: 1 ether, gas: 100_000}("");
        assertTrue(gasbackSuccess);
        assertEq(address(safe).balance, 1 ether);
        assertEq(address(gasback).balance, 1 ether);
        assertEq(safe.nonce(), 0);
    }

    function test_vaultPullBeforeAndAfterShareChangeSafeFirst() public {
        _assertVaultPull(false);
    }

    function test_vaultPullBeforeAndAfterShareChangeGasbackFirst() public {
        _assertVaultPull(true);
    }

    function _assertVaultPull(bool gasbackFirst) private {
        MutableFeeVaultSplitter splitter = _deploySplitter(gasbackFirst);
        SplitterAuditVault vault = new SplitterAuditVault(address(splitter));
        vm.prank(SYSTEM);
        gasback.setBaseFeeVault(address(vault));
        vm.fee(1 gwei);
        vm.txGasPrice(1 gwei);
        address caller = address(0xB0B);
        vm.deal(address(vault), 0.001 ether);
        vm.prank(caller);
        (bool success, bytes memory result) = address(gasback).call(abi.encode(uint256(1_000_000)));
        assertTrue(success);
        assertEq(abi.decode(result, (uint256)), 0.0006 ether);
        assertEq(address(safe).balance, 0.0004 ether);
        assertEq(address(gasback).balance, 0);
        assertEq(address(vault).balance, 0);

        uint256[] memory weights = new uint256[](2);
        weights[0] = 20;
        weights[1] = 80;
        if (gasbackFirst) {
            weights[0] = 80;
            weights[1] = 20;
        }
        vm.prank(GOVERNANCE);
        splitter.setShares(weights);
        vm.deal(address(gasback), 0.0001 ether);
        vm.deal(address(vault), 0.001 ether);
        vm.prank(caller);
        (success, result) = address(gasback).call(abi.encode(uint256(1_000_000)));
        assertTrue(success);
        assertEq(abi.decode(result, (uint256)), 0.0006 ether);
        assertEq(caller.balance, 0.0012 ether);
        assertEq(address(safe).balance, 0.0006 ether);
        assertEq(address(gasback).balance, 0.0003 ether);
        assertEq(address(vault).balance, 0);
        assertEq(address(splitter).balance, 0);
        assertEq(splitter.totalReleased(), 0.002 ether);
        assertEq(splitter.releasable(address(safe)), 0);
        assertEq(splitter.releasable(address(gasback)), 0);
    }

    function _deploySplitter(bool gasbackFirst) private returns (MutableFeeVaultSplitter) {
        address[] memory payees = new address[](2);
        uint256[] memory weights = new uint256[](2);
        payees[0] = address(safe);
        payees[1] = address(gasback);
        weights[0] = 40;
        weights[1] = 60;
        if (gasbackFirst) {
            payees[0] = address(gasback);
            payees[1] = address(safe);
            weights[0] = 60;
            weights[1] = 40;
        }
        return new MutableFeeVaultSplitter(GOVERNANCE, payees, weights);
    }
}
