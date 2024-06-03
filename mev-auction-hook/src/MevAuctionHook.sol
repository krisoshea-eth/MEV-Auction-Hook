// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {BaseHook} from "v4-periphery/BaseHook.sol";
import {ERC20} from "solmate/tokens/ERC20.sol";

import {CurrencyLibrary, Currency} from "v4-core/types/Currency.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {BalanceDeltaLibrary, BalanceDelta} from "v4-core/types/BalanceDelta.sol";

import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";

import {Hooks} from "v4-core/libraries/Hooks.sol";

contract MevAuctionHook is BaseHook, ERC20 {
	// Use CurrencyLibrary and BalanceDeltaLibrary
	// to add some helper functions over the Currency and BalanceDelta
	// data types 
	using CurrencyLibrary for Currency;
    using BalanceDeltaLibrary for BalanceDelta;

	// Keeping track of user => auctionWinner
	mapping(address => address) public auctionWinner;

	// Amount of points someone gets for referring someone else
    uint256 public constant POINTS_FOR_REFERRAL = 500 * 10 ** 18;

	// Initialize BaseHook and ERC20
    constructor(
        IPoolManager _manager,
        string memory _name,
        string memory _symbol
    ) BaseHook(_manager) ERC20(_name, _symbol, 18) {}

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
        address,
        PoolKey calldata key,
        IPoolManager.SwapParams calldata swapParams,
        BalanceDelta delta,
        bytes calldata hookData
    ) external override poolManagerOnly returns (bytes4) {
		// 1: call the eigenlayer avs to trigger the beginning of the auction
        // 2: Wait a given duration for the auction to end
        // 3: Once the auction ends, return both the auction price and the authorised arb's address
        // 4: allow the execution of the swap only by the authorised arb
		return this.beforeSwap.selector;
	}
	
    // Distribute arbitrageur auction profits amongst pool Lps
	function afterSwap(
        address,
        PoolKey calldata key,
        IPoolManager.SwapParams calldata swapParams,
        BalanceDelta delta,
        bytes calldata hookData
    ) external override poolManagerOnly returns (bytes4) {
		// 1: ensure the arb has a) carried out the swap with correct amounts and transferred funds
        // 2: ensure arb has transferred the auction amount
        // 3: distribute the auction amount amongst the Pool Lps as fees or something similar
		return this.afterSwap.selector;
	}

	
    function getHookData(
        address referrer,
        address referree
    ) public pure returns (bytes memory) {
        return abi.encode(referrer, referree);
    }
}