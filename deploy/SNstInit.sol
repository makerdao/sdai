// SPDX-FileCopyrightText: © 2023 Dai Foundation <www.daifoundation.org>
// SPDX-License-Identifier: AGPL-3.0-or-later
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

pragma solidity >=0.8.0;

import { DssInstance } from "dss-test/MCD.sol";
import { SNstInstance } from "./SNstInstance.sol";

interface SNstLike {
    function version() external view returns (string memory);
    function getImplementation() external view returns (address);
    function nstJoin() external view returns (address);
    function vat() external view returns (address);
    function nst() external view returns (address);
    function vow() external view returns (address);
    function file(bytes32, uint256) external;
    function drip() external returns (uint256);
}

interface NstJoinLike {
    function nst() external view returns (address);
}

struct SNstConfig {
    address nstJoin;
    address nst;
    uint256 nsr;
}

library SNstInit {

    uint256 constant internal RAY                   = 10**27;
    uint256 constant internal RATES_ONE_HUNDRED_PCT = 1000000021979553151239153027;

    function init(
        DssInstance  memory dss,
        SNstInstance memory instance,
        SNstConfig   memory cfg
    ) internal {
        require(keccak256(abi.encodePacked(SNstLike(instance.sNst).version())) == keccak256(abi.encodePacked("1")), "SNstInit/version-does-not-match");
        require(SNstLike(instance.sNst).getImplementation() == instance.sNstImp, "SNstInit/imp-does-not-match");

        require(SNstLike(instance.sNst).vat()     == address(dss.vat), "SNstInit/vat-does-not-match");
        require(SNstLike(instance.sNst).nstJoin() == cfg.nstJoin,      "SNstInit/nstJoin-does-not-match");
        require(SNstLike(instance.sNst).nst()     == cfg.nst,          "SNstInit/nst-does-not-match");
        require(SNstLike(instance.sNst).vow()     == address(dss.vow), "SNstInit/vow-does-not-match");

        require(cfg.nsr >= RAY && cfg.nsr <= RATES_ONE_HUNDRED_PCT, "SNstInit/nsr-out-of-boundaries");

        dss.vat.rely(instance.sNst);

        SNstLike(instance.sNst).drip();
        SNstLike(instance.sNst).file("nsr", cfg.nsr);

        dss.chainlog.setAddress("SNST",      instance.sNst);
        dss.chainlog.setAddress("SNST_IMP",  instance.sNstImp);
    }
}
