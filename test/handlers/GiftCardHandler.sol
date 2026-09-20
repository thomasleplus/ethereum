// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.30;

import {CommonBase} from "forge-std/Base.sol";
import {StdCheats} from "forge-std/StdCheats.sol";
import {StdUtils} from "forge-std/StdUtils.sol";

import {GiftCard} from "../../samples/contracts/GiftCard.sol";

/**
 * @title Gift Card invariant handler
 * @notice Drives gift cards through bounded, randomised call sequences on behalf of every
 *         actor the contract can distinguish: the giver, the receiver and strangers.
 * @dev The fuzzer targets this contract rather than a card, so every call reaches the card with
 *      a plausible `msg.sender` and in-range arguments, and calls that could not possibly
 *      succeed are never issued. That lets the suites run with `fail-on-revert = true`, so an
 *      unexpected revert is a finding rather than a silently discarded sequence.
 *
 *      A gift card is single-use: three of its six entry points empty it in one call, and it has
 *      no top-up path. Driving a single card would therefore spend almost every call on an empty
 *      contract. Instead the handler retires a card as soon as it is drained and rolls a fresh
 *      one, so sequences stay deep and the ghost variables accumulate across cards.
 * @author Thomas Leplus
 */
contract GiftCardHandler is CommonBase, StdCheats, StdUtils {
    /// @dev Ether each card is funded with on creation.
    uint256 public constant DEPOSIT = 10 ether;

    address public immutable giver;
    address public immutable receiver;

    /// @dev The card currently under test. Replaced once drained or bricked.
    GiftCard public card;

    /// @dev Cards retired so far.
    uint256 public ghostCardsIssued;
    /// @dev Ether put into cards on creation, across every card.
    uint256 public ghostDeposited;
    /// @dev Ether that left a card towards the receiver or a payee of its choosing.
    uint256 public ghostPaidOut;
    /// @dev Ether that left a card back towards the giver.
    uint256 public ghostRefunded;
    /// @dev Ether pushed into a card without going through a normal entry point.
    uint256 public ghostDonated;
    /// @dev Force-fed ether sitting in the current card, reset whenever a card is retired.
    uint256 public ghostDonatedToCurrentCard;
    /// @dev Ether left behind in retired cards, i.e. ether nobody can ever reach again.
    uint256 public ghostStranded;
    /// @dev Number of times a non-principal moved funds. Must stay at zero.
    uint256 public ghostUnauthorizedSuccesses;
    /// @dev Number of times a plain ether transfer was accepted. Must stay at zero.
    uint256 public ghostDirectTransferSuccesses;

    /// @dev Call distribution, reported by `afterInvariant()` so coverage gaps stay visible.
    mapping(bytes32 action => uint256 count) public callCount;

    /// @dev Payees `spend` is allowed to target: plain EOAs that always accept ether.
    address[] internal payees;

    constructor(address giver_, address receiver_) {
        giver = giver_;
        receiver = receiver_;

        payees.push(makeAddr("payee.alice"));
        payees.push(makeAddr("payee.bob"));
        payees.push(makeAddr("payee.carol"));

        _issueCard();
    }

    /**
     * @notice Retires the current card once it is spent, then issues a replacement.
     * @dev A spent card still holds any ether that was force-fed into it: `balance` is zero, so
     *      no entry point will pay it out. That ether is stranded forever, which the conservation
     *      invariant tracks explicitly rather than ignoring. Force-feeding alone does *not* retire
     *      a card — since the solvency fix in `validBalance` a card with a surplus keeps working,
     *      which is what `invariant_cardIsAlwaysDrainable` checks on every single call.
     */
    function _ensureLiveCard() internal {
        if (card.balance() != 0) return;

        ghostStranded += address(card).balance;
        _issueCard();
    }

    function _issueCard() internal {
        vm.deal(address(this), address(this).balance + DEPOSIT);
        vm.deal(giver, DEPOSIT);

        vm.prank(giver);
        card = new GiftCard{value: DEPOSIT}(receiver);

        ghostDeposited += DEPOSIT;
        ghostDonatedToCurrentCard = 0;
        ghostCardsIssued += 1;
    }

    function _payee(uint256 seed) internal view returns (address) {
        return payees[bound(seed, 0, payees.length - 1)];
    }

    // -------------------------------------------------------------------------
    // Receiver actions
    // -------------------------------------------------------------------------

    function spend(uint256 amountSeed, uint256 payeeSeed) external {
        _ensureLiveCard();
        uint256 amount = bound(amountSeed, 1, card.balance());

        vm.prank(receiver);
        card.spend(_payee(payeeSeed), amount);

        ghostPaidOut += amount;
        callCount["spend"] += 1;
    }

    function spendAll(uint256 payeeSeed) external {
        _ensureLiveCard();
        uint256 amount = card.balance();

        vm.prank(receiver);
        card.spendAll(_payee(payeeSeed));

        ghostPaidOut += amount;
        callCount["spendAll"] += 1;
    }

    function withdraw(uint256 amountSeed) external {
        _ensureLiveCard();
        uint256 amount = bound(amountSeed, 1, card.balance());

        vm.prank(receiver);
        card.withdraw(amount);

        ghostPaidOut += amount;
        callCount["withdraw"] += 1;
    }

    function withdrawAll() external {
        _ensureLiveCard();
        uint256 amount = card.balance();

        vm.prank(receiver);
        card.withdrawAll();

        ghostPaidOut += amount;
        callCount["withdrawAll"] += 1;
    }

    // -------------------------------------------------------------------------
    // Giver actions
    // -------------------------------------------------------------------------

    function refund(uint256 amountSeed) external {
        _ensureLiveCard();
        uint256 amount = bound(amountSeed, 1, card.balance());

        vm.prank(giver);
        card.refund(amount);

        ghostRefunded += amount;
        callCount["refund"] += 1;
    }

    function refundAll() external {
        _ensureLiveCard();
        uint256 amount = card.balance();

        vm.prank(giver);
        card.refundAll();

        ghostRefunded += amount;
        callCount["refundAll"] += 1;
    }

    // -------------------------------------------------------------------------
    // Hostile actions
    // -------------------------------------------------------------------------

    /**
     * @notice A random stranger tries a random entry point. Every attempt must be rejected.
     * @dev Uses a low-level call so a (correct) revert does not abort the fuzz sequence; the
     *      outcome is recorded in a ghost counter that `invariant_onlyPrincipalsMoveFunds`
     *      asserts on.
     */
    function strangerCalls(uint256 senderSeed, uint256 selectorSeed, uint256 amountSeed) external {
        _ensureLiveCard();

        address stranger = address(uint160(bound(senderSeed, 1, type(uint160).max)));
        if (stranger == giver || stranger == receiver) return;

        uint256 amount = bound(amountSeed, 0, DEPOSIT);

        bytes memory payload;
        uint256 choice = bound(selectorSeed, 0, 5);
        if (choice == 0) {
            payload = abi.encodeCall(GiftCard.spend, (stranger, amount));
        } else if (choice == 1) {
            payload = abi.encodeCall(GiftCard.spendAll, (stranger));
        } else if (choice == 2) {
            payload = abi.encodeCall(GiftCard.withdraw, (amount));
        } else if (choice == 3) {
            payload = abi.encodeCall(GiftCard.withdrawAll, ());
        } else if (choice == 4) {
            payload = abi.encodeCall(GiftCard.refund, (amount));
        } else {
            payload = abi.encodeCall(GiftCard.refundAll, ());
        }

        vm.prank(stranger);
        //slither-disable-next-line low-level-calls
        (bool accepted,) = address(card).call(payload);
        if (accepted) ghostUnauthorizedSuccesses += 1;

        callCount["strangerCalls"] += 1;
    }

    /// @notice Someone tries to top a card up with a plain transfer. `receive()` must refuse.
    function directTransfer(uint256 amountSeed) external {
        _ensureLiveCard();

        uint256 amount = bound(amountSeed, 1, 10 ether);
        vm.deal(address(this), address(this).balance + amount);

        //slither-disable-next-line low-level-calls
        (bool accepted,) = address(card).call{value: amount}("");
        if (accepted) ghostDirectTransferSuccesses += 1;

        callCount["directTransfer"] += 1;
    }

    /**
     * @notice Force-feeds ether into the card, bypassing `receive()`.
     * @dev Models `selfdestruct`, a block reward or a beacon-chain withdrawal paid to the card.
     *      `vm.deal` is used rather than a real `selfdestruct` so the handler does not depend on
     *      the configured EVM version; `GiftCardSecurityTest` exercises the real vector.
     *      Only the force-fed suite targets this selector, so the other suite can additionally
     *      assert that no ether is ever stranded when the card is used as intended.
     */
    function donate(uint256 amountSeed) external {
        _ensureLiveCard();

        uint256 amount = bound(amountSeed, 1, 1 ether);
        vm.deal(address(card), address(card).balance + amount);

        ghostDonated += amount;
        ghostDonatedToCurrentCard += amount;
        callCount["donate"] += 1;
    }
}
