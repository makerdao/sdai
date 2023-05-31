// SPDX-License-Identifier: AGPL-3.0-or-later

// Copyright (C) 2021-2022 Dai Foundation
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU Affero General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.
//
// This program is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
// GNU Affero General Public License for more details.
//
// You should have received a copy of the GNU Affero General Public License
// along with this program.  If not, see <https://www.gnu.org/licenses/>.

pragma solidity ^0.8.17;

import "dss-test/DssTest.sol";
import "dss-interfaces/Interfaces.sol";

import { SavingsDai, IERC1271 } from "../SavingsDai.sol";

contract MockMultisig is IERC1271 {
    address public signer1;
    address public signer2;

    constructor(address signer1_, address signer2_) {
        signer1 = signer1_;
        signer2 = signer2_;
    }

    function isValidSignature(bytes32 digest, bytes memory signature) external view returns (bytes4 sig) {
        bytes32 r;
        bytes32 s;
        uint8 v;
        assembly {
            r := mload(add(signature, 0x20))
            s := mload(add(signature, 0x40))
            v := byte(0, mload(add(signature, 0x60)))
        }
        if (signer1 == ecrecover(digest, v, r, s)) {
            assembly {
                r := mload(add(signature, 0x80))
                s := mload(add(signature, 0xA0))
                v := byte(0, mload(add(signature, 0xC0)))
            }
            if (signer2 == ecrecover(digest, v, r, s)) {
                sig = IERC1271.isValidSignature.selector;
            }
        }
    }
}

contract SavingsDaiIntegrationTest is DssTest {

    using GodMode for *;

    VatAbstract vat;
    DaiJoinAbstract daiJoin;
    DaiAbstract dai;
    PotAbstract pot;

    SavingsDai token;

    event Transfer(address indexed from, address indexed to, uint256 amount);
    event Approval(address indexed owner, address indexed spender, uint256 amount);
    event Deposit(address indexed sender, address indexed owner, uint256 assets, uint256 shares);
    event Withdraw(address indexed sender, address indexed receiver, address indexed owner, uint256 assets, uint256 shares);
    event Referral(uint16 indexed referral, address indexed owner, uint256 assets, uint256 shares);

    bytes32 constant PERMIT_TYPEHASH =
        keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)");

    function setUp() public {
        ChainlogAbstract chainlog = ChainlogAbstract(0xdA0Ab1e0017DEbCd72Be8599041a2aa3bA7e740F);
        
        vat = VatAbstract(chainlog.getAddress("MCD_VAT"));
        dai = DaiAbstract(chainlog.getAddress("MCD_DAI"));
        daiJoin = DaiJoinAbstract(chainlog.getAddress("MCD_JOIN_DAI"));
        pot = PotAbstract(chainlog.getAddress("MCD_POT"));

        token = new SavingsDai(
            address(daiJoin),
            address(pot)
        );
        
        dai.setBalance(address(this), 100 ether);
        dai.approve(address(token), type(uint256).max);
        pot.drip();
    }

    function _divup(uint256 x, uint256 y) internal pure returns (uint256 z) {
        unchecked {
            z = x != 0 ? ((x - 1) / y) + 1 : 0;
        }
    }

    function testConstructor() public {
        assertEq(token.name(), "Savings Dai");
        assertEq(token.symbol(), "sDAI");
        assertEq(token.version(), "1");
        assertEq(token.decimals(), 18);
        assertEq(address(token.vat()), address(vat));
        assertEq(address(token.daiJoin()), address(daiJoin));
        assertEq(address(token.dai()), address(dai));
        assertEq(address(token.pot()), address(pot));
        assertEq(address(token.asset()), address(dai));
    }

    function testConversion() public {
        assertGt(pot.dsr(), 0);

        uint256 pshares = token.convertToShares(1e18);
        uint256 passets = token.convertToAssets(pshares);

        // Converting back and forth should always round against
        assertLe(passets, 1e18);

        // Accrue some interest
        vm.warp(block.timestamp + 1 days);

        uint256 shares = token.convertToShares(1e18);

        // Shares should be less because more interest has accrued
        assertLt(shares, pshares);
    }

    function testDeposit() public {
        uint256 dsrDai = vat.dai(address(pot));

        uint256 pie = 1e18 * RAY / pot.chi();
        vm.expectEmit(true, true, true, true);
        emit Deposit(address(this), address(0xBEEF), 1e18, pie);
        token.deposit(1e18, address(0xBEEF));

        assertEq(token.totalSupply(), pie);
        assertLe(token.totalAssets(), 1e18);    // May be slightly less due to rounding error
        assertGe(token.totalAssets(), 1e18 - 1);
        assertEq(token.balanceOf(address(0xBEEF)), pie);
        assertEq(vat.dai(address(pot)), dsrDai + pie * pot.chi());
    }

    function testReferredDeposit() public {
        uint256 dsrDai = vat.dai(address(pot));

        uint256 pie = 1e18 * RAY / pot.chi();
        vm.expectEmit(true, true, true, true);
        emit Deposit(address(this), address(0xBEEF), 1e18, pie);
        vm.expectEmit(true, true, true, true);
        emit Referral(888, address(0xBEEF), 1e18, pie);
        token.deposit(1e18, address(0xBEEF), 888);

        assertEq(token.totalSupply(), pie);
        assertLe(token.totalAssets(), 1e18);    // May be slightly less due to rounding error
        assertGe(token.totalAssets(), 1e18 - 1);
        assertEq(token.balanceOf(address(0xBEEF)), pie);
        assertEq(vat.dai(address(pot)), dsrDai + pie * pot.chi());
    }

    function testDepositBadAddress() public {
        vm.expectRevert("SavingsDai/invalid-address");
        token.deposit(1e18, address(0));
        vm.expectRevert("SavingsDai/invalid-address");
        token.deposit(1e18, address(token));
    }

    function testMint() public {
        uint256 dsrDai = vat.dai(address(pot));

        uint256 pie = 1e18 * RAY / pot.chi();
        vm.expectEmit(true, true, true, true);
        emit Deposit(address(this), address(0xBEEF), _divup(pie * pot.chi(), RAY), pie);
        token.mint(pie, address(0xBEEF));

        assertEq(token.totalSupply(), pie);
        assertLe(token.totalAssets(), 1e18);    // May be slightly less due to rounding error
        assertGe(token.totalAssets(), 1e18 - 1);
        assertEq(token.balanceOf(address(0xBEEF)), pie);
        assertEq(vat.dai(address(pot)), dsrDai + pie * pot.chi());
    }

    function testReferredMint() public {
        uint256 dsrDai = vat.dai(address(pot));

        uint256 pie = 1e18 * RAY / pot.chi();
        vm.expectEmit(true, true, true, true);
        emit Deposit(address(this), address(0xBEEF), _divup(pie * pot.chi(), RAY), pie);
        vm.expectEmit(true, true, true, true);
        emit Referral(888, address(0xBEEF), 1e18, pie);
        token.mint(pie, address(0xBEEF), 888);

        assertEq(token.totalSupply(), pie);
        assertLe(token.totalAssets(), 1e18);    // May be slightly less due to rounding error
        assertGe(token.totalAssets(), 1e18 - 1);
        assertEq(token.balanceOf(address(0xBEEF)), pie);
        assertEq(vat.dai(address(pot)), dsrDai + pie * pot.chi());
    }

    function testMintBadAddress() public {
        vm.expectRevert("SavingsDai/invalid-address");
        token.mint(1e18, address(0));
        vm.expectRevert("SavingsDai/invalid-address");
        token.mint(1e18, address(token));
    }

    function testRedeem() public {
        uint256 dsrDai = vat.dai(address(pot));

        token.deposit(1e18, address(0xBEEF));
        uint256 pie = 1e18 * RAY / pot.chi();

        assertEq(vat.dai(address(pot)), dsrDai + pie * pot.chi());

        vm.expectEmit(true, true, true, true);
        emit Withdraw(address(0xBEEF), address(this), address(0xBEEF), (pie * 0.9e18 / WAD) * pot.chi() / RAY, pie * 0.9e18 / WAD);
        vm.prank(address(0xBEEF));
        token.redeem(pie * 0.9e18 / WAD, address(this), address(0xBEEF));

        assertEq(token.totalSupply(), pie - pie * 0.9e18 / WAD);
        assertEq(token.balanceOf(address(0xBEEF)), pie - pie * 0.9e18 / WAD);
        assertEq(vat.dai(address(pot)), dsrDai + pie * pot.chi() - (pie * 0.9e18 / WAD) * pot.chi());
    }

    function testWithdraw() public {
        uint256 dsrDai = vat.dai(address(pot));

        token.deposit(1e18, address(0xBEEF));
        uint256 pie = 1e18 * RAY / pot.chi();

        assertEq(vat.dai(address(pot)), dsrDai + pie * pot.chi());

        uint256 assets = (pie * 0.9e18 / WAD) * pot.chi() / RAY;
        uint256 shares = _divup(assets * RAY, pot.chi());
        vm.expectEmit(true, true, true, true);
        emit Withdraw(address(0xBEEF), address(this), address(0xBEEF), assets, shares);
        vm.prank(address(0xBEEF));
        token.withdraw(assets, address(this), address(0xBEEF));

        assertEq(token.totalSupply(), pie - shares);
        assertEq(token.balanceOf(address(0xBEEF)), pie - shares);
        assertEq(vat.dai(address(pot)), dsrDai + pie * pot.chi() - shares * pot.chi());
    }

    function testSharesEstimatesMatch() public {
        vm.warp(block.timestamp + 365 days);

        uint256 assets = 1e18;
        uint256 shares = token.convertToShares(assets);

        pot.drip();

        assertEq(token.convertToShares(assets), shares);
    }

    function testAssetsEstimatesMatch() public {
        vm.warp(block.timestamp + 365 days);

        uint256 shares = 1e18;
        uint256 assets = token.convertToAssets(shares);

        pot.drip();

        assertEq(token.convertToAssets(shares), assets);
    }

    function testApprove() public {
        vm.expectEmit(true, true, true, true);
        emit Approval(address(this), address(0xBEEF), 1e18);
        assertTrue(token.approve(address(0xBEEF), 1e18));

        assertEq(token.allowance(address(this), address(0xBEEF)), 1e18);
    }

    function testIncreaseAllowance() public {
        vm.expectEmit(true, true, true, true);
        emit Approval(address(this), address(0xBEEF), 1e18);
        assertTrue(token.increaseAllowance(address(0xBEEF), 1e18));

        assertEq(token.allowance(address(this), address(0xBEEF)), 1e18);
    }

    function testDecreaseAllowance() public {
        assertTrue(token.increaseAllowance(address(0xBEEF), 3e18));
        vm.expectEmit(true, true, true, true);
        emit Approval(address(this), address(0xBEEF), 2e18);
        assertTrue(token.decreaseAllowance(address(0xBEEF), 1e18));

        assertEq(token.allowance(address(this), address(0xBEEF)), 2e18);
    }

    function testDecreaseAllowanceInsufficientBalance() public {
        assertTrue(token.increaseAllowance(address(0xBEEF), 1e18));
        vm.expectRevert("SavingsDai/insufficient-allowance");
        token.decreaseAllowance(address(0xBEEF), 2e18);
    }

    function testTransfer() public {
        uint256 pie = 1e18 * RAY / pot.chi();
        token.deposit(1e18, address(this));

        vm.expectEmit(true, true, true, true);
        emit Transfer(address(this), address(0xBEEF), pie);
        assertTrue(token.transfer(address(0xBEEF), pie));
        assertEq(token.totalSupply(), pie);

        assertEq(token.balanceOf(address(this)), 0);
        assertEq(token.balanceOf(address(0xBEEF)), pie);
    }

    function testTransferBadAddress() public {
        uint256 pie = 1e18 * RAY / pot.chi();
        token.deposit(1e18, address(this));

        vm.expectRevert("SavingsDai/invalid-address");
        token.transfer(address(0), pie);
        vm.expectRevert("SavingsDai/invalid-address");
        token.transfer(address(token), pie);
    }

    function testTransferFrom() public {
        address from = address(0xABCD);

        uint256 pie = 1e18 * RAY / pot.chi();
        token.deposit(1e18, from);

        vm.prank(from);
        token.approve(address(this), pie);

        vm.expectEmit(true, true, true, true);
        emit Transfer(from, address(0xBEEF), pie);
        assertTrue(token.transferFrom(from, address(0xBEEF), pie));
        assertEq(token.totalSupply(), pie);

        assertEq(token.allowance(from, address(this)), 0);

        assertEq(token.balanceOf(from), 0);
        assertEq(token.balanceOf(address(0xBEEF)), pie);
    }

    function testTransferFromBadAddress() public {
        uint256 pie = 1e18 * RAY / pot.chi();
        token.deposit(1e18, address(this));
        
        vm.expectRevert("SavingsDai/invalid-address");
        token.transferFrom(address(this), address(0), pie);
        vm.expectRevert("SavingsDai/invalid-address");
        token.transferFrom(address(this), address(token), pie);
    }

    function testInfiniteApproveTransferFrom() public {
        address from = address(0xABCD);

        uint256 pie = 1e18 * RAY / pot.chi();
        token.deposit(1e18, from);

        vm.prank(from);
        vm.expectEmit(true, true, true, true);
        emit Approval(from, address(this), type(uint256).max);
        token.approve(address(this), type(uint256).max);

        vm.expectEmit(true, true, true, true);
        emit Transfer(from, address(0xBEEF), pie);
        assertTrue(token.transferFrom(from, address(0xBEEF), pie));
        assertEq(token.totalSupply(), pie);

        assertEq(token.allowance(from, address(this)), type(uint256).max);

        assertEq(token.balanceOf(from), 0);
        assertEq(token.balanceOf(address(0xBEEF)), pie);
    }

    function testPermit() public {
        uint256 privateKey = 0xBEEF;
        address owner = vm.addr(privateKey);

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(
            privateKey,
            keccak256(
                abi.encodePacked(
                    "\x19\x01",
                    token.DOMAIN_SEPARATOR(),
                    keccak256(abi.encode(PERMIT_TYPEHASH, owner, address(0xCAFE), 1e18, 0, block.timestamp))
                )
            )
        );

        vm.expectEmit(true, true, true, true);
        emit Approval(owner, address(0xCAFE), 1e18);
        token.permit(owner, address(0xCAFE), 1e18, block.timestamp, v, r, s);

        assertEq(token.allowance(owner, address(0xCAFE)), 1e18);
        assertEq(token.nonces(owner), 1);
    }

    function testPermitContract() public {
        uint256 privateKey1 = 0xBEEF;
        address signer1 = vm.addr(privateKey1);
        uint256 privateKey2 = 0xBEEE;
        address signer2 = vm.addr(privateKey2);

        address mockMultisig = address(new MockMultisig(signer1, signer2));

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(
            uint256(privateKey1),
            keccak256(
                abi.encodePacked(
                    "\x19\x01",
                    token.DOMAIN_SEPARATOR(),
                    keccak256(abi.encode(PERMIT_TYPEHASH, mockMultisig, address(0xCAFE), 1e18, 0, block.timestamp))
                )
            )
        );

        (uint8 v2, bytes32 r2, bytes32 s2) = vm.sign(
            uint256(privateKey2),
            keccak256(
                abi.encodePacked(
                    "\x19\x01",
                    token.DOMAIN_SEPARATOR(),
                    keccak256(abi.encode(PERMIT_TYPEHASH, mockMultisig, address(0xCAFE), 1e18, 0, block.timestamp))
                )
            )
        );

        bytes memory signature = abi.encode(r, s, bytes32(uint256(v) << 248), r2, s2, bytes32(uint256(v2) << 248));
        vm.expectEmit(true, true, true, true);
        emit Approval(mockMultisig, address(0xCAFE), 1e18);
        token.permit(mockMultisig, address(0xCAFE), 1e18, block.timestamp, signature);

        assertEq(token.allowance(mockMultisig, address(0xCAFE)), 1e18);
        assertEq(token.nonces(mockMultisig), 1);
    }

    function testPermitContractInvalidSignature() public {
        uint256 privateKey1 = 0xBEEF;
        address signer1 = vm.addr(privateKey1);
        uint256 privateKey2 = 0xBEEE;
        address signer2 = vm.addr(privateKey2);

        address mockMultisig = address(new MockMultisig(signer1, signer2));

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(
            uint256(privateKey1),
            keccak256(
                abi.encodePacked(
                    "\x19\x01",
                    token.DOMAIN_SEPARATOR(),
                    keccak256(abi.encode(PERMIT_TYPEHASH, mockMultisig, address(0xCAFE), 1e18, 0, block.timestamp))
                )
            )
        );

        (uint8 v2, bytes32 r2, bytes32 s2) = vm.sign(
            uint256(0xCEEE),
            keccak256(
                abi.encodePacked(
                    "\x19\x01",
                    token.DOMAIN_SEPARATOR(),
                    keccak256(abi.encode(PERMIT_TYPEHASH, mockMultisig, address(0xCAFE), 1e18, 0, block.timestamp))
                )
            )
        );

        bytes memory signature = abi.encode(r, s, bytes32(uint256(v) << 248), r2, s2, bytes32(uint256(v2) << 248));
        vm.expectRevert("SavingsDai/invalid-permit");
        token.permit(mockMultisig, address(0xCAFE), 1e18, block.timestamp, signature);
    }

    function testTransferInsufficientBalance() public {
        uint256 pie = 0.9e18 * RAY / pot.chi();
        token.deposit(0.9e18, address(this));
        vm.expectRevert("SavingsDai/insufficient-balance");
        token.transfer(address(0xBEEF), pie + 1);
    }

    function testTransferFromInsufficientAllowance() public {
        address from = address(0xABCD);

        uint256 pie = 1e18 * RAY / pot.chi();
        token.deposit(1e18, from);

        vm.prank(from);
        token.approve(address(0xBEEF), pie - 1);

        vm.expectRevert("SavingsDai/insufficient-allowance");
        token.transferFrom(from, address(0xBEEF), pie);
    }

    function testTransferFromInsufficientBalance() public {
        address from = address(0xABCD);

        uint256 pie = 0.9e18 * RAY / pot.chi();
        token.deposit(0.9e18, from);

        vm.prank(from);
        token.approve(address(this), pie + 1);

        vm.expectRevert("SavingsDai/insufficient-balance");
        token.transferFrom(from, address(0xBEEF), pie + 1);
    }

    function testPermitBadNonce() public {
        uint256 privateKey = 0xBEEF;
        address owner = vm.addr(privateKey);

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(
            privateKey,
            keccak256(
                abi.encodePacked(
                    "\x19\x01",
                    token.DOMAIN_SEPARATOR(),
                    keccak256(abi.encode(PERMIT_TYPEHASH, owner, address(0xCAFE), 1e18, 1, block.timestamp))
                )
            )
        );

        vm.expectRevert("SavingsDai/invalid-permit");
        token.permit(owner, address(0xCAFE), 1e18, block.timestamp, v, r, s);
    }

    function testPermitBadDeadline() public {
        uint256 privateKey = 0xBEEF;
        address owner = vm.addr(privateKey);

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(
            privateKey,
            keccak256(
                abi.encodePacked(
                    "\x19\x01",
                    token.DOMAIN_SEPARATOR(),
                    keccak256(abi.encode(PERMIT_TYPEHASH, owner, address(0xCAFE), 1e18, 0, block.timestamp))
                )
            )
        );

        vm.expectRevert("SavingsDai/invalid-permit");
        token.permit(owner, address(0xCAFE), 1e18, block.timestamp + 1, v, r, s);
    }

    function testPermitPastDeadline() public {
        uint256 privateKey = 0xBEEF;
        address owner = vm.addr(privateKey);
        uint256 deadline = block.timestamp;

        bytes32 domain_separator = token.DOMAIN_SEPARATOR();
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(
            privateKey,
            keccak256(
                abi.encodePacked(
                    "\x19\x01",
                    domain_separator,
                    keccak256(abi.encode(PERMIT_TYPEHASH, owner, address(0xCAFE), 1e18, 0, deadline))
                )
            )
        );

        vm.warp(deadline + 1);

        vm.expectRevert("SavingsDai/permit-expired");
        token.permit(owner, address(0xCAFE), 1e18, deadline, v, r, s);
    }

    function testPermitOwnerZero() public {
        vm.expectRevert("SavingsDai/invalid-owner");
        token.permit(address(0), address(0xCAFE), 1e18, block.timestamp, 28, bytes32(0), bytes32(0));
    }

    function testPermitReplay() public {
        uint256 privateKey = 0xBEEF;
        address owner = vm.addr(privateKey);

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(
            privateKey,
            keccak256(
                abi.encodePacked(
                    "\x19\x01",
                    token.DOMAIN_SEPARATOR(),
                    keccak256(abi.encode(PERMIT_TYPEHASH, owner, address(0xCAFE), 1e18, 0, block.timestamp))
                )
            )
        );

        token.permit(owner, address(0xCAFE), 1e18, block.timestamp, v, r, s);
        vm.expectRevert("SavingsDai/invalid-permit");
        token.permit(owner, address(0xCAFE), 1e18, block.timestamp, v, r, s);
    }

    function testDeposit(address to, uint256 amount, uint256 warp) public {
        amount %= 100 ether;
        vm.warp(block.timestamp + warp % 365 days);
        uint256 shares = token.previewDeposit(amount);
        if (to != address(0) && to != address(token)) {
            vm.expectEmit(true, true, true, true);
            emit Deposit(address(this), to, amount, shares);
        } else {
            vm.expectRevert("SavingsDai/invalid-address");
        }
        uint256 ashares = token.deposit(amount, to);

        if (to != address(0) && to != address(token)) {
            assertEq(ashares, shares);
            assertEq(token.totalSupply(), shares);
            assertEq(token.balanceOf(to), shares);
        }
    }

    function testMint(address to, uint256 shares, uint256 warp) public {
        shares %= 100 ether * RAY / pot.chi();
        vm.warp(block.timestamp + warp % 365 days);
        uint256 assets = token.previewMint(shares);
        if (to != address(0) && to != address(token)) {
            vm.expectEmit(true, true, true, true);
            emit Deposit(address(this), to, assets, shares);
        } else {
            vm.expectRevert("SavingsDai/invalid-address");
        }
        uint256 aassets = token.mint(shares, to);

        if (to != address(0) && to != address(token)) {
            assertEq(aassets, assets);
            assertEq(token.totalSupply(), shares);
            assertEq(token.balanceOf(to), shares);
        }
    }

    function testRedeem(
        address from,
        uint256 mintAmount,
        uint256 burnAmount,
        uint256 warp
    ) public {
        mintAmount %= 100 ether;
        burnAmount %= 100 ether;
        vm.warp(block.timestamp + warp % 365 days);
        if (from == address(0) || from == address(token)) return;

        uint256 initialFromBalance = dai.balanceOf(from);
        uint256 initialTestBalance = dai.balanceOf(TEST_ADDRESS);

        uint256 pie = token.convertToShares(mintAmount);
        burnAmount = bound(burnAmount, 0, pie);

        token.deposit(mintAmount, from);

        uint256 assets = token.previewRedeem(burnAmount);
        vm.expectEmit(true, true, true, true);
        emit Withdraw(address(from), TEST_ADDRESS, address(from), assets, burnAmount);
        vm.prank(from);
        uint256 aassets = token.redeem(burnAmount, TEST_ADDRESS, from);

        assertEq(aassets, assets);
        if (from != TEST_ADDRESS) assertEq(dai.balanceOf(from), initialFromBalance);
        assertEq(dai.balanceOf(TEST_ADDRESS), initialTestBalance + assets);
    }

    function testWithdraw(
        address from,
        uint256 mintAmount,
        uint256 burnAmount,
        uint256 warp
    ) public {
        mintAmount = mintAmount % 99 ether + 1 ether;
        burnAmount %= 100 ether;
        vm.warp(block.timestamp + warp % 365 days);
        if (from == address(0) || from == address(token)) return;

        uint256 initialFromBalance = dai.balanceOf(from);
        uint256 initialTestBalance = dai.balanceOf(TEST_ADDRESS);

        uint256 pie = token.convertToShares(mintAmount);
        burnAmount = bound(burnAmount, 0, mintAmount);

        token.deposit(mintAmount, from);

        uint256 shares = token.previewWithdraw(burnAmount);
        vm.expectEmit(true, true, true, true);
        emit Withdraw(address(from), TEST_ADDRESS, address(from), burnAmount, shares);
        vm.prank(from);
        uint256 ashares = token.withdraw(burnAmount, TEST_ADDRESS, from);

        assertEq(ashares, shares);
        if (from != TEST_ADDRESS) assertEq(dai.balanceOf(from), initialFromBalance);
        assertEq(dai.balanceOf(TEST_ADDRESS), initialTestBalance + burnAmount);
        assertEq(token.totalSupply(), pie - shares);
        assertEq(token.balanceOf(from), pie - shares);
    }

    function testApprove(address to, uint256 amount) public {
        vm.expectEmit(true, true, true, true);
        emit Approval(address(this), to, amount);
        assertTrue(token.approve(to, amount));

        assertEq(token.allowance(address(this), to), amount);
    }

    function testTransfer(address to, uint256 amount) public {
        amount %= 100 ether;
        if (to == address(0) || to == address(token)) return;

        uint256 pie = amount * RAY / pot.chi();
        token.deposit(amount, address(this));

        vm.expectEmit(true, true, true, true);
        emit Transfer(address(this), to, pie);
        assertTrue(token.transfer(to, pie));
        assertEq(token.totalSupply(), pie);

        if (address(this) == to) {
            assertEq(token.balanceOf(address(this)), pie);
        } else {
            assertEq(token.balanceOf(address(this)), 0);
            assertEq(token.balanceOf(to), pie);
        }
    }

    function testTransferFrom(
        address to,
        uint256 approval,
        uint256 amount
    ) public {
        approval %= 100 ether;
        amount %= 100 ether;
        if (to == address(0) || to == address(token)) return;

        amount = bound(amount, 0, approval);
        approval = approval * RAY / pot.chi();

        address from = address(0xABCD);

        uint256 pie = amount * RAY / pot.chi();
        token.deposit(amount, from);

        vm.prank(from);
        token.approve(address(this), approval);

        vm.expectEmit(true, true, true, true);
        emit Transfer(from, to, pie);
        assertTrue(token.transferFrom(from, to, pie));
        assertEq(token.totalSupply(), pie);

        uint256 app = from == address(this) || approval == type(uint256).max ? approval : approval - pie;
        assertEq(token.allowance(from, address(this)), app);

        if (from == to) {
            assertEq(token.balanceOf(from), pie);
        } else  {
            assertEq(token.balanceOf(from), 0);
            assertEq(token.balanceOf(to), pie);
        }
    }

    function testPermit(
        uint248 privKey,
        address to,
        uint256 amount,
        uint256 deadline
    ) public {
        uint256 privateKey = privKey;
        if (deadline < block.timestamp) deadline = block.timestamp;
        if (privateKey == 0) privateKey = 1;

        address owner = vm.addr(privateKey);

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(
            privateKey,
            keccak256(
                abi.encodePacked(
                    "\x19\x01",
                    token.DOMAIN_SEPARATOR(),
                    keccak256(abi.encode(PERMIT_TYPEHASH, owner, to, amount, 0, deadline))
                )
            )
        );

        vm.expectEmit(true, true, true, true);
        emit Approval(owner, to, amount);
        token.permit(owner, to, amount, deadline, v, r, s);

        assertEq(token.allowance(owner, to), amount);
        assertEq(token.nonces(owner), 1);
    }

    function testRedeemInsufficientBalance(
        address to,
        uint256 mintAmount,
        uint256 burnAmount
    ) public {
        mintAmount %= 100 ether;
        burnAmount %= 100 ether;
        if (to == address(0) || to == address(token)) return;

        uint256 pie = mintAmount * RAY / pot.chi();
        burnAmount = bound(burnAmount, pie + 1, type(uint256).max / pot.chi());

        token.deposit(mintAmount, to);
        vm.expectRevert("SavingsDai/insufficient-balance");
        token.redeem(burnAmount, to, to);
    }

    function testTransferInsufficientBalance(
        address to,
        uint256 mintAmount,
        uint256 sendAmount
    ) public {
        mintAmount %= 100 ether;
        sendAmount %= 100 ether;
        if (to == address(0) || to == address(token)) return;

        uint256 pie = mintAmount * RAY / pot.chi();
        sendAmount = bound(sendAmount, pie + 1, 100 ether);

        token.deposit(mintAmount, address(this));
        vm.expectRevert("SavingsDai/insufficient-balance");
        token.transfer(to, sendAmount);
    }

    function testTransferFromInsufficientAllowance(
        address to,
        uint256 approval,
        uint256 amount
    ) public {
        approval %= 100 ether;
        amount %= 100 ether;
        if (to == address(0) || to == address(token)) return;

        amount = bound(amount, approval + 1, 100 ether);
        approval = approval * RAY / pot.chi();

        address from = address(0xABCD);

        uint256 pie = amount * RAY / pot.chi();
        if (pie == 0) return;
        token.deposit(amount, from);

        vm.prank(from);
        token.approve(to, approval);

        vm.expectRevert("SavingsDai/insufficient-allowance");
        token.transferFrom(from, to, pie);
    }

    function testTransferFromInsufficientBalance(
        address to,
        uint256 mintAmount,
        uint256 sendAmount
    ) public {
        mintAmount %= 100 ether;
        sendAmount %= 100 ether;
        if (to == address(0) || to == address(token)) return;

        uint256 pie = mintAmount * RAY / pot.chi();
        sendAmount = bound(sendAmount, pie + 1, 100 ether);

        address from = address(0xABCD);

        token.deposit(mintAmount, from);

        vm.prank(from);
        token.approve(address(this), sendAmount);

        vm.expectRevert("SavingsDai/insufficient-balance");
        token.transferFrom(from, to, sendAmount);
    }

    function testPermitBadNonce(
        uint128 privateKey,
        address to,
        uint256 amount,
        uint256 deadline,
        uint256 nonce
    ) public {
        if (deadline < block.timestamp) deadline = block.timestamp;
        if (privateKey == 0) privateKey = 1;
        if (nonce == 0) nonce = 1;

        address owner = vm.addr(privateKey);

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(
            privateKey,
            keccak256(
                abi.encodePacked(
                    "\x19\x01",
                    token.DOMAIN_SEPARATOR(),
                    keccak256(abi.encode(PERMIT_TYPEHASH, owner, to, amount, nonce, deadline))
                )
            )
        );

        vm.expectRevert("SavingsDai/invalid-permit");
        token.permit(owner, to, amount, deadline, v, r, s);
    }

    function testPermitBadDeadline(
        uint128 privateKey,
        address to,
        uint256 amount,
        uint256 deadline
    ) public {
        if (deadline == type(uint256).max) deadline -= 1;
        if (deadline < block.timestamp) deadline = block.timestamp;
        if (privateKey == 0) privateKey = 1;

        address owner = vm.addr(privateKey);

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(
            privateKey,
            keccak256(
                abi.encodePacked(
                    "\x19\x01",
                    token.DOMAIN_SEPARATOR(),
                    keccak256(abi.encode(PERMIT_TYPEHASH, owner, to, amount, 0, deadline))
                )
            )
        );

        vm.expectRevert("SavingsDai/invalid-permit");
        token.permit(owner, to, amount, deadline + 1, v, r, s);
    }

    function testPermitPastDeadline(
        uint128 privateKey,
        address to,
        uint256 amount,
        uint256 deadline
    ) public {
        if (deadline == type(uint256).max) deadline -= 1;

        // private key cannot be 0 for secp256k1 pubkey generation
        if (privateKey == 0) privateKey = 1;

        address owner = vm.addr(privateKey);

        bytes32 domain_separator = token.DOMAIN_SEPARATOR();
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(
            privateKey,
            keccak256(
                abi.encodePacked(
                    "\x19\x01",
                    domain_separator,
                    keccak256(abi.encode(PERMIT_TYPEHASH, owner, to, amount, 0, deadline))
                )
            )
        );

        vm.warp(deadline + 1);

        vm.expectRevert("SavingsDai/permit-expired");
        token.permit(owner, to, amount, deadline, v, r, s);
    }

    function testPermitReplay(
        uint128 privateKey,
        address to,
        uint256 amount,
        uint256 deadline
    ) public {
        if (deadline < block.timestamp) deadline = block.timestamp;
        if (privateKey == 0) privateKey = 1;

        address owner = vm.addr(privateKey);

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(
            privateKey,
            keccak256(
                abi.encodePacked(
                    "\x19\x01",
                    token.DOMAIN_SEPARATOR(),
                    keccak256(abi.encode(PERMIT_TYPEHASH, owner, to, amount, 0, deadline))
                )
            )
        );

        token.permit(owner, to, amount, deadline, v, r, s);
        vm.expectRevert("SavingsDai/invalid-permit");
        token.permit(owner, to, amount, deadline, v, r, s);
    }
}
