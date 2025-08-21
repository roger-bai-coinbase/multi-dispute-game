// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import { Test, console2 } from "forge-std/Test.sol";

// Relay Contracts
import { RelayAnchorStateRegistry } from "src/RelayAnchorStateRegistry.sol";
import { DisputeGameRelay } from "src/DisputeGameRelay.sol";
import { IRelayAnchorStateRegistry } from "src/interfaces/IRelayAnchorStateRegistry.sol";
import { IZKVerifier } from "src/interfaces/IZKVerifier.sol";

// ZKDisputeGame
import { ZKDisputeGame } from "src/ZKDisputeGame.sol";

// Mocks
import { MockTEEDisputeGame } from "src/mocks/MockTEEDisputeGame.sol";
import { MockOutputOracle } from "src/mocks/MockOutputOracle.sol";
import { MockVM } from "src/mocks/MockVM.sol";
import { MockPreimageOracle } from "src/mocks/MockPreimageOracle.sol";
import { MockZKDisputeGame } from "src/mocks/MockZKDisputeGame.sol";
import { MockZKVerifier } from "src/mocks/MockZKVerifier.sol";
import { MockSystemConfig } from "src/mocks/MockSystemConfig.sol";

// Optimism
import { FaultDisputeGame, IAnchorStateRegistry, IDelayedWETH, IBigStepper, IPreimageOracle } from "optimism/src/dispute/FaultDisputeGame.sol";
import { IDisputeGame, DisputeGameFactory } from "optimism/src/dispute/DisputeGameFactory.sol";
import { GameType, Duration, Claim } from "optimism/src/dispute/lib/Types.sol";
import { ISystemConfig, IDisputeGameFactory, Hash, Proposal } from "optimism/src/dispute/AnchorStateRegistry.sol";
import { DelayedWETH } from "optimism/src/dispute/DelayedWETH.sol";

// OpenZeppelin
import { ProxyAdmin } from "@openzeppelin/contracts/proxy/transparent/ProxyAdmin.sol";
import { TransparentUpgradeableProxy } from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";

contract BaseTest is Test {
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
    GameType public constant MOCK_ZK_DISPUTE_GAME_TYPE = GameType.wrap(1337);
    GameType public constant ZK_DISPUTE_GAME_TYPE = GameType.wrap(621);
    GameType public constant RELAY_GAME_TYPE = GameType.wrap(type(uint32).max);

    // Bond amounts
    uint256 public constant FAULT_DISPUTE_GAME_BOND_AMOUNT = 0.1 ether;
    uint256 public constant ZK_DISPUTE_GAME_BOND_AMOUNT = 0.1 ether;

    uint256 public constant TOTAL_BOND_AMOUNT = FAULT_DISPUTE_GAME_BOND_AMOUNT + ZK_DISPUTE_GAME_BOND_AMOUNT;
    
    uint256 public constant L2_CHAIN_ID = 8453;
    uint256 public constant ZK_DISPUTE_GAME_BLOCK_INTERVAL = 100;

    function setUp() public virtual {
        _deployContractsAndProxies();
        _initializeProxies();

        // Deploy the implementations
        _deployAndSetFaultDisputeGame();
        _deployAndSetTEEDisputeGame();
        _deployAndSetMockZKDisputeGame();
        _deployAndSetZKDisputeGame();
        _deployAndSetDisputeGameRelay();

        // Set the timestamp to after the retirement timestamp
        vm.warp(block.timestamp + 1);
        vm.deal(address(this), TOTAL_BOND_AMOUNT);
    }

    receive() external payable {}

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
                maxGameDepth: 73,
                splitDepth: 30,
                clockExtension: Duration.wrap(10800), // 3 hours
                maxClockDuration: Duration.wrap(302400), // 3.5 days
                vm: IBigStepper(address(bigStepper)),
                weth: IDelayedWETH(payable(address(delayedWETH))),
                anchorStateRegistry: IAnchorStateRegistry(address(anchorStateRegistry)),
                l2ChainId: L2_CHAIN_ID
            })
        );

        // Set the implementation for the fault dispute game
        factory.setImplementation(FAULT_DISPUTE_GAME_TYPE, IDisputeGame(address(faultDisputeGameImpl)));

        // Set the bond amount for the fault dispute game
        factory.setInitBond(FAULT_DISPUTE_GAME_TYPE, FAULT_DISPUTE_GAME_BOND_AMOUNT);
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
        factory.setImplementation(TEE_GAME_TYPE, IDisputeGame(address(teeDisputeGameImpl)));

        anchorStateRegistry.setFinalityDelay(TEE_GAME_TYPE, ZK_DISPUTE_GAME_FINALIZATION_DELAY_SECONDS);
    }

    function _deployAndSetMockZKDisputeGame() internal {
        // Deploy the verifier
        verifier = new MockZKVerifier();

        // Deploy the ZK dispute game implementation
        MockZKDisputeGame zkDisputeGameImpl = new MockZKDisputeGame(
            MockZKDisputeGame.ZKConstructorParams({
                gameType: MOCK_ZK_DISPUTE_GAME_TYPE,
                anchorStateRegistry: IRelayAnchorStateRegistry(address(anchorStateRegistry)),
                l2ChainId: L2_CHAIN_ID,
                verifier: IZKVerifier(address(verifier)),
                finalizationDelay: ZK_DISPUTE_GAME_FINALIZATION_DELAY_SECONDS
            })
        );

        // Set the implementation for the ZKDisputeGame 
        factory.setImplementation(MOCK_ZK_DISPUTE_GAME_TYPE, IDisputeGame(address(zkDisputeGameImpl)));

        // Set the bond amount for the ZKDisputeGame
        factory.setInitBond(MOCK_ZK_DISPUTE_GAME_TYPE, ZK_DISPUTE_GAME_BOND_AMOUNT);

        anchorStateRegistry.setFinalityDelay(MOCK_ZK_DISPUTE_GAME_TYPE, ZK_DISPUTE_GAME_FINALIZATION_DELAY_SECONDS);
    }

    function _deployAndSetZKDisputeGame() internal {
        // Deploy the verifier
        verifier = new MockZKVerifier();

        // Deploy the ZK dispute game implementation
        ZKDisputeGame zkDisputeGameImpl = new ZKDisputeGame({
            _gameType: ZK_DISPUTE_GAME_TYPE,
            _maxChallengeDuration: Duration.wrap(302400), // 3.5 days
            _maxProveDuration: Duration.wrap(302400), // 3.5 days
            _anchorStateRegistry: IRelayAnchorStateRegistry(address(anchorStateRegistry)),
            _l2ChainId: L2_CHAIN_ID,
            _verifier: IZKVerifier(address(verifier)),
            _challengerBond: ZK_DISPUTE_GAME_BOND_AMOUNT,
            _blockInterval: ZK_DISPUTE_GAME_BLOCK_INTERVAL
        });

        // Set the implementation for the ZKDisputeGame
        factory.setImplementation(ZK_DISPUTE_GAME_TYPE, IDisputeGame(address(zkDisputeGameImpl)));

        // Set the bond amount for the ZKDisputeGame
        factory.setInitBond(ZK_DISPUTE_GAME_TYPE, ZK_DISPUTE_GAME_BOND_AMOUNT);

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
}