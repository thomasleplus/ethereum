# Contracts

Example Ethereum smart contracts, for **educational use only** (see the
warning in the [root readme](../../README.md)).

- [GiftCard.sol](GiftCard.sol) — a sample gift-card contract in Solidity.

The Solidity sources are compiled in CI by the `Solc` workflow.

## GiftCard.sol

A gift card holding Ether. One card is one contract: the giver deploys
it with some Ether and names the receiver, and both of those are fixed
for the life of the card. The card has no top-up path — it is funded
once, at construction, and drained from there.

See the [root readme](../../README.md#gift-card) for why the giver can
also take the money back, and why that makes this a coding exercise
rather than a gift card you would actually use.

### Actors

| Actor | Stored as | Can |
| --- | --- | --- |
| Giver | `address public immutable from` | Refund part or all of the balance to itself |
| Receiver | `address public immutable to` | Withdraw to itself, or pay any address it chooses |
| Anyone else | — | Read the views. Nothing else. |

Both principals are `immutable`: they are written into the deployed
bytecode at construction and there is no code path that can change
them, so there is no ownership transfer, no admin role and no upgrade
hook to abuse.

### Entry points

Every state-changing function carries an explicit modifier chain. The
chain *is* the security model, so it is worth reading as a table:

| Function | Caller | Modifiers |
| --- | --- | --- |
| `spend(address recipient, uint256 amount)` | receiver | `onlyRecipient` `validRecipient` `validBalance` `validAmount` `nonReentrant` |
| `spendAll(address recipient)` | receiver | `onlyRecipient` `validRecipient` `validBalance` `nonReentrant` |
| `withdraw(uint256 amount)` | receiver | `onlyRecipient` `validBalance` `validAmount` `nonReentrant` |
| `withdrawAll()` | receiver | `onlyRecipient` `validBalance` `nonReentrant` |
| `refund(uint256 amount)` | giver | `onlyOriginalSender` `validBalance` `validAmount` `nonReentrant` |
| `refundAll()` | giver | `onlyOriginalSender` `validBalance` `nonReentrant` |
| `getContractBalance()` | anyone | `view` |
| `isBalanceConsistent()` | anyone | `view` |

`constructor(address recipient) payable` is guarded by
`validRecipient` and rejects a zero `msg.value`: a card cannot be
created empty or pointed at the zero address.

## Security and correctness features

### Access control

`onlyRecipient` and `onlyOriginalSender` compare `msg.sender` against
the two immutables. Every one of the six state-changing functions
carries exactly one of them, so there is no unguarded path that moves
Ether. `spend` and `spendAll` let the receiver choose *where* the money
goes, but only the receiver can trigger them.

### Input validation

- `validRecipient` rejects `address(0)`, so Ether cannot be burned by
  a typo — in the constructor and on both `spend` paths.
- `validAmount` rejects zero (a no-op that would still emit an event)
  and rejects anything above `balance`.
- `validBalance` rejects operating on an empty card.

### Reentrancy protection

`nonReentrant` is a contract-wide guard, not a per-function one, so it
blocks *cross-function* reentrancy: a callee that re-enters
`refundAll()` from inside the external call made by `withdraw()` hits
the same flag and reverts with `ReentrancyGuardActive()`.

The guard is backed by transient storage (EIP-1153):

```solidity
bool private transient locked;
```

A reentrancy flag only needs to live for the length of one
transaction, which is exactly what transient storage is for. It costs
~100 gas per access instead of a cold storage slot, it is cleared
automatically at the end of the transaction so no "stuck guard" state
can ever be persisted, and it keeps `balance` alone in the contract's
only storage slot. This requires an EVM at Cancun or later — see
[Requirements](#requirements).

### Checks-Effects-Interactions

Every function zeroes or decrements `balance` *before* calling out:

```solidity
uint256 amountToWithdraw = balance;
balance = 0;
_safeTransfer(msg.sender, amountToWithdraw);
```

So even without the reentrancy guard, a re-entrant call would find a
card that already reports what it owes correctly. The guard is defence
in depth on top of the ordering, not a substitute for it.

### Safe Ether transfer

`_safeTransfer` uses `call` rather than `transfer`/`send` — it does not
impose the 2300-gas stipend, which has broken contracts across gas
repricings — and checks the returned success flag, reverting with
`TransferFailed()` rather than silently continuing. It also
pre-checks `address(this).balance` and reverts with
`ContractHasInsufficientEther()` if the contract somehow cannot cover
the payment.

### Solvency, not strict equality

`validBalance` asks whether the contract can cover what it owes:

```solidity
if (address(this).balance < balance) revert InvalidBalance();
```

It deliberately does **not** demand
`balance == address(this).balance`. `receive()` rejects plain
transfers, but Ether can still be pushed into any address via
`selfdestruct`, a block reward, or a beacon-chain withdrawal — none of
which execute the recipient's code. Under a strict equality check,
anyone could send the card **one wei** and permanently brick all six
entry points: the money would be locked forever and neither the giver
nor the receiver could recover it. That is a denial-of-service bug, and
this repo's invariant suite was what surfaced it.

With the solvency check, force-fed Ether is a harmless surplus. The
card keeps working on `balance` as usual; the surplus is simply
unreachable and is never paid out. `isBalanceConsistent()` still
reports the strict equality, so the surplus is *observable* — it just
has no effect on the card.

### Rejecting stray Ether and unknown calls

`receive()` reverts on plain transfers ("Direct transfers not
allowed") and `fallback()` reverts on calls to functions that do not
exist ("Function does not exist"), rather than accepting them
silently. A card is funded at construction and nowhere else.

### Custom errors

All failure modes use custom errors (`OnlyRecipientCanSpend`,
`OnlyOriginalSenderCanRefund`, `InsufficientBalance`, `InvalidAmount`,
`InvalidBalance`, `InvalidRecipient`, `TransferFailed`,
`ReentrancyGuardActive`, `ContractHasInsufficientEther`) instead of
revert strings. They are cheaper and, more usefully here, they let
tests assert on the exact reason a call was rejected rather than on
"it reverted".

### Events

`GiftCardCreated`, `AmountSpent` and `AmountRefunded` are emitted after
the state change on every path that moves Ether, with the addresses
indexed for filtering.

## Storage layout and gas

The contract uses exactly **one** storage slot:

| Slot | Variable | Notes |
| --- | --- | --- |
| 0 | `uint256 public balance` | The only persistent state |
| — | `address public immutable from` | In bytecode, not storage |
| — | `address public immutable to` | In bytecode, not storage |
| — | `bool private transient locked` | Transient storage (EIP-1153) |

Two `address` values plus a `bool` would normally pack into one further
slot; making the addresses `immutable` and the guard `transient`
removes that slot altogether, along with its cold-access cost.

Moving the guard from storage to transient storage measures as
follows, via `forge test --gas-report` (averages, including the 21,000
gas intrinsic transaction cost and capped EIP-3529 refunds, which is
why the relative savings differ per function):

| Function | Storage guard | Transient guard | Change |
| --- | --- | --- | --- |
| `withdrawAll` | 46,452 | 31,364 | −32% |
| `refundAll` | 46,418 | 31,322 | −33% |
| `withdraw` | 47,128 | 37,009 | −21% |
| `spend` | 69,438 | 64,897 | −7% |

## Testing

35 tests across four suites. Run them with:

```sh
forge install foundry-rs/forge-std
forge test -vvv
```

| Suite | File | Tests |
| --- | --- | --- |
| Unit | [`test/GiftCard.t.sol`](../../test/GiftCard.t.sol) | 12 |
| Security | [`test/GiftCard.security.t.sol`](../../test/GiftCard.security.t.sol) | 6 |
| Invariants | [`test/GiftCard.invariants.t.sol`](../../test/GiftCard.invariants.t.sol) | 9 |
| Invariants, force-fed | [`test/GiftCard.invariants.t.sol`](../../test/GiftCard.invariants.t.sol) | 8 |

### Unit tests

Happy paths and the obvious rejections: constructor state and its two
rejections, withdraw, withdrawAll, spend to a chosen address,
overspending, refund access control, refundAll, direct transfers, and
balance consistency.

### Security tests

Targeted adversarial scenarios, each with a purpose-built attacker
contract:

- `testReentrantWithdrawIsBlocked` — a malicious receiver re-enters
  `withdraw` from its `receive()`.
- `testCrossFunctionReentrancyIsBlocked` — it re-enters a *different*
  entry point, proving the guard is contract-wide.
- `testReentrancyIsRejectedByTheGuardItself` — asserts the revert data
  is exactly `ReentrancyGuardActive()`, so the test cannot pass because
  the call failed for some unrelated reason.
- `testGuardUsesNoStorageSlot` — reads slot 0 during the callback and
  asserts the guard never touches persistent storage.
- `testForceFedEtherDoesNotBrickTheCard` — a real `selfdestruct`
  force-feed, after which the card must still be fully drainable.
- `testForceFedEtherIsNeverPaidOut` — the surplus stays unreachable.

### Stateful invariant suites

Unit tests assert what happens along known paths. The invariant suites
assert what must remain true after *any* path: Foundry assembles
random sequences of calls from random actors and re-checks every
invariant after each one. Configured in
[`foundry.toml`](../../foundry.toml) at **128 runs × 128 depth** with
`fail_on_revert = true` — the handler only ever issues calls that
should succeed, so an unexpected revert is a finding rather than a
silently discarded sequence. CI can turn the campaign up via
`FOUNDRY_INVARIANT_RUNS` without editing the suites.

Calls are driven through
[`test/handlers/GiftCardHandler.sol`](../../test/handlers/GiftCardHandler.sol),
which acts for the giver, the receiver, strangers and force-feeders,
and tracks ghost variables for everything deposited, paid out,
refunded, donated and stranded. Because a card is single-use — three
of its six entry points empty it in one call — the handler retires a
drained card and rolls a fresh one, so sequences stay deep instead of
spending ~98% of their calls on an empty contract.

Holding under every scenario:

| Invariant | Property |
| --- | --- |
| `invariant_cardIsSolvent` | A card never owes more than it holds |
| `invariant_etherIsConserved` | Every wei is still in a card, paid out, refunded, or stranded in a retired card |
| `invariant_payoutsNeverExceedDeposits` | A card only pays out Ether that was deposited into it |
| `invariant_cardIsAlwaysDrainable` | A funded card can *always* be emptied by its receiver |
| `invariant_onlyPrincipalsMoveFunds` | No stranger ever moved funds; no plain transfer was accepted |
| `invariant_principalsAreImmutable` | Giver and receiver never change |

`invariant_cardIsAlwaysDrainable` is the strongest of these. Rather
than re-implementing the contract's preconditions and asserting they
hold — which would drift from the contract over time — it takes a
state snapshot, actually drains the card, asserts the receiver was paid
exactly what was owed, and rolls back. It fails on every bricking bug
at once: a stuck reentrancy guard, a botched access check, or the
strict-equality balance check that one wei used to defeat.

Additionally, when nothing is force-fed:

| Invariant | Property |
| --- | --- |
| `invariant_accountingIsExact` | `balance` matches the real Ether held, exactly |
| `invariant_balanceNeverGrows` | No top-up path exists |
| `invariant_noEtherIsStranded` | Normal use never leaves Ether unreachable |

And under force-feeding:

| Invariant | Property |
| --- | --- |
| `invariant_donationsOnlyAddSurplus` | Force-fed Ether can never make a card insolvent |
| `invariant_donationsAreNeverPaidOut` | Force-fed Ether never becomes spendable |

### Mutation testing

A test suite that has never failed is not evidence of anything, so
each safeguard was verified by deliberately breaking the contract and
confirming the suites catch it:

| Mutation | Result |
| --- | --- |
| `balance -= amount / 2` in `withdraw` | 44 failures in the new suites; the unit tests caught it only via one hardcoded assertion (11/12 passed) |
| `nonReentrant` removed from `withdraw` | The 3 reentrancy tests fail — but **all 12 unit tests still passed**, i.e. the bug was invisible to them |
| Strict `balance == address(this).balance` restored | The force-fed suite fails 8/8 plus 2 security tests, while the other suites correctly still pass |

The middle row is the point of the exercise: a reentrancy hole is
exactly the kind of bug that traditional unit tests cannot see,
because it lives in a call sequence they never make.

### Static analysis

[Slither](https://github.com/crytic/slither) reports 0 findings across
its 102 detectors. The two `slither-disable-next-line` comments in the
source are for the deliberate low-level `call` in `_safeTransfer` and
the deliberate strict equality in `isBalanceConsistent()`.

### CI

| Workflow | Does |
| --- | --- |
| `Foundry` | Installs Foundry and forge-std, runs `forge test` |
| `Solc` | Compiles every `.sol` with `solc` 0.8.30 and runs Slither |

## Requirements

- Solidity **0.8.30** (pinned, not a `^` range).
- An EVM at **Cancun or later**, for the transient-storage reentrancy
  guard. `foundry.toml` sets `evm_version = "prague"`, which is solc
  0.8.30's own default, so `forge` and the bare `solc` CI job agree.

## Known limitations

Beyond the repo-wide warning that none of this is fit for production
use:

- **The giver can rescind the gift at any time.** Deliberate, and
  discussed in the [root readme](../../README.md#gift-card), but it is
  not how a gift card should behave.
- **Force-fed Ether is unreachable.** The contract does not brick, but
  there is no sweep function, so a surplus is stuck forever. Adding
  one would mean deciding who owns it, which this sample does not try
  to answer.
- **A card is single-use.** There is no way to top it up after
  construction.
- **`spend` to a contract that rejects Ether reverts** with
  `TransferFailed()`. The receiver simply picks another payee, but
  there is no pull-payment fallback.
- **`_safeTransfer` forwards all remaining gas** to the payee. That is
  what makes the reentrancy guard load-bearing rather than
  theoretical.
- **`GiftCardDestroyed` is declared but never emitted.** The contract
  has no destruction path; the event is dead code left over from an
  earlier design.
