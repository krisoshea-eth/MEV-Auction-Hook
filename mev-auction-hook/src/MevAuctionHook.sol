// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {BaseHook} from "v4-periphery/BaseHook.sol";
import {ERC20} from "solmate/tokens/ERC20.sol";

import {CurrencyLibrary, Currency} from "v4-core/types/Currency.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {BalanceDeltaLibrary, BalanceDelta} from "v4-core/types/BalanceDelta.sol";

import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";

import {Hooks} from "v4-core/libraries/Hooks.sol";
import {IMevAuctionTaskManager} from "../../mev-auction-avs/contracts/src/IMevAuctionTaskManager.sol";

contract MevAuctionHook is BaseHook, ERC20 {
	// Use CurrencyLibrary and BalanceDeltaLibrary
	// to add some helper functions over the Currency and BalanceDelta
	// data types 
	using CurrencyLibrary for Currency;
    using BalanceDeltaLibrary for BalanceDelta;

    bool public hooksDisabled;
    IMevAuctionTaskManager public mevAuctionTaskManager;
    IPoolManager public poolManager;

    struct SwapDetails {
        address originalSender;
        uint256 amountSpecified;
        bool isCompleted;
        uint256 bidAmount;
    }

	// Keeping track of user => auctionWinner
	mapping(address => address) public auctionWinner;
    // keeping track of swap details
    mapping(uint32 => SwapDetails) public swaps;

    modifier onlyWhenHooksEnabled() {
        require(!hooksDisabled, "Hooks are disabled");
        _;
    }

	// Initialize BaseHook and ERC20
    constructor(
        IPoolManager _manager,
        string memory _name,
        string memory _symbol,
        IMevAuctionTaskManager _mevAuctionTaskManager
    ) BaseHook(_manager) ERC20(_name, _symbol, 18) {
        mevAuctionTaskManager = _mevAuctionTaskManager;
        poolManager = _manager;
    }

	// Set up hook permissions to return `true`
	// for the two hook functions we are using
    function getHookPermissions()
        public
        pure
        override
        returns (Hooks.Permissions memory)
    {
        return
            Hooks.Permissions({
                beforeInitialize: false,
                afterInitialize: false,
                beforeAddLiquidity: false,
                beforeRemoveLiquidity: false,
                afterAddLiquidity: false,
                afterRemoveLiquidity: false,
                beforeSwap: true,
                afterSwap: true,
                beforeDonate: false,
                afterDonate: false
            });
    }

    // Make a call to the eigenlayer AVS to initiate the auction
	function beforeSwap(
        address sender,
        PoolKey calldata key,
        IPoolManager.SwapParams calldata swapParams,
        BalanceDelta delta,
        bytes calldata hookData
    ) external override onlyWhenHooksEnabled poolManagerOnly returns (bytes4) {
		// 1: call the eigenlayer avs to trigger the beginning of the auction
        mevAuctionTaskManager.createNewTask(swapParams.amountSpecified, 10 minutes, 50, hookData);

        // 2: store swap detials
        swaps[taskManager.latestTaskNum()] = SwapDetails({
            originalSender: sender,
            amountSpecified: swapParams.amountSpecified,
            isCompleted: false,
            bidAmount: 0
        });

		return this.beforeSwap.selector;
	}
	
    // Distribute arbitrageur auction profits amongst pool Lps
	function afterSwap(
        address,
        PoolKey calldata key,
        IPoolManager.SwapParams calldata swapParams,
        BalanceDelta delta,
        bytes calldata hookData
    ) external override onlyWhenHooksEnabled poolManagerOnly returns (bytes4) {

        // Handle distribution of bid amount to liquidity providers
        (uint32 taskId, uint256 bidAmount) = abi.decode(hookData, (uint32, uint256));

        require(swaps[taskId].isCompleted, "Swap not completed by arbitrageur");

        // Distribute the bid amount to liquidity providers
        distributeToLPs(bidAmount, key);
        
        return this.afterSwap.selector;
	}

    function executeSwap(
        uint32 taskId,
        PoolKey calldata key,
        IPoolManager.SwapParams calldata swapParams
    ) external payable {
        // Get auction details to verify caller
        IMevAuctionTaskManager.Auction memory auction = mevAuctionTaskManager.getAuctionDetails(taskId);
        require(msg.sender == auction.highestBidder, "Only the highest bidder can execute the swap");
        require(msg.value == auction.highestBid, "Incorrect bid amount");

        // Mark the swap as completed and store the bid amount
        swaps[taskId].isCompleted = true;
        swaps[taskId].bidAmount = msg.value;

        // Disable hooks temporarily
        hooksDisabled = true;

        // Execute the swap and capture the output amount
        uint256 outputAmount;
        {
            // Temporarily disable transfer fees and other hooks
            // Call the swap function and capture the output amount
            outputAmount = IPoolManager(manager).swap(key, swapParams);
        }

        // Enable hooks again
        hooksDisabled = false;

         // Send swap output to the original sender
         ERC20 outputToken = ERC20(swapParams.zeroForOne ? key.currency1 : key.currency0);
         outputToken.transfer(swaps[taskId].originalSender, outputAmount);
    }
    
    function distributeToLPs(uint256 amount, PoolKey calldata key) internal {
        uint256 totalLiquidity = poolManager.getTotalLiquidity(key); // Function to get total liquidity in the pool
        address[] memory liquidityProviders = poolManager.getAllLiquidityProviders(key); // Function to get all LPs in the pool

        for (uint256 i = 0; i < liquidityProviders.length; i++) {
            uint256 lpShare = (poolManager.getLiquidity(key, liquidityProviders[i]) * amount) / totalLiquidity;
            (bool sent, ) = liquidityProviders[i].call{value: lpShare}("");
            require(sent, "Failed to send Ether to liquidity provider");
        }
    }
}