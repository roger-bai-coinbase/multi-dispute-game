// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import { Test, console2 } from "forge-std/Test.sol";

// Relay Contracts
// import { DisputeGameRelayFactory } from "src/DisputeGameRelayFactory.sol";
import { RelayGameType, RelayAnchorStateRegistry } from "src/RelayAnchorStateRegistry.sol";
import { DisputeGameRelay } from "src/DisputeGameRelay.sol";
import { IRelayAnchorStateRegistry } from "src/interfaces/IRelayAnchorStateRegistry.sol";
import { IZKVerifier } from "src/interfaces/IZKVerifier.sol";

// Mocks
import { MockTEEDisputeGame } from "src/mocks/MockTEEDisputeGame.sol";
import { MockOutputOracle } from "src/mocks/MockOutputOracle.sol";
import { MockVM } from "src/mocks/MockVM.sol";
import { MockPreimageOracle } from "src/mocks/MockPreimageOracle.sol";
import { MockZKDisputeGame } from "src/mocks/MockZKDisputeGame.sol";
import { MockZKVerifier } from "src/mocks/MockZKVerifier.sol";
import { MockSystemConfig } from "src/mocks/MockSystemConfig.sol";

// Optimism
import { FaultDisputeGame, IAnchorStateRegistry, IDelayedWETH, IBigStepper, IPreimageOracle, BondDistributionMode } from "optimism/src/dispute/FaultDisputeGame.sol";
import { IDisputeGame, DisputeGameFactory } from "optimism/src/dispute/DisputeGameFactory.sol";
import { GameType, Duration, Claim, GameStatus } from "optimism/src/dispute/lib/Types.sol";
import { ISystemConfig, IDisputeGameFactory, Hash, Proposal } from "optimism/src/dispute/AnchorStateRegistry.sol";
import { DelayedWETH } from "optimism/src/dispute/DelayedWETH.sol";
import { GameNotFinalized } from "optimism/src/dispute/lib/Errors.sol";

// OpenZeppelin
import { ProxyAdmin } from "@openzeppelin/contracts/proxy/transparent/ProxyAdmin.sol";
import { TransparentUpgradeableProxy } from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";

contract DisputeGameRelayTest is Test {
    DisputeGameFactory public factory;
    RelayAnchorStateRegistry public anchorStateRegistry;

    MockOutputOracle public outputOracle;
    MockVM public bigStepper;
    MockPreimageOracle public preimageOracle;
    DelayedWETH public delayedWETH;
    MockZKVerifier public verifier;

    ProxyAdmin public proxyAdmin;
    MockSystemConfig public systemConfig;

    // Constants
    uint256 public constant DISPUTE_GAME_FINALITY_DELAY_SECONDS = 7 days;
    uint256 public constant ZK_DISPUTE_GAME_FINALIZATION_DELAY_SECONDS = 1 days;

    // Game types
    GameType public constant FAULT_DISPUTE_GAME_TYPE = GameType.wrap(0);
    GameType public constant TEE_GAME_TYPE = GameType.wrap(733);
    GameType public constant ZK_DISPUTE_GAME_TYPE = GameType.wrap(1337); // Kailua
    GameType public constant RELAY_GAME_TYPE = GameType.wrap(type(uint32).max);

    // Bond amounts
    uint256 public constant FAULT_DISPUTE_GAME_BOND_AMOUNT = 0.1 ether;
    uint256 public constant ZK_DISPUTE_GAME_BOND_AMOUNT = 0.1 ether;

    uint256 public constant TOTAL_BOND_AMOUNT = FAULT_DISPUTE_GAME_BOND_AMOUNT + ZK_DISPUTE_GAME_BOND_AMOUNT;
    
    uint256 public constant L2_CHAIN_ID = 8453;

    function setUp() public {
        _deployContractsAndProxies();
        _initializeProxies();

        // Deploy the implementations
        _deployAndSetFaultDisputeGame();
        _deployAndSetTEEDisputeGame();
        _deployAndSetZKDisputeGame();
        _deployAndSetDisputeGameRelay();

        // Set the timestamp to after the retirement timestamp
        vm.warp(block.timestamp + 1);
        vm.deal(address(this), TOTAL_BOND_AMOUNT);
    }

    function testDeployRelayGame() public {
        RelayGameType[] memory relayGameTypes = new RelayGameType[](3);
        relayGameTypes[0] = RelayGameType({gameType: ZK_DISPUTE_GAME_TYPE, required: false});
        relayGameTypes[1] = RelayGameType({gameType: TEE_GAME_TYPE, required: false});
        relayGameTypes[2] = RelayGameType({gameType: FAULT_DISPUTE_GAME_TYPE, required: false});
        
        uint256 l2SequenceNumber = 1;
        bytes[] memory underlyingExtraData = new bytes[](3);
        underlyingExtraData[0] = abi.encode(l2SequenceNumber);
        underlyingExtraData[1] = abi.encode(l2SequenceNumber);
        underlyingExtraData[2] = abi.encode(l2SequenceNumber);

        DisputeGameRelay relayGame = _deployRelayGame(relayGameTypes, underlyingExtraData, l2SequenceNumber, 2);

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
        relayGameTypes[0] = RelayGameType({gameType: ZK_DISPUTE_GAME_TYPE, required: false});
        relayGameTypes[1] = RelayGameType({gameType: TEE_GAME_TYPE, required: false});
        relayGameTypes[2] = RelayGameType({gameType: FAULT_DISPUTE_GAME_TYPE, required: false});

        uint256 l2SequenceNumber = 1;
        bytes[] memory underlyingExtraData = new bytes[](3);
        underlyingExtraData[0] = abi.encode(l2SequenceNumber);
        underlyingExtraData[1] = abi.encode(l2SequenceNumber);
        underlyingExtraData[2] = abi.encode(l2SequenceNumber);

        DisputeGameRelay relayGame = _deployRelayGame(relayGameTypes, underlyingExtraData, l2SequenceNumber, 2);

        // zk, tee, fault
        address[] memory underlyingDisputeGames = relayGame.underlyingDisputeGames();

        MockZKDisputeGame zkGameProxy = MockZKDisputeGame(underlyingDisputeGames[0]);
        MockTEEDisputeGame teeGameProxy = MockTEEDisputeGame(underlyingDisputeGames[1]);

        // resolve zk game
        zkGameProxy.resolve("");

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
        relayGameTypes[0] = RelayGameType({gameType: ZK_DISPUTE_GAME_TYPE, required: false});
        relayGameTypes[1] = RelayGameType({gameType: TEE_GAME_TYPE, required: false});
        relayGameTypes[2] = RelayGameType({gameType: FAULT_DISPUTE_GAME_TYPE, required: false});

        uint256 l2SequenceNumber = 1;
        bytes[] memory underlyingExtraData = new bytes[](3);
        underlyingExtraData[0] = abi.encode(l2SequenceNumber);
        underlyingExtraData[1] = abi.encode(l2SequenceNumber);
        underlyingExtraData[2] = abi.encode(l2SequenceNumber);

        DisputeGameRelay relayGame = _deployRelayGame(relayGameTypes, underlyingExtraData, l2SequenceNumber, 2);

        // zk, tee, fault
        address[] memory underlyingDisputeGames = relayGame.underlyingDisputeGames();

        MockZKDisputeGame zkGameProxy = MockZKDisputeGame(underlyingDisputeGames[0]);

        // resolve zk game
        zkGameProxy.resolve("");

        // nullify zk game
        zkGameProxy.nullify("", Claim.wrap(keccak256("2")));

        // check that the zk game is nullifed
        assert(zkGameProxy.status() == GameStatus.CHALLENGER_WINS);

        // check that the game type changed
        assert(GameType.unwrap(anchorStateRegistry.respectedGameType()) == 1);
    }

    function test2of3RequireTEE() public {
        RelayGameType[] memory relayGameTypes = new RelayGameType[](3);
        relayGameTypes[0] = RelayGameType({gameType: ZK_DISPUTE_GAME_TYPE, required: false});
        relayGameTypes[1] = RelayGameType({gameType: TEE_GAME_TYPE, required: true});
        relayGameTypes[2] = RelayGameType({gameType: FAULT_DISPUTE_GAME_TYPE, required: false});

        uint256 l2SequenceNumber = 1;
        bytes[] memory underlyingExtraData = new bytes[](3);
        underlyingExtraData[0] = abi.encode(l2SequenceNumber);
        underlyingExtraData[1] = abi.encode(l2SequenceNumber);
        underlyingExtraData[2] = abi.encode(l2SequenceNumber);

        DisputeGameRelay relayGame = _deployRelayGame(relayGameTypes, underlyingExtraData, l2SequenceNumber, 2);

        // check that the required game types are correct
        GameType[] memory requiredGameTypes = anchorStateRegistry.requiredGameTypes();
        assertEq(requiredGameTypes.length, 1);
        assertEq(requiredGameTypes[0].raw(), TEE_GAME_TYPE.raw());

        // zk, tee, fault
        address[] memory underlyingDisputeGames = relayGame.underlyingDisputeGames();

        MockZKDisputeGame zkGameProxy = MockZKDisputeGame(underlyingDisputeGames[0]);
        MockTEEDisputeGame teeGameProxy = MockTEEDisputeGame(underlyingDisputeGames[1]);
        FaultDisputeGame faultGameProxy = FaultDisputeGame(underlyingDisputeGames[2]);
        
        // resolve fault game
        vm.warp(block.timestamp + 7 days + 1);
        faultGameProxy.resolveClaim(0, 512);
        faultGameProxy.resolve();

        // resolve zk game
        zkGameProxy.resolve("");

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
        relayGameTypes[0] = RelayGameType({gameType: ZK_DISPUTE_GAME_TYPE, required: false});
        relayGameTypes[1] = RelayGameType({gameType: TEE_GAME_TYPE, required: false});
        relayGameTypes[2] = RelayGameType({gameType: FAULT_DISPUTE_GAME_TYPE, required: false});

        uint256 l2SequenceNumber = 1;
        bytes[] memory underlyingExtraData = new bytes[](3);
        underlyingExtraData[0] = abi.encode(l2SequenceNumber);
        underlyingExtraData[1] = abi.encode(l2SequenceNumber);
        underlyingExtraData[2] = abi.encode(l2SequenceNumber);

        DisputeGameRelay relayGame = _deployRelayGame(relayGameTypes, underlyingExtraData, l2SequenceNumber, 2);

        // zk, tee, fault
        address[] memory underlyingDisputeGames = relayGame.underlyingDisputeGames();

        MockZKDisputeGame zkGameProxy = MockZKDisputeGame(underlyingDisputeGames[0]);
        FaultDisputeGame faultGameProxy = FaultDisputeGame(underlyingDisputeGames[2]);

        // resolve zk game
        zkGameProxy.resolve("");

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

    receive() external payable {}

    function testBlacklistUnderlyingGame() public {
        // Deploy the relay game
        RelayGameType[] memory relayGameTypes = new RelayGameType[](3);
        relayGameTypes[0] = RelayGameType({gameType: ZK_DISPUTE_GAME_TYPE, required: false});
        relayGameTypes[1] = RelayGameType({gameType: TEE_GAME_TYPE, required: true});
        relayGameTypes[2] = RelayGameType({gameType: FAULT_DISPUTE_GAME_TYPE, required: false});

                uint256 l2SequenceNumber = 1;
        bytes[] memory underlyingExtraData = new bytes[](3);
        underlyingExtraData[0] = abi.encode(l2SequenceNumber);
        underlyingExtraData[1] = abi.encode(l2SequenceNumber);
        underlyingExtraData[2] = abi.encode(l2SequenceNumber);

        DisputeGameRelay relayGame = _deployRelayGame(relayGameTypes, underlyingExtraData, l2SequenceNumber, 2);

        // check that the relay game is not blacklisted
        assert(!anchorStateRegistry.isGameBlacklisted(IDisputeGame(address(relayGame))));

        // blacklist an underlying game
        address[] memory underlyingDisputeGames = relayGame.underlyingDisputeGames();
        anchorStateRegistry.blacklistDisputeGame(IDisputeGame(underlyingDisputeGames[0]));

        // check that the relay game is blacklisted
        assert(anchorStateRegistry.isGameBlacklisted(IDisputeGame(address(relayGame))));
    }

    function _deployContractsAndProxies() internal {
        // Deploy the system config
        systemConfig = new MockSystemConfig();

        // Deploy the relay anchor state registry
        RelayAnchorStateRegistry _anchorStateRegistry = new RelayAnchorStateRegistry(DISPUTE_GAME_FINALITY_DELAY_SECONDS);
        // Deploy the dispute game relay factory
        DisputeGameFactory _factory = new DisputeGameFactory();

        // Deploy proxy admin
        proxyAdmin = new ProxyAdmin();

        // Deploy proxy for anchor state registry
        TransparentUpgradeableProxy anchorStateRegistryProxy = new TransparentUpgradeableProxy(
            address(_anchorStateRegistry),
            address(proxyAdmin),
            ""
        );
        anchorStateRegistry = RelayAnchorStateRegistry(address(anchorStateRegistryProxy));
        
        // Deploy proxy for factory
        TransparentUpgradeableProxy factoryProxy = new TransparentUpgradeableProxy(
            address(_factory),
            address(proxyAdmin),
            ""
        );
        factory = DisputeGameFactory(address(factoryProxy));

        // Deploy the delayed WETH
        DelayedWETH _delayedWETH = new DelayedWETH(1 days);
        // Deploy proxy for delayed WETH
        TransparentUpgradeableProxy delayedWETHProxy = new TransparentUpgradeableProxy(
            address(_delayedWETH),
            address(proxyAdmin),
            ""
        );
        delayedWETH = DelayedWETH(payable(address(delayedWETHProxy)));
    }

    function _initializeProxies() internal {
        // Initialize the proxies
        anchorStateRegistry.initialize(ISystemConfig(address(systemConfig)), IDisputeGameFactory(address(factory)), Proposal({root: Hash.wrap(keccak256("0")), l2SequenceNumber: 0}), GameType.wrap(0));
        factory.initialize(address(this));
        delayedWETH.initialize(ISystemConfig(address(systemConfig)));
    }

    function _deployAndSetFaultDisputeGame() internal {
        // Deploy the preimage oracle
        preimageOracle = new MockPreimageOracle();

        // Deploy the VM
        bigStepper = new MockVM(IPreimageOracle(address(preimageOracle)));

        // Deploy the fault dispute game implementation
        FaultDisputeGame faultDisputeGameImpl = new FaultDisputeGame(
            FaultDisputeGame.GameConstructorParams({
                gameType: FAULT_DISPUTE_GAME_TYPE, // Default game type
                absolutePrestate: Claim.wrap(bytes32(0)),
                maxGameDepth: 64,
                splitDepth: 4,
                clockExtension: Duration.wrap(300), // 5 minutes
                maxClockDuration: Duration.wrap(3600), // 1 hour
                vm: IBigStepper(address(bigStepper)),
                weth: IDelayedWETH(payable(address(delayedWETH))),
                anchorStateRegistry: IAnchorStateRegistry(address(anchorStateRegistry)),
                l2ChainId: L2_CHAIN_ID
            })
        );

        // Set the implementation for the fault dispute game
        factory.setImplementation(GameType.wrap(0), IDisputeGame(address(faultDisputeGameImpl)));

        // Set the bond amount for the fault dispute game
        factory.setInitBond(GameType.wrap(0), FAULT_DISPUTE_GAME_BOND_AMOUNT);
    }

    function _deployAndSetTEEDisputeGame() internal {
        // Deploy the output oracle
        outputOracle = new MockOutputOracle();

        // Deploy the TEEDisputeGame implementation
        MockTEEDisputeGame teeDisputeGameImpl = new MockTEEDisputeGame(
            MockTEEDisputeGame.TEEConstructorParams({
                gameType: TEE_GAME_TYPE, // Default game type
                anchorStateRegistry: IAnchorStateRegistry(address(anchorStateRegistry)),
                l2ChainId: L2_CHAIN_ID,
                outputOracle: address(outputOracle)
            })
        );

        // Set the implementation for the TEEDisputeGame
        factory.setImplementation(GameType.wrap(733), IDisputeGame(address(teeDisputeGameImpl)));

        anchorStateRegistry.setFinalityDelay(TEE_GAME_TYPE, ZK_DISPUTE_GAME_FINALIZATION_DELAY_SECONDS);
    }

    function _deployAndSetZKDisputeGame() internal {
        // Deploy the verifier
        verifier = new MockZKVerifier();

        // Deploy the ZK dispute game implementation
        MockZKDisputeGame zkDisputeGameImpl = new MockZKDisputeGame(
            MockZKDisputeGame.ZKConstructorParams({
                gameType: ZK_DISPUTE_GAME_TYPE,
                anchorStateRegistry: IRelayAnchorStateRegistry(address(anchorStateRegistry)),
                l2ChainId: L2_CHAIN_ID,
                verifier: IZKVerifier(address(verifier)),
                finalizationDelay: ZK_DISPUTE_GAME_FINALIZATION_DELAY_SECONDS
            })
        );

        // Set the implementation for the ZKDisputeGame 
        factory.setImplementation(GameType.wrap(1337), IDisputeGame(address(zkDisputeGameImpl)));

        // Set the bond amount for the ZKDisputeGame
        factory.setInitBond(GameType.wrap(1337), ZK_DISPUTE_GAME_BOND_AMOUNT);

        anchorStateRegistry.setFinalityDelay(ZK_DISPUTE_GAME_TYPE, ZK_DISPUTE_GAME_FINALIZATION_DELAY_SECONDS);
    }

    function _deployAndSetDisputeGameRelay() internal {

    // Deploy the dispute game relay implementation
    DisputeGameRelay disputeGameRelayImpl = new DisputeGameRelay(
        DisputeGameRelay.RelayConstructorParams({
            anchorStateRegistry: IRelayAnchorStateRegistry(address(anchorStateRegistry)),
            l2ChainId: L2_CHAIN_ID
        })
    );

        // Set the implementation for the dispute game relay
        factory.setImplementation(RELAY_GAME_TYPE, IDisputeGame(address(disputeGameRelayImpl)));
        factory.setInitBond(RELAY_GAME_TYPE, TOTAL_BOND_AMOUNT);
    }

    function _deployRelayGame(RelayGameType[] memory _relayGameTypes, bytes[] memory _underlyingExtraData, uint256 _l2SequenceNumber, uint256 _threshold) internal returns (DisputeGameRelay) {
        require(_relayGameTypes.length == _underlyingExtraData.length, "Relay game types and underlying extra data must have the same length");
        
        anchorStateRegistry.setRespectedGameType(RELAY_GAME_TYPE);
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
