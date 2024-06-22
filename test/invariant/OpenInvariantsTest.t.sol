// // SPDX-License-Identifier: MIT

// pragma solidity ^0.8.19;

// import {Test, console} from "forge-std/Test.sol";
// import {DeployDSC} from "../../script/DeployDSC.s.sol";
// import {DSCEngine} from "../../src/DSCEngine.sol";
// import {DecentralizedStableCoin} from "../../src/DecentralizedStableCoin.sol";
// import {HelperConfig} from "../../script/HelperConfig.s.sol";
// import {StdInvariant} from "forge-std/StdInvariant.sol";
// import {IERC20} from "@openzeppelin/contracts/interfaces/IERC20.sol";

// contract OpenInvariantsTest is StdInvariant, Test {
//     DeployDSC public deployer;
//     DecentralizedStableCoin public dsc;
//     DSCEngine public engine;
//     HelperConfig public config;
//     address weth;
//     address usdc;

//     function setUp() public {
//         deployer = new DeployDSC();
//         (dsc, engine, config) = deployer.run();
//         (,, weth, usdc,) = config.activeNetworkConfig();
//         targetContract(address(engine));
//     }

//     function invariant_protocolMustHaveMoreValueThanTotalSupply() public view {
//         // get the value of all the collateral in the protocol
//         // compare it to all the debt (dsc)
//         uint256 totalSupply = dsc.totalSupply();
//         uint256 totalWethDeposited = IERC20(weth).balanceOf(address(engine));
//         uint256 totalUsdcDeposited = IERC20(usdc).balanceOf(address(engine));

//         uint256 wethValue = engine._getUsdValue(weth, totalWethDeposited);
//         uint256 usdcValue = engine._getUsdValue(usdc, totalUsdcDeposited);

//         assert(wethValue + usdcValue >= totalSupply);
//     }
// }
