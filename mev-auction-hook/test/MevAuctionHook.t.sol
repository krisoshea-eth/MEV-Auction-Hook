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
import {BalanceDelta, BalanceDeltaLibrary, toBalanceDelta} from "v4-core/types/BalanceDelta.sol";
import {BeforeSwapDelta} from "v4-core/types/BeforeSwapDelta.sol";

import {MevAuctionHook} from "../src/MevAuctionHook.sol";
import {MevAuctionTaskManager} from "../mev-auction-avs/contracts/src/MevAuctionTaskManager.sol";
import {IMevAuctionTaskManager} from "../mev-auction-avs/contracts/src/IMevAuctionTaskManager.sol";
import {MevAuctionServiceManager} from "../mev-auction-avs/contracts/src/MevAuctionServiceManager.sol";
import {IRegistryCoordinator} from "../mev-auction-avs/contracts/lib/eigenlayer-middleware/src/interfaces/IRegistryCoordinator.sol"; // Correct the path if necessary
import {IPauserRegistry} from "../mev-auction-avs/contracts/lib/eigenlayer-middleware/lib/eigenlayer-contracts/src/contracts/interfaces/IPauserRegistry.sol";
import {BLSMockAVSDeployer} from "../mev-auction-avs/contracts/lib/eigenlayer-middleware/test/utils/BLSMockAVSDeployer.sol";
import {HookMiner} from "./utils/HookMiner.sol";
import {TransparentUpgradeableProxy} from "../mev-auction-avs/contracts/lib/eigenlayer-middleware/lib/openzeppelin-contracts/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {Address} from "../mev-auction-avs/contracts/lib/eigenlayer-middleware/lib/openzeppelin-contracts/contracts/utils/Address.sol";

contract TestMevAuctionHook is Test, Deployers {
    MevAuctionServiceManager sm;
    MevAuctionServiceManager smImplementation;
    MevAuctionTaskManager tm;
    MevAuctionTaskManager tmImplementation;
    BLSMockAVSDeployer avsDeployer;

    uint32 public constant TASK_RESPONSE_WINDOW_BLOCK = 30;
    address aggregator = address(uint160(uint256(keccak256(abi.encodePacked("aggregator")))));
    address generator = address(uint160(uint256(keccak256(abi.encodePacked("generator")))));
    
    using CurrencyLibrary for Currency;
    using BalanceDeltaLibrary for BalanceDelta;

	MockERC20 token; // our token to use in the ETH-TOKEN pool

	// Native tokens are represented by address(0)
	Currency ethCurrency = Currency.wrap(address(0));
	Currency tokenCurrency;

	MevAuctionHook hook;
    IPoolManager poolManager; // Declare poolManager

    uint160 constant SQRT_RATIO_1_1 = 79228162514264337593543950336;

	function setUp() public {
        emit log("Setting up BLSMockAVSDeployer");
        avsDeployer = new BLSMockAVSDeployer();
        avsDeployer._setUpBLSMockAVSDeployer();
        emit log("BLSMockAVSDeployer set up");
        
        address registryCoordinator = address(avsDeployer.registryCoordinator());
        address proxyAdmin = address(avsDeployer.proxyAdmin());
        address pauserRegistry = address(avsDeployer.pauserRegistry());
        address registryCoordinatorOwner = avsDeployer.registryCoordinatorOwner();

        emit log_named_address("Registry Coordinator", registryCoordinator);
        emit log_named_address("Proxy Admin", proxyAdmin);
        emit log_named_address("Pauser Registry", pauserRegistry);
        emit log_named_address("Registry Coordinator Owner", registryCoordinatorOwner);

        emit log("Deploying MevAuctionTaskManager implementation");
        tmImplementation = new MevAuctionTaskManager(
            IRegistryCoordinator(registryCoordinator),
            TASK_RESPONSE_WINDOW_BLOCK
        );
        emit log("MevAuctionTaskManager implementation deployed");

        // Third, upgrade the proxy contracts to use the correct implementation contracts and initialize them.
        emit log("Deploying TransparentUpgradeableProxy for MevAuctionTaskManager");
        tm = MevAuctionTaskManager(
            address(
                new TransparentUpgradeableProxy(
                    address(tmImplementation),
                    proxyAdmin,
                    abi.encodeWithSelector(
                        tm.initialize.selector,
                        pauserRegistry,
                        registryCoordinatorOwner,
                        aggregator,
                        generator
                    )
                )
            )
        );
        emit log("TransparentUpgradeableProxy for MevAuctionTaskManager deployed");
        
        
        // Deploy PoolManager and Router contracts
        deployFreshManagerAndRouters();
    
        // Deploy our TOKEN contract
        token = new MockERC20("Test Token", "TEST", 18);
        tokenCurrency = Currency.wrap(address(token));
    
        // Mint a bunch of TOKEN to ourselves and to address(1)
        token.mint(address(this), 1000 ether);
        token.mint(address(1), 1000 ether);
    
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
            tm
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

    function testCreateNewTask() public {
        bytes memory quorumNumbers = new bytes(0);
        vm.prank(generator);
        tm.createNewTask(2, 100, quorumNumbers);
        assertEq(tm.latestTaskNum(), 1);
    }

    function testSubmitBid() public {
        bytes memory quorumNumbers = new bytes(0);
        vm.prank(generator);
        tm.createNewTask(2, 100, quorumNumbers);

        vm.prank(address(1));
        tm.submitBid(0, 1 ether);

        IMevAuctionTaskManager.Auction memory auction = tm.getAuctionDetails(0);
        assertEq(auction.highestBid, 1 ether);
        assertEq(auction.highestBidder, address(1));
    }

    function testCompleteAuction() public {
        bytes memory quorumNumbers = new bytes(0);
        vm.prank(generator);
        tm.createNewTask(2, 100, quorumNumbers);

        vm.prank(address(1));
        tm.submitBid(0, 1 ether);

        // Increase the time to after the auction end time
        vm.warp(block.timestamp + 3);

        vm.prank(address(2));
        tm.completeAuction(0);

        IMevAuctionTaskManager.Auction memory auction = tm.getAuctionDetails(0);
        assertTrue(auction.completed);
    }

    function testGetAuctionDetails() public {
        bytes memory quorumNumbers = new bytes(0);
        vm.prank(generator);
        tm.createNewTask(2, 100, quorumNumbers);

        vm.prank(address(1));
        tm.submitBid(0, 1 ether);

        IMevAuctionTaskManager.Auction memory auction = tm.getAuctionDetails(0);
        assertEq(auction.highestBid, 1 ether);
        assertEq(auction.highestBidder, address(1));
        assertEq(auction.endTime, block.timestamp + 2);
        assertFalse(auction.completed);
    }

    function testMultipleBids() public {
        bytes memory quorumNumbers = new bytes(0);
        vm.prank(generator);
        tm.createNewTask(2, 100, quorumNumbers);

        vm.prank(address(1));
        tm.submitBid(0, 1 ether);

        vm.prank(address(2));
        tm.submitBid(0, 2 ether);

        IMevAuctionTaskManager.Auction memory auction = tm.getAuctionDetails(0);
        assertEq(auction.highestBid, 2 ether);
        assertEq(auction.highestBidder, address(2));
    }

    function testAuctionFailsAfterEndTime() public {
        bytes memory quorumNumbers = new bytes(0);
        vm.prank(generator);
        tm.createNewTask(2, 100, quorumNumbers);

        vm.prank(address(1));
        tm.submitBid(0, 1 ether);

        // Increase the time to after the auction end time
        vm.warp(block.timestamp + 3);

        vm.prank(address(2));
        vm.expectRevert("Auction has ended");
        tm.submitBid(0, 2 ether);
    }

    function testBidNotHigherThanCurrent() public {
        bytes memory quorumNumbers = new bytes(0);
        vm.prank(generator);
        tm.createNewTask(2, 100, quorumNumbers);

        vm.prank(address(1));
        tm.submitBid(0, 1 ether);

        vm.prank(address(2));
        vm.expectRevert("Bid is not higher than current highest bid");
        tm.submitBid(0, 0.5 ether);
    }

    function test_addLiquidityAndSwap() public {
        // Set no referrer in the hook data
        bytes memory hookData = abi.encode(address(0), address(this));
    
        // Add liquidity
        modifyLiquidityRouter.modifyLiquidity{value: 0.003 ether}(
            key,
            IPoolManager.ModifyLiquidityParams({
                tickLower: -60,
                tickUpper: 60,
                liquidityDelta: 1 ether,
                salt: 0
            }),
            hookData
        );
    
        // Swap tokens
        swapRouter.swap{value: 0.001 ether}(
            key,
            IPoolManager.SwapParams({
                zeroForOne: true,
                amountSpecified: -0.001 ether,
                sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            }),
            PoolSwapTest.TestSettings({
               takeClaims: true,
               settleUsingBurn: true
            }),
            hookData
        );
    }

    function test_executeSwap() public {
        uint32 taskId = 1;
        bytes memory hookData = abi.encode(address(0), address(this));

        uint256 highestBid = 0.1 ether;
        address highestBidder = address(this);

        // Initialize swap details
        MevAuctionHook.SwapDetails memory swapDetails = MevAuctionHook.SwapDetails({
            originalSender: address(1),
            amountSpecified: 1 ether,
            isCompleted: false,
            bidAmount: highestBid
        });
        hook.setSwapDetails(taskId, swapDetails);

        // Execute swap
        vm.prank(highestBidder);
        hook.executeSwap{value: highestBid}(
            taskId,
            key,
            IPoolManager.SwapParams({
                zeroForOne: true,
                amountSpecified: -0.001 ether,
                sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            })
        );

        // Verify the swap was completed
        MevAuctionHook.SwapDetails memory completedSwap = hook.getSwapDetails(taskId);
        assertTrue(completedSwap.isCompleted);
        assertEq(completedSwap.bidAmount, highestBid);
    }

    function test_afterSwapDistributeToLPs() public {
        uint32 taskId = 1;
        uint256 bidAmount = 0.1 ether;
        bytes memory hookData = abi.encode(taskId, bidAmount);

        // Initialize swap details
        MevAuctionHook.SwapDetails memory swapDetails = MevAuctionHook.SwapDetails({
            originalSender: address(0),
            amountSpecified: 0,
            isCompleted: true,
            bidAmount: bidAmount
        });
        hook.setSwapDetails(taskId, swapDetails);

        // Call afterSwap
        vm.prank(address(poolManager));
        hook.afterSwap(
            address(0),
            key,
            IPoolManager.SwapParams({
                zeroForOne: true,
                amountSpecified: -0.001 ether,
                sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            }),
            toBalanceDelta(0, 0),
            hookData
        );

        // Verify distribution
        MevAuctionHook.SwapDetails memory completedSwap = hook.getSwapDetails(taskId);
        assertTrue(completedSwap.isCompleted);
    }
}