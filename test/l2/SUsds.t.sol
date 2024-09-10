// SPDX-License-Identifier: AGPL-3.0-or-later

pragma solidity ^0.8.21;

import "token-tests/TokenFuzzTests.sol";
import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import { Upgrades, Options } from "openzeppelin-foundry-upgrades/Upgrades.sol";

import { SUsds, UUPSUpgradeable, Initializable, ERC1967Utils } from "src/l2/SUsds.sol";

import { SUsdsInstance } from "deploy/SUsdsInstance.sol";
import { SUsdsDeploy } from "deploy/l2/SUsdsDeploy.sol";

contract SUsds2 is UUPSUpgradeable {
    mapping (address => uint256) public wards;
    string  public constant version  = "2";

    uint256 public totalSupply;
    mapping (address => uint256)                      public balanceOf;
    mapping (address => mapping (address => uint256)) public allowance;
    mapping (address => uint256)                      public nonces;

    event UpgradedTo(string version);

    modifier auth {
        require(wards[msg.sender] == 1, "SUsds/not-authorized");
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

contract SUsdsTest is TokenFuzzTests {
    SUsds usds;
    bool  validate;

    event UpgradedTo(string version);

    function setUp() public {
        validate = vm.envOr("VALIDATE", false);

        address imp = address(new SUsds());
        vm.expectEmit(true, true, true, true);
        emit Rely(address(this));
        usds = SUsds(address(new ERC1967Proxy(imp, abi.encodeCall(SUsds.initialize, ()))));
        assertEq(usds.version(), "1");
        assertEq(usds.wards(address(this)), 1);
        assertEq(usds.getImplementation(), imp);

        _token_ = address(usds);
        _contractName_ = "SUsds";
        _tokenName_ = "Savings USDS";
        _symbol_ = "sUSDS";
    }

    function invariantMetadata() public view {
        assertEq(usds.name(), "Savings USDS");
        assertEq(usds.symbol(), "sUSDS");
        assertEq(usds.version(), "1");
        assertEq(usds.decimals(), 18);
    }

    function testDeployWithUpgradesLib() public {
        Options memory opts;
        if (!validate) {
            opts.unsafeSkipAllChecks = true;
        } else {
            opts.unsafeAllow = 'state-variable-immutable,constructor';
        }

        vm.expectEmit(true, true, true, true);
        emit Rely(address(this));
        address proxy = Upgrades.deployUUPSProxy(
            "out/l2/SUsds.sol/SUsds.json",
            abi.encodeCall(SUsds.initialize, ()),
            opts
        );
        assertEq(SUsds(proxy).version(), "1");
        assertEq(SUsds(proxy).wards(address(this)), 1);
    }

    function testUpgrade() public {
        address implementation1 = usds.getImplementation();

        address newImpl = address(new SUsds2());
        vm.expectEmit(true, true, true, true);
        emit UpgradedTo("2");
        usds.upgradeToAndCall(newImpl, abi.encodeCall(SUsds2.reinitialize, ()));

        address implementation2 = usds.getImplementation();
        assertEq(implementation2, newImpl);
        assertTrue(implementation2 != implementation1);
        assertEq(usds.version(), "2");
        assertEq(usds.wards(address(this)), 1); // still a ward
    }

    function testUpgradeWithUpgradesLib() public {
        address implementation1 = usds.getImplementation();

        Options memory opts;
        if (!validate) {
            opts.unsafeSkipAllChecks = true;
        } else {
            opts.referenceContract = "out/SUsds.sol/SUsds.json";
            opts.unsafeAllow = 'constructor';
        }

        vm.expectEmit(true, true, true, true);
        emit UpgradedTo("2");
        Upgrades.upgradeProxy(
            address(usds),
            "out/SUsds.t.sol/SUsds2.json",
            abi.encodeCall(SUsds2.reinitialize, ()),
            opts
        );

        address implementation2 = usds.getImplementation();
        assertTrue(implementation1 != implementation2);
        assertEq(usds.version(), "2");
        assertEq(usds.wards(address(this)), 1); // still a ward
    }

    function testUpgradeUnauthed() public {
        address newImpl = address(new SUsds2());
        vm.expectRevert("SUsds/not-authorized");
        vm.prank(address(0x123)); usds.upgradeToAndCall(newImpl, abi.encodeCall(SUsds2.reinitialize, ()));
    }

    function testInitializeAgain() public {
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        usds.initialize();
    }

    function testInitializeDirectly() public {
        address implementation = usds.getImplementation();
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        SUsds(implementation).initialize();
    }

    function testDeployment() public {
        SUsdsInstance memory inst = SUsdsDeploy.deploy(address(this), address(123));
        assertEq(SUsds(inst.sUsds).wards(address(this)), 0);
        assertEq(SUsds(inst.sUsds).wards(address(123)), 1);
        assertEq(SUsds(inst.sUsds).getImplementation(), inst.sUsdsImp);
    }
}
