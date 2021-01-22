/*
 * GiftCard - GiftCard example
 */

contract GiftCard {
    
    uint public balance;
    address public from;
    address public to;
    
    function GiftCard(address reciever) {
        balance = msg.value;
        from = msg.sender;
        to = reciever;
    }
    
    function spend(address reciever, uint amount) returns (bool success) {
        if (msg.sender != to) {
            throw;
        }
        if (balance < 0) {
            throw;
        }
        if (amount < 0) {
            throw;
        }
        if (balance < amount) {
            throw;
        }
        balance -= amount;
        reciever.send(amount);
        return true;
    }
    
    function spendAll(address receiver) returns (bool success) {
        return spend(receiver, balance);
    }
    
    function withdraw(uint amount) returns (bool success) {
        return spend(msg.sender, amount);
    }
    
    function withdrawAll() returns (bool success) {
        return withdraw(balance);
    }
    
    function refund(uint amount) returns (bool success) {
        return spend(from, amount);
    }
    
    function refundAll() returns (bool success) {
        return refund(balance);
    }
    
    function () {
        throw;
    }
    
}



