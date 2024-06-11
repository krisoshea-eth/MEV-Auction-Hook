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
        PoolKey key;
        IPoolManager.SwapParams swapParams;
        bool isCompleted;
        uint256 bidAmount;
    }

	// Keeping track of user => auctionWinner
	mapping(address => address) public auctionWinner;
    // keeping track of swap details
    mapping(uint32 => SwapDetails) public swaps;

    event NewTaskCreated(uint32 taskId);
    event SwapExecuting(uint32 taskId);
    event SwapExecuted(uint32 taskId, uint256 deltaAmount);

    modifier onlyWhenHooksEnabled() {
        require(!hooksDisabled, "Hooks are disabled");
        _;
    }

	// Initialize BaseHook and ERC20
    constructor(
        IPoolManager poolManager,
        string memory _name,
        string memory _symbol,
        IMevAuctionTaskManager _mevAuctionTaskManager
    ) BaseHook(poolManager) ERC20(_name, _symbol, 18) {
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
                afterSwap: false,
                beforeDonate: false,
                afterDonate: false,
                beforeSwapReturnDelta: true,
                afterSwapReturnDelta: false,
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
        
        if (hookData.length == 0) {
            mevAuctionTaskManager.createNewTask(uint256(swapParams.amountSpecified), 10 minutes, hookData);
            swaps[mevAuctionTaskManager.taskNumber()] = SwapDetails({
                originalSender: sender,
                key: key,
                swapParams: swapParams,
                isCompleted: false,
                bidAmount: 0
            });
            emit NewTaskCreated(mevAuctionTaskManager.taskNumber());
        }

        uint256 amountSpecified = swapParams.amountSpecified > 0 ? uint256(swapParams.amountSpecified) : uint256(-swapParams.amountSpecified);
        require(amountSpecified <= type(uint256).max, "Amount specified overflow");

        if (swapParams.zeroForOne){
            poolManager.take(key.currency0, address(this), amountSpecified);
        } else {
            poolManager.take(key.currency1, address(this), amountSpecified);
        }

        return (this.beforeSwap.selector, toBeforeSwapDelta(int128(-swapParams.amountSpecified), 0), 0);
    }

    function executeSwap(uint32 taskId) external payable {
        SwapDetails storage swapDetails = swaps[taskId];
        IMevAuctionTaskManager.Auction memory auction = mevAuctionTaskManager.getAuctionDetails(taskId);

        require(msg.sender == auction.highestBidder, "Only the highest bidder can execute the swap");
        require(msg.value == auction.highestBid, "Incorrect bid amount");

        swapDetails.bidAmount = msg.value;
        BalanceDelta finalDelta = abi.decode(
            poolManager.unlock(
                abi.encode(
                    SwapDetails(swapDetails.originalSender, swapDetails.key, swapDetails.swapParams, swapDetails.isCompleted, swapDetails.bidAmount)
                )
            ),
            (BalanceDelta)
        );

        swapDetails.isCompleted = true;
        
        emit SwapExecuting(taskId);

        bytes memory hookData = abi.encode(taskId, msg.value);

        ERC20 outputToken = ERC20(Currency.unwrap(swapDetails.swapParams.zeroForOne ? swapDetails.key.currency1 : swapDetails.key.currency0));
        uint256 amountOut = finalDelta.amount1() > 0 ? uint256(int256(finalDelta.amount1())) : 0;
        outputToken.transfer(swapDetails.originalSender, amountOut);
        emit SwapExecuted(taskId, amountOut);

        if (swapDetails.swapParams.zeroForOne) {
            if (finalDelta.amount0() < 0) {
                poolManager.settle(swapDetails.key.currency0);
            }
            if (finalDelta.amount1() > 0) {
                poolManager.take(swapDetails.key.currency1, address(this), uint256(int256(finalDelta.amount1())));
            }
        } else {
            if (finalDelta.amount1() < 0) {
                poolManager.settle(swapDetails.key.currency1);
            }
            if (finalDelta.amount0() > 0) {
                poolManager.take(swapDetails.key.currency0, address(this), uint256(int256(finalDelta.amount0())));
            }
        }
    }

    function unlockCallback(bytes calldata data) external override poolManagerOnly returns (bytes memory) {
        SwapDetails memory swapDetails = abi.decode(data, (SwapDetails));

        BalanceDelta swapDelta = poolManager.swap(swapDetails.key, swapDetails.swapParams, "");
        BalanceDelta donateDelta = poolManager.donate(swapDetails.key, swapDetails.bidAmount, 0, "");

        BalanceDelta finalDelta = swapDelta;

        return abi.encode(finalDelta);
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

    receive() external payable {
        require(msg.value > 0, "Must send ETH");
    }
}