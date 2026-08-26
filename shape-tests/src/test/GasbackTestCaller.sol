// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

contract GasbackTestCaller {
    error NotOwner();
    error ZeroAddress();
    error InvalidGasbackAddress();
    error GasbackCallFailed();
    error UnexpectedReturnData();
    error WithdrawFailed();

    event GasbackCalled(address indexed caller, uint256 gasToBurn, uint256 ethReceived);
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);
    event Withdrawal(address indexed to, uint256 amount);

    address public immutable GASBACK;
    address public owner;

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    constructor(address gasback_) {
        if (gasback_ == address(0)) revert ZeroAddress();
        if (gasback_.code.length == 0) revert InvalidGasbackAddress();
        GASBACK = gasback_;
        owner = msg.sender;
        emit OwnershipTransferred(address(0), msg.sender);
    }

    function burnGas(uint256 gasToBurn) external returns (uint256 ethReceived) {
        (bool success, bytes memory data) = GASBACK.call(abi.encode(gasToBurn));
        if (!success) revert GasbackCallFailed();
        if (data.length != 32) revert UnexpectedReturnData();
        ethReceived = abi.decode(data, (uint256));
        emit GasbackCalled(msg.sender, gasToBurn, ethReceived);
    }

    function withdraw(address payable to, uint256 amount) external onlyOwner {
        if (to == address(0)) revert ZeroAddress();
        (bool success,) = to.call{value: amount}("");
        if (!success) revert WithdrawFailed();
        emit Withdrawal(to, amount);
    }

    function transferOwnership(address newOwner) external onlyOwner {
        if (newOwner == address(0)) revert ZeroAddress();
        emit OwnershipTransferred(owner, newOwner);
        owner = newOwner;
    }

    receive() external payable {}
}
