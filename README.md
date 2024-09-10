# Savings USDS

A tokenized implementation of a savings rate for USDS. Supports ERC4626. Share to asset conversions are real-time even if `drip` hasn't been called in a while.

The contract uses the ERC-1822 UUPS pattern for upgradeability and the ERC-1967 proxy storage slots standard.
It is important that the `SUsdsDeploy` library sequence be used for deploying.

#### OZ upgradeability validations

The OZ validations can be run alongside the existing tests:  
`VALIDATE=true forge test --ffi --build-info --extra-output storageLayout`

## Referral Code

The `deposit` and `mint` functions accept an optional `uint16 referral` parameter that frontends can use to mark deposits as originating from them. Such deposits emit a `Referral(uint16 indexed referral, address indexed owner, uint256 assets, uint256 shares)` event. This could be used to implement a revshare campaign, in which case the off-chain calculation scheme will likely need to keep track of any `Transfer` and `Withdraw` events following a `Referral` for a given token owner.

## Shutdown

The implementation assumes Maker emergency shutdown can not be triggered. Any system shutdown should be orchestrated by Maker governance.

## Copyright

The original code was created by hexonaut (SavingsDai) and the MakerDAO devs (Pot).
Since it should belong to the MakerDAO community the Copyright for the code has been transferred to Dai Foundation

## L2 deployment

For L2s the token implementation is of a standard upgradeable token and does not have staking logic. It is based on the USDS code.
