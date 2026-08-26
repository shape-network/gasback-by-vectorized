// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {SoladyTest} from "./utils/SoladyTest.sol";
import {ERC721} from "solady/tokens/ERC721.sol";
import {ERC1155} from "solady/tokens/ERC1155.sol";
import {Gasback} from "../src/Gasback.sol";
import {
    GasbackRoyalties,
    IGasbackRoyalties
} from "../src/standard-interactions/GasbackRoyalties.sol";

contract GasbackRoyaltiesHarness is GasbackRoyalties {
    constructor(address gasback_) GasbackRoyalties(gasback_) {}

    function setDefaultRoyalty(address receiver, uint96 feeNumerator) external {
        _setDefaultRoyalty(receiver, feeNumerator);
    }

    function setTokenRoyalty(uint256 tokenId, address receiver, uint96 feeNumerator) external {
        _setTokenRoyalty(tokenId, receiver, feeNumerator);
    }

    function pay(uint256 tokenId, uint256 gasToBurn)
        external
        returns (uint256 gasbackAmount, uint256 royaltyAmount, uint256 refundAmount)
    {
        return _payGasbackRoyalty(tokenId, gasToBurn);
    }

    function payBatch(uint256[] memory tokenIds, uint256[] memory amounts, uint256 gasToBurn)
        external
        returns (uint256 gasbackAmount, uint256 royaltyAmount, uint256 refundAmount)
    {
        return _payGasbackRoyalties(tokenIds, amounts, gasToBurn);
    }
}

contract GasbackRoyaltiesERC721Harness is ERC721, GasbackRoyalties {
    constructor(address gasback_) GasbackRoyalties(gasback_) {}

    function name() public pure override returns (string memory) {
        return "Gasback Royalties ERC721";
    }

    function symbol() public pure override returns (string memory) {
        return "GBR721";
    }

    function tokenURI(uint256) public pure override returns (string memory) {
        return "";
    }

    function setDefaultRoyalty(address receiver, uint96 feeNumerator) external {
        _setDefaultRoyalty(receiver, feeNumerator);
    }

    function setTokenRoyalty(uint256 tokenId, address receiver, uint96 feeNumerator) external {
        _setTokenRoyalty(tokenId, receiver, feeNumerator);
    }

    function mintWithRoyalty(address to, uint256 tokenId, uint256 gasToBurn)
        external
        returns (uint256 gasbackAmount, uint256 royaltyAmount, uint256 refundAmount)
    {
        _mint(to, tokenId);
        return _payGasbackRoyalty(tokenId, gasToBurn);
    }

    function supportsInterface(bytes4 interfaceId)
        public
        view
        override(ERC721, GasbackRoyalties)
        returns (bool)
    {
        return ERC721.supportsInterface(interfaceId)
            || GasbackRoyalties.supportsInterface(interfaceId);
    }
}

contract GasbackRoyaltiesERC1155Harness is ERC1155, GasbackRoyalties {
    constructor(address gasback_) GasbackRoyalties(gasback_) {}

    function uri(uint256) public pure override returns (string memory) {
        return "";
    }

    function setDefaultRoyalty(address receiver, uint96 feeNumerator) external {
        _setDefaultRoyalty(receiver, feeNumerator);
    }

    function setTokenRoyalty(uint256 tokenId, address receiver, uint96 feeNumerator) external {
        _setTokenRoyalty(tokenId, receiver, feeNumerator);
    }

    function mintWithRoyalty(address to, uint256 tokenId, uint256 amount, uint256 gasToBurn)
        external
        returns (uint256 gasbackAmount, uint256 royaltyAmount, uint256 refundAmount)
    {
        _mint(to, tokenId, amount, "");
        return _payGasbackRoyalty(tokenId, gasToBurn);
    }

    function mintBatchWithRoyalty(
        address to,
        uint256[] memory tokenIds,
        uint256[] memory amounts,
        uint256 gasToBurn
    ) external returns (uint256 gasbackAmount, uint256 royaltyAmount, uint256 refundAmount) {
        _batchMint(to, tokenIds, amounts, "");
        return _payGasbackRoyalties(tokenIds, amounts, gasToBurn);
    }

    function pay(uint256 tokenId, uint256 gasToBurn)
        external
        returns (uint256 gasbackAmount, uint256 royaltyAmount, uint256 refundAmount)
    {
        return _payGasbackRoyalty(tokenId, gasToBurn);
    }

    function payBatch(uint256[] memory tokenIds, uint256[] memory amounts, uint256 gasToBurn)
        external
        returns (uint256 gasbackAmount, uint256 royaltyAmount, uint256 refundAmount)
    {
        return _payGasbackRoyalties(tokenIds, amounts, gasToBurn);
    }

    function supportsInterface(bytes4 interfaceId)
        public
        view
        override(ERC1155, GasbackRoyalties)
        returns (bool)
    {
        return ERC1155.supportsInterface(interfaceId)
            || GasbackRoyalties.supportsInterface(interfaceId);
    }
}

contract MockGasbackTarget {
    bool public shouldRevert;
    uint256 public sendAmount;
    uint256 public returnAmount;
    uint256 public returnDataLength;

    constructor(
        bool shouldRevert_,
        uint256 sendAmount_,
        uint256 returnAmount_,
        uint256 returnDataLength_
    ) payable {
        shouldRevert = shouldRevert_;
        sendAmount = sendAmount_;
        returnAmount = returnAmount_;
        returnDataLength = returnDataLength_;
    }

    fallback() external payable {
        if (shouldRevert) revert();
        if (sendAmount != 0) {
            (bool success,) = msg.sender.call{value: sendAmount}("");
            require(success);
        }
        uint256 value = returnAmount;
        uint256 length = returnDataLength;
        assembly {
            mstore(0x00, value)
            return(0x00, length)
        }
    }

    receive() external payable {}
}

contract RejectingGasbackRoyaltyReceiver {
    receive() external payable {
        revert();
    }
}

contract RejectingGasbackRoyaltyCaller {
    function trigger(GasbackRoyaltiesERC1155Harness harness, uint256 tokenId, uint256 gasToBurn)
        external
        returns (uint256 gasbackAmount, uint256 royaltyAmount, uint256 refundAmount)
    {
        return harness.pay(tokenId, gasToBurn);
    }

    receive() external payable {
        revert();
    }
}

contract GasbackRoyaltiesTest is SoladyTest {
    uint256 internal constant GASBACK_DENOMINATOR = 1 ether;
    uint96 internal constant FEE_DENOMINATOR = 10000;

    Gasback internal gasbackTarget;

    function setUp() public {
        gasbackTarget = new Gasback();
    }

    function _expectedGasback(uint256 baseFee, uint256 gasToBurn) internal view returns (uint256) {
        return (baseFee * gasToBurn * gasbackTarget.gasbackRatioNumerator()) / GASBACK_DENOMINATOR;
    }

    function _fundGasback(uint256 baseFee, uint256 gasToBurn) internal returns (uint256 amount) {
        amount = _expectedGasback(baseFee, gasToBurn);
        vm.deal(address(gasbackTarget), amount);
        vm.fee(baseFee);
    }

    function _mockHarness(uint256 sendAmount, uint256 returnAmount)
        internal
        returns (GasbackRoyaltiesHarness harness)
    {
        MockGasbackTarget target =
            new MockGasbackTarget{value: sendAmount}(false, sendAmount, returnAmount, 32);
        harness = new GasbackRoyaltiesHarness(address(target));
    }

    function test_constructorRejectsZeroGasbackAddress() public {
        vm.expectRevert(GasbackRoyalties.GasbackIsTheZeroAddress.selector);
        new GasbackRoyaltiesHarness(address(0));
    }

    function test_erc165ReportsGasbackRoyaltiesAndNftInterfaces() public {
        GasbackRoyaltiesERC721Harness erc721 =
            new GasbackRoyaltiesERC721Harness(address(gasbackTarget));
        GasbackRoyaltiesERC1155Harness erc1155 =
            new GasbackRoyaltiesERC1155Harness(address(gasbackTarget));

        assertTrue(erc721.supportsInterface(0x01ffc9a7));
        assertTrue(erc721.supportsInterface(0x80ac58cd));
        assertTrue(erc721.supportsInterface(0x5b5e139f));
        assertTrue(erc721.supportsInterface(0x2a55205a));
        assertTrue(erc721.supportsInterface(type(IGasbackRoyalties).interfaceId));

        assertTrue(erc1155.supportsInterface(0x01ffc9a7));
        assertTrue(erc1155.supportsInterface(0xd9b67a26));
        assertTrue(erc1155.supportsInterface(0x0e89341c));
        assertTrue(erc1155.supportsInterface(0x2a55205a));
        assertTrue(erc1155.supportsInterface(type(IGasbackRoyalties).interfaceId));

        assertTrue(type(IGasbackRoyalties).interfaceId == 0x160487ee);
    }

    function test_singleTokenPayoutPaysCreatorAndRefundsCaller() public {
        GasbackRoyaltiesERC721Harness harness =
            new GasbackRoyaltiesERC721Harness(address(gasbackTarget));

        address creator = address(0xA11CE);
        address caller = address(0xB0B);
        uint96 bps = 2500;
        uint256 baseFee = 10;
        uint256 gasToBurn = 1000;
        uint256 gasbackAmount = _fundGasback(baseFee, gasToBurn);
        uint256 expectedRoyalty = (gasbackAmount * bps) / FEE_DENOMINATOR;
        uint256 expectedRefund = gasbackAmount - expectedRoyalty;

        harness.setDefaultRoyalty(creator, bps);

        vm.prank(caller);
        (uint256 returnedGasback, uint256 royaltyAmount, uint256 refundAmount) =
            harness.mintWithRoyalty(caller, 1, gasToBurn);

        assertEq(returnedGasback, gasbackAmount);
        assertEq(royaltyAmount, expectedRoyalty);
        assertEq(refundAmount, expectedRefund);
        assertEq(creator.balance, expectedRoyalty);
        assertEq(caller.balance, expectedRefund);
        assertEq(harness.ownerOf(1), caller);
        assertEq(address(harness).balance, 0);
    }

    function test_tokenRoyaltyOverrideBeatsDefaultRoyalty() public {
        GasbackRoyaltiesERC721Harness harness =
            new GasbackRoyaltiesERC721Harness(address(gasbackTarget));

        address defaultCreator = address(0xA11CE);
        address tokenCreator = address(0xBEEF);
        address caller = address(0xB0B);
        uint96 tokenBps = 5000;
        uint256 gasbackAmount = _fundGasback(10, 1000);
        uint256 expectedRoyalty = (gasbackAmount * tokenBps) / FEE_DENOMINATOR;

        harness.setDefaultRoyalty(defaultCreator, 1000);
        harness.setTokenRoyalty(7, tokenCreator, tokenBps);

        vm.prank(caller);
        (, uint256 royaltyAmount, uint256 refundAmount) = harness.mintWithRoyalty(caller, 7, 1000);

        assertEq(royaltyAmount, expectedRoyalty);
        assertEq(refundAmount, gasbackAmount - expectedRoyalty);
        assertEq(defaultCreator.balance, 0);
        assertEq(tokenCreator.balance, expectedRoyalty);
        assertEq(caller.balance, gasbackAmount - expectedRoyalty);
    }

    function test_erc1155BatchSplitsByAmountsAndPaysPerTokenRoyalty() public {
        GasbackRoyaltiesERC1155Harness harness =
            new GasbackRoyaltiesERC1155Harness(address(gasbackTarget));

        address creator1 = address(0xA11CE);
        address creator2 = address(0xBEEF);
        address creator3 = address(0xCAFE);
        address caller = address(0xB0B);
        uint256 gasbackAmount = _fundGasback(10, 1000);

        uint256[] memory ids = new uint256[](3);
        uint256[] memory amounts = new uint256[](3);
        ids[0] = 1;
        ids[1] = 2;
        ids[2] = 3;
        amounts[0] = 2;
        amounts[1] = 3;
        amounts[2] = 5;

        harness.setDefaultRoyalty(creator1, 1000);
        harness.setTokenRoyalty(2, creator2, 5000);
        harness.setTokenRoyalty(3, creator3, 10000);

        vm.prank(caller);
        (uint256 returnedGasback, uint256 royaltyAmount, uint256 refundAmount) =
            harness.mintBatchWithRoyalty(caller, ids, amounts, 1000);

        uint256 royalty1 = 1200 * 1000 / FEE_DENOMINATOR;
        uint256 royalty2 = 1800 * 5000 / FEE_DENOMINATOR;
        uint256 royalty3 = 3000;
        uint256 expectedRoyalty = royalty1 + royalty2 + royalty3;

        assertEq(gasbackAmount, 6000);
        assertEq(returnedGasback, gasbackAmount);
        assertEq(royaltyAmount, expectedRoyalty);
        assertEq(refundAmount, gasbackAmount - expectedRoyalty);
        assertEq(creator1.balance, royalty1);
        assertEq(creator2.balance, royalty2);
        assertEq(creator3.balance, royalty3);
        assertEq(caller.balance, gasbackAmount - expectedRoyalty);
        assertEq(harness.balanceOf(caller, 1), 2);
        assertEq(harness.balanceOf(caller, 2), 3);
        assertEq(harness.balanceOf(caller, 3), 5);
        assertEq(address(harness).balance, 0);
    }

    function test_roundingConservationAcrossBatchAllocations() public {
        GasbackRoyaltiesHarness harness = _mockHarness(100, 100);
        address creator = address(0xA11CE);
        address caller = address(0xB0B);

        uint256[] memory ids = new uint256[](3);
        uint256[] memory amounts = new uint256[](3);
        ids[0] = 1;
        ids[1] = 2;
        ids[2] = 3;
        amounts[0] = 1;
        amounts[1] = 1;
        amounts[2] = 1;

        harness.setDefaultRoyalty(creator, 10000);

        vm.prank(caller);
        (uint256 gasbackAmount, uint256 royaltyAmount, uint256 refundAmount) =
            harness.payBatch(ids, amounts, 1);

        assertEq(gasbackAmount, 100);
        assertEq(royaltyAmount, 100);
        assertEq(refundAmount, 0);
        assertEq(creator.balance, 100);
        assertEq(caller.balance, 0);
        assertEq(address(harness).balance, 0);
    }

    function test_zeroGasToBurnNoopsWithoutCallingGasback() public {
        MockGasbackTarget target = new MockGasbackTarget(true, 0, 0, 0);
        GasbackRoyaltiesHarness harness = new GasbackRoyaltiesHarness(address(target));

        (uint256 gasbackAmount, uint256 royaltyAmount, uint256 refundAmount) = harness.pay(1, 0);

        assertEq(gasbackAmount, 0);
        assertEq(royaltyAmount, 0);
        assertEq(refundAmount, 0);
    }

    function test_revert_whenGasbackCallReverts() public {
        MockGasbackTarget target = new MockGasbackTarget(true, 0, 0, 0);
        GasbackRoyaltiesHarness harness = new GasbackRoyaltiesHarness(address(target));

        vm.expectRevert(GasbackRoyalties.GasbackCallFailed.selector);
        harness.pay(1, 1);
    }

    function test_revert_whenGasbackReturnsEmptyData() public {
        MockGasbackTarget target = new MockGasbackTarget(false, 0, 0, 0);
        GasbackRoyaltiesHarness harness = new GasbackRoyaltiesHarness(address(target));

        vm.expectRevert(GasbackRoyalties.UnexpectedGasbackReturnData.selector);
        harness.pay(1, 1);
    }

    function test_revert_whenGasbackReturnsMalformedData() public {
        MockGasbackTarget target = new MockGasbackTarget(false, 0, 0, 31);
        GasbackRoyaltiesHarness harness = new GasbackRoyaltiesHarness(address(target));

        vm.expectRevert(GasbackRoyalties.UnexpectedGasbackReturnData.selector);
        harness.pay(1, 1);
    }

    function test_revert_whenReturnedAmountDoesNotMatchReceivedDelta() public {
        GasbackRoyaltiesHarness harness = _mockHarness(1 ether, 2 ether);
        address caller = address(0xB0B);

        vm.expectRevert(
            abi.encodeWithSelector(
                GasbackRoyalties.GasbackPayoutMismatch.selector, 2 ether, 1 ether
            )
        );
        vm.prank(caller);
        harness.pay(1, 1);
    }

    function test_revert_preexistingContractEthDoesNotSatisfyMissingPayout() public {
        MockGasbackTarget target = new MockGasbackTarget(false, 0, 1 ether, 32);
        GasbackRoyaltiesHarness harness = new GasbackRoyaltiesHarness(address(target));

        vm.deal(address(harness), 1 ether);

        vm.expectRevert(
            abi.encodeWithSelector(GasbackRoyalties.GasbackPayoutMismatch.selector, 1 ether, 0)
        );
        harness.pay(1, 1);

        assertEq(address(harness).balance, 1 ether);
    }

    function test_forceSendsToRejectingRoyaltyReceiver() public {
        GasbackRoyaltiesHarness harness = _mockHarness(1 ether, 1 ether);
        RejectingGasbackRoyaltyReceiver receiver = new RejectingGasbackRoyaltyReceiver();
        address caller = address(0xB0B);

        harness.setDefaultRoyalty(address(receiver), 10000);

        vm.prank(caller);
        (, uint256 royaltyAmount, uint256 refundAmount) = harness.pay(1, 1);

        assertEq(royaltyAmount, 1 ether);
        assertEq(refundAmount, 0);
        assertEq(address(receiver).balance, 1 ether);
        assertEq(address(harness).balance, 0);
    }

    function test_forceSendsRefundToRejectingCaller() public {
        GasbackRoyaltiesERC1155Harness harness =
            new GasbackRoyaltiesERC1155Harness(address(_newMockGasbackTarget(1 ether, 1 ether)));
        RejectingGasbackRoyaltyCaller caller = new RejectingGasbackRoyaltyCaller();

        harness.setDefaultRoyalty(address(0xA11CE), 0);

        (uint256 gasbackAmount, uint256 royaltyAmount, uint256 refundAmount) =
            caller.trigger(harness, 1, 1);

        assertEq(gasbackAmount, 1 ether);
        assertEq(royaltyAmount, 0);
        assertEq(refundAmount, 1 ether);
        assertEq(address(caller).balance, 1 ether);
        assertEq(address(harness).balance, 0);
    }

    function test_revert_batchLengthMismatch() public {
        GasbackRoyaltiesHarness harness = _mockHarness(1, 1);
        uint256[] memory ids = new uint256[](2);
        uint256[] memory amounts = new uint256[](1);

        vm.expectRevert(GasbackRoyalties.GasbackRoyaltyArrayLengthMismatch.selector);
        harness.payBatch(ids, amounts, 1);
    }

    function test_revert_batchAllZeroAmounts() public {
        GasbackRoyaltiesHarness harness = _mockHarness(1, 1);
        uint256[] memory ids = new uint256[](2);
        uint256[] memory amounts = new uint256[](2);

        vm.expectRevert(GasbackRoyalties.GasbackRoyaltyNoTokenAmounts.selector);
        harness.payBatch(ids, amounts, 1);
    }

    function testFuzz_batchRoyaltyConservesGasbackPayout(
        uint256 baseFee,
        uint256 gasToBurn,
        uint96 bps,
        uint256[8] memory rawAmounts,
        uint8 rawLength
    ) public {
        baseFee = _bound(baseFee, 2, 1e6);
        gasToBurn = _bound(gasToBurn, 1, 1000);
        bps = uint96(_bound(bps, 0, FEE_DENOMINATOR));
        uint256 length = _bound(rawLength, 1, 8);

        GasbackRoyaltiesERC1155Harness harness =
            new GasbackRoyaltiesERC1155Harness(address(gasbackTarget));
        address creator = address(0xA11CE);
        address caller = address(0xB0B);
        uint256 gasbackAmount = _fundGasback(baseFee, gasToBurn);

        uint256[] memory ids = new uint256[](length);
        uint256[] memory amounts = new uint256[](length);
        uint256 totalAmount;
        for (uint256 i; i < length; ++i) {
            ids[i] = i + 1;
            amounts[i] = _bound(rawAmounts[i], 0, 100);
            totalAmount += amounts[i];
        }
        if (totalAmount == 0) {
            amounts[0] = 1;
        }

        harness.setDefaultRoyalty(creator, bps);

        uint256 creatorBefore = creator.balance;
        uint256 callerBefore = caller.balance;

        vm.prank(caller);
        (uint256 returnedGasback, uint256 royaltyAmount, uint256 refundAmount) =
            harness.payBatch(ids, amounts, gasToBurn);

        assertEq(returnedGasback, gasbackAmount);
        assertEq(royaltyAmount + refundAmount, gasbackAmount);
        assertEq(creator.balance - creatorBefore, royaltyAmount);
        assertEq(caller.balance - callerBefore, refundAmount);
        assertEq(address(harness).balance, 0);
    }

    function _newMockGasbackTarget(uint256 sendAmount, uint256 returnAmount)
        internal
        returns (MockGasbackTarget target)
    {
        target = new MockGasbackTarget{value: sendAmount}(false, sendAmount, returnAmount, 32);
    }
}
