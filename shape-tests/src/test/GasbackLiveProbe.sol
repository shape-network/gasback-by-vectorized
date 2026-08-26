// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

interface IGasbackLiveProbeTarget {
    function accrued() external view returns (uint256);
}

contract GasbackLiveProbe {
    error NotOwner();
    error ZeroAddress();
    error InvalidGasbackAddress();
    error GasbackCallFailed();
    error UnexpectedReturnData();
    error WithdrawFailed();

    event ProbeResult(
        uint256 gasToBurn,
        uint256 blockBaseFee,
        uint256 payout,
        uint256 accruedBefore,
        uint256 accruedAfter,
        uint256 gasbackBalanceBefore,
        uint256 gasbackBalanceAfter
    );

    address public immutable GASBACK;
    address public owner;

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    constructor(address gasback) {
        if (gasback == address(0)) revert ZeroAddress();
        if (gasback.code.length == 0) revert InvalidGasbackAddress();
        GASBACK = gasback;
        owner = msg.sender;
    }

    function probe(uint256 gasToBurn) external returns (uint256 payout) {
        address gasback = GASBACK;
        uint256 accruedBefore = IGasbackLiveProbeTarget(gasback).accrued();
        uint256 gasbackBalanceBefore = gasback.balance;

        (bool success, bytes memory data) = gasback.call(abi.encode(gasToBurn));
        if (!success) revert GasbackCallFailed();
        if (data.length != 32) revert UnexpectedReturnData();
        payout = abi.decode(data, (uint256));

        emit ProbeResult(
            gasToBurn,
            block.basefee,
            payout,
            accruedBefore,
            IGasbackLiveProbeTarget(gasback).accrued(),
            gasbackBalanceBefore,
            gasback.balance
        );
    }

    function withdraw(address payable to, uint256 amount) external onlyOwner {
        if (to == address(0)) revert ZeroAddress();
        (bool success,) = to.call{value: amount}("");
        if (!success) revert WithdrawFailed();
    }

    function transferOwnership(address newOwner) external onlyOwner {
        if (newOwner == address(0)) revert ZeroAddress();
        owner = newOwner;
    }

    receive() external payable {}
}
