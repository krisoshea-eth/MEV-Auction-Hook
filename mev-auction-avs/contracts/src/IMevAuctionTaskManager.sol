// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.9;

import "@eigenlayer-middleware/src/libraries/BN254.sol";

interface IMevAuctionTaskManager {
    // EVENTS
    event NewTaskCreated(uint32 indexed taskIndex, Auction auction);
    event TaskResponded(TaskResponse taskResponse, TaskResponseMetadata taskResponseMetadata);
    event TaskCompleted(uint32 indexed taskIndex);
    event TaskChallengedSuccessfully(uint32 indexed taskIndex, address indexed challenger);
    event TaskChallengedUnsuccessfully(uint32 indexed taskIndex, address indexed challenger);
    event NewBidSubmitted(uint32 taskId, address bidder, uint256 bidAmount);
    event AuctionCompleted(uint32 taskId, address highestBidder, uint256 highestBid);

    // STRUCTS
    struct Task {
        uint256 auctionDuration;
        uint32 taskCreatedBlock;
        bytes quorumNumbers;
        uint32 quorumThresholdPercentage;
    }

    struct TaskResponse {
        uint32 referenceTaskIndex;
        uint256 numberSquared;
    }

    struct TaskResponseMetadata {
        uint32 taskResponsedBlock;
        bytes32 hashOfNonSigners;
    }

    struct Auction {
        uint256 highestBid;
        address highestBidder;
        uint256 endTime;
        bool completed;
    }

    // FUNCTIONS
    function createNewTask(
        uint256 auctionDuration,
        uint32 quorumThresholdPercentage,
        bytes calldata quorumNumbers
    ) external;

    function taskNumber() external view returns (uint32);

    function raiseAndResolveChallenge(
        Task calldata task,
        TaskResponse calldata taskResponse,
        TaskResponseMetadata calldata taskResponseMetadata,
        BN254.G1Point[] memory pubkeysOfNonSigningOperators
    ) external;

    function getTaskResponseWindowBlock() external view returns (uint32);

    function submitBid(uint32 taskId, uint256 bidAmount) external;

    function completeAuction(uint32 taskId) external;

    function getAuctionDetails(uint32 taskId) external view returns (Auction memory);
}