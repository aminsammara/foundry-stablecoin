//SPDX-License-Identifier: MIT

pragma solidity ^0.8.19;

import {Script} from "forge-std/Script.sol";
import {MockV3Aggregator} from "../test/mocks/MockV3Aggregator.sol";
import {ERC20Mock} from "@openzeppelin/contracts/mocks/token/ERC20Mock.sol";

contract HelperConfig is Script {
    struct NetworkConfig {
        address wethUsdPriceFeed;
        address usdcPriceFeed;
        address weth;
        address usdc;
        uint256 deployerKey;
    }

    uint8 public constant DECIMALS = 8;
    int256 public constant WETH_USD_PRICE = 2000e8;
    int256 public constant USDC_USD_PRICE = 1e8;
    uint256 public constant DEFAULT_ANVIL_KEY = 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80;

    NetworkConfig public activeNetworkConfig;

    constructor() {
        if (block.chainid == 1115511) {
            activeNetworkConfig = getSepoliaEthConfig();
        } else {
            activeNetworkConfig = getOrCreateAnvilEthConfig();
        }
    }

    function getSepoliaEthConfig() public view returns (NetworkConfig memory) {
        return NetworkConfig({
            wethUsdPriceFeed: 0x694AA1769357215DE4FAC081bf1f309aDC325306,
            usdcPriceFeed: 0xA2F78ab2355fe2f984D808B5CeE7FD0A93D5270E,
            weth: 0x7b79995e5f793A07Bc00c21412e50Ecae098E7f9,
            usdc: 0x1c7D4B196Cb0C7B01d743Fbc6116a902379C7238,
            deployerKey: vm.envUint("PRIVATE_KEY")
        });
    }

    function getOrCreateAnvilEthConfig() public returns (NetworkConfig memory) {
        if (activeNetworkConfig.wethUsdPriceFeed != address(0)) {
            return activeNetworkConfig;
        }
        vm.startBroadcast();
        MockV3Aggregator wethUsdPriceFeed = new MockV3Aggregator(DECIMALS, WETH_USD_PRICE);
        MockV3Aggregator usdcPriceFeed = new MockV3Aggregator(DECIMALS, USDC_USD_PRICE);
        ERC20Mock wethMock = new ERC20Mock();
        wethMock.mint(msg.sender, 1000e8);
        ERC20Mock usdcMock = new ERC20Mock();
        usdcMock.mint(msg.sender, 1000e8);
        vm.stopBroadcast();

        return NetworkConfig({
            wethUsdPriceFeed: address(wethUsdPriceFeed),
            usdcPriceFeed: address(usdcPriceFeed),
            weth: address(wethMock),
            usdc: address(usdcMock),
            deployerKey: DEFAULT_ANVIL_KEY
        });
    }
}
