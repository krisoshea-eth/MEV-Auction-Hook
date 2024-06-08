// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.12;

import "../src/MevAuctionServiceManager.sol" as mevacsm;
import {MevAuctionTaskManager} from "../src/MevAuctionTaskManager.sol";
import {BLSMockAVSDeployer} from "@eigenlayer-middleware/test/utils/BLSMockAVSDeployer.sol";
import {TransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import "forge-std/Test.sol";

contract MevAuctionTaskManagerTest is BLSMockAVSDeployer, Test {
    mevacsm.MevAuctionServiceManager sm;
    mevacsm.MevAuctionServiceManager smImplementation;
    MevAuctionTaskManager tm;
    MevAuctionTaskManager tmImplementation;

    uint32 public constant TASK_RESPONSE_WINDOW_BLOCK = 10;
    address aggregator =
        address(uint160(uint256(keccak256(abi.encodePacked("aggregator")))));
    address generator =
        address(uint160(uint256(keccak256(abi.encodePacked("generator")))));

    function setUp() public {
        _setUpBLSMockAVSDeployer();

        tmImplementation = new MevAuctionTaskManager(
            mevacsm.IRegistryCoordinator(address(registryCoordinator)),
            TASK_RESPONSE_WINDOW_BLOCK
        );

        // Third, upgrade the proxy contracts to use the correct implementation contracts and initialize them.
        tm = MevAuctionTaskManager(
            address(
                new TransparentUpgradeableProxy(
                    address(tmImplementation),
                    address(proxyAdmin),
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
    }

    function testCreateNewTask() public {
        bytes memory quorumNumbers = new bytes(0);
        // cheats.prank(generator, generator);
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

        (uint256 highestBid, address highestBidder, , ) = tm.getAuctionDetails(0);
        assertEq(highestBid, 1 ether);
        assertEq(highestBidder, address(1));
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

        (, , , bool completed) = tm.getAuctionDetails(0);
        assertTrue(completed);
    }

    function testGetAuctionDetails() public {
        bytes memory quorumNumbers = new bytes(0);
        vm.prank(generator);
        tm.createNewTask(2, 100, quorumNumbers);

        vm.prank(address(1));
        tm.submitBid(0, 1 ether);

        (uint256 highestBid, address highestBidder, uint256 endTime, bool completed) = tm.getAuctionDetails(0);
        assertEq(highestBid, 1 ether);
        assertEq(highestBidder, address(1));
        assertEq(endTime, block.timestamp + 2);
        assertFalse(completed);
    }

    function testMultipleBids() public {
        bytes memory quorumNumbers = new bytes(0);
        vm.prank(generator);
        tm.createNewTask(2, 100, quorumNumbers);

        vm.prank(address(1));
        tm.submitBid(0, 1 ether);

        vm.prank(address(2));
        tm.submitBid(0, 2 ether);

        (uint256 highestBid, address highestBidder, , ) = tm.getAuctionDetails(0);
        assertEq(highestBid, 2 ether);
        assertEq(highestBidder, address(2));
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
}
