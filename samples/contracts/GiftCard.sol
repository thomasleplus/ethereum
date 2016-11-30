/*
 * GiftCard - GiftCard example
 * Copyright (C) 2016 Thomas Leplus
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with this program.  If not, see <http://www.gnu.org/licenses/>.
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



