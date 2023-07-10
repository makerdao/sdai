# Savings DAI

A tokenized wrapper around the DSR. Supports ERC4626. Share to asset conversions are real-time even if the pot hasn't been dripped in a while.

## Deployments

Commit `665879762f8b5df5d234463f45d1d6a49bd4fbeb` (no referral):

- [Mainnet](https://etherscan.io/address/0x83f20f44975d03b1b09e64809b757c47f942beea)
- [Goerli](https://goerli.etherscan.io/address/0xd8134205b0328f5676aaefb3b2a0dc15f4029d8c)

## Referral Code

The `deposit` and `mint` functions accept an optional `uint16 referral` parameter that frontends can use to mark deposits as originating from them. Such deposits emit a `Referral(uint16 indexed referral, address indexed owner, uint256 assets, uint256 shares)` event. This could be used to implement a revshare campaign, in which case the off-chain calculation scheme will likely need to keep track of any `Transfer` and `Withdraw` events following a `Referral` for a given token owner.

## Copyright

This code was created by hexonaut.
Since it should belong to the MakerDAO community the Copyright for the code has been transferred to Dai Foundation
