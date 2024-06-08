// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Test} from "forge-std/Test.sol";

import {Deployers} from "@uniswap/v4-core/test/utils/Deployers.sol";
import {PoolSwapTest} from "v4-core/test/PoolSwapTest.sol";
import {MockERC20} from "solmate/test/utils/mocks/MockERC20.sol";

import {PoolManager} from "v4-core/PoolManager.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";

import {Currency, CurrencyLibrary} from "v4-core/types/Currency.sol";

import {Hooks} from "v4-core/libraries/Hooks.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";

import {MevAuctionHook} from "../src/MevAuctionHook.sol";
import {MevAuctionTaskManager} from "../../mev-auction-avs/contracts/src/MevAuctionTaskManager.sol";
import {HookMiner} from "./utils/HookMiner.sol";

contract TestMevAuctionHook is Test, Deployers {
	using CurrencyLibrary for Currency;

	MockERC20 token; // our token to use in the ETH-TOKEN pool

	// Native tokens are represented by address(0)
	Currency ethCurrency = Currency.wrap(address(0));
	Currency tokenCurrency;

	MevAuctionHook hook;
    MevAuctionTaskManager public mevAuctionTaskManager;
    PoolKey key;

	function setUp() public {
        // Deploy PoolManager and Router contracts
        deployFreshManagerAndRouters();
    
        // Deploy our TOKEN contract
        token = new MockERC20("Test Token", "TEST", 18);
        tokenCurrency = Currency.wrap(address(token));
    
        // Mint a bunch of TOKEN to ourselves and to address(1)
        token.mint(address(this), 1000 ether);
        token.mint(address(1), 1000 ether);

        mevAuctionTaskManager = new MevAuctionTaskManager(
            IRegistryCoordinator(address(0)),
            10 // Replace with your desired task response window block
        );

        mevAuctionTaskManager.initialize(
            IPauserRegistry(address(0)),
            address(this),
            address(this),
            address(this)
        );
    
        // Mine an address that has flags set for
        // the hook functions we want
        uint160 flags = uint160(
            Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG
        );
        (, bytes32 salt) = HookMiner.find(
            address(this),
            flags,
            0,
            type(MevAuctionHook).creationCode,
            abi.encode(manager, "Auction Token", "TEST_MEV_AUCTION")
        );
    
        // Deploy our hook
        hook = new MevAuctionHook{salt: salt}(
            manager,
            "Auction Token",
            "TEST_MEV_AUCTION",
            mevAuctionTaskManager
        );
    
        // Approve our TOKEN for spending on the swap router and modify liquidity router
        // These variables are coming from the `Deployers` contract
        token.approve(address(swapRouter), type(uint256).max);
        token.approve(address(modifyLiquidityRouter), type(uint256).max);
    
        // Initialize a pool
        (key, ) = initPool(
            ethCurrency, // Currency 0 = ETH
            tokenCurrency, // Currency 1 = TOKEN
            hook, // Hook Contract
            3000, // Swap Fees
            SQRT_RATIO_1_1, // Initial Sqrt(P) value = 1
            ZERO_BYTES // No additional `initData`
        );
    }

    function test_addLiquidityAndSwap() public {
        // Set no referrer in the hook data
        bytes memory hookData = hook.getHookData(address(0), address(this));
    
        // How we landed on 0.003 ether here is based on computing value of x and y given
        // total value of delta L (liquidity delta) = 1 ether
        // This is done by computing x and y from the equation shown in Ticks and Q64.96 Numbers lesson
        // View the full code for this lesson on GitHub which has additional comments
        // showing the exact computation and a Python script to do that calculation for you
        modifyLiquidityRouter.modifyLiquidity{value: 0.003 ether}(
            key,
            IPoolManager.ModifyLiquidityParams({
                tickLower: -60,
                tickUpper: 60,
                liquidityDelta: 1 ether
            }),
            hookData
        );
    
        // Now we swap
        // We will swap 0.001 ether for tokens
        // We should get 20% of 0.001 * 10**18 points
        // = 2 * 10**14
        swapRouter.swap{value: 0.001 ether}(
            key,
            IPoolManager.SwapParams({
                zeroForOne: true,
                amountSpecified: -0.001 ether, // Exact input for output swap
                sqrtPriceLimitX96: TickMath.MIN_SQRT_RATIO + 1
            }),
            PoolSwapTest.TestSettings({
                withdrawTokens: true,
                settleUsingTransfer: true,
                currencyAlreadySent: false
            }),
            hookData
        );
    }

    function test_executeSwap() public {
        // Assume an auction has already been created with taskId 1
        uint32 taskId = 1;
        bytes memory hookData = hook.getHookData(address(0), address(this));

        // Simulate winning the auction
        uint256 highestBid = 0.1 ether;
        address highestBidder = address(this);

        // Mock auction details
        hook.swaps(taskId).originalSender = address(1);
        hook.swaps(taskId).amountSpecified = 1 ether;
        hook.swaps(taskId).isCompleted = false;
        hook.swaps(taskId).bidAmount = highestBid;

        // Execute swap
        vm.prank(highestBidder);
        hook.executeSwap{value: highestBid}(
            taskId,
            key,
            IPoolManager.SwapParams({
                zeroForOne: true,
                amountSpecified: -0.001 ether, // Exact input for output swap
                sqrtPriceLimitX96: TickMath.MIN_SQRT_RATIO + 1
            })
        );

        // Verify the swap was completed
        assertTrue(hook.swaps(taskId).isCompleted);

        // Verify the bid amount was stored
        assertEq(hook.swaps(taskId).bidAmount, highestBid);
    }

    function test_afterSwapDistributeToLPs() public {
        uint32 taskId = 1;
        uint256 bidAmount = 0.1 ether;
        bytes memory hookData = abi.encode(taskId, bidAmount);

        // Mock swap completion
        hook.swaps(taskId).isCompleted = true;

        // Call afterSwap to trigger distribution
        vm.prank(address(poolManager));
        hook.afterSwap(
            address(0),
            key,
            IPoolManager.SwapParams({
                zeroForOne: true,
                amountSpecified: -0.001 ether, // Exact input for output swap
                sqrtPriceLimitX96: TickMath.MIN_SQRT_RATIO + 1
            }),
            BalanceDelta(0, 0),
            hookData
        );

        // Check if distribution happened correctly
        // This requires more detailed checks based on the state of liquidity providers
        // Mock data for liquidity providers and verify their balances
        // This is a placeholder and should be replaced with actual checks
    }
}