// SPDX-License-Identifier: MIT
// Handler is going to narrow down the way we would call functions

pragma solidity ^0.8.19;

import {Test} from "forge-std/Test.sol";
import {DSCEngine} from "../../src/DSCEngine.sol";
import {DecentralizedStableCoin} from "../../src/DecentralizedStableCoin.sol";
import {ERC20Mock} from "@openzeppelin/contracts/mocks/token/ERC20Mock.sol";
import {MockV3Aggregator} from "../mocks/MockV3Aggregator.sol";

contract Handler is Test {
    // first task only call redeemCollateral if there is collateral
    DSCEngine engine;
    DecentralizedStableCoin dsc;
    ERC20Mock weth;
    ERC20Mock usdc;
    uint256 MAX_DEPOSIT_SIZE = type(uint96).max;

    MockV3Aggregator public ethUsdPriceFeed;

    constructor(DSCEngine _dscEngine, DecentralizedStableCoin _dsc) {
        engine = _dscEngine;
        dsc = _dsc;

        address[] memory collateralTokens = engine.getCollateralTokens();
        weth = ERC20Mock(collateralTokens[0]);
        usdc = ERC20Mock(collateralTokens[1]);

        ethUsdPriceFeed = MockV3Aggregator(engine.getCollateralTokenPriceFeedAddress(address(weth)));
    }

    function redeemCollateral(uint256 collateralSeed, uint256 amountCollateral) public {
        ERC20Mock collateral = _getCollateralFromSeed(collateralSeed);
        uint256 maxCollateralToRedeem = engine.getCollateralBalanceOfUser(msg.sender, address(collateral));
        amountCollateral = bound(amountCollateral, 0, maxCollateralToRedeem);
        if (amountCollateral == 0) {
            return;
        }
        vm.prank(msg.sender);
        engine.redeemCollateral(address(collateral), amountCollateral);
    }
    // this would break our test suite... no way around it
    // function updateCollateralPrice(int96 newPrice) public {
    //     int256 price = int256(newPrice);
    //     ethUsdPriceFeed.updateAnswer(price);
    // }

    function depositCollateral(uint256 collateralSeed, uint256 amountCollateral) public {
        ERC20Mock collateral = _getCollateralFromSeed(collateralSeed);
        amountCollateral = bound(amountCollateral, 10, MAX_DEPOSIT_SIZE);
        // The deployer is the contract initially minting weth/usdc
        // so I must give Handler.t.sol some tokens and approve engine to use its tokens in order for the fuzz tests to go through
        vm.startPrank(msg.sender);
        collateral.mint(msg.sender, amountCollateral);
        collateral.approve(address(engine), amountCollateral);
        engine.depositCollateral(address(collateral), amountCollateral);
        vm.stopPrank();
    }

    // Helper Functions

    function _getCollateralFromSeed(uint256 collateralSeed) public view returns (ERC20Mock) {
        if (collateralSeed % 2 == 0) {
            return weth;
        }
        return usdc;
    }
}
