// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

// Test Contracts
import { console2 } from "forge-std/Test.sol";
import { BaseTest } from "test/BaseTest.sol";

// Relay Contracts
import { RelayGameType } from "src/RelayAnchorStateRegistry.sol";
import { DisputeGameRelay } from "src/DisputeGameRelay.sol";

// Mocks
import { MockTEEDisputeGame } from "src/mocks/MockTEEDisputeGame.sol";
import { MockZKDisputeGame } from "src/mocks/MockZKDisputeGame.sol";

// // Optimism
import { FaultDisputeGame, BondDistributionMode } from "optimism/src/dispute/FaultDisputeGame.sol";
import { IDisputeGame } from "optimism/src/dispute/DisputeGameFactory.sol";
import { GameType, Claim, GameStatus } from "optimism/src/dispute/lib/Types.sol";
import { GameNotFinalized } from "optimism/src/dispute/lib/Errors.sol";

contract DisputeGameRelayTest is BaseTest {

    function setUp() public override {
        super.setUp();
        anchorStateRegistry.setRespectedGameType(RELAY_GAME_TYPE);
    }

    function testDeployRelayGame() public {
        RelayGameType[] memory relayGameTypes = new RelayGameType[](3);
        relayGameTypes[0] = RelayGameType({gameType: MOCK_ZK_DISPUTE_GAME_TYPE, required: false});
        relayGameTypes[1] = RelayGameType({gameType: TEE_GAME_TYPE, required: false});
        relayGameTypes[2] = RelayGameType({gameType: FAULT_DISPUTE_GAME_TYPE, required: false});
        
        uint256 l2SequenceNumber = 1;
        bytes[] memory underlyingExtraData = new bytes[](3);
        underlyingExtraData[0] = abi.encode(l2SequenceNumber);
        underlyingExtraData[1] = abi.encode(l2SequenceNumber);
        underlyingExtraData[2] = abi.encode(l2SequenceNumber);

        DisputeGameRelay relayGame = _createRelayGame(relayGameTypes, underlyingExtraData, l2SequenceNumber, 2);

        bytes32 claim = keccak256("1");

        // Check that the relay game was created
        assertEq(relayGame.l2SequenceNumber(), l2SequenceNumber);
        assertEq(Claim.unwrap(relayGame.rootClaim()), claim);
        assertEq(relayGame.numberOfUnderlyingGames(), 3);
        assertTrue(relayGame.wasRespectedGameTypeWhenCreated());

        for (uint256 i = 0; i < relayGameTypes.length; i++) {
            assertEq(relayGame.gameTypes()[i].raw(), relayGameTypes[i].gameType.raw());
        }

        for (uint256 i = 0; i < underlyingExtraData.length; i++) {
            assertEq(relayGame.extraDataArray()[i], underlyingExtraData[i]);
        }

        bytes memory expectedExtraData = abi.encodePacked(l2SequenceNumber, relayGameTypes.length);

        for (uint256 i = 0; i < relayGameTypes.length; i++) {
            expectedExtraData = abi.encodePacked(expectedExtraData, relayGameTypes[i].gameType);
        }

        for (uint256 i = 0; i < underlyingExtraData.length; i++) {
            expectedExtraData = abi.encodePacked(expectedExtraData, underlyingExtraData[i].length, underlyingExtraData[i]);
        }

        assertEq(relayGame.extraDataLength(), expectedExtraData.length);
        assertEq(relayGame.extraData(), expectedExtraData);
    }

    function test2of3TEEAndZK() public {
        RelayGameType[] memory relayGameTypes = new RelayGameType[](3);
        relayGameTypes[0] = RelayGameType({gameType: MOCK_ZK_DISPUTE_GAME_TYPE, required: false});
        relayGameTypes[1] = RelayGameType({gameType: TEE_GAME_TYPE, required: false});
        relayGameTypes[2] = RelayGameType({gameType: FAULT_DISPUTE_GAME_TYPE, required: false});

        uint256 l2SequenceNumber = 1;
        bytes[] memory underlyingExtraData = new bytes[](3);
        underlyingExtraData[0] = abi.encode(l2SequenceNumber);
        underlyingExtraData[1] = abi.encode(l2SequenceNumber);
        underlyingExtraData[2] = abi.encode(l2SequenceNumber);

        DisputeGameRelay relayGame = _createRelayGame(relayGameTypes, underlyingExtraData, l2SequenceNumber, 2);

        // zk, tee, fault
        address[] memory underlyingDisputeGames = relayGame.underlyingDisputeGames();

        MockZKDisputeGame mockZKGameProxy = MockZKDisputeGame(underlyingDisputeGames[0]);
        MockTEEDisputeGame teeGameProxy = MockTEEDisputeGame(underlyingDisputeGames[1]);

        // resolve zk game
        mockZKGameProxy.resolve("");

        // resolve tee game
        outputOracle.proposeL2Output(keccak256("1"), 1, 1, "");
        teeGameProxy.resolve(0);

        // resolve relay game
        relayGame.resolve();

        // check that the relay game is finalized
        assert(relayGame.status() == GameStatus.DEFENDER_WINS);

        // cannot close yet
        vm.expectRevert(abi.encodeWithSelector(GameNotFinalized.selector));
        relayGame.closeGame();

        // close relay game
        vm.warp(block.timestamp + 1 days + 1);
        relayGame.closeGame();

        // check anchor state updated
        assert(address(anchorStateRegistry.anchorGame()) == address(relayGame));
    }

    function testNullify() public {
        anchorStateRegistry.setBackUpGameType(GameType.wrap(1));

        RelayGameType[] memory relayGameTypes = new RelayGameType[](3);
        relayGameTypes[0] = RelayGameType({gameType: MOCK_ZK_DISPUTE_GAME_TYPE, required: false});
        relayGameTypes[1] = RelayGameType({gameType: TEE_GAME_TYPE, required: false});
        relayGameTypes[2] = RelayGameType({gameType: FAULT_DISPUTE_GAME_TYPE, required: false});

        uint256 l2SequenceNumber = 1;
        bytes[] memory underlyingExtraData = new bytes[](3);
        underlyingExtraData[0] = abi.encode(l2SequenceNumber);
        underlyingExtraData[1] = abi.encode(l2SequenceNumber);
        underlyingExtraData[2] = abi.encode(l2SequenceNumber);

        DisputeGameRelay relayGame = _createRelayGame(relayGameTypes, underlyingExtraData, l2SequenceNumber, 2);

        // zk, tee, fault
        address[] memory underlyingDisputeGames = relayGame.underlyingDisputeGames();

        MockZKDisputeGame mockZKGameProxy = MockZKDisputeGame(underlyingDisputeGames[0]);

        // resolve zk game
        mockZKGameProxy.resolve("");

        // nullify zk game
        mockZKGameProxy.nullify("", Claim.wrap(keccak256("2")));

        // check that the zk game is nullifed
        assert(mockZKGameProxy.status() == GameStatus.CHALLENGER_WINS);

        // check that the game type changed
        assert(GameType.unwrap(anchorStateRegistry.respectedGameType()) == 1);
    }

    function test2of3RequireTEE() public {
        RelayGameType[] memory relayGameTypes = new RelayGameType[](3);
        relayGameTypes[0] = RelayGameType({gameType: MOCK_ZK_DISPUTE_GAME_TYPE, required: false});
        relayGameTypes[1] = RelayGameType({gameType: TEE_GAME_TYPE, required: true});
        relayGameTypes[2] = RelayGameType({gameType: FAULT_DISPUTE_GAME_TYPE, required: false});

        uint256 l2SequenceNumber = 1;
        bytes[] memory underlyingExtraData = new bytes[](3);
        underlyingExtraData[0] = abi.encode(l2SequenceNumber);
        underlyingExtraData[1] = abi.encode(l2SequenceNumber);
        underlyingExtraData[2] = abi.encode(l2SequenceNumber);

        DisputeGameRelay relayGame = _createRelayGame(relayGameTypes, underlyingExtraData, l2SequenceNumber, 2);

        // check that the required game types are correct
        GameType[] memory requiredGameTypes = anchorStateRegistry.requiredGameTypes();
        assertEq(requiredGameTypes.length, 1);
        assertEq(requiredGameTypes[0].raw(), TEE_GAME_TYPE.raw());

        // zk, tee, fault
        address[] memory underlyingDisputeGames = relayGame.underlyingDisputeGames();

        MockZKDisputeGame mockZKGameProxy = MockZKDisputeGame(underlyingDisputeGames[0]);
        MockTEEDisputeGame teeGameProxy = MockTEEDisputeGame(underlyingDisputeGames[1]);
        FaultDisputeGame faultGameProxy = FaultDisputeGame(underlyingDisputeGames[2]);
        
        // resolve fault game
        vm.warp(block.timestamp + 7 days + 1);
        faultGameProxy.resolveClaim(0, 512);
        faultGameProxy.resolve();

        // resolve zk game
        mockZKGameProxy.resolve("");

        // cannot resolve relay game
        vm.expectRevert("Required game not resolved");
        relayGame.resolve();

        // resolve tee game
        outputOracle.proposeL2Output(keccak256("1"), 1, 1, "");
        teeGameProxy.resolve(0);

        // check that the relay game is resolved   
        relayGame.resolve();
        assert(relayGame.status() == GameStatus.DEFENDER_WINS);

        // cannot close yet
        vm.expectRevert("Required game not finalized");
        relayGame.closeGame();

        // close relay game after finalizing the tee game
        vm.warp(block.timestamp + 1 days + 1);
        relayGame.closeGame();

        // check anchor state updated
        assert(address(anchorStateRegistry.anchorGame()) == address(relayGame));
    }

    function testBondDistribution() public {
        // Deploy the relay game
        RelayGameType[] memory relayGameTypes = new RelayGameType[](3);
        relayGameTypes[0] = RelayGameType({gameType: MOCK_ZK_DISPUTE_GAME_TYPE, required: false});
        relayGameTypes[1] = RelayGameType({gameType: TEE_GAME_TYPE, required: false});
        relayGameTypes[2] = RelayGameType({gameType: FAULT_DISPUTE_GAME_TYPE, required: false});

        uint256 l2SequenceNumber = 1;
        bytes[] memory underlyingExtraData = new bytes[](3);
        underlyingExtraData[0] = abi.encode(l2SequenceNumber);
        underlyingExtraData[1] = abi.encode(l2SequenceNumber);
        underlyingExtraData[2] = abi.encode(l2SequenceNumber);

        DisputeGameRelay relayGame = _createRelayGame(relayGameTypes, underlyingExtraData, l2SequenceNumber, 2);

        // zk, tee, fault
        address[] memory underlyingDisputeGames = relayGame.underlyingDisputeGames();

        MockZKDisputeGame mockZKGameProxy = MockZKDisputeGame(underlyingDisputeGames[0]);
        FaultDisputeGame faultGameProxy = FaultDisputeGame(underlyingDisputeGames[2]);

        // resolve zk game
        mockZKGameProxy.resolve("");

        // resolve fault game
        vm.warp(block.timestamp + 7 days + 1);
        faultGameProxy.resolveClaim(0, 512);
        faultGameProxy.resolve();

        // resolve relay game
        relayGame.resolve();

        // close fault game
        vm.warp(block.timestamp + 14 days + 1);
        faultGameProxy.claimCredit(address(relayGame));

        // check that the bond distribution mode is normal
        assert(faultGameProxy.bondDistributionMode() == BondDistributionMode.NORMAL);

        // 1 day delay for bond withdrawal
        vm.warp(block.timestamp + 1 days);

        assertEq(address(this).balance, 0);
        relayGame.claimCredit();
        assertEq(address(this).balance, TOTAL_BOND_AMOUNT);
    }

    function testBlacklistUnderlyingGame() public {
        // Deploy the relay game
        RelayGameType[] memory relayGameTypes = new RelayGameType[](3);
        relayGameTypes[0] = RelayGameType({gameType: MOCK_ZK_DISPUTE_GAME_TYPE, required: false});
        relayGameTypes[1] = RelayGameType({gameType: TEE_GAME_TYPE, required: true});
        relayGameTypes[2] = RelayGameType({gameType: FAULT_DISPUTE_GAME_TYPE, required: false});

                uint256 l2SequenceNumber = 1;
        bytes[] memory underlyingExtraData = new bytes[](3);
        underlyingExtraData[0] = abi.encode(l2SequenceNumber);
        underlyingExtraData[1] = abi.encode(l2SequenceNumber);
        underlyingExtraData[2] = abi.encode(l2SequenceNumber);

        DisputeGameRelay relayGame = _createRelayGame(relayGameTypes, underlyingExtraData, l2SequenceNumber, 2);

        // check that the relay game is not blacklisted
        assert(!anchorStateRegistry.isGameBlacklisted(IDisputeGame(address(relayGame))));

        // blacklist an underlying game
        address[] memory underlyingDisputeGames = relayGame.underlyingDisputeGames();
        anchorStateRegistry.blacklistDisputeGame(IDisputeGame(underlyingDisputeGames[0]));

        // check that the relay game is blacklisted
        assert(anchorStateRegistry.isGameBlacklisted(IDisputeGame(address(relayGame))));
    }

    function _createRelayGame(RelayGameType[] memory _relayGameTypes, bytes[] memory _underlyingExtraData, uint256 _l2SequenceNumber, uint256 _threshold) internal returns (DisputeGameRelay) {
        require(_relayGameTypes.length == _underlyingExtraData.length, "Relay game types and underlying extra data must have the same length");
        
        anchorStateRegistry.setRelayGameTypesAndThreshold(_relayGameTypes, _threshold);

        // Deploy the relay game
        Claim claim = Claim.wrap(keccak256("1"));
        
        bytes memory relayGameExtraData = abi.encodePacked(_l2SequenceNumber, _relayGameTypes.length);
        for (uint256 i = 0; i < _relayGameTypes.length; i++) {
            relayGameExtraData = abi.encodePacked(relayGameExtraData, _relayGameTypes[i].gameType);
        }
        for (uint256 i = 0; i < _underlyingExtraData.length; i++) {
            relayGameExtraData = abi.encodePacked(relayGameExtraData, _underlyingExtraData[i].length, _underlyingExtraData[i]);
        }

        return DisputeGameRelay(payable(address(factory.create{value: TOTAL_BOND_AMOUNT}(RELAY_GAME_TYPE, claim, relayGameExtraData))));
    }
}
