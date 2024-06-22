// SPDX-License-Identifier: MIT

pragma solidity ^0.8.19;

import {Test, console} from "forge-std/Test.sol";
import {DeployDSC} from "../../script/DeployDSC.s.sol";
import {DSCEngine} from "../../src/DSCEngine.sol";
import {DecentralizedStableCoin} from "../../src/DecentralizedStableCoin.sol";
import {HelperConfig} from "../../script/HelperConfig.s.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {IERC20} from "@openzeppelin/contracts/interfaces/IERC20.sol";
import {Handler} from "./Handler.t.sol";

contract OpenInvariantsTest is StdInvariant, Test {
    DeployDSC deployer;
    DecentralizedStableCoin dsc;
    DSCEngine engine;
    HelperConfig config;
    address weth;
    address usdc;
    Handler handler;

    function setUp() public {
        deployer = new DeployDSC();
        (dsc, engine, config) = deployer.run();
        (,, weth, usdc,) = config.activeNetworkConfig();
        handler = new Handler(engine, dsc);
        targetContract(address(handler));
    }

    function invariant_protocolMustHaveMoreValueThanTotalSupply() public view {
        // get the value of all the collateral in the protocol
        // compare it to all the debt (dsc)
        uint256 totalSupply = dsc.totalSupply();
        uint256 totalWethDeposited = IERC20(weth).balanceOf(address(engine));
        uint256 totalUsdcDeposited = IERC20(usdc).balanceOf(address(engine));

        uint256 wethValue = engine._getUsdValue(weth, totalWethDeposited);
        uint256 usdcValue = engine._getUsdValue(usdc, totalUsdcDeposited);

        assert(wethValue + usdcValue >= totalSupply);
    }

    function invariant_gettersShouldNotRevert() public view {
        // if we put all our getters here, then we can do stateful fuzzy (invariant) testing to check they all work
        // if one getter fails, this test reverts
        // run forge inspect DSCEngine methods to get a list of all methods in the contract {DSCEngine};
        engine.getCollateralTokens();
    }
}
