# Savings DAI

A tokenized wrapper around the DSR. Supports ERC4626. Share to asset conversions are real-time even if the pot hasn't been dripped in a while. Please note this is sample code only and there is no official deploys. Feel free to deploy it yourself.

## Referral Code

The `deposit` and `mint` functions accept an optional `uint16 referral` parameter that frontends can use to mark deposits as originating from them. Such deposits emit a `Referral(uint16 indexed referral, address indexed owner, uint256 assets, uint256 shares)` event. This could be used to implement a revshare campaign, in which case the off-chain calculation scheme will likely need to keep track of any `Transfer` and `Withdraw` events following a `Referral` for a given token owner.

## Copyright

This code was created by hexonaut.
Since it should belong to the MakerDAO community the Copyright for the code has been transferred to Dai Foundation
