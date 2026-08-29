// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {GiftCard} from "../samples/contracts/GiftCard.sol";

/// @notice Unit tests for the educational GiftCard contract.
contract GiftCardTest is Test {
    address internal sender = address(0xA11CE);
    address internal recipient = address(0xB0B);
    GiftCard internal card;

    function setUp() public {
        vm.deal(sender, 10 ether);
        vm.prank(sender);
        card = new GiftCard{value: 1 ether}(recipient);
    }

    function testConstructorSetsState() public view {
        assertEq(card.balance(), 1 ether);
        assertEq(card.from(), sender);
        assertEq(card.to(), recipient);
    }

    function testConstructorRejectsZeroValue() public {
        vm.prank(sender);
        vm.expectRevert(GiftCard.InvalidAmount.selector);
        new GiftCard{value: 0}(recipient);
    }

    function testConstructorRejectsZeroRecipient() public {
        vm.prank(sender);
        vm.expectRevert(GiftCard.InvalidRecipient.selector);
        new GiftCard{value: 1 ether}(address(0));
    }

    function testRecipientCanWithdraw() public {
        vm.prank(recipient);
        card.withdraw(0.4 ether);
        assertEq(card.balance(), 0.6 ether);
        assertEq(recipient.balance, 0.4 ether);
    }

    function testWithdrawAllEmptiesCard() public {
        vm.prank(recipient);
        card.withdrawAll();
        assertEq(card.balance(), 0);
        assertEq(recipient.balance, 1 ether);
    }

    function testNonRecipientCannotWithdraw() public {
        vm.prank(sender);
        vm.expectRevert(GiftCard.OnlyRecipientCanSpend.selector);
        card.withdraw(0.1 ether);
    }

    function testSpendSendsToChosenAddress() public {
        address payee = address(0xCAFE);
        vm.prank(recipient);
        card.spend(payee, 0.25 ether);
        assertEq(payee.balance, 0.25 ether);
        assertEq(card.balance(), 0.75 ether);
    }

    function testSpendMoreThanBalanceReverts() public {
        vm.prank(recipient);
        vm.expectRevert(GiftCard.InsufficientBalance.selector);
        card.spend(recipient, 2 ether);
    }

    function testOnlyOriginalSenderCanRefund() public {
        vm.prank(recipient);
        vm.expectRevert(GiftCard.OnlyOriginalSenderCanRefund.selector);
        card.refund(0.1 ether);
    }

    function testSenderCanRefundAll() public {
        uint256 balanceBefore = sender.balance;
        vm.prank(sender);
        card.refundAll();
        assertEq(card.balance(), 0);
        assertEq(sender.balance, balanceBefore + 1 ether);
    }

    function testDirectTransferReverts() public {
        vm.deal(address(this), 1 ether);
        (bool ok, ) = address(card).call{value: 1 wei}("");
        assertFalse(ok);
    }

    function testBalanceIsConsistent() public view {
        assertTrue(card.isBalanceConsistent());
    }
}
