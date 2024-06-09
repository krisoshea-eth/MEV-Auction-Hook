// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.12;

import "../src/MevAuctionServiceManager.sol";
import {MevAuctionTaskManager} from "../src/MevAuctionTaskManager.sol";
import {BLSMockAVSDeployer} from "@eigenlayer-middleware/test/utils/BLSMockAVSDeployer.sol";
import {TransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {Test} from "forge-std/Test.sol";

contract MevAuctionTaskManagerTest is Test {
    MevAuctionServiceManager sm;
    MevAuctionServiceManager smImplementation;
    MevAuctionTaskManager tm;
    MevAuctionTaskManager tmImplementation;
    BLSMockAVSDeployer avsDeployer;

    uint32 public constant TASK_RESPONSE_WINDOW_BLOCK = 30;
    address aggregator = address(uint160(uint256(keccak256(abi.encodePacked("aggregator")))));
    address generator = address(uint160(uint256(keccak256(abi.encodePacked("generator")))));

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
}
