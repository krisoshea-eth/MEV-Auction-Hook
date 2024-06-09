// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {BaseHook} from "v4-periphery/BaseHook.sol";
import {ERC20} from "solmate/tokens/ERC20.sol";

import {CurrencyLibrary, Currency} from "v4-core/types/Currency.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {BalanceDeltaLibrary, BalanceDelta} from "v4-core/types/BalanceDelta.sol";

import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";

import {Hooks} from "v4-core/libraries/Hooks.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary, toBeforeSwapDelta} from "v4-core/types/BeforeSwapDelta.sol";
import {IMevAuctionTaskManager} from "mev-auction-avs/contracts/src/IMevAuctionTaskManager.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {Position} from "v4-core/libraries/Position.sol";
import {Pool} from "v4-core/libraries/Pool.sol";

contract MevAuctionHook is BaseHook, ERC20 {
	// Use CurrencyLibrary and BalanceDeltaLibrary
	// to add some helper functions over the Currency and BalanceDelta
	// data types 
	using CurrencyLibrary for Currency;
    using BalanceDeltaLibrary for BalanceDelta;
    using BeforeSwapDeltaLibrary for BeforeSwapDelta;
    using PoolIdLibrary for PoolKey; 
    using Position for mapping(bytes32 => Position.Info);

    bool public hooksDisabled;
    IMevAuctionTaskManager public mevAuctionTaskManager;

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
        IPoolManager _poolManager,
        string memory _name,
        string memory _symbol,
        IMevAuctionTaskManager _mevAuctionTaskManager
    ) BaseHook(_poolManager) ERC20(_name, _symbol, 18) {
        mevAuctionTaskManager = _mevAuctionTaskManager;
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
                afterDonate: false,
                beforeSwapReturnDelta: false,
                afterSwapReturnDelta: true,
                afterAddLiquidityReturnDelta: false,
                afterRemoveLiquidityReturnDelta: false
            });
    }

    // Make a call to the eigenlayer AVS to initiate the auction
	function beforeSwap(
        address sender,
        PoolKey calldata key,
        IPoolManager.SwapParams calldata swapParams,
        bytes calldata hookData
    ) external override onlyWhenHooksEnabled poolManagerOnly returns (bytes4, BeforeSwapDelta, uint24) {
        mevAuctionTaskManager.createNewTask(uint256(swapParams.amountSpecified), 10 minutes, hookData);
        swaps[mevAuctionTaskManager.taskNumber()] = SwapDetails({
            originalSender: sender,
            amountSpecified: uint256(swapParams.amountSpecified),
            isCompleted: false,
            bidAmount: 0
        });
        return (this.beforeSwap.selector, toBeforeSwapDelta(0, 0), 0);
    }
	
    // Distribute arbitrageur auction profits amongst pool Lps
	function afterSwap(
        address,
        PoolKey calldata key,
        IPoolManager.SwapParams calldata swapParams,
        BalanceDelta delta,
        bytes calldata hookData
    ) external override onlyWhenHooksEnabled poolManagerOnly returns (bytes4, int128) {

        // Handle distribution of bid amount to liquidity providers
        (uint32 taskId, uint256 bidAmount) = abi.decode(hookData, (uint32, uint256));

        require(swaps[taskId].isCompleted, "Swap not completed by arbitrageur");

        // Distribute the bid amount to liquidity providers
        distributeToLPs(bidAmount, key);
        
        return (this.afterSwap.selector, 0);
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
        BalanceDelta delta = poolManager.swap(key, swapParams, "");

        // Enable hooks again
        hooksDisabled = false;

         // Send swap output to the original sender
         ERC20 outputToken = ERC20(Currency.unwrap(swapParams.zeroForOne ? key.currency1 : key.currency0));
         outputToken.transfer(swaps[taskId].originalSender, uint256(int256(delta.amount1())));
    }
    
    function distributeToLPs(uint256 amount, PoolKey calldata key) internal {
        PoolId poolId = key.toId();
        uint128 totalLiquidity = StateLibrary.getLiquidity(poolManager, poolId);

        for (uint256 i = 0; i < getPositionCount(poolId); i++) {
            bytes32 positionKey = getPositionKeyAt(poolId, i);
            (uint128 liquidity,,) = StateLibrary.getPositionInfo(poolManager, poolId, positionKey);
            address owner = getOwnerFromPositionKey(positionKey); // Assuming this method exists to extract owner info
            uint256 lpShare = (liquidity * amount) / totalLiquidity;
            (bool sent, ) = owner.call{value: lpShare}("");
            require(sent, "Failed to send Ether to liquidity provider");
        }
    }

    function getPositionCount(PoolId poolId) internal view returns (uint256 count) {
        count = 0;
        bytes32 stateSlot = StateLibrary._getPoolStateSlot(poolId);
        bytes32 positionSlot = keccak256(abi.encodePacked(bytes32(uint256(6)), stateSlot));
        while (true) {
            bytes32 key = keccak256(abi.encodePacked(count, positionSlot));
            if (uint256(poolManager.extsload(key)) == 0) break;
            count++;
        }
    }

    function getPositionKeyAt(PoolId poolId, uint256 index) internal view returns (bytes32) {
        bytes32 stateSlot = StateLibrary._getPoolStateSlot(poolId);
        bytes32 positionSlot = keccak256(abi.encodePacked(bytes32(uint256(6)), stateSlot));
        return keccak256(abi.encodePacked(index, positionSlot));
    }

    // In MevAuctionHook contract
    function getSwapDetails(uint32 taskId) external view returns (SwapDetails memory) {
        return swaps[taskId];
    }

    // Function to set swap details
    function setSwapDetails(uint32 taskId, SwapDetails memory swapDetails) public {
        swaps[taskId] = swapDetails;
    }

    function getOwnerFromPositionKey(bytes32 positionKey) internal pure returns (address) {
        // Extract owner information from positionKey. Assuming the owner address is part of the positionKey.
        // This function needs to be implemented based on how the positionKey is generated.
        return address(uint160(uint256(positionKey)));   
    }
}