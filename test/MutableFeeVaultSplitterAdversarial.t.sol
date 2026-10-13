// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {Test} from "forge-std/Test.sol";
import {MutableFeeVaultSplitter} from "../src/MutableFeeVaultSplitter.sol";
import {Gasback} from "../src/Gasback.sol";
import {SplitterForceETH} from "./MutableFeeVaultSplitterInvariant.t.sol";

contract SplitterAuditVault {
    address public recipient;

    constructor(address recipient_) {
        recipient = recipient_;
    }

    function withdraw() external {
        (bool success,) = recipient.call{value: address(this).balance}("");
        require(success, "Vault transfer failed");
    }
}

contract SplitterAuditFactory {
    function deploy(bytes32 salt, address owner, address[] memory payees, uint256[] memory weights)
        external
        payable
        returns (MutableFeeVaultSplitter)
    {
        return new MutableFeeVaultSplitter{salt: salt, value: msg.value}(owner, payees, weights);
    }
}

contract SplitterCallbackPayee {
    address public target;
    bytes public payload;
    uint256 public refund;
    bool public succeeded;

    function configure(address target_, bytes calldata payload_, uint256 refund_) external {
        target = target_;
        payload = payload_;
        refund = refund_;
    }

    receive() external payable {
        if (refund > 0) {
            uint256 amount = refund;
            refund = 0;
            new SplitterForceETH{value: amount}(payable(msg.sender));
        } else {
            (succeeded,) = target.call(payload);
        }
    }
}

contract SplitterGasbackReenterer {
    Gasback private _gasback;
    bool private _entered;

    constructor(Gasback gasback_) {
        _gasback = gasback_;
    }

    receive() external payable {
        if (!_entered) {
            _entered = true;
            (bool success,) = address(_gasback).call(abi.encode(uint256(1_000)));
            require(success);
        }
    }
}

contract SplitterHostilePayee {
    enum Mode {
        Accept,
        BurnGas,
        ReturnBomb,
        RevertBomb,
        Expensive
    }

    Mode public mode;

    function setMode(Mode mode_) external {
        mode = mode_;
    }

    receive() external payable {
        Mode current = mode;
        if (current == Mode.BurnGas) {
            assembly ("memory-safe") {
                invalid()
            }
        }
        if (current == Mode.ReturnBomb) {
            assembly ("memory-safe") {
                return(0, 0x80000)
            }
        }
        if (current == Mode.RevertBomb) {
            assembly ("memory-safe") {
                revert(0, 0x80000)
            }
        }
        if (current == Mode.Expensive) {
            require(gasleft() > 150_000, "Needs more gas");
        }
    }
}

contract MutableFeeVaultSplitterAdversarialTest is Test {
    MutableFeeVaultSplitter private splitter;
    SplitterHostilePayee private hostile;
    address private constant HONEST = address(0xCAFE);
    address[] private payees;
    uint256[] private weights;

    function setUp() public {
        hostile = new SplitterHostilePayee();
        payees.push(address(hostile));
        payees.push(HONEST);
        weights.push(1);
        weights.push(1);
        splitter = new MutableFeeVaultSplitter(address(this), payees, weights);
        vm.deal(address(this), 10 ether);
    }

    function test_gasBurningPayeeDoesNotBlockDepositOrHonestPayee() public {
        hostile.setMode(SplitterHostilePayee.Mode.BurnGas);
        (bool success,) = address(splitter).call{value: 1 ether, gas: 500_000}("");
        assertTrue(success, "hostile payee blocked deposit");
        assertEq(HONEST.balance, 0.5 ether);
        assertEq(splitter.releasable(address(hostile)), 0.5 ether);
        assertEq(splitter.totalReleased(), 0.5 ether);
        hostile.setMode(SplitterHostilePayee.Mode.Accept);
        splitter.release(payable(address(hostile)));
        assertEq(address(hostile).balance, 0.5 ether);
    }

    function test_returnDataBombDoesNotBlockDeposit() public {
        hostile.setMode(SplitterHostilePayee.Mode.ReturnBomb);
        (bool success,) = address(splitter).call{value: 1 ether, gas: 1_000_000}("");
        assertTrue(success, "return data bomb blocked deposit");
        assertEq(HONEST.balance, 0.5 ether);
        assertEq(splitter.releasable(address(hostile)), 0.5 ether);
    }

    function test_revertDataBombDoesNotBlockDeposit() public {
        hostile.setMode(SplitterHostilePayee.Mode.RevertBomb);
        (bool success,) = address(splitter).call{value: 1 ether, gas: 1_000_000}("");
        assertTrue(success, "revert data bomb blocked deposit");
        assertEq(HONEST.balance, 0.5 ether);
        assertEq(splitter.releasable(address(hostile)), 0.5 ether);
    }

    function test_directReleaseDoesNotCopySuccessfulReturnBomb() public {
        hostile.setMode(SplitterHostilePayee.Mode.ReturnBomb);
        vm.deal(address(splitter), 1 ether);
        (bool success,) = address(splitter).call{gas: 1_000_000}(
            abi.encodeCall(splitter.release, (payable(address(hostile))))
        );
        assertTrue(success, "successful recipient return exhausted caller gas");
        assertEq(address(hostile).balance, 0.5 ether);
        assertEq(splitter.releasable(address(hostile)), 0);
    }

    function test_expensivePayeeCanUseDirectRelease() public {
        hostile.setMode(SplitterHostilePayee.Mode.Expensive);
        (bool success,) = address(splitter).call{value: 1 ether, gas: 500_000}("");
        assertTrue(success);
        assertEq(HONEST.balance, 0.5 ether);
        assertEq(address(hostile).balance, 0);
        assertEq(splitter.releasable(address(hostile)), 0.5 ether);
        splitter.release{gas: 500_000}(payable(address(hostile)));
        assertEq(address(hostile).balance, 0.5 ether);
        assertEq(address(splitter).balance, 0);
    }

    function test_allPayeesCanFailWithoutBlockingDepositOrShareUpdate() public {
        SplitterHostilePayee second = new SplitterHostilePayee();
        payees[1] = address(second);
        splitter = new MutableFeeVaultSplitter(address(this), payees, weights);
        hostile.setMode(SplitterHostilePayee.Mode.BurnGas);
        second.setMode(SplitterHostilePayee.Mode.RevertBomb);
        (bool success,) = address(splitter).call{value: 1 ether, gas: 700_000}("");
        assertTrue(success);
        assertEq(splitter.totalReleased(), 0);
        assertEq(address(splitter).balance, 1 ether);
        weights[0] = 0;
        weights[1] = 1;
        splitter.setShares(weights);
        assertEq(splitter.releasable(address(hostile)), 0.5 ether);
        assertEq(splitter.releasable(address(second)), 0.5 ether);
        hostile.setMode(SplitterHostilePayee.Mode.Accept);
        second.setMode(SplitterHostilePayee.Mode.Accept);
        splitter.distribute(0, 2);
        assertEq(address(hostile).balance, 0.5 ether);
        assertEq(address(second).balance, 0.5 ether);
    }

    function test_tooLittleTransactionGasRevertsAtomically() public {
        (bool success,) = address(splitter).call{value: 1 ether, gas: 30_000}("");
        assertFalse(success);
        assertEq(address(this).balance, 10 ether);
        assertEq(address(splitter).balance, 0);
        assertEq(address(hostile).balance, 0);
        assertEq(HONEST.balance, 0);
        assertEq(splitter.totalReleased(), 0);
    }

    function test_nonemptyCalldataRejectsETHAndCannotCallUnknownSetter() public {
        (bool success,) = address(splitter).call{value: 1 ether}(hex"deadbeef");
        assertFalse(success);
        assertEq(address(splitter).balance, 0);
        assertEq(splitter.totalReleased(), 0);
    }

    function test_forceETHDuringPayoutIsAccountedWithoutDoubleRelease() public {
        SplitterCallbackPayee callback = new SplitterCallbackPayee();
        payees[0] = address(callback);
        splitter = new MutableFeeVaultSplitter(address(this), payees, weights);
        callback.configure(address(0), "", 0.1 ether);
        (bool success,) = address(splitter).call{value: 1 ether}("");
        assertTrue(success);
        assertEq(address(callback).balance, 0.4 ether);
        assertEq(HONEST.balance, 0.55 ether);
        assertEq(splitter.releasable(address(callback)), 0.05 ether);
        splitter.release(payable(address(callback)));
        assertEq(address(callback).balance, 0.45 ether);
        assertEq(splitter.totalReleased(), 1.1 ether);
        assertEq(address(splitter).balance, 0);
    }

    function test_receiveReentrancyIsBlockedEvenWithZeroETH() public {
        SplitterCallbackPayee callback = new SplitterCallbackPayee();
        payees[0] = address(callback);
        splitter = new MutableFeeVaultSplitter(address(this), payees, weights);
        callback.configure(address(splitter), "", 0);
        (bool success,) = address(splitter).call{value: 1 ether}("");
        assertTrue(success);
        assertFalse(callback.succeeded());
        assertEq(address(callback).balance, 0.5 ether);
        assertEq(HONEST.balance, 0.5 ether);
    }

    function test_create2PrefundingUsesExplicitOwnerAndInitialShares() public {
        SplitterAuditFactory factory = new SplitterAuditFactory();
        bytes32 salt = keccak256("splitter-audit");
        bytes32 initHash = keccak256(
            abi.encodePacked(
                type(MutableFeeVaultSplitter).creationCode,
                abi.encode(address(this), payees, weights)
            )
        );
        address expected = address(
            uint160(
                uint256(keccak256(abi.encodePacked(bytes1(0xff), address(factory), salt, initHash)))
            )
        );
        (bool success,) = expected.call{value: 1 ether}("");
        assertTrue(success);
        splitter = factory.deploy{value: 1 ether}(salt, address(this), payees, weights);
        assertEq(address(splitter), expected);
        assertEq(splitter.owner(), address(this));
        weights[0] = 0;
        weights[1] = 1;
        splitter.setShares(weights);
        splitter.distribute(0, 2);
        assertEq(address(hostile).balance, 1 ether);
        assertEq(HONEST.balance, 1 ether);
    }

    function test_selfPayeeRejected() public {
        address expected = vm.computeCreateAddress(address(this), vm.getNonce(address(this)));
        payees[0] = expected;
        vm.expectRevert(MutableFeeVaultSplitter.InvalidPayee.selector);
        new MutableFeeVaultSplitter(address(this), payees, weights);
    }

    function test_ownershipCanBeCancelledReplacedAndRenouncedWhilePending() public {
        splitter.transferOwnership(HONEST);
        splitter.transferOwnership(address(0));
        vm.prank(HONEST);
        vm.expectRevert("Ownable2Step: caller is not the new owner");
        splitter.acceptOwnership();
        splitter.transferOwnership(HONEST);
        splitter.transferOwnership(address(hostile));
        vm.prank(HONEST);
        vm.expectRevert("Ownable2Step: caller is not the new owner");
        splitter.acceptOwnership();
        splitter.renounceOwnership();
        assertEq(splitter.pendingOwner(), address(0));
        vm.prank(address(hostile));
        vm.expectRevert("Ownable2Step: caller is not the new owner");
        splitter.acceptOwnership();
    }

    function test_pendingVaultFundsUseSharesAtWithdrawalTime() public {
        SplitterAuditVault vault = new SplitterAuditVault(address(splitter));
        vm.deal(address(vault), 1 ether);
        weights[0] = 0;
        weights[1] = 1;
        splitter.setShares(weights);
        vault.withdraw();
        assertEq(address(hostile).balance, 0);
        assertEq(HONEST.balance, 1 ether);
    }

    function test_repeatedUpdatesWithoutIncomeCannotInflateClaims() public {
        vm.deal(address(splitter), 11);
        splitter.distribute(0, 2);
        for (uint256 i; i < 128; ++i) {
            weights[0] = i % 2;
            weights[1] = 1 - weights[0];
            splitter.setShares(weights);
            assertEq(
                splitter.released(address(hostile)) + splitter.released(HONEST)
                    + splitter.releasable(address(hostile)) + splitter.releasable(HONEST),
                11
            );
        }
        splitter.distribute(0, 2);
        assertEq(address(hostile).balance + HONEST.balance, 11);
        assertEq(address(splitter).balance, 0);
    }

    function testFuzz_hostilePayeeAtAnyPositionDoesNotBlockOthers(uint8 position) public {
        position %= 3;
        address[] memory recipients = new address[](3);
        uint256[] memory shares = new uint256[](3);
        for (uint256 i; i < 3; ++i) {
            recipients[i] = address(uint160(0x10000 + i));
            shares[i] = 1;
        }
        recipients[position] = address(hostile);
        hostile.setMode(SplitterHostilePayee.Mode.BurnGas);
        splitter = new MutableFeeVaultSplitter(address(this), recipients, shares);
        (bool success,) = address(splitter).call{value: 3 ether, gas: 700_000}("");
        assertTrue(success);
        for (uint256 i; i < 3; ++i) {
            if (i == position) {
                assertEq(splitter.releasable(recipients[i]), 1 ether);
            } else {
                assertEq(recipients[i].balance, 1 ether);
            }
        }
    }

    function test_untrustedPayeeCanStillBlockGasbackViaCrossContractReentry() public {
        Gasback gasback = new Gasback();
        SplitterGasbackReenterer reenterer = new SplitterGasbackReenterer(gasback);
        payees[0] = address(gasback);
        payees[1] = address(reenterer);
        splitter = new MutableFeeVaultSplitter(address(this), payees, weights);
        SplitterAuditVault vault = new SplitterAuditVault(address(splitter));
        vm.prank(0xffffFFFfFFffffffffffffffFfFFFfffFFFfFFfE);
        gasback.setBaseFeeVault(address(vault));
        vm.fee(1 gwei);
        vm.txGasPrice(1 gwei);
        vm.deal(address(vault), 0.0000012 ether);
        vm.prank(address(0xB0B));
        (bool success, bytes memory result) = address(gasback).call(abi.encode(uint256(1_000)));
        assertTrue(success);
        assertEq(abi.decode(result, (uint256)), 0);
        assertEq(address(vault).balance, 0.0000012 ether);
        assertEq(address(gasback).balance, 0);
        assertEq(address(reenterer).balance, 0);
        assertEq(splitter.totalReleased(), 0);
    }

    function test_gasbackPullThroughVaultWorksAfterShareChanges() public {
        Gasback gasback = new Gasback();
        payees[0] = address(gasback);
        splitter = new MutableFeeVaultSplitter(address(this), payees, weights);
        SplitterAuditVault vault = new SplitterAuditVault(address(splitter));
        vm.prank(0xffffFFFfFFffffffffffffffFfFFFfffFFFfFFfE);
        gasback.setBaseFeeVault(address(vault));
        vm.fee(1 gwei);
        vm.txGasPrice(1 gwei);
        weights[0] = 80;
        weights[1] = 20;
        splitter.setShares(weights);
        vm.deal(address(vault), 0.002 ether);
        vm.prank(address(0xB0B));
        (bool success, bytes memory result) = address(gasback).call(abi.encode(uint256(1_000_000)));
        assertTrue(success);
        assertEq(abi.decode(result, (uint256)), 0.0006 ether);
        assertEq(address(0xB0B).balance, 0.0006 ether);
        assertEq(address(gasback).balance, 0.001 ether);
        assertEq(HONEST.balance, 0.0004 ether);
        assertEq(address(vault).balance, 0);
    }

    function test_insufficientGasbackShareRollsBackEntireVaultWithdrawal() public {
        Gasback gasback = new Gasback();
        payees[0] = address(gasback);
        splitter = new MutableFeeVaultSplitter(address(this), payees, weights);
        SplitterAuditVault vault = new SplitterAuditVault(address(splitter));
        vm.prank(0xffffFFFfFFffffffffffffffFfFFFfffFFFfFFfE);
        gasback.setBaseFeeVault(address(vault));
        vm.fee(1 gwei);
        vm.txGasPrice(1 gwei);
        weights[0] = 1;
        weights[1] = 99;
        splitter.setShares(weights);
        vm.deal(address(vault), 0.001 ether);
        vm.prank(address(0xB0B));
        (bool success, bytes memory result) = address(gasback).call(abi.encode(uint256(1_000_000)));
        assertTrue(success);
        assertEq(abi.decode(result, (uint256)), 0);
        assertEq(address(vault).balance, 0.001 ether);
        assertEq(address(gasback).balance, 0);
        assertEq(HONEST.balance, 0);
        assertEq(splitter.totalReleased(), 0);
        weights[0] = 80;
        weights[1] = 20;
        splitter.setShares(weights);
        vm.prank(address(0xB0B));
        (success, result) = address(gasback).call(abi.encode(uint256(1_000_000)));
        assertTrue(success);
        assertEq(abi.decode(result, (uint256)), 0.0006 ether);
        assertEq(address(vault).balance, 0);
    }
}
