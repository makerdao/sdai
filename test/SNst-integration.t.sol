// SPDX-License-Identifier: AGPL-3.0-or-later

// Copyright (C) 2021 Dai Foundation
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

pragma solidity ^0.8.21;

import "token-tests/TokenFuzzChecks.sol";
import "dss-interfaces/Interfaces.sol";
import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import { Upgrades, Options } from "openzeppelin-foundry-upgrades/Upgrades.sol";

import { NstMock } from "test/mocks/NstMock.sol";
import { NstJoinMock } from "test/mocks/NstJoinMock.sol";

import { SNst, UUPSUpgradeable, Initializable, ERC1967Utils } from "src/SNst.sol";

import { SNstInstance } from "deploy/SNstInstance.sol";
import { SNstDeploy } from "deploy/SNstDeploy.sol";
import { SNstInit, SNstConfig } from "deploy/SNstInit.sol";

contract SNst2 is UUPSUpgradeable {
    // Admin
    mapping (address => uint256) public wards;
    // ERC20
    uint256                                           public totalSupply;
    mapping (address => uint256)                      public balanceOf;
    mapping (address => mapping (address => uint256)) public allowance;
    mapping (address => uint256)                      public nonces;
    // Savings yield
    uint192 public chi;   // The Rate Accumulator  [ray]
    uint64  public rho;   // Time of last drip     [unix epoch time]
    uint256 public nsr;   // The NST Savings Rate  [ray]

    string  public constant version  = "2";

    event UpgradedTo(string version);

    modifier auth {
        require(wards[msg.sender] == 1, "SNst/not-authorized");
        _;
    }

    constructor() {
        _disableInitializers(); // Avoid initializing in the context of the implementation
    }

    function reinitialize() reinitializer(2) external {
        emit UpgradedTo(version);
    }

    function _authorizeUpgrade(address newImplementation) internal override auth {}

    function getImplementation() external view returns (address) {
        return ERC1967Utils.getImplementation();
    }
}

contract SNstIntegrationTest is TokenFuzzChecks {

    using GodMode for *;

    DssInstance dss;
    address pauseProxy;
    NstJoinMock nstJoin;
    NstMock nst;

    SNst token;
    bool validate;

    event Drip(uint256 chi, uint256 diff);
    event Deposit(address indexed sender, address indexed owner, uint256 assets, uint256 shares);
    event Withdraw(address indexed sender, address indexed receiver, address indexed owner, uint256 assets, uint256 shares);
    event Referral(uint16 indexed referral, address indexed owner, uint256 assets, uint256 shares);
    event UpgradedTo(string version);

    function setUp() public {
        vm.createSelectFork(vm.envString("ETH_RPC_URL"));
        validate = vm.envOr("VALIDATE", false);

        ChainlogAbstract LOG = ChainlogAbstract(0xdA0Ab1e0017DEbCd72Be8599041a2aa3bA7e740F);
        dss = MCD.loadFromChainlog(LOG);
        
        pauseProxy = LOG.getAddress("MCD_PAUSE_PROXY");
        nst = new NstMock();
        nstJoin = new NstJoinMock(address(dss.vat), address(nst));
        nst.rely(address(nstJoin));

        SNstInstance memory inst = SNstDeploy.deploy(address(this), pauseProxy, address(nstJoin));
        token = SNst(inst.sNst);
        SNstConfig memory conf = SNstConfig({
            nstJoin: address(nstJoin),
            nst: address(nst),
            nsr: 1000000001547125957863212448
        });
        vm.warp(block.timestamp + 10);
        vm.startPrank(pauseProxy);
        SNstInit.init(dss, inst, conf);
        vm.stopPrank();
        assertEq(token.chi(), RAY);
        assertEq(token.rho(), block.timestamp);
        assertEq(token.nsr(), 1000000001547125957863212448);
        assertEq(dss.vat.can(address(token), address(nstJoin)), 1);
        assertEq(token.wards(pauseProxy), 1);
        assertEq(token.version(), "1");
        assertEq(token.getImplementation(), inst.sNstImp);

        deal(address(nst), address(this), 200 ether);
        nst.approve(address(token), type(uint256).max);
        token.deposit(100 ether, address(0x222));
    }

    function _rpow(uint256 x, uint256 n) internal pure returns (uint256 z) {
        assembly {
            switch x case 0 {switch n case 0 {z := RAY} default {z := 0}}
            default {
                switch mod(n, 2) case 0 { z := RAY } default { z := x }
                let half := div(RAY, 2)  // for rounding.
                for { n := div(n, 2) } n { n := div(n,2) } {
                    let xx := mul(x, x)
                    if iszero(eq(div(xx, x), x)) { revert(0,0) }
                    let xxRound := add(xx, half)
                    if lt(xxRound, xx) { revert(0,0) }
                    x := div(xxRound, RAY)
                    if mod(n,2) {
                        let zx := mul(z, x)
                        if and(iszero(iszero(x)), iszero(eq(div(zx, x), z))) { revert(0,0) }
                        let zxRound := add(zx, half)
                        if lt(zxRound, zx) { revert(0,0) }
                        z := div(zxRound, RAY)
                    }
                }
            }
        }
    }

    function _divup(uint256 x, uint256 y) internal pure returns (uint256 z) {
        // Note: _divup(0,0) will return 0 differing from natural solidity division
        unchecked {
            z = x != 0 ? ((x - 1) / y) + 1 : 0;
        }
    }

    function testDeployWithUpgradesLib() public {
        Options memory opts;
        if (!validate) {
            opts.unsafeSkipAllChecks = true;
        } else {
            opts.unsafeAllow = 'state-variable-immutable,constructor';
        }
        opts.constructorData = abi.encode(address(nstJoin), address(0x111));

        vm.expectEmit(true, true, true, true);
        emit Rely(address(this));
        address proxy = Upgrades.deployUUPSProxy(
            "out/SNst.sol/SNst.json",
            abi.encodeCall(SNst.initialize, ()),
            opts
        );
        assertEq(SNst(proxy).version(), "1");
        assertEq(SNst(proxy).wards(address(this)), 1);
    }

    function testUpgrade() public {
        address implementation1 = token.getImplementation();

        address newImpl = address(new SNst2());
        vm.startPrank(pauseProxy);
        vm.expectEmit(true, true, true, true);
        emit UpgradedTo("2");
        token.upgradeToAndCall(newImpl, abi.encodeCall(SNst2.reinitialize, ()));
        vm.stopPrank();

        address implementation2 = token.getImplementation();
        assertEq(implementation2, newImpl);
        assertTrue(implementation2 != implementation1);
        assertEq(token.version(), "2");
        assertEq(token.wards(address(pauseProxy)), 1); // still a ward
    }

    function testUpgradeWithUpgradesLib() public {
        address implementation1 = token.getImplementation();

        Options memory opts;
        if (!validate) {
            opts.unsafeSkipAllChecks = true;
        } else {
            opts.referenceContract = "out/SNst.sol/SNst.json";
            opts.unsafeAllow = 'constructor';
        }

        vm.startPrank(pauseProxy);
        vm.expectEmit(true, true, true, true);
        emit UpgradedTo("2");
        Upgrades.upgradeProxy(
            address(token),
            "out/SNst-integration.t.sol/SNst2.json",
            abi.encodeCall(SNst2.reinitialize, ()),
            opts
        );
        vm.stopPrank();

        address implementation2 = token.getImplementation();
        assertTrue(implementation1 != implementation2);
        assertEq(token.version(), "2");
        assertEq(token.wards(address(pauseProxy)), 1); // still a ward
    }

    function testUpgradeUnauthed() public {
        address newImpl = address(new SNst2());
        vm.expectRevert("SNst/not-authorized");
        vm.prank(address(0x123)); token.upgradeToAndCall(newImpl, abi.encodeCall(SNst2.reinitialize, ()));
    }

    function testInitializeAgain() public {
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        token.initialize();
    }

    function testInitializeDirectly() public {
        address implementation = token.getImplementation();
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        SNst(implementation).initialize();
    }

    function testConstructor() public {
        address imp = address(new SNst(address(nstJoin), address(0x111)));
        vm.expectEmit(true, true, true, true);
        emit Rely(address(this));
        SNst token2 = SNst(address(new ERC1967Proxy(imp, abi.encodeCall(SNst.initialize, ()))));
        assertEq(token2.name(), "Savings Nst");
        assertEq(token2.symbol(), "sNST");
        assertEq(token2.version(), "1");
        assertEq(token2.decimals(), 18);
        assertEq(token2.chi(), RAY);
        assertEq(token2.rho(), block.timestamp);
        assertEq(token2.nsr(), RAY);
        assertEq(dss.vat.can(address(token2), address(nstJoin)), 1);
        assertEq(token2.wards(address(this)), 1);
        assertEq(address(token2.nstJoin()), address(nstJoin));
        assertEq(address(token2.vat()), address(dss.vat));
        assertEq(address(token2.nst()), address(nst));
        assertEq(address(token2.vow()), address(0x111));
        assertEq(address(token2.asset()), address(nst));
    }

    function testAuth() public {
        checkAuth(address(token), "SNst");
    }

    function testFile() public {
        checkFileUint(address(token), "SNst", ["nsr"]);

        vm.expectRevert("SNst/wrong-nsr-value");
        vm.prank(pauseProxy); token.file("nsr", RAY - 1);

        vm.warp(block.timestamp + 1);
        vm.expectRevert("SNst/chi-not-up-to-date");
        vm.prank(pauseProxy); token.file("nsr", RAY);
    }

    function testERC20() public {
        checkBulkERC20(address(token), "SNst", "Savings Nst", "sNST", "1", 18);
    }

    function testPermit() public {
        checkBulkPermit(address(token), "SNst");
    }

    function testConversion() public {
        assertGt(token.nsr(), 0);

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

    function testDrip() public {
        token.deposit(100 ether, address(this));
        vm.warp(block.timestamp + 100 days);
        uint256 supply = token.totalSupply();
        uint256 nsrNst = nst.balanceOf(address(token));
        uint256 originalChi = token.chi();
        uint256 expectedChi1 = _rpow(token.nsr(), block.timestamp - token.rho()) * token.chi() / RAY;
        uint256 diff1 = supply * expectedChi1 / RAY - supply * originalChi / RAY;
        vm.expectEmit();
        emit Drip(expectedChi1, diff1);
        assertEq(token.drip(), expectedChi1);
        assertEq(token.chi(), expectedChi1);
        assertGt(diff1, 0);
        assertEq(nst.balanceOf(address(token)), nsrNst + diff1);
        vm.warp(block.timestamp + 100 days);
        uint256 expectedChi2 = _rpow(token.nsr(), 100 days) * expectedChi1 / RAY;
        uint256 diff2 = supply * expectedChi2 / RAY - supply * expectedChi1 / RAY;
        vm.expectEmit();
        emit Drip(expectedChi2, diff2);
        assertEq(token.drip(), expectedChi2);
        assertGt(expectedChi2, expectedChi1);
        assertGt(diff2, 0);
        assertEq(nst.balanceOf(address(token)), nsrNst + diff1 + diff2);
        vm.expectEmit();
        emit Drip(expectedChi2, 0);
        assertEq(token.drip(), expectedChi2);
        vm.warp(block.timestamp - 1);
        vm.expectEmit();
        emit Drip(expectedChi2, 0);
        assertEq(token.drip(), expectedChi2);
    }

    function testDeposit() public {
        uint256 prevSupply = token.totalSupply();
        uint256 nsrNst = nst.balanceOf(address(token));

        uint256 chiFirst = token.chi();
        uint256 chiLast = _rpow(token.nsr(), 100 days) * chiFirst / RAY;
        assertGt(chiLast, chiFirst);

        vm.warp(block.timestamp + 100 days);

        uint256 diff = prevSupply * chiLast / RAY - prevSupply * chiFirst / RAY;
        uint256 pie = 1e18 * RAY / chiLast;
        vm.expectEmit();
        emit Drip(chiLast, diff);
        vm.expectEmit();
        emit Deposit(address(this), address(0xBEEF), 1e18, pie);
        vm.expectEmit();
        emit Transfer(address(0), address(0xBEEF), pie);
        token.deposit(1e18, address(0xBEEF));

        assertEq(token.chi(), chiLast);
        assertEq(token.totalSupply(), prevSupply + pie);
        assertLe(token.totalAssets(), nsrNst + diff + 1e18);    // May be slightly less due to rounding error
        assertGe(token.totalAssets(), nsrNst + diff + 1e18 - 1);
        assertEq(token.balanceOf(address(0xBEEF)), pie);
        assertEq(nst.balanceOf(address(token)), nsrNst + diff + _divup(pie * chiLast, RAY));
    }

    function testReferredDeposit() public {
        uint256 prevSupply = token.totalSupply();
        uint256 nsrNst = nst.balanceOf(address(token));

        uint256 chiFirst = token.chi();
        uint256 chiLast = _rpow(token.nsr(), 100 days) * chiFirst / RAY;
        assertGt(chiLast, chiFirst);

        vm.warp(block.timestamp + 100 days);

        uint256 diff = prevSupply * chiLast / RAY - prevSupply * chiFirst / RAY;
        uint256 pie = 1e18 * RAY / chiLast;
        vm.expectEmit();
        emit Drip(chiLast, diff);
        vm.expectEmit();
        emit Deposit(address(this), address(0xBEEF), 1e18, pie);
        vm.expectEmit();
        emit Transfer(address(0), address(0xBEEF), pie);
        vm.expectEmit();
        emit Referral(888, address(0xBEEF), 1e18, pie);
        token.deposit(1e18, address(0xBEEF), 888);

        assertEq(token.chi(), chiLast);
        assertEq(token.totalSupply(), prevSupply + pie);
        assertLe(token.totalAssets(), nsrNst + diff + 1e18);    // May be slightly less due to rounding error
        assertGe(token.totalAssets(), nsrNst + diff + 1e18 - 1);
        assertEq(token.balanceOf(address(0xBEEF)), pie);
        assertEq(nst.balanceOf(address(token)), nsrNst + diff + _divup(pie * chiLast, RAY));
    }

    function testDepositBadAddress() public {
        vm.expectRevert("SNst/invalid-address");
        token.deposit(1e18, address(0));
        vm.expectRevert("SNst/invalid-address");
        token.deposit(1e18, address(token));
    }

    function testMint() public {
        uint256 prevSupply = token.totalSupply();
        uint256 nsrNst = nst.balanceOf(address(token));

        uint256 chiFirst = token.chi();
        uint256 chiLast = _rpow(token.nsr(), 100 days) * chiFirst / RAY;
        assertGt(chiLast, chiFirst);

        vm.warp(block.timestamp + 100 days);

        uint256 diff = prevSupply * chiLast / RAY - prevSupply * chiFirst / RAY;
        uint256 pie = 1e18 * RAY / chiLast;
        vm.expectEmit();
        emit Drip(chiLast, diff);
        vm.expectEmit();
        emit Deposit(address(this), address(0xBEEF), _divup(pie * chiLast, RAY), pie);
        vm.expectEmit();
        emit Transfer(address(0), address(0xBEEF), pie);
        token.mint(pie, address(0xBEEF));

        assertEq(token.chi(), chiLast);
        assertEq(token.totalSupply(), prevSupply + pie);
        assertLe(token.totalAssets(), nsrNst + diff + 1e18);    // May be slightly less due to rounding error
        assertGe(token.totalAssets(), nsrNst + diff + 1e18 - 1);
        assertEq(token.balanceOf(address(0xBEEF)), pie);
        assertEq(nst.balanceOf(address(token)), nsrNst + diff + _divup(pie * chiLast, RAY));
    }

    function testReferredMint() public {
        uint256 prevSupply = token.totalSupply();
        uint256 nsrNst = nst.balanceOf(address(token));

        uint256 chiFirst = token.chi();
        uint256 chiLast = _rpow(token.nsr(), 100 days) * chiFirst / RAY;
        assertGt(chiLast, chiFirst);

        vm.warp(block.timestamp + 100 days);

        uint256 diff = prevSupply * chiLast / RAY - prevSupply * chiFirst / RAY;
        uint256 pie = 1e18 * RAY / chiLast;
        vm.expectEmit();
        emit Drip(chiLast, diff);
        vm.expectEmit();
        emit Deposit(address(this), address(0xBEEF), _divup(pie * chiLast, RAY), pie);
        vm.expectEmit();
        emit Transfer(address(0), address(0xBEEF), pie);
        vm.expectEmit();
        emit Referral(888, address(0xBEEF), 1e18, pie);
        token.mint(pie, address(0xBEEF), 888);

        assertEq(token.chi(), chiLast);
        assertEq(token.totalSupply(), prevSupply + pie);
        assertLe(token.totalAssets(), nsrNst + diff + 1e18);    // May be slightly less due to rounding error
        assertGe(token.totalAssets(), nsrNst + diff + 1e18 - 1);
        assertEq(token.balanceOf(address(0xBEEF)), pie);
        assertEq(nst.balanceOf(address(token)), nsrNst + diff + _divup(pie * chiLast, RAY));
    }

    function testMintBadAddress() public {
        vm.expectRevert("SNst/invalid-address");
        token.mint(1e18, address(0));
        vm.expectRevert("SNst/invalid-address");
        token.mint(1e18, address(token));
    }

    function testRedeem() public {
        uint256 prevSupply = token.totalSupply();
        uint256 nsrNst = nst.balanceOf(address(token));

        uint256 chiFirst = token.chi();
        uint256 chiMiddle = _rpow(token.nsr(), 100 days) * chiFirst / RAY;
        uint256 chiLast = _rpow(token.nsr(), 200 days) * chiMiddle / RAY;
        assertGt(chiMiddle, chiFirst);
        assertGt(chiLast, chiMiddle);

        vm.warp(block.timestamp + 100 days);

        token.deposit(1e18, address(0xBEEF));
        uint256 pie = 1e18 * RAY / chiMiddle;

        assertEq(token.chi(), chiMiddle);
        uint256 diff = prevSupply * chiMiddle / RAY - prevSupply * chiFirst / RAY;
        assertEq(nst.balanceOf(address(token)), nsrNst + diff + _divup(pie * chiMiddle, RAY));

        vm.warp(block.timestamp + 200 days);

        vm.expectEmit();
        emit Drip(chiLast, (prevSupply + pie) * chiLast / RAY - (prevSupply + pie) * chiMiddle / RAY);
        vm.expectEmit();
        emit Transfer(address(0xBEEF), address(0), pie * 0.9e18 / WAD);
        vm.expectEmit();
        emit Withdraw(address(0xBEEF), address(0xAAA), address(0xBEEF), (pie * 0.9e18 / WAD) * chiLast / RAY, pie * 0.9e18 / WAD);
        vm.prank(address(0xBEEF));
        token.redeem(pie * 0.9e18 / WAD, address(0xAAA), address(0xBEEF));

        diff += (prevSupply + pie) * chiLast / RAY - (prevSupply + pie) * chiMiddle / RAY;
        assertEq(token.chi(), chiLast);
        assertEq(token.totalSupply(), prevSupply + pie - pie * 0.9e18 / WAD);
        assertEq(token.balanceOf(address(0xBEEF)), pie - pie * 0.9e18 / WAD);
        assertEq(nst.balanceOf(address(0xAAA)), (pie * 0.9e18 / WAD) * chiLast / RAY);
        assertEq(nst.balanceOf(address(token)), nsrNst + diff + 1e18 - (pie * 0.9e18 / WAD) * chiLast / RAY);

        vm.prank(address(0xBEEF));
        token.redeem(pie - pie * 0.9e18 / WAD, address(0xAAA), address(0xBEEF));
        assertEq(token.totalSupply(), prevSupply);
        assertEq(token.balanceOf(address(0xBEEF)), 0);
        assertEq(nst.balanceOf(address(0xAAA)), (pie * 0.9e18 / WAD) * chiLast / RAY + (pie - pie * 0.9e18 / WAD) * chiLast / RAY);
        assertEq(nst.balanceOf(address(token)), nsrNst + diff + 1e18 - (pie * 0.9e18 / WAD) * chiLast / RAY - (pie - pie * 0.9e18 / WAD) * chiLast / RAY);
    }

    function testWithdraw() public {
        uint256 prevSupply = token.totalSupply();
        uint256 nsrNst = nst.balanceOf(address(token));

        uint256 chiFirst = token.chi();
        uint256 chiMiddle = _rpow(token.nsr(), 100 days) * chiFirst / RAY;
        uint256 chiLast = _rpow(token.nsr(), 200 days) * chiMiddle / RAY;
        assertGt(chiMiddle, chiFirst);
        assertGt(chiLast, chiMiddle);

        vm.warp(block.timestamp + 100 days);

        token.deposit(1e18, address(0xBEEF));
        uint256 pie = 1e18 * RAY / chiMiddle;

        assertEq(token.chi(), chiMiddle);
        uint256 diff = prevSupply * chiMiddle / RAY - prevSupply * chiFirst / RAY;
        assertEq(nst.balanceOf(address(token)), nsrNst + diff + 1e18);

        vm.warp(block.timestamp + 200 days);

        uint256 assets = (pie * 0.9e18 / WAD) * chiLast / RAY;
        uint256 shares = _divup(assets * RAY, chiLast);
        vm.expectEmit();
        emit Drip(chiLast, (prevSupply + pie) * chiLast / RAY - (prevSupply + pie) * chiMiddle / RAY);
        vm.expectEmit();
        emit Transfer(address(0xBEEF), address(0), shares);
        vm.expectEmit();
        emit Withdraw(address(0xBEEF), address(0xAAA), address(0xBEEF), assets, shares);
        vm.prank(address(0xBEEF));
        token.withdraw(assets, address(0xAAA), address(0xBEEF));

        diff += (prevSupply + pie) * chiLast / RAY - (prevSupply + pie) * chiMiddle / RAY;
        assertEq(token.chi(), chiLast);
        assertEq(token.totalSupply(), prevSupply + pie - shares);
        assertEq(token.balanceOf(address(0xBEEF)), pie - shares);
        assertEq(nst.balanceOf(address(0xAAA)), assets);
        assertEq(nst.balanceOf(address(token)), nsrNst + diff + 1e18 - assets);

        uint256 rAssets = token.balanceOf(address(0xBEEF)) * chiLast / RAY;
        vm.prank(address(0xBEEF));
        token.withdraw(rAssets, address(0xAAA), address(0xBEEF));
        assertEq(token.totalSupply(), prevSupply);
        assertEq(token.balanceOf(address(0xBEEF)), 0);
        assertEq(nst.balanceOf(address(0xAAA)), assets + rAssets);
        assertEq(nst.balanceOf(address(token)), nsrNst + diff + 1e18 - (pie * 0.9e18 / WAD) * chiLast / RAY - (pie - pie * 0.9e18 / WAD) * chiLast / RAY);
    }

    function testSharesEstimatesMatch() public {
        vm.warp(block.timestamp + 365 days);

        uint256 assets = 1e18;
        uint256 shares = token.convertToShares(assets);

        token.drip();

        assertEq(token.convertToShares(assets), shares);
    }

    function testAssetsEstimatesMatch() public {
        vm.warp(block.timestamp + 365 days);

        uint256 shares = 1e18;
        uint256 assets = token.convertToAssets(shares);

        token.drip();

        assertEq(token.convertToAssets(shares), assets);
    }

    function testERC20Fuzz(
        address from,
        address to,
        uint256 amount1,
        uint256 amount2
    ) public {
        checkBulkERC20Fuzz(address(token), "SNst", from, to, amount1, amount2);
    }

    function testPermitFuzz(
        uint128 privKey,
        address to,
        uint256 amount,
        uint256 deadline,
        uint256 nonce
    ) public {
        checkBulkPermitFuzz(address(token), "SNst", privKey, to, amount, deadline, nonce);
    }

    function testDrip(uint256 amount, uint256 warp, uint256 warp2) public {
        warp %= 365 days;
        warp2 %= 365 days;
        vm.assume(warp > 0 && warp2 > 0);
        amount %= 100 ether;

        token.deposit(amount, address(this));
        vm.warp(block.timestamp + warp);
        uint256 supply = token.totalSupply();
        uint256 nsrNst = nst.balanceOf(address(token));
        uint256 originalChi = token.chi();
        uint256 expectedChi1 = _rpow(token.nsr(), block.timestamp - token.rho()) * token.chi() / RAY;
        uint256 diff1 = supply * expectedChi1 / RAY - supply * originalChi / RAY;
        vm.expectEmit();
        emit Drip(expectedChi1, diff1);
        assertEq(token.drip(), expectedChi1);
        assertEq(token.chi(), expectedChi1);
        assertGt(diff1, 0);
        assertEq(nst.balanceOf(address(token)), nsrNst + diff1);
        vm.warp(block.timestamp + warp2);
        uint256 expectedChi2 = _rpow(token.nsr(), warp2) * expectedChi1 / RAY;
        uint256 diff2 = supply * expectedChi2 / RAY - supply * expectedChi1 / RAY;
        vm.expectEmit();
        emit Drip(expectedChi2, diff2);
        assertEq(token.drip(), expectedChi2);
        assertGt(expectedChi2, expectedChi1);
        assertGt(diff2, 0);
        assertEq(nst.balanceOf(address(token)), nsrNst + diff1 + diff2);
        vm.expectEmit();
        emit Drip(expectedChi2, 0);
        assertEq(token.drip(), expectedChi2);
        vm.warp(block.timestamp - 1);
        vm.expectEmit();
        emit Drip(expectedChi2, 0);
        assertEq(token.drip(), expectedChi2);
    }

    function testDeposit(address to, uint256 amount, uint256 warp) public {
        vm.assume(to != address(0x222));
        amount %= 100 ether;
        warp %= 365 days;

        uint256 prevSupply = token.totalSupply();
        uint256 nsrNst = nst.balanceOf(address(token));

        uint256 chiFirst = token.chi();
        uint256 chiLast = _rpow(token.nsr(), warp) * chiFirst / RAY;
        assertGe(chiLast, chiFirst);

        vm.warp(block.timestamp + warp);

        uint256 shares = token.previewDeposit(amount);
        if (to != address(0) && to != address(token)) {
            uint256 diff = prevSupply * chiLast / RAY - prevSupply * chiFirst / RAY;

            vm.expectEmit();
            emit Drip(chiLast, diff);
            vm.expectEmit();
            emit Deposit(address(this), to, amount, shares);
            vm.expectEmit();
            emit Transfer(address(0), to, shares);
            uint256 ashares = token.deposit(amount, to);

            assertEq(token.chi(), chiLast);
            assertEq(ashares, shares);
            assertEq(token.totalSupply(), prevSupply + shares);
            assertEq(token.balanceOf(to), shares);
            assertEq(nst.balanceOf(address(token)), nsrNst + diff + amount);
        } else {
            vm.expectRevert("SNst/invalid-address");
            token.deposit(amount, to);
        }
    }

    function testMint(address to, uint256 shares, uint256 warp) public {
        vm.assume(to != address(0x222));
        warp %= 365 days;

        vm.warp(block.timestamp + warp);

        uint256 prevSupply = token.totalSupply();
        uint256 nsrNst = nst.balanceOf(address(token));

        uint256 chiFirst = token.chi();
        uint256 chiLast = _rpow(token.nsr(), warp) * chiFirst / RAY;
        assertGe(chiLast, chiFirst);

        shares %= 100 ether * RAY / chiLast;

        uint256 assets = token.previewMint(shares);
        if (to != address(0) && to != address(token)) {
            uint256 diff = prevSupply * chiLast / RAY - prevSupply * chiFirst / RAY;

            vm.expectEmit();
            emit Drip(chiLast, diff);
            vm.expectEmit();
            emit Deposit(address(this), to, assets, shares);
            vm.expectEmit();
            emit Transfer(address(0), to, shares);
            uint256 aassets = token.mint(shares, to);

            assertEq(token.chi(), chiLast);
            assertEq(aassets, assets);
            assertEq(token.totalSupply(), prevSupply + shares);
            assertEq(token.balanceOf(to), shares);
            assertEq(nst.balanceOf(address(token)), nsrNst + diff + _divup(shares * chiLast, RAY));
        } else {
            vm.expectRevert("SNst/invalid-address");
            token.mint(shares, to);
        }
    }

    struct TestData {
        uint256 chiFirst;
        uint256 chiMiddle;
        uint256 chiLast;
        uint256 nstBalanceToken;
        uint256 nstBalanceFrom;
        uint256 nstBalanceTo;
    }

    function testRedeem(
        address from,
        address to,
        uint256 depositAmount,
        uint256 redeemAmount,
        uint256 warp,
        uint256 warp2
    ) public {
        vm.assume(from != address(0) && from != address(token) && from != address(0x222));
        vm.assume(to != address(0) && to != address(token) && to != address(0x222));
        depositAmount %= 100 ether;
        redeemAmount %= 100 ether;

        warp %= 365 days;
        warp2 %= 365 days;

        uint256 prevSupply = token.totalSupply();
        TestData memory testData;
        testData.nstBalanceToken = nst.balanceOf(address(token));
        testData.nstBalanceFrom = nst.balanceOf(from);
        testData.nstBalanceTo = nst.balanceOf(to);
        testData.chiFirst = token.chi();
        testData.chiMiddle = _rpow(token.nsr(), warp) * testData.chiFirst / RAY;
        testData.chiLast = _rpow(token.nsr(), warp2) * testData.chiMiddle / RAY;
        assertGe(testData.chiMiddle, testData.chiFirst);
        assertGe(testData.chiLast, testData.chiMiddle);

        vm.warp(block.timestamp + warp);

        uint256 pie = token.convertToShares(depositAmount);
        redeemAmount = bound(redeemAmount, 0, pie);

        deal(address(nst), address(0x222), depositAmount);
        vm.startPrank(address(0x222));
        nst.approve(address(token), depositAmount);
        token.deposit(depositAmount, from);
        vm.stopPrank();

        assertEq(token.chi(), testData.chiMiddle);
        uint256 diff = prevSupply * testData.chiMiddle / RAY - prevSupply * testData.chiFirst / RAY;
        assertEq(nst.balanceOf(address(token)), testData.nstBalanceToken + diff + depositAmount);

        vm.warp(block.timestamp + warp2);

        uint256 assets = token.previewRedeem(redeemAmount);
        vm.expectEmit();
        emit Drip(testData.chiLast, (prevSupply + pie) * testData.chiLast / RAY - (prevSupply + pie) * testData.chiMiddle / RAY);
        vm.expectEmit();
        emit Transfer(address(from), address(0), redeemAmount);
        vm.expectEmit();
        emit Withdraw(address(from), to, address(from), assets, redeemAmount);
        vm.prank(from);
        assertEq(token.redeem(redeemAmount, to, from), assets);

        diff += (prevSupply + pie) * testData.chiLast / RAY - (prevSupply + pie) * testData.chiMiddle / RAY;
        assertEq(token.chi(), testData.chiLast);
        uint256 shares = _divup(assets * RAY, testData.chiLast);
        assertEq(token.totalSupply(), prevSupply + pie - shares);
        assertEq(token.balanceOf(from), pie - shares);
        if (from != to) assertEq(nst.balanceOf(from), testData.nstBalanceFrom);
        assertEq(nst.balanceOf(to), testData.nstBalanceTo + assets);
        assertEq(nst.balanceOf(address(token)), testData.nstBalanceToken + diff + depositAmount - assets);

        vm.prank(from);
        token.redeem(pie - redeemAmount, to, from);
        assertEq(token.totalSupply(), prevSupply);
        assertEq(token.balanceOf(from), 0);
        if (from != to) assertEq(nst.balanceOf(from), testData.nstBalanceFrom);
        assertEq(nst.balanceOf(to), assets + (pie - redeemAmount) * testData.chiLast / RAY);
        assertEq(nst.balanceOf(address(token)), testData.nstBalanceToken + diff + depositAmount - assets - (pie - redeemAmount) * testData.chiLast / RAY);
    }

    function testWithdraw(
        address from,
        address to,
        uint256 depositAmount,
        uint256 withdrawAmount,
        uint256 warp,
        uint256 warp2
    ) public {
        vm.assume(from != address(0) && from != address(token) && from != address(0x222));
        vm.assume(to != address(0) && to != address(token) && to != address(0x222));
        depositAmount = depositAmount % 99 ether + 1 ether;
        withdrawAmount %= 100 ether;

        warp %= 365 days;
        warp2 %= 365 days;

        uint256 prevSupply = token.totalSupply();
        TestData memory testData;
        testData.nstBalanceToken = nst.balanceOf(address(token));
        testData.nstBalanceFrom = nst.balanceOf(from);
        testData.nstBalanceTo = nst.balanceOf(to);
        testData.chiFirst = token.chi();
        testData.chiMiddle = _rpow(token.nsr(), warp) * testData.chiFirst / RAY;
        testData.chiLast = _rpow(token.nsr(), warp2) * testData.chiMiddle / RAY;
        assertGe(testData.chiMiddle, testData.chiFirst);
        assertGe(testData.chiLast, testData.chiMiddle);

        vm.warp(block.timestamp + warp);

        uint256 pie = token.convertToShares(depositAmount);
        withdrawAmount = bound(withdrawAmount, 0, depositAmount);

        deal(address(nst), address(0x222), depositAmount);
        vm.startPrank(address(0x222));
        nst.approve(address(token), depositAmount);
        token.deposit(depositAmount, from);
        vm.stopPrank();

        assertEq(token.chi(), testData.chiMiddle);
        uint256 diff = prevSupply * testData.chiMiddle / RAY - prevSupply * testData.chiFirst / RAY;
        assertEq(nst.balanceOf(address(token)), testData.nstBalanceToken + diff + depositAmount);

        vm.warp(block.timestamp + warp2);

        uint256 shares = token.previewWithdraw(withdrawAmount);
        vm.expectEmit();
        emit Drip(testData.chiLast, (prevSupply + pie) * testData.chiLast / RAY - (prevSupply + pie) * testData.chiMiddle / RAY);
        vm.expectEmit();
        emit Transfer(address(from), address(0), shares);
        vm.expectEmit();
        emit Withdraw(address(from), to, address(from), withdrawAmount, shares);
        vm.prank(from);
        assertEq(token.withdraw(withdrawAmount, to, from), shares);

        diff += (prevSupply + pie) * testData.chiLast / RAY - (prevSupply + pie) * testData.chiMiddle / RAY;
        assertEq(token.chi(), testData.chiLast);
        assertEq(token.totalSupply(), prevSupply + pie - shares);
        assertEq(token.balanceOf(from), pie - shares);
        if (from != to) assertEq(nst.balanceOf(from), testData.nstBalanceFrom);
        assertEq(nst.balanceOf(to), testData.nstBalanceTo + withdrawAmount);
        assertEq(nst.balanceOf(address(token)), testData.nstBalanceToken + diff + depositAmount - withdrawAmount);

        uint256 rAssets = token.balanceOf(address(from)) * testData.chiLast / RAY;
        vm.prank(address(from));
        token.withdraw(rAssets, to, address(from));
        assertEq(token.totalSupply(), prevSupply);
        assertEq(token.balanceOf(from), 0);
        if (from != to) assertEq(nst.balanceOf(from), testData.nstBalanceFrom);
        assertEq(nst.balanceOf(to), testData.nstBalanceTo + withdrawAmount + rAssets);
        assertEq(nst.balanceOf(address(token)), testData.nstBalanceToken + diff + depositAmount - withdrawAmount - (pie - shares) * testData.chiLast / RAY);
    }

    function testRedeemInsufficientBalance(
        address to,
        uint256 mintAmount,
        uint256 burnAmount
    ) public {
        vm.assume(to != address(0) && to != address(token));
        mintAmount %= 100 ether;
        burnAmount %= 100 ether;

        uint256 pie = mintAmount * RAY / token.chi();
        burnAmount = bound(burnAmount, pie + 1, type(uint256).max / token.chi());

        token.deposit(mintAmount, to);
        vm.expectRevert("SNst/insufficient-balance");
        token.redeem(burnAmount, to, to);
    }
}
