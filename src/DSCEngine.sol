// SPDX-License-Identifier: MIT

// Layout of Contract:
// version
// imports
// interfaces, libraries, contracts
// errors
// Type declarations
// State variables
// Events
// Modifiers
// Functions

// Layout of Functions:
// constructor
// receive function (if exists)
// fallback function (if exists)
// external
// public
// internal
// private
// internal & private view & pure functions
// external & public view & pure functions

pragma solidity ^0.8.19;

import {DecentralizedStableCoin} from "./DecentralizedStableCoin.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";
import {OracleLib} from "./libraries/OracleLib.sol";

/*
 * @title DSCEngine
 * @author Amin Sammara
 *
 * The system is designed to be as minimal as possible, and have the tokens maintain a 1 token == $1 peg at all times.
 * This is a stablecoin with the properties:
 * - Exogenously Collateralized
 * - Dollar Pegged
 * - Algorithmically Stable
 *
 * It is similar to DAI if DAI had no governance, no fees, and was backed by only WETH and WBTC.
 *
 * Our DSC system should always be "overcollateralized". At no point, should the value of
 * all collateral < the $ backed value of all the DSC.
 *
 * @notice This contract is the core of the Decentralized Stablecoin system. It handles all the logic
 * for minting and redeeming DSC, as well as depositing and withdrawing collateral.
 * @notice This contract is based on the MakerDAO DSS system
 */

contract DSCEngine is ReentrancyGuard {
    /////////////////
    // Errors
    /////////////////

    error DSCEngine__NeedsMoreThanZero();
    error DSCEngine__TokenAddressesAndPriceFeedAddressesNotSameLength();
    error DSCEngine__NotAllowedToken();
    error DSCEngine__TransferFailed();
    error DSCEngine__BreaksHealthFactor(uint256 healthFactor);
    error DSCEngine__MintFailed();
    error DSCEngine__HealthFactorOk();
    error DSCEnging__HealthFactorNotImproved();

    /////////////////
    // Types
    /////////////////
    // adds all methods of OracleLib to all instances of the contract AggregatorV3Interface
    using OracleLib for AggregatorV3Interface;

    /////////////////
    // State Variables
    /////////////////

    uint256 private constant ADDITIONAL_FEED_PRECISION = 1e10;
    uint256 private constant PRECISION = 1e18;
    uint256 private constant LIQUIDATION_THRESHOLD = 50;
    uint256 private constant LIQUIDATION_PRECISION = 100;
    uint256 private constant MIN_HEALTH_FACTOR = 1e18;
    uint256 private constant LIQUIDATION_BONUS = 10; // this is 10%
    uint256 private constant MAX_HEALTH_FACTOR = type(uint256).max;

    mapping(address addressToken => address priceFeed) private s_priceFeeds;
    mapping(address user => mapping(address token => uint256 amount)) private s_collateralDeposited;
    mapping(address user => uint256 amountDscMinted) private s_DSCMinted;
    // I use this to be able to loop through collateral tokens and calculate USD value of collateral
    address[] private s_collateralTokens;

    DecentralizedStableCoin private immutable i_dsc;

    /////////////////
    // Events
    /////////////////

    event CollateralDeposited(address indexed user, address indexed token, uint256 indexed amount);
    event CollateralRedeemed(
        address indexed redeemedFrom, address indexed redeemedTo, address indexed token, uint256 amount
    );
    event Liquidated(address indexed liquidator, address indexed liquidatedUser, uint256 indexed amountLiquidatd);

    /////////////////
    // Modifiers
    /////////////////

    modifier moreThanZero(uint256 amount) {
        if (amount == 0) {
            revert DSCEngine__NeedsMoreThanZero();
        }
        _;
    }

    modifier isAllowedToken(address tokenContractAddress) {
        if (s_priceFeeds[tokenContractAddress] == address(0)) {
            revert DSCEngine__NotAllowedToken();
        }
        _;
    }

    /////////////////
    // Functions
    /////////////////

    constructor(address[] memory tokenAddresses, address[] memory priceFeedAddresses, address dscAddress) {
        if (tokenAddresses.length != priceFeedAddresses.length) {
            revert DSCEngine__TokenAddressesAndPriceFeedAddressesNotSameLength();
        }

        for (uint256 i = 0; i < tokenAddresses.length; i++) {
            s_priceFeeds[tokenAddresses[i]] = priceFeedAddresses[i];
            s_collateralTokens.push(tokenAddresses[i]);
        }

        i_dsc = DecentralizedStableCoin(dscAddress);
    }

    /////////////////
    // External Functions
    /////////////////

    /**
     *
     * @param tokenCollaterallAddress The address of the token to deposit as collateral
     * @param amountCollateral The amount of collateral to deposit
     * @param amountDscToMint Amount of DSC to mint
     * @notice this function deposits collateral and mints Dsc in one go
     */
    function depositCollateralAndMintDsc(
        address tokenCollaterallAddress,
        uint256 amountCollateral,
        uint256 amountDscToMint
    ) external {
        depositCollateral(tokenCollaterallAddress, amountCollateral);
        mintDsc(amountDscToMint);
    }

    /*
     * @param tokenCollateralAddress The address of the token to deposit as collateral
     * @param amountCollateral The amount of collateral to deposit
     * @notice follows CEI - checks, effects, interactions
     */
    function depositCollateral(address tokenCollateralAddress, uint256 amountCollateral)
        public
        moreThanZero(amountCollateral)
        isAllowedToken(tokenCollateralAddress)
        nonReentrant
    {
        s_collateralDeposited[msg.sender][tokenCollateralAddress] += amountCollateral;
        emit CollateralDeposited(msg.sender, tokenCollateralAddress, amountCollateral);
        bool success = IERC20(tokenCollateralAddress).transferFrom(msg.sender, address(this), amountCollateral);
        if (!success) revert DSCEngine__TransferFailed();
    }

    function redeemCollateralForDsc(address tokenCollateralAddrress, uint256 amountCollateral, uint256 amountDscToBurn)
        external
    {
        burnDsc(amountDscToBurn);
        redeemCollateral(tokenCollateralAddrress, amountCollateral);
    }

    // in order to redeem collateral:
    // 1. health factor must be > 1 after they redeem
    function redeemCollateral(address tokenCollateralAddress, uint256 amountCollateral)
        public
        moreThanZero(amountCollateral)
        nonReentrant
    {
        _redeemCollateral(msg.sender, msg.sender, tokenCollateralAddress, amountCollateral);
    }

    /**
     *
     * @param amountDscToMint Amount of DSC to mint
     * @notice they must have more collateral value more than the minimum threshold
     */
    function mintDsc(uint256 amountDscToMint) public moreThanZero(amountDscToMint) nonReentrant {
        s_DSCMinted[msg.sender] += amountDscToMint;
        // if they minted too much
        _revertIfHealthFactorIsBroken(msg.sender);
        bool minted = i_dsc.mint(msg.sender, amountDscToMint);
        if (!minted) revert DSCEngine__MintFailed();
    }

    function burnDsc(uint256 amountToBurn) public moreThanZero(amountToBurn) {
        _burnDsc(amountToBurn, msg.sender, msg.sender);
    }

    // If someone is almost undercollateralized, we'll pay you to liquidate them!
    // If someone has %75 of collateral backing $50 of DSC
    // we'll let a liquidator take the $75 collateral in return for paying off the $50 DSC

    /**
     *
     * @param collateralTokenAddress The erc20 collateral address to liquidate from the user
     * @param user the user who broken the health factor. Their health factor must be below MIN_HEALTH_FACTOR
     * @param debtToCover The amount of DSC you want to burn to improve the users health factor
     * @notice You can partially liquidate a user
     * @notice You will get a bonus for liquidating an underwater user
     * @notice This function working assumes the protocol will be roughly 200% overcollateralized in order for this to work.
     * @notice A known bug would be if the protoocl is 100% or less collateralized then we wouldn't be able to incentivize liquidators.
     */
    function liquidate(address collateralTokenAddress, address user, uint256 debtToCover)
        external
        moreThanZero(debtToCover)
        nonReentrant
    {
        // check health factor of user
        uint256 startingUserHealthFactor = _healthFactor(user);
        if (startingUserHealthFactor >= MIN_HEALTH_FACTOR) {
            revert DSCEngine__HealthFactorOk();
        }
        // We should burn the DSC "debt"
        // and take their collateral

        // how much ETH/Token is debtToCover (which is amount of DSC in wei) worth?
        uint256 tokenAmountFromDebtCovered = getTokenAmountFromUsd(collateralTokenAddress, debtToCover);
        // let's also give them a bonus of 10%.. i.e. $110 of WETH for 100 DSC
        // we should impelement a featureto liquidate in the event the protocol is insolvent
        // and sweep extra amounts into a treasury (but we're not gonna do that)
        uint256 bonusCollateral = ((tokenAmountFromDebtCovered * LIQUIDATION_BONUS) / LIQUIDATION_PRECISION);
        uint256 totalCollateralToRedeem = tokenAmountFromDebtCovered + bonusCollateral;
        _redeemCollateral(user, msg.sender, collateralTokenAddress, totalCollateralToRedeem);
        // burn the DSC
        _burnDsc(debtToCover, user, msg.sender);
        uint256 endingHealthFactor = _healthFactor(user);
        if (endingHealthFactor <= startingUserHealthFactor) revert DSCEnging__HealthFactorNotImproved();
        emit Liquidated(msg.sender, user, debtToCover);
        // revert if liquidator's health factor deteriorates below minimum health factor as a result of liquidating someone
        _revertIfHealthFactorIsBroken(msg.sender);
    }

    /////////////////
    // Private and Internal View Functions
    /////////////////

    function _burnDsc(uint256 amountToBurn, address onBehalfOf, address dscFrom) private {
        s_DSCMinted[onBehalfOf] -= amountToBurn;
        bool success = i_dsc.transferFrom(dscFrom, address(this), amountToBurn);
        if (!success) revert DSCEngine__TransferFailed();
        i_dsc.burn(amountToBurn);
    }

    function _redeemCollateral(address from, address to, address tokenCollateralAddress, uint256 amountCollateral)
        private
    {
        s_collateralDeposited[from][tokenCollateralAddress] -= amountCollateral;
        emit CollateralRedeemed(from, to, tokenCollateralAddress, amountCollateral);

        bool success = IERC20(tokenCollateralAddress).transfer(to, amountCollateral);

        if (!success) revert DSCEngine__TransferFailed();
        _revertIfHealthFactorIsBroken(msg.sender);
    }

    function _getAccountInformation(address user)
        private
        view
        returns (uint256 totalDscMinted, uint256 collateralValueInUsd)
    {
        totalDscMinted = s_DSCMinted[user];
        collateralValueInUsd = getAccountCollateralValueInUsd(user);
        return (totalDscMinted, collateralValueInUsd);
    }

    /**
     *
     * @param user address of the user
     * @notice returns how close to a liquidation a user is.
     * If a user health factor goes below 1, they can get liquidated
     */
    function _healthFactor(address user) private view returns (uint256) {
        // had to add this line since if a user just deposits then redeems collateral, the _healthFactor calculation divides by a zero.
        if (s_DSCMinted[user] == 0) return MAX_HEALTH_FACTOR;

        (uint256 totalDscMinted, uint256 collateralValueInUsd) = _getAccountInformation(user);
        uint256 collateralAdjustedForThreshold = (collateralValueInUsd * LIQUIDATION_THRESHOLD) / LIQUIDATION_PRECISION;
        // 20000000000000000000000
        // 10000000000000000000000 * 1e18 / 1000
        return (collateralAdjustedForThreshold * PRECISION) / (totalDscMinted * PRECISION);
    }

    // 1. Check Health factor (do they have enough collateral)
    function _revertIfHealthFactorIsBroken(address user) internal view {
        uint256 userHealthFactor = _healthFactor(user);
        if (userHealthFactor < MIN_HEALTH_FACTOR) {
            revert DSCEngine__BreaksHealthFactor(userHealthFactor);
        }
    }

    /////////////////
    // Public and External View Functions
    /////////////////

    function getHealthFactor(address user) external view returns (uint256) {
        return _healthFactor(user);
    }

    function getTokenAmountFromUsd(address tokenCollateralAddress, uint256 usdAmountInWei)
        public
        view
        returns (uint256)
    {
        AggregatorV3Interface priceFeed = AggregatorV3Interface(s_priceFeeds[tokenCollateralAddress]);
        (, int256 price,,,) = priceFeed.staleCheckLatestRoundData();
        return ((usdAmountInWei * PRECISION) / (uint256(price) * ADDITIONAL_FEED_PRECISION));
    }

    function getAccountCollateralValueInUsd(address user) public view returns (uint256 totalCollateralValueInUsd) {
        // loop through each collateral token, get amount they deposited
        // map it to price to get USD value
        for (uint256 i = 0; i < s_collateralTokens.length; i++) {
            address token = s_collateralTokens[i];
            uint256 collateralAmount = s_collateralDeposited[user][token];
            totalCollateralValueInUsd += _getUsdValue(token, collateralAmount);
        }
        return totalCollateralValueInUsd;
    }

    function _getUsdValue(address token, uint256 amount) public view returns (uint256) {
        AggregatorV3Interface priceFeed = AggregatorV3Interface(s_priceFeeds[token]);
        (, int256 price,,,) = priceFeed.staleCheckLatestRoundData();
        // The returned value from CL (at least for ETH and BTC) is 8 decimals
        // 1 ETH = $1000, returned value will be 1000 * 1e18;
        return ((ADDITIONAL_FEED_PRECISION * uint256(price)) * amount) / PRECISION; // ((1000 * 1e8 * 1e10) * 1e18) / 1e18;
            // suppose ETH is $3200.5
            // ((1e10 * 320050000000) * 1) / 1e18
            // == 320050000000 / 1e8 = 3200.5AXc
    }

    function getAccountInformation(address user)
        external
        view
        returns (uint256 totalDscMinted, uint256 collateralValueInUsd)
    {
        (totalDscMinted, collateralValueInUsd) = _getAccountInformation(user);
    }

    function getDscMintedInformation(address user) public view returns (uint256) {
        return s_DSCMinted[user];
    }

    function getCollateralTokens() external view returns (address[] memory) {
        return s_collateralTokens;
    }

    function getCollateralBalanceOfUser(address user, address token) external view returns (uint256) {
        return s_collateralDeposited[user][token];
    }

    function getCollateralTokenPriceFeedAddress(address token) public view returns (address) {
        return s_priceFeeds[token];
    }
}
