// SPDX-License-Identifier: AGPL-3.0-or-later

/// DaiJoin.sol -- Dai adapter

// Copyright (C) 2018 Rain <rainbreak@riseup.net>
// Copyright (C) 2022 Dai Foundation
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

pragma solidity ^0.8.13;

interface DaiLike {
    function burn(address,uint256) external;
    function mint(address,uint256) external;
}

interface VatLike {
    function move(address,address,uint256) external;
}

contract DaiJoinMock {
    VatLike public immutable vat;       // CDP Engine
    DaiLike public immutable dai;       // Stablecoin Token
    uint256 constant RAY = 10 ** 27;

    // --- Events ---
    event Join(address indexed usr, uint256 wad);
    event Exit(address indexed usr, uint256 wad);

    constructor(address vat_, address dai_) {
        vat = VatLike(vat_);
        dai = DaiLike(dai_);
    }

    // --- User's functions ---
    function join(address usr, uint256 wad) external {
        vat.move(address(this), usr, RAY * wad);
        dai.burn(msg.sender, wad);
        emit Join(usr, wad);
    }

    function exit(address usr, uint256 wad) external {
        vat.move(msg.sender, address(this), RAY * wad);
        dai.mint(usr, wad);
        emit Exit(usr, wad);
    }
}
