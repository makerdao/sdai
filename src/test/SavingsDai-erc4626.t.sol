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

import "erc4626-tests/ERC4626.test.sol";

import { VatMock } from "./mocks/VatMock.sol";
import { DaiMock } from "./mocks/DaiMock.sol";
import { DaiJoinMock } from "./mocks/DaiJoinMock.sol";
import { PotMock } from "./mocks/PotMock.sol";

import { SavingsDai } from "../SavingsDai.sol";

contract SavingsDaiERC4626Test is ERC4626Test {

    VatMock vat;
    DaiMock dai;
    DaiJoinMock daiJoin;
    PotMock pot;

    SavingsDai savingsDai;

    function setUp() public override {
        vat = new VatMock();
        dai = new DaiMock();
        daiJoin = new DaiJoinMock(address(vat), address(dai));
        pot = new PotMock(address(vat));

        dai.rely(address(daiJoin));
        vat.suck(address(123), address(daiJoin), 100_000_000_000 * 10 ** 45);
        vat.rely(address(pot));

        vat.deny(address(this));
        pot.deny(address(this));

        savingsDai = new SavingsDai(address(daiJoin), address(pot));

        _underlying_ = address(dai);
        _vault_ = address(savingsDai);
        _delta_ = 0;
        _vaultMayBeEmpty = true;
        _unlimitedAmount = false;
    }

    // setup initial vault state as follows:
    //
    // totalAssets == sum(init.share) + init.yield
    // totalShares == sum(init.share)
    //
    // init.user[i]'s assets == init.asset[i]
    // init.user[i]'s shares == init.share[i]
    function setUpVault(Init memory init) public override {
        // setup initial shares and assets for individual users
        for (uint i = 0; i < N; i++) {
            init.share[i] %= 1_000_000_000 ether;
            init.asset[i] %= 1_000_000_000 ether;

            address user = init.user[i];
            vm.assume(_isEOA(user));
            // shares
            uint shares = init.share[i];
            try IMockERC20(_underlying_).mint(user, shares) {} catch { vm.assume(false); }
            _approve(_underlying_, user, _vault_, shares);
            vm.prank(user); try IERC4626(_vault_).deposit(shares, user) {} catch { vm.assume(false); }
            // assets
            uint assets = init.asset[i];
            try IMockERC20(_underlying_).mint(user, assets) {} catch { vm.assume(false); }
        }

        // setup initial yield for vault
        setUpYield(init);
    }

    // setup initial yield
    function setUpYield(Init memory init) public override {
        vm.assume(init.yield >= 0);
        init.yield %= 1_000_000_000 ether;
        uint gain = uint(init.yield);
        pot.setYield(gain);
    }

}
