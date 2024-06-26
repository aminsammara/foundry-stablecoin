//SPDX-License-Identifier: MIT

pragma solidity ^0.8.19;

import {Test, console} from "forge-std/Test.sol";
import {DeployDSC} from "../../script/DeployDSC.s.sol";
import {DSCEngine} from "../../src/DSCEngine.sol";
import {DecentralizedStableCoin} from "../../src/DecentralizedStableCoin.sol";
import {HelperConfig} from "../../script/HelperConfig.s.sol";
import {ERC20Mock} from "@openzeppelin/contracts/mocks/token/ERC20Mock.sol";
import {MockV3Aggregator} from "../../test/mocks/MockV3Aggregator.sol";

contract DSCEngineTest is Test {
    DeployDSC public deployer;
    DecentralizedStableCoin public dsc;
    DSCEngine public engine;
    HelperConfig public config;

    address wethUsdPriceFeed;
    address weth;
    address usdc;

    address public USER = makeAddr("user");
    uint256 public constant STARTING_WETH_BALANCE = 100 ether;
    uint256 public constant AMOUNT_COLLATERAL = 10 ether;
    uint256 private constant PRECISION = 1e18;

    function setUp() public {
        deployer = new DeployDSC();
        (dsc, engine, config) = deployer.run();
        (wethUsdPriceFeed,, weth, usdc,) = config.activeNetworkConfig();
        ERC20Mock(weth).mint(USER, STARTING_WETH_BALANCE);
    }

    /////////////////////
    // Constructor Tests
    /////////////////////

    address[] public tokenAddresses;
    address[] public priceFeedAddresses;

    function testRevertIfTokenLengthDoesntMatchPriceFeeds() public {
        tokenAddresses.push(weth);
        tokenAddresses.push(usdc);
        priceFeedAddresses.push(wethUsdPriceFeed);

        vm.expectRevert(DSCEngine.DSCEngine__TokenAddressesAndPriceFeedAddressesNotSameLength.selector);
        new DSCEngine(tokenAddresses, priceFeedAddresses, address(dsc));
    }

    /////////////////////
    // Price Tests
    /////////////////////

    function testGetUsdValue() public view {
        uint256 ethAmount = 15e18;
        // 15e18 * 2000/eth = 30,000e18
        uint256 expectedUsd = 30000e18;
        uint256 actualUsd = engine._getUsdValue(weth, ethAmount);
        assertEq(expectedUsd, actualUsd);
    }

    function testGetTokenAmountFromUsd() public view {
        uint256 usdAmount = 100 ether;
        uint256 expectedWeth = (100 * 1e18) / 2000;
        uint256 returnedAmount = engine.getTokenAmountFromUsd(weth, usdAmount);
        assertEq(expectedWeth, returnedAmount);
    }

    /////////////////////
    // Deposit Collateral Tests
    /////////////////////

    function testRevertsIfCollateralIsZero() public {
        // I don't need the first two lines here since the depositCollateral function reverts at 0 before it initiates transferFrom()
        vm.startPrank(address(deployer));
        ERC20Mock(weth).approve(address(engine), AMOUNT_COLLATERAL);
        vm.expectRevert(DSCEngine.DSCEngine__NeedsMoreThanZero.selector);
        engine.depositCollateral(weth, 0);
        // assert(ERC20Mock(weth).balanceOf(address(engine)) == 1);
        vm.stopPrank();
    }

    function testRevertsWithUnApprovedCollateral() public {
        ERC20Mock ranToken = new ERC20Mock();
        ranToken.mint(USER, STARTING_WETH_BALANCE);
        vm.expectRevert(DSCEngine.DSCEngine__NotAllowedToken.selector);
        engine.depositCollateral(address(ranToken), AMOUNT_COLLATERAL);
    }

    modifier depositedCollateral() {
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(engine), AMOUNT_COLLATERAL);
        engine.depositCollateral(weth, AMOUNT_COLLATERAL);
        vm.stopPrank();
        _;
    }

    function testCanDepositCollateralAndCanGetAccountInfo() public depositedCollateral {
        (uint256 totalDscMinted, uint256 collateralValueInUsd) = engine.getAccountInformation(USER);
        uint256 expectedDscMinted = 0;
        uint256 expectedcollateralValueInUsd = engine._getUsdValue(weth, AMOUNT_COLLATERAL);
        assertEq(totalDscMinted, expectedDscMinted);
        assertEq(expectedcollateralValueInUsd, collateralValueInUsd);
    }

    function testEmitsCollateralDepositedEvent() public {
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(engine), AMOUNT_COLLATERAL);
        vm.expectEmit();
        emit DSCEngine.CollateralDeposited(USER, weth, AMOUNT_COLLATERAL);
        engine.depositCollateral(weth, AMOUNT_COLLATERAL);
        vm.stopPrank();
    }

    /////////////////////
    // Mint DSC Tests
    /////////////////////

    function testMintDscIsProperlyRecorded() public depositedCollateral {
        vm.startPrank(USER);
        engine.mintDsc(100);
        vm.stopPrank();

        uint256 expectedDscBalance = 100;
        uint256 dscBalance = engine.getDscMintedInformation(USER);

        assertEq(expectedDscBalance, dscBalance);
    }

    function testMintingTooMuchDscFailsAndReturnsCorrectHealthFactor() public depositedCollateral {
        (, uint256 collateralValueInUsd) = engine.getAccountInformation(USER);
        uint256 amountDscToMint = AMOUNT_COLLATERAL;
        uint256 healthFactor = ((((collateralValueInUsd * 50) / 100) * PRECISION) / (amountDscToMint * PRECISION));

        vm.startPrank(USER);
        vm.expectRevert(abi.encodeWithSelector(DSCEngine.DSCEngine__BreaksHealthFactor.selector, healthFactor));
        engine.mintDsc(amountDscToMint);
        vm.stopPrank();
    }

    /////////////////////
    // Redeem Collateral Tests
    /////////////////////

    function testRedeemCollateralWorks() public depositedCollateral {
        vm.startPrank(USER);
        engine.redeemCollateral(weth, AMOUNT_COLLATERAL);
        vm.stopPrank();

        uint256 expectedCollateralBalance = 0;
        (, uint256 collateralBalance) = engine.getAccountInformation(USER);
        assertEq(expectedCollateralBalance, collateralBalance);
    }

    /////////////////////
    // Liquidate Tests
    /////////////////////

    function testNotPossibleToLiquidateAHealthyUser() public depositedCollateral {
        address pirateUser = makeAddr("pirate");
        ERC20Mock(weth).mint(pirateUser, STARTING_WETH_BALANCE);

        // User mints only a little bit of DSC
        vm.prank(USER);
        engine.mintDsc(1000);

        uint256 userHealthFactor = engine.getHealthFactor(USER);
        assert(userHealthFactor > 1e18);
        // USER has a healthfactor of 10e18 > 1e18
        // therefore pirateUser should not be able to liquidate them
        vm.expectRevert(DSCEngine.DSCEngine__HealthFactorOk.selector);
        vm.prank(pirateUser);
        engine.liquidate(weth, USER, 100);
    }

    function testPossibleToLiquidateUnderwaterUser() public depositedCollateral {
        // user deposited 10 ether of weth worth $2k each => total collateral $20k
        // user then mints 5000 DSC => healthFactor = 10k / 5k = 2 OK
        vm.prank(USER);
        engine.mintDsc(5000);
        address pirateUser = makeAddr("pirate");
        ERC20Mock(weth).mint(pirateUser, STARTING_WETH_BALANCE);
        vm.startPrank(pirateUser);
        ERC20Mock(weth).approve(address(engine), STARTING_WETH_BALANCE);
        dsc.approve(address(engine), STARTING_WETH_BALANCE);
        engine.depositCollateral(weth, AMOUNT_COLLATERAL);
        engine.mintDsc(1000);
        vm.stopPrank();

        // at this point suppose price of ETH drops to $999 => healthFactor < 1 UNDERWATER
        MockV3Aggregator(wethUsdPriceFeed).updateAnswer(999e8);
        // at this point pirateUser can liquidate them

        uint256 amountToLiquidate = 500;
        vm.startPrank(pirateUser);
        vm.expectEmit();
        emit DSCEngine.Liquidated(pirateUser, USER, amountToLiquidate);
        engine.liquidate(weth, USER, amountToLiquidate);
        vm.stopPrank();
    }
}
