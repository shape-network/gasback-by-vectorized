// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/**
 * @title ShapePaymentSplitter
 * @dev This contract, forked from OpenZeppelin's PaymentSplitter, allows for splitting Ether payments among a group of accounts.
 * It has been modified by Shape to remove ERC20 interactions, focusing solely on Ether distribution.
 *
 * The split can be in equal parts or in any other arbitrary proportion, specified by assigning shares to each account.
 * Each account can claim an amount proportional to their percentage of total shares. The share distribution is set at
 * contract deployment and cannot be updated thereafter.
 *
 * ShapePaymentSplitter follows a _push payment_ model. Payments are not automatically forwarded to accounts.
 *
 * The sender of Ether to this contract does not need to be aware of the split mechanism, as it is handled transparently.
 */
contract ShapePaymentSplitter {
    event PayeeAdded(address account, uint256 shares);
    event PaymentReleased(address to, uint256 amount);
    event PaymentReceived(address from, uint256 amount);

    error FailedToSendValue();
    error PayeesAndSharesLengthMismatch();
    error NoPayees();
    error AccountAlreadyHasShares();
    error AccountIsTheZeroAddress();
    error SharesAreZero();
    error AccountHasNoShares();
    error AccountIsNotDuePayment();
    error InsufficientBalance();

    uint256 private _totalShares;
    uint256 private _totalReleased;

    mapping(address => uint256) private _shares;
    mapping(address => uint256) private _released;
    address[] private _payees;

    /**
     * @dev Creates an instance of `ShapePaymentSplitter` where each account in `payees` is assigned the number of shares at
     * the matching position in the `shares` array.
     *
     * All addresses in `payees` must be non-zero. Both arrays must have the same non-zero length, and there must be no
     * duplicates in `payees`.
     */
    constructor(address[] memory payees_, uint256[] memory shares_) payable {
        if (payees_.length != shares_.length)
            revert PayeesAndSharesLengthMismatch();
        if (payees_.length == 0) revert NoPayees();

        for (uint256 i = 0; i < payees_.length; i++) {
            _addPayee(payees_[i], shares_[i]);
        }
    }

    /**
     * @dev The Ether received will be logged with {PaymentReceived} events. Note that these events are not fully
     * reliable: it's possible for a contract to receive Ether without triggering this function. This only affects the
     * reliability of the events, and not the actual splitting of Ether.
     *
     * To learn more about this see the Solidity documentation for
     * https://solidity.readthedocs.io/en/latest/contracts.html#fallback-function[fallback
     * functions].
     */
    receive() external payable {
        for (uint256 i = 0; i < _payees.length; i++) {
            release(payable(_payees[i]));
        }
        emit PaymentReceived(msg.sender, msg.value);
    }

    /**
     * @dev Getter for the total shares held by payees.
     */
    function totalShares() public view returns (uint256) {
        return _totalShares;
    }

    /**
     * @dev Getter for the total amount of Ether already released.
     */
    function totalReleased() public view returns (uint256) {
        return _totalReleased;
    }

    /**
     * @dev Getter for the amount of shares held by an account.
     */
    function shares(address account) public view returns (uint256) {
        return _shares[account];
    }

    /**
     * @dev Getter for the amount of Ether already released to a payee.
     */
    function released(address account) public view returns (uint256) {
        return _released[account];
    }

    /**
     * @dev Getter for the address of the payee number `index`.
     */
    function payee(uint256 index) public view returns (address) {
        return _payees[index];
    }

    /**
     * @dev Getter for the addresses of the payees.
     */
    function payees() public view returns (address[] memory) {
        return _payees;
    }

    /**
     * @dev Getter for the amount of payee's releasable Ether.
     */
    function releasable(address account) public view returns (uint256) {
        uint256 totalReceived = address(this).balance + totalReleased();
        return _pendingPayment(account, totalReceived, released(account));
    }

    /**
     * @dev Triggers a transfer to `account` of the amount of Ether they are owed, according to their percentage of the
     * total shares and their previous withdrawals.
     */
    function release(address payable account) public {
        if (_shares[account] == 0) revert AccountHasNoShares();

        uint256 payment = releasable(account);

        if (payment == 0) revert AccountIsNotDuePayment();

        // _totalReleased is the sum of all values in _released.
        // If "_totalReleased += payment" does not overflow, then "_released[account] += payment" cannot overflow.
        _totalReleased += payment;
        unchecked {
            _released[account] += payment;
        }

        _sendValue(account, payment);

        emit PaymentReleased(account, payment);
    }

    /**
     * @dev internal logic for computing the pending payment of an `account` given the token historical balances and
     * already released amounts.
     */
    function _pendingPayment(
        address account,
        uint256 totalReceived,
        uint256 alreadyReleased
    ) private view returns (uint256) {
        return
            (totalReceived * _shares[account]) / _totalShares - alreadyReleased;
    }

    /**
     * @dev Add a new payee to the contract.
     * @param account The address of the payee to add.
     * @param shares_ The number of shares owned by the payee.
     */
    function _addPayee(address account, uint256 shares_) private {
        if (account == address(0)) revert AccountIsTheZeroAddress();
        if (shares_ == 0) revert SharesAreZero();
        if (_shares[account] != 0) revert AccountAlreadyHasShares();

        _payees.push(account);
        _shares[account] = shares_;
        _totalShares = _totalShares + shares_;
        emit PayeeAdded(account, shares_);
    }

    /**
     * @dev Replacement for Solidity's `transfer`: sends `amount` wei to
     * `recipient`, forwarding all available gas and reverting on errors.
     *
     * https://eips.ethereum.org/EIPS/eip-1884[EIP1884] increases the gas cost
     * of certain opcodes, possibly making contracts go over the 2300 gas limit
     * imposed by `transfer`, making them unable to receive funds via
     * `transfer`. {sendValue} removes this limitation.
     *
     * https://consensys.net/diligence/blog/2019/09/stop-using-soliditys-transfer-now/[Learn more].
     *
     * IMPORTANT: because control is transferred to `recipient`, care must be
     * taken to not create reentrancy vulnerabilities. Consider using
     * {ReentrancyGuard} or the
     * https://solidity.readthedocs.io/en/v0.8.20/security-considerations.html#use-the-checks-effects-interactions-pattern[checks-effects-interactions pattern].
     */
    function _sendValue(address payable recipient, uint256 amount) private {
        if (address(this).balance < amount) {
            revert InsufficientBalance();
        }

        (bool success, ) = recipient.call{value: amount}("");
        if (!success) {
            revert FailedToSendValue();
        }
    }
}
