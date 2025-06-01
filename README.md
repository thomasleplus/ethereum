# Ethereum

[![Solc](https://github.com/thomasleplus/ristretto/workflows/Solc/badge.svg)](https://github.com/thomasleplus/ristretto/actions?query=workflow:"Solc")

Musings with Ethereum smart contracts.

> [!WARNING]
> The code in this repo was written for educational purposes only. It
> is not fit for any purpose and if you choose to use it in any way,
> you are doing so at your own risk and sole responsibility.

## [Gift Card](samples/contracts/GiftCard.sol)

A simple contract emulating a gift card. The properties of the gift
card are different from those of a typical physical gift card:
- The gift card is registered: the receiver of the gift card is set by
  the giver once and for all and cannot be changed (whereas physical
  gift cards are typically considered owned by whomever is the bearer
  at any given moment, like cash).
- The gift card can be rescinded partially or in full by the giver:
  both the receiver and the giver can withdraw money from the contract
  at any time (up to the card's current balance of course).

The above properties made for a more interesting coding exercise but
are unlikely to be the desired behavior for a practical gift card use
case (especially the fact that the giver can withdraw from the card
after it has been given). So please do not use this contract unless
you fully understand how it works and are sure that it fits your
purpose.
