// SPDX-License-Identifier: AGPL-3.0-or-later

// Copyright (C) 2024 Dai Foundation
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

import { ScriptTools } from "dss-test/ScriptTools.sol";
import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import { SUsds } from "src/l2/SUsds.sol";

import { SUsdsInstance } from "deploy/SUsdsInstance.sol";

library SUsdsDeploy {
    function deploy(
        address deployer,
        address owner
    ) internal returns (SUsdsInstance memory instance) {
        address _sUsdsImp = address(new SUsds());
        address _sUsds = address((new ERC1967Proxy(_sUsdsImp, abi.encodeCall(SUsds.initialize, ()))));
        ScriptTools.switchOwner(_sUsds, deployer, owner);

        instance.sUsds    = _sUsds;
        instance.sUsdsImp = _sUsdsImp;
    }
}
