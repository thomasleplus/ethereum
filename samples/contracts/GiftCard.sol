// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.30;

/**
 * @title GiftCard
 * @dev A secure gift card contract that allows creating, spending, and refunding Ether-based gift cards
 * @author Updated for modern Solidity practices
 */
contract GiftCard {
    // State variables
    uint256 public balance;
    address public immutable from;
    address public immutable to;
    bool private locked; // Reentrancy guard
    
    // Events for transparency
    event GiftCardCreated(address indexed from, address indexed to, uint256 amount);
    event AmountSpent(address indexed recipient, uint256 amount);
    event AmountRefunded(address indexed originalSender, uint256 amount);
    event GiftCardDestroyed(address indexed by, uint256 remainingBalance);
    
    // Custom errors (gas efficient)
    error OnlyRecipientCanSpend();
    error OnlyOriginalSenderCanRefund();
    error InsufficientBalance();
    error InvalidAmount();
    error InvalidBalance();
    error TransferFailed();
    error ReentrancyGuardActive();
    error ContractHasInsufficientEther();
    
    // Modifiers
    modifier onlyRecipient() {
        if (msg.sender != to) revert OnlyRecipientCanSpend();
        _;
    }
    
    modifier onlyOriginalSender() {
        if (msg.sender != from) revert OnlyOriginalSenderCanRefund();
        _;
    }
    
    modifier validBalance() {
        if (balance != address(this).balance) revert InvalidBalance();
        if (balance == 0) revert InsufficientBalance();
        _;
    }
    
    modifier validAmount(uint256 amount) {
        if (amount == 0) revert InvalidAmount();
        if (amount > balance) revert InsufficientBalance();
        _;
    }
    
    modifier nonReentrant() {
        if (locked) revert ReentrancyGuardActive();
        locked = true;
        _;
        locked = false;
    }
    
    /**
     * @dev Constructor to create a gift card
     * @param recipient The address that can spend the gift card
     */
    constructor(address recipient) payable {
        if (recipient == address(0)) revert InvalidAmount();
        if (msg.value == 0) revert InvalidAmount();
        
        balance = msg.value;
        from = msg.sender;
        to = recipient;
        
        emit GiftCardCreated(msg.sender, recipient, msg.value);
    }
    
    /**
     * @dev Internal function to handle secure Ether transfers
     * @param recipient Address to send Ether to
     * @param amount Amount of Ether to send
     */
    function _safeTransfer(address recipient, uint256 amount) internal {
        if (address(this).balance < amount) revert ContractHasInsufficientEther();
        //slither-disable-next-line low-level-calls,functions-that-send-ether-to-arbitrary-destinations
        (bool success, ) = payable(recipient).call{value: amount}("");
        if (!success) revert TransferFailed();
    }
    
    /**
     * @dev Spend a specific amount from the gift card
     * @param recipient Address to send the Ether to
     * @param amount Amount to spend (in wei)
     * @return success True if the transaction succeeded
     */
    function spend(address recipient, uint256 amount) 
        external 
        onlyRecipient 
        validBalance 
        validAmount(amount) 
        nonReentrant 
        returns (bool success) 
    {
        if (recipient == address(0)) revert InvalidAmount();
        
        balance -= amount;
        _safeTransfer(recipient, amount);
        
        emit AmountSpent(recipient, amount);
        return true;
    }
    
    /**
     * @dev Spend all remaining balance from the gift card
     * @param recipient Address to send all remaining Ether to
     * @return success True if the transaction succeeded
     */
    function spendAll(address recipient) external onlyRecipient validBalance nonReentrant returns (bool success) {
        if (recipient == address(0)) revert InvalidAmount();
        
        uint256 amountToSpend = balance;
        balance = 0;
        _safeTransfer(recipient, amountToSpend);
        
        emit AmountSpent(recipient, amountToSpend);
        return true;
    }
    
    /**
     * @dev Withdraw a specific amount to the recipient's own address
     * @param amount Amount to withdraw (in wei)
     * @return success True if the transaction succeeded
     */
    function withdraw(uint256 amount) external onlyRecipient validBalance validAmount(amount) nonReentrant returns (bool success) {
        balance -= amount;
        _safeTransfer(msg.sender, amount);
        
        emit AmountSpent(msg.sender, amount);
        return true;
    }
    
    /**
     * @dev Withdraw all remaining balance to the recipient's own address
     * @return success True if the transaction succeeded
     */
    function withdrawAll() external onlyRecipient validBalance nonReentrant returns (bool success) {
        uint256 amountToWithdraw = balance;
        balance = 0;
        _safeTransfer(msg.sender, amountToWithdraw);
        
        emit AmountSpent(msg.sender, amountToWithdraw);
        return true;
    }
    
    /**
     * @dev Refund a specific amount back to the original sender
     * @param amount Amount to refund (in wei)
     * @return success True if the transaction succeeded
     */
    function refund(uint256 amount) external onlyOriginalSender validBalance validAmount(amount) nonReentrant returns (bool success) {
        balance -= amount;
        _safeTransfer(from, amount);
        
        emit AmountRefunded(from, amount);
        return true;
    }
    
    /**
     * @dev Refund all remaining balance back to the original sender
     * @return success True if the transaction succeeded
     */
    function refundAll() external onlyOriginalSender validBalance nonReentrant returns (bool success) {
        uint256 amountToRefund = balance;
        balance = 0;
        _safeTransfer(from, amountToRefund);
        
        emit AmountRefunded(from, amountToRefund);
        return true;
    }
    
    /**
     * @dev Get the actual Ether balance of the contract
     * @return The contract's Ether balance in wei
     */
    function getContractBalance() external view returns (uint256) {
        return address(this).balance;
    }
    
    /**
     * @dev Check if the contract's state is consistent
     * @return True if gift card balance matches contract's Ether balance
     */
    function isBalanceConsistent() external view returns (bool) {
        //slither-disable-next-line dangerous-strict-equalities
        return balance == address(this).balance;
    }
    
    /**
     * @dev Fallback function - rejects all direct Ether transfers
     */
    receive() external payable {
        revert("Direct transfers not allowed");
    }
    
    /**
     * @dev Fallback function for non-existent function calls
     */
    fallback() external {
        revert("Function does not exist");
    }
}
