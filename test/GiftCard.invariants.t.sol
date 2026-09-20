// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {console} from "forge-std/console.sol";

import {GiftCard} from "../samples/contracts/GiftCard.sol";
import {GiftCardHandler} from "./handlers/GiftCardHandler.sol";

/**
 * @notice Shared setup and invariants for the stateful suites.
 * @dev Unit tests assert what happens along known paths. These suites assert what must remain
 *      true after *any* path: the fuzzer assembles random sequences of calls from random actors
 *      and every invariant is re-checked after each one. The properties below are the ones the
 *      contract's safety rests on — solvency, conservation of ether, access control, and the
 *      liveness property that a funded card can always be emptied by its receiver.
 */
abstract contract GiftCardInvariantBase is Test {
    address internal giver;
    address internal receiver;
    GiftCardHandler internal handler;

    function _setUpHandler() internal {
        giver = makeAddr("giver");
        receiver = makeAddr("receiver");

        handler = new GiftCardHandler(giver, receiver);
        targetContract(address(handler));
    }

    /// @dev The card currently under test. The handler rolls a fresh one once a card is spent.
    function _card() internal view returns (GiftCard) {
        return handler.card();
    }

    // -------------------------------------------------------------------------
    // Invariants that hold under every scenario
    // -------------------------------------------------------------------------

    /// @notice Solvency: a card never owes more ether than it actually holds.
    function invariant_cardIsSolvent() public view {
        GiftCard card = _card();
        assertLe(card.balance(), address(card).balance, "card owes more than it holds");
    }

    /**
     * @notice Conservation: every wei that entered a card is still in it, was paid out to the
     *         receiver, was refunded to the giver, or is stranded in a retired card.
     */
    function invariant_etherIsConserved() public view {
        assertEq(
            address(_card()).balance + handler.ghostPaidOut() + handler.ghostRefunded() + handler.ghostStranded(),
            handler.ghostDeposited() + handler.ghostDonated(),
            "ether was created or destroyed"
        );
    }

    /**
     * @notice Cards only ever pay out ether that was deposited into them.
     * @dev Deliberately compared against deposits alone: force-fed ether must never become
     *      spendable, so it does not belong on the right-hand side.
     */
    function invariant_payoutsNeverExceedDeposits() public view {
        assertLe(
            handler.ghostPaidOut() + handler.ghostRefunded(),
            handler.ghostDeposited(),
            "a card paid out more than it was funded with"
        );
    }

    /**
     * @notice Liveness: a card with a balance can always be emptied by its receiver.
     * @dev The strongest property in the suite, and the one that fails on every bricking bug at
     *      once — a stuck reentrancy guard, a botched access check, or the strict
     *      `balance == address(this).balance` test that one wei of force-fed ether used to
     *      defeat. Rather than re-implementing the contract's preconditions and asserting they
     *      hold, this actually drains the card inside a state snapshot and rolls it back, so it
     *      cannot drift away from what the contract really does.
     */
    function invariant_cardIsAlwaysDrainable() public {
        GiftCard card = _card();
        uint256 owed = card.balance();
        if (owed == 0) return;

        uint256 snapshot = vm.snapshotState();
        uint256 balanceBefore = receiver.balance;

        vm.prank(receiver);
        card.withdrawAll();

        assertEq(card.balance(), 0, "card could not be emptied");
        assertEq(receiver.balance - balanceBefore, owed, "receiver was not paid what the card owed");

        vm.revertToState(snapshot);
    }

    /// @notice Only the giver and the receiver can move funds, and only through the entry points.
    function invariant_onlyPrincipalsMoveFunds() public view {
        assertEq(handler.ghostUnauthorizedSuccesses(), 0, "a stranger moved funds");
        assertEq(handler.ghostDirectTransferSuccesses(), 0, "a plain ether transfer was accepted");
    }

    /// @notice Giver and receiver are fixed for the life of a card.
    function invariant_principalsAreImmutable() public view {
        GiftCard card = _card();
        assertEq(card.from(), giver, "giver changed");
        assertEq(card.to(), receiver, "receiver changed");
    }

    function afterInvariant() public view {
        console.log("cards issued  ", handler.ghostCardsIssued());
        console.log("spend         ", handler.callCount("spend"));
        console.log("spendAll      ", handler.callCount("spendAll"));
        console.log("withdraw      ", handler.callCount("withdraw"));
        console.log("withdrawAll   ", handler.callCount("withdrawAll"));
        console.log("refund        ", handler.callCount("refund"));
        console.log("refundAll     ", handler.callCount("refundAll"));
        console.log("strangerCalls ", handler.callCount("strangerCalls"));
        console.log("directTransfer", handler.callCount("directTransfer"));
        console.log("donate        ", handler.callCount("donate"));
    }
}

/**
 * @notice Invariants over the card's supported surface: both principals, plus strangers and
 *         plain transfers that must always bounce.
 * @dev Runs, depth and `fail_on_revert` are set once in foundry.toml rather than inline here, so
 *      CI can turn the campaign up via FOUNDRY_INVARIANT_RUNS without editing the suites.
 */
contract GiftCardInvariantTest is GiftCardInvariantBase {
    function setUp() public {
        _setUpHandler();

        // Every selector except `donate`, which GiftCardForceFedInvariantTest exercises.
        bytes4[] memory selectors = new bytes4[](8);
        selectors[0] = GiftCardHandler.spend.selector;
        selectors[1] = GiftCardHandler.spendAll.selector;
        selectors[2] = GiftCardHandler.withdraw.selector;
        selectors[3] = GiftCardHandler.withdrawAll.selector;
        selectors[4] = GiftCardHandler.refund.selector;
        selectors[5] = GiftCardHandler.refundAll.selector;
        selectors[6] = GiftCardHandler.strangerCalls.selector;
        selectors[7] = GiftCardHandler.directTransfer.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
    }

    /**
     * @notice With no force-fed ether a card's bookkeeping matches its real balance exactly.
     * @dev The strong form of `invariant_cardIsSolvent`. It only holds while nobody has pushed
     *      ether in through a non-standard path — which is exactly why `validBalance` checks
     *      solvency rather than this equality: the contract must not depend on a property an
     *      outsider can break.
     */
    function invariant_accountingIsExact() public view {
        GiftCard card = _card();
        assertEq(card.balance(), address(card).balance, "accounting drifted from ether held");
        assertTrue(card.isBalanceConsistent(), "card reports inconsistent balance");
    }

    /// @notice A card's balance never exceeds what it was funded with: there is no top-up path.
    function invariant_balanceNeverGrows() public view {
        assertLe(_card().balance(), handler.DEPOSIT(), "balance grew beyond the deposit");
    }

    /// @notice Using only the supported entry points, no ether is ever left unreachable.
    function invariant_noEtherIsStranded() public view {
        assertEq(handler.ghostStranded(), 0, "ether was stranded without any force-feeding");
    }
}

/**
 * @notice The same invariants once ether has been force-fed into a card by `selfdestruct`, a
 *         block reward or a beacon-chain withdrawal — paths `receive()` cannot intercept.
 * @dev Runs with `fail-on-revert = true` as well, which is the point: an outsider pushing ether
 *      into a card must not make any entry point revert, let alone brick it. Together with
 *      `invariant_cardIsAlwaysDrainable`, this is the regression test for the strict
 *      `balance == address(this).balance` check that one wei used to defeat permanently.
 *      The surplus itself stays unreachable, and `invariant_donationsAreNeverPaidOut` holds it
 *      to that.
 */
contract GiftCardForceFedInvariantTest is GiftCardInvariantBase {
    function setUp() public {
        _setUpHandler();
    }

    /// @notice Force-fed ether is only ever a surplus; it can never make a card insolvent.
    function invariant_donationsOnlyAddSurplus() public view {
        GiftCard card = _card();
        // Phrased as an addition so an insolvent card reports the mismatch instead of
        // underflowing into an opaque arithmetic panic.
        assertEq(
            address(card).balance,
            card.balance() + handler.ghostDonatedToCurrentCard(),
            "surplus does not match the ether force-fed into this card"
        );
    }

    /// @notice Force-fed ether never becomes spendable: it can only ever end up stranded.
    function invariant_donationsAreNeverPaidOut() public view {
        assertLe(
            handler.ghostDonated(),
            handler.ghostStranded() + handler.ghostDonatedToCurrentCard(),
            "force-fed ether was paid out"
        );
    }
}
