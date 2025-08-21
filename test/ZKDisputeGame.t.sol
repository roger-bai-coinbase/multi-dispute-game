// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

// Test Contracts
import { console2 } from "forge-std/Test.sol";
import { BaseTest } from "test/BaseTest.sol";

// ZKDisputeGame
import { ZKDisputeGame, Claim, GameStatus, BondDistributionMode } from "src/ZKDisputeGame.sol";
import { GameNotOver, ParentGameNotResolved } from "src/errors/ZKErrors.sol";

// Optimism
import { GameType } from "optimism/src/dispute/lib/Types.sol";

contract ZKDisputeGameTest is BaseTest {

    uint256 internal _l2BlockNumber = 100;

    function setUp() public override {
        super.setUp();
        anchorStateRegistry.setRespectedGameType(ZK_DISPUTE_GAME_TYPE);
    }

    function testCreateZKDisputeGame() public {
        Claim claim = Claim.wrap(keccak256(abi.encode(_l2BlockNumber)));
        ZKDisputeGame zkDisputeGame = _createZKDisputeGame(claim, _l2BlockNumber, type(uint32).max);

        assertEq(zkDisputeGame.l2BlockNumber(), _l2BlockNumber);
        assertEq(zkDisputeGame.parentIndex(), type(uint32).max);
        assertEq(Claim.unwrap(zkDisputeGame.rootClaim()), Claim.unwrap(claim));
        assertEq(zkDisputeGame.extraData(), abi.encodePacked(_l2BlockNumber, type(uint32).max));
    }

    function testOptimisticResolution() public {
        Claim claim = Claim.wrap(keccak256(abi.encode(_l2BlockNumber)));
        ZKDisputeGame zkDisputeGame = _createZKDisputeGame(claim, _l2BlockNumber, type(uint32).max);

        // game is not over until after 3.5 days
        vm.warp(block.timestamp + 3.5 days);
        vm.expectRevert(GameNotOver.selector);
        zkDisputeGame.resolve();

        vm.warp(block.timestamp + 1);
        zkDisputeGame.resolve();

        assert(zkDisputeGame.status() == GameStatus.DEFENDER_WINS);
    }

    function testMultipleInvalidProposalsAtNextBlockInterval() public {
        address attacker = makeAddr("attacker");
        vm.deal(attacker, 100e18);

        // create the first anchor and resolve it
        ZKDisputeGame firstZKDisputeGame = _createZKDisputeGame(Claim.wrap(keccak256(abi.encode(_l2BlockNumber))), _l2BlockNumber, type(uint32).max);
        firstZKDisputeGame.prove("");
        
        firstZKDisputeGame.resolve();
        assert(firstZKDisputeGame.status() == GameStatus.DEFENDER_WINS);

        // finalize after finality delay
        vm.warp(block.timestamp + 1 days + 1);
        firstZKDisputeGame.claimCredit(address(this));
        assertEq(address(anchorStateRegistry.anchorGame()), address(firstZKDisputeGame));

        uint32 parentIndex = uint32(factory.gameCount() - 1);
        _l2BlockNumber += ZK_DISPUTE_GAME_BLOCK_INTERVAL;

        // attacker creates multiple invalid proposals that cannot be proved with a zk proof
        ZKDisputeGame[] memory invalidGames = new ZKDisputeGame[](10);
        vm.startPrank(attacker);
        for (uint256 i = 0; i < 10; i++) {
            Claim incorrectClaim = Claim.wrap(keccak256(abi.encodePacked("attack", i)));
            invalidGames[i] = _createZKDisputeGame(incorrectClaim, _l2BlockNumber, parentIndex);
        }
        vm.stopPrank();

        // propose and prove the correct proposal
        Claim claim = Claim.wrap(keccak256(abi.encode(_l2BlockNumber)));
        ZKDisputeGame correctZKDisputeGame = _createZKDisputeGame(claim, _l2BlockNumber, parentIndex);

        correctZKDisputeGame.prove(abi.encode(keccak256(abi.encode(_l2BlockNumber))));
        correctZKDisputeGame.resolve();

        assert(correctZKDisputeGame.status() == GameStatus.DEFENDER_WINS);

        // invalid games cannot resolve yet
        vm.warp(block.timestamp + 1 days + 1);
        for (uint256 i = 0; i < 10; i++) {
            vm.expectRevert(GameNotOver.selector);
            invalidGames[i].resolve();
        }

        // but we can update the anchor with the correct proposal
        correctZKDisputeGame.claimCredit(address(this));
        assertEq(address(anchorStateRegistry.anchorGame()), address(correctZKDisputeGame));

        // invalid games can now never resolve to DEFENDER_WINS, even optimistically
        vm.warp(block.timestamp + 3.5 days + 1);
        for (uint256 i = 0; i < 10; i++) {
            invalidGames[i].resolve();
            assert(invalidGames[i].status() != GameStatus.DEFENDER_WINS);
            assert(invalidGames[i].bondDistributionMode() == BondDistributionMode.REFUND);
        }
    }

    function testChainOfInvalidGames() public {
        address attacker = makeAddr("attacker");
        vm.deal(attacker, 100e18);

        // create the first anchor and resolve it
        ZKDisputeGame firstZKDisputeGame = _createZKDisputeGame(Claim.wrap(keccak256(abi.encode(_l2BlockNumber))), _l2BlockNumber, type(uint32).max);
        firstZKDisputeGame.prove("");
        
        firstZKDisputeGame.resolve();
        assert(firstZKDisputeGame.status() == GameStatus.DEFENDER_WINS);

        // finalize after finality delay
        vm.warp(block.timestamp + 1 days + 1);
        firstZKDisputeGame.claimCredit(address(this));
        assertEq(address(anchorStateRegistry.anchorGame()), address(firstZKDisputeGame));

        uint32 parentIndex = uint32(factory.gameCount() - 1);
        _l2BlockNumber += ZK_DISPUTE_GAME_BLOCK_INTERVAL;

        // attacker creates a chain of invalid proposals that cannot be proved with a zk proof
        ZKDisputeGame[] memory invalidGames = new ZKDisputeGame[](10);
        vm.startPrank(attacker);
        for (uint256 i = 0; i < 10; i++) {
            Claim incorrectClaim = Claim.wrap(keccak256(abi.encodePacked("attack", i)));
            invalidGames[i] = _createZKDisputeGame(incorrectClaim, _l2BlockNumber + i * ZK_DISPUTE_GAME_BLOCK_INTERVAL, parentIndex + uint32(i));
        }
        vm.stopPrank();

        // propose and prove the correct proposal
        Claim claim = Claim.wrap(keccak256(abi.encode(_l2BlockNumber)));
        ZKDisputeGame correctZKDisputeGame = _createZKDisputeGame(claim, _l2BlockNumber, parentIndex);

        correctZKDisputeGame.prove(abi.encode(keccak256(abi.encode(_l2BlockNumber))));
        correctZKDisputeGame.resolve();

        assert(correctZKDisputeGame.status() == GameStatus.DEFENDER_WINS);

        // invalid games cannot resolve yet
        vm.warp(block.timestamp + 1 days + 1);
        for (uint256 i = 0; i < 10; i++) {
            if (i == 0) {
                vm.expectRevert(GameNotOver.selector);
            } else {
                vm.expectRevert(ParentGameNotResolved.selector);
            }
            invalidGames[i].resolve();
        }

        // but we can update the anchor with the correct proposal
        correctZKDisputeGame.claimCredit(address(this));
        assertEq(address(anchorStateRegistry.anchorGame()), address(correctZKDisputeGame));

        // first game in the chain can now never resolve to DEFENDER_WINS, even optimistically
        vm.warp(block.timestamp + 3.5 days + 1);
        invalidGames[0].resolve();
        assert(invalidGames[0].status() != GameStatus.DEFENDER_WINS);
        assert(invalidGames[0].bondDistributionMode() == BondDistributionMode.REFUND);

        // rest of the games in the chain can now never resolve as parent has not resolved
        for (uint256 i = 1; i < 10; i++) {
            vm.expectRevert(ParentGameNotResolved.selector);
            invalidGames[i].resolve();
        }
    }

    function testNullifyZKDisputeGame() public {
        anchorStateRegistry.setBackUpGameType(GameType.wrap(1));

        ZKDisputeGame zkDisputeGame = _createZKDisputeGame(Claim.wrap(keccak256(abi.encode(_l2BlockNumber))), _l2BlockNumber, type(uint32).max);
        zkDisputeGame.prove("");
        zkDisputeGame.resolve();

        assert(zkDisputeGame.status() == GameStatus.DEFENDER_WINS);

        zkDisputeGame.nullify("", Claim.wrap(keccak256(abi.encode(_l2BlockNumber + 1))));

        assert(zkDisputeGame.status() == GameStatus.CHALLENGER_WINS);
        assert(GameType.unwrap(anchorStateRegistry.respectedGameType()) == 1);
    }

    function _createZKDisputeGame(Claim claim, uint256 l2BlockNumber, uint32 parentIndex) internal returns (ZKDisputeGame) {
        bytes memory extraData = abi.encodePacked(l2BlockNumber, parentIndex);

        return ZKDisputeGame(payable(address(factory.create{value: ZK_DISPUTE_GAME_BOND_AMOUNT}(ZK_DISPUTE_GAME_TYPE, claim, extraData))));
    }
}