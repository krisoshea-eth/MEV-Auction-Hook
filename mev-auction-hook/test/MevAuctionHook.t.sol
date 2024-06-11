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
import {AddressAliased} from "../lib/v4-periphery/lib/openzeppelin-contracts/contracts/utils/AddressAliased.sol";

contract TestMevAuctionHook is Test, Deployers {
    using AddressAliased for address;
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
    
        // Mine an address that has flags set for the hook functions we want
        uint160 flags = uint160(Hooks.BEFORE_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG);

        // Generate creation code with constructor arguments
        bytes memory creationCode = type(MevAuctionHook).creationCode;
        bytes memory constructorArgs = abi.encode(address(manager), "Auction Token", "TEST_MEV_AUCTION", address(tm));
        bytes memory creationCodeWithArgs = abi.encodePacked(creationCode, constructorArgs);

        (address hookAddress, bytes32 salt) = HookMiner.find(
            address(this),
            flags,
            creationCode,
            constructorArgs
        );

         // Verify the hook address
         require(uint160(hookAddress) & HookMiner.FLAG_MASK == flags, "Invalid hook address generated");
         emit log_named_address("Hook Address", hookAddress);

        // Deploy our hook
        hook = new MevAuctionHook{salt: salt}(
            manager,
            "Auction Token",
            "TEST_MEV_AUCTION",
            tm
        );
        deal(address(hook), 10 ether);
         // Mint 1000 MockERC20 tokens to the MevAuctionHook contract
         token.mint(address(hook), 1000 ether);
         vm.prank(address(hook));


        // Ensure the deployed address matches the mined address
        require(hookAddress == address(hook), "Deployed hook address does not match mined address");
    
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

         // Approve tokens for pool manager and swap router
    token.approve(address(poolManager), type(uint256).max);
    token.approve(address(swapRouter), type(uint256).max);

    // Ensure the manager has enough tokens
    token.mint(address(poolManager), 1000 ether);

    // Ensure the regular address has enough tokens
    address regularAddress = address(0x123);
    token.mint(regularAddress, 1000 ether);
    vm.prank(regularAddress);
    token.approve(address(swapRouter), type(uint256).max);

    // Log balances and approvals
    emit log_named_uint("Pool Manager Token Balance", token.balanceOf(address(poolManager)));
    emit log_named_uint("Regular Address Token Balance", token.balanceOf(regularAddress));
    emit log_named_uint("Token Allowance for Swap Router by Regular Address", token.allowance(regularAddress, address(swapRouter)));
    emit log_named_uint("Token Allowance for Pool Manager by this contract", token.allowance(address(this), address(poolManager)));

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
        // Define an outside address (e.g., a user)
        address outsideAddress = address(0x123);
    
        // Set no referrer in the hook data
        bytes memory hookData = abi.encode(address(0), outsideAddress);
        
        // Ensure the manager has enough Ether
        vm.deal(address(manager), 10 ether);
        
        // Ensure the manager has enough tokens and approves them for spending
        uint256 tokenAmount = 10 ether;
        token.mint(address(manager), tokenAmount);
        vm.prank(address(manager));
        token.approve(address(modifyLiquidityRouter), tokenAmount);
        
        // Ensure the outside address has enough tokens and approves them for spending
        token.mint(outsideAddress, tokenAmount);
        vm.prank(outsideAddress);
        token.approve(address(swapRouter), tokenAmount);
        
        vm.startPrank(address(manager));
        emit log_named_uint("Manager ETH balance before add liquidity", address(manager).balance);
        emit log_named_uint("Manager TOKEN balance before add liquidity", token.balanceOf(address(manager)));
        
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
        
        emit log_named_uint("Manager ETH balance after add liquidity", address(manager).balance);
        emit log_named_uint("Manager TOKEN balance after add liquidity", token.balanceOf(address(manager)));
        vm.stopPrank();
        
        // Swap tokens by the outside address
        vm.startPrank(outsideAddress);
        emit log_named_uint("Outside address ETH balance before swap", outsideAddress.balance);
        emit log_named_uint("Outside address TOKEN balance before swap", token.balanceOf(outsideAddress));
        
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
        
        emit log_named_uint("Outside address ETH balance after swap", outsideAddress.balance);
        emit log_named_uint("Outside address TOKEN balance after swap", token.balanceOf(outsideAddress));
        vm.stopPrank();
    }

    function test_executeSwap() public {
        uint32 taskId;
        bytes memory hookData;
        
        uint256 highestBid = 0.1 ether;
        address highestBidder = address(this);
        vm.deal(highestBidder, 10 ether);
    
        // Mint tokens to the highest bidder and approve
        token.mint(highestBidder, 1000 ether);
        vm.prank(highestBidder);
        token.approve(address(tm), 1000 ether);
    
        // Regular address initiates a swap, triggering beforeSwap and creating the auction
        address regularAddress = address(0x123);
        vm.deal(regularAddress, 10 ether);
        token.mint(regularAddress, 1000 ether);
        vm.prank(regularAddress);
        token.approve(address(swapRouter), 1 ether);
    
        // Ensure the MevAuctionHook contract has enough ETH
        vm.deal(address(hook), 1 ether); // Adjust the amount as needed
    
        // Regular address initiates the swap
        vm.prank(regularAddress);
        swapRouter.swap{gas: 3000000}(
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
    
        // Retrieve the created taskId from the swap
        taskId = tm.latestTaskNum();
        hookData = abi.encode(taskId, address(this));
    
        // Submit the highest bid
        vm.prank(highestBidder);
        tm.submitBid(taskId, highestBid);
    
        // Warp to the end of the auction period
        vm.warp(block.timestamp + 10 minutes);
    
        // Execute swap by the highest bidder
        vm.prank(highestBidder);
        hook.executeSwap{value: highestBid, gas: 3000000}(
            taskId
        );
    
        // Verify the swap was completed
        MevAuctionHook.SwapDetails memory completedSwap = hook.getSwapDetails(taskId);
        assertTrue(completedSwap.isCompleted);
        assertEq(completedSwap.bidAmount, highestBid);
    }
    
    
    

    function test_afterSwapDistributeToLPs() public {
        uint32 taskId;
        uint256 highestBid = 0.1 ether;
        address highestBidder = address(this);
        vm.deal(highestBidder, 10 ether);

        // Regular address initiates a swap, triggering beforeSwap and creating the auction
        address regularAddress = address(0x123);
        vm.deal(regularAddress, 10 ether);
        vm.prank(regularAddress);
        swapRouter.swap{value: 0.001 ether, gas: 3000000}(
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
            new bytes(0)
        );

        // Retrieve the created taskId from the swap
        taskId = tm.latestTaskNum();

        // Submit the highest bid
        vm.prank(highestBidder);
        tm.submitBid(taskId, highestBid);

        // Warp to the end of the auction period
        vm.warp(block.timestamp + 10 minutes);

        // Execute swap by the highest bidder
        vm.prank(highestBidder);
        hook.executeSwap{value: highestBid, gas: 3000000}(
            taskId
        );

        // Call afterSwap
        bytes memory hookData = abi.encode(taskId, highestBid);
        vm.prank(address(manager));
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
