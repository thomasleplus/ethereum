// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.30;

import {CommonBase} from "forge-std/Base.sol";
import {Test} from "forge-std/Test.sol";

import {GiftCard} from "../samples/contracts/GiftCard.sol";

/**
 * @notice A malicious receiver that calls back into the card while being paid.
 * @dev Inherits CommonBase purely for access to `vm`, so it can inspect the card's storage from
 *      inside the callback — the moment when the reentrancy guard is engaged.
 */
contract ReentrantRecipient is CommonBase {
    GiftCard public card;
    bytes public reentryPayload;

    uint256 public reentryAttempts;
    bool public reentrySucceeded;
    bytes public reentryRevertData;
    bytes32 public guardSlotDuringCallback;

    function arm(GiftCard card_, bytes memory reentryPayload_) external {
        card = card_;
        reentryPayload = reentryPayload_;
    }

    /// @notice Kicks off the outer call that will pay this contract and trigger `receive()`.
    function pull(bytes memory outerPayload) external returns (bool accepted) {
        //slither-disable-next-line low-level-calls
        (accepted,) = address(card).call(outerPayload);
    }

    receive() external payable {
        if (reentryAttempts != 0) return;
        reentryAttempts += 1;

        guardSlotDuringCallback = vm.load(address(card), bytes32(uint256(1)));

        //slither-disable-next-line low-level-calls
        (bool accepted, bytes memory result) = address(card).call(reentryPayload);
        reentrySucceeded = accepted;
        reentryRevertData = result;
    }
}

/// @notice Force-feeds ether into a target, bypassing its `receive()`.
contract ForceFeeder {
    constructor(address payable target) payable {
        //slither-disable-next-line suicidal
        selfdestruct(target);
    }
}

/**
 * @notice Targeted security tests for the GiftCard: reentrancy protection, storage layout and
 *         the contract's response to ether it did not account for.
 * @author Thomas Leplus
 */
contract GiftCardSecurityTest is Test {
    address internal giver = makeAddr("giver");
    address internal receiver = makeAddr("receiver");
    address internal payee = makeAddr("payee");

    function _newCard(address to, uint256 amount) internal returns (GiftCard) {
        vm.deal(giver, amount);
        vm.prank(giver);
        return new GiftCard{value: amount}(to);
    }

    // -------------------------------------------------------------------------
    // Reentrancy
    // -------------------------------------------------------------------------

    /**
     * @notice Runs the canonical attack: a 1 ether card held by a reentrant receiver, which calls
     *         back with `reentryPayload` while being paid by an outer withdrawal of half the card.
     * @dev Only half is withdrawn so that at callback time the card still holds exactly what it
     *      thinks it holds: without the guard the reentrant call would pass every check.
     */
    function _attack(bytes memory reentryPayload)
        internal
        returns (ReentrantRecipient attacker, GiftCard card, bool accepted)
    {
        attacker = new ReentrantRecipient();
        card = _newCard(address(attacker), 1 ether);
        attacker.arm(card, reentryPayload);

        vm.prank(address(attacker));
        accepted = attacker.pull(abi.encodeCall(GiftCard.withdraw, (0.5 ether)));
    }

    /// @notice A receiver that re-enters `withdraw` while being paid cannot double-spend.
    function testReentrantWithdrawIsBlocked() public {
        (ReentrantRecipient attacker, GiftCard card, bool accepted) =
            _attack(abi.encodeCall(GiftCard.withdraw, (0.5 ether)));

        assertTrue(accepted, "outer withdrawal should succeed");
        assertEq(attacker.reentryAttempts(), 1, "callback did not fire");
        assertFalse(attacker.reentrySucceeded(), "reentrant withdrawal was allowed");
        assertEq(address(attacker).balance, 0.5 ether, "attacker drained more than one withdrawal");
        assertEq(card.balance(), 0.5 ether, "card lost more than one withdrawal");
        assertTrue(card.isBalanceConsistent(), "accounting drifted during reentrancy");
    }

    /// @notice Re-entering a *different* entry point is blocked too: the guard is contract-wide.
    function testCrossFunctionReentrancyIsBlocked() public {
        (ReentrantRecipient attacker, GiftCard card,) = _attack(abi.encodeCall(GiftCard.spend, (payee, 0.5 ether)));

        assertFalse(attacker.reentrySucceeded(), "reentrant spend was allowed");
        assertEq(payee.balance, 0, "payee was paid during a reentrant call");
        assertEq(card.balance(), 0.5 ether, "card lost more than one withdrawal");
    }

    /**
     * @notice It is the reentrancy guard specifically, not some other check, that rejects the
     *         reentrant call — and it is released again afterwards.
     * @dev Asserting on the revert data rather than on a storage slot keeps this test honest now
     *      that the guard lives in transient storage: `ReentrancyGuardActive` can only come from
     *      `nonReentrant`, whereas an amount or balance check would surface a different error.
     */
    function testReentrancyIsRejectedByTheGuardItself() public {
        (ReentrantRecipient attacker, GiftCard card,) = _attack(abi.encodeCall(GiftCard.withdraw, (0.5 ether)));

        assertEq(
            attacker.reentryRevertData(),
            abi.encodeWithSelector(GiftCard.ReentrancyGuardActive.selector),
            "reentrant call was not rejected by the reentrancy guard"
        );

        // And the card still works afterwards: the guard did not brick it.
        vm.prank(address(attacker));
        card.withdrawAll();
        assertEq(card.balance(), 0, "card was left unusable after a blocked reentrancy");
    }

    // -------------------------------------------------------------------------
    // Storage layout
    // -------------------------------------------------------------------------

    /**
     * @notice The card uses exactly one storage slot: `balance`.
     * @dev `from` and `to` are immutable and live in code. `locked` is transient, so it never
     *      touches a storage slot — asserted from inside the payout callback, i.e. at the one
     *      moment the guard is actually engaged. That pins both the layout and the choice of
     *      transient storage: a plain `bool` guard would show up as 1 in slot 1 right there.
     */
    function testGuardUsesNoStorageSlot() public {
        (ReentrantRecipient attacker, GiftCard card,) = _attack(abi.encodeCall(GiftCard.withdraw, (0.5 ether)));

        assertEq(attacker.reentryAttempts(), 1, "callback did not fire");
        assertEq(uint256(attacker.guardSlotDuringCallback()), 0, "guard occupies a storage slot");
        assertEq(uint256(vm.load(address(card), bytes32(uint256(0)))), card.balance(), "slot 0 is not `balance`");
        assertEq(uint256(vm.load(address(card), bytes32(uint256(1)))), 0, "unexpected second storage slot");
    }

    // -------------------------------------------------------------------------
    // Unaccounted ether
    // -------------------------------------------------------------------------

    /**
     * @notice Ether force-fed into the card does not disturb it.
     * @dev `receive()` rejects plain transfers, but ether can still be pushed in by
     *      `selfdestruct`, by a block reward or by a beacon-chain withdrawal. `validBalance`
     *      therefore checks solvency rather than strict equality: a surplus is tolerated and
     *      simply stays out of reach. With a strict `balance == address(this).balance` check, the
     *      one wei below would have made every entry point revert forever.
     */
    function testForceFedEtherDoesNotBrickTheCard() public {
        GiftCard card = _newCard(receiver, 1 ether);

        vm.deal(address(this), 1 wei);
        new ForceFeeder{value: 1 wei}(payable(address(card)));

        assertEq(address(card).balance, 1 ether + 1, "force-feed did not land");
        assertFalse(card.isBalanceConsistent(), "card should report the surplus");

        // Every entry point still works, for both principals.
        vm.prank(receiver);
        card.withdraw(0.1 ether);
        assertEq(card.balance(), 0.9 ether, "withdraw failed after force-feed");

        vm.prank(receiver);
        card.spend(payee, 0.1 ether);
        assertEq(payee.balance, 0.1 ether, "spend failed after force-feed");

        vm.prank(giver);
        card.refund(0.1 ether);
        assertEq(card.balance(), 0.7 ether, "refund failed after force-feed");

        vm.prank(receiver);
        card.withdrawAll();

        // The card paid out everything it owed; only the force-fed wei is left behind.
        assertEq(card.balance(), 0, "card could not be emptied");
        assertEq(address(card).balance, 1 wei, "card kept more than the force-fed surplus");
    }

    /// @notice The surplus is never payable: a force-fed card still only owes its own balance.
    function testForceFedEtherIsNeverPaidOut() public {
        GiftCard card = _newCard(receiver, 1 ether);

        vm.deal(address(this), 5 ether);
        new ForceFeeder{value: 5 ether}(payable(address(card)));

        vm.prank(receiver);
        vm.expectRevert(GiftCard.InsufficientBalance.selector);
        card.withdraw(2 ether);

        vm.prank(receiver);
        card.withdrawAll();
        assertEq(receiver.balance, 1 ether, "receiver was paid force-fed ether");
        assertEq(address(card).balance, 5 ether, "surplus was not left untouched");
    }
}
