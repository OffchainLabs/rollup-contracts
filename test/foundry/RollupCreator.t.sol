// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.4;

import "forge-std/Test.sol";
import "./util/TestUtil.sol";
import "../../src/rollup/RollupCreator.sol";
import "../../src/rollup/RollupAdminLogic.sol";
import "../../src/rollup/RollupUserLogic.sol";
import "../../src/rollup/ValidatorWalletCreator.sol";
import "../../src/challengeV2/EdgeChallengeManager.sol";
import "../../src/osp/OneStepProver0.sol";
import "../../src/osp/OneStepProverMemory.sol";
import "../../src/osp/OneStepProverMath.sol";
import "../../src/osp/OneStepProverHostIo.sol";
import "../../src/osp/OneStepProofEntry.sol";
import "../../src/mocks/UpgradeExecutorMock.sol";
import "../../src/rollup/DeployHelper.sol";
import "../../src/mocks/TestWETH9.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import "@openzeppelin/contracts/token/ERC20/presets/ERC20PresetFixedSupply.sol";
import {NoZeroTransferToken} from "./util/NoZeroTransferToken.sol";

contract RollupCreatorTest is Test {
    RollupCreator public rollupCreator;
    address public rollupOwner = makeAddr("rollupOwner");
    address public deployer = makeAddr("deployer");
    IRollupAdmin public rollupAdmin;
    IRollupUser public rollupUser;
    DeployHelper public deployHelper;
    IReader4844 dummyReader4844 = IReader4844(address(137));
    IERC20 token;

    // 1 gwei
    uint256 public constant MAX_FEE_PER_GAS = 1_000_000_000;
    uint256 public constant MAX_DATA_SIZE = 117_964;

    BridgeCreator.BridgeTemplates public ethBasedTemplates = BridgeCreator.BridgeTemplates({
        bridge: new Bridge(),
        sequencerInbox: new SequencerInbox(MAX_DATA_SIZE, dummyReader4844, false, false),
        delayBufferableSequencerInbox: new SequencerInbox(MAX_DATA_SIZE, dummyReader4844, false, true),
        inbox: new Inbox(MAX_DATA_SIZE),
        rollupEventInbox: new RollupEventInbox(),
        outbox: new Outbox()
    });
    BridgeCreator.BridgeTemplates public erc20BasedTemplates = BridgeCreator.BridgeTemplates({
        bridge: new ERC20Bridge(),
        sequencerInbox: new SequencerInbox(MAX_DATA_SIZE, dummyReader4844, true, false),
        delayBufferableSequencerInbox: new SequencerInbox(MAX_DATA_SIZE, dummyReader4844, true, true),
        inbox: new ERC20Inbox(MAX_DATA_SIZE),
        rollupEventInbox: new ERC20RollupEventInbox(),
        outbox: new ERC20Outbox()
    });

    /* solhint-disable func-name-mixedcase */
    function setUp() public {
        //// deploy rollup creator and set templates
        vm.startPrank(deployer);
        rollupCreator = new RollupCreator();
        deployHelper = new DeployHelper();

        // deploy BridgeCreators
        BridgeCreator bridgeCreator = new BridgeCreator(ethBasedTemplates, erc20BasedTemplates);

        IUpgradeExecutor upgradeExecutorLogic = new UpgradeExecutorMock();

        (
            IOneStepProofEntry ospEntry,
            IEdgeChallengeManager challengeManager,
            IRollupAdmin _rollupAdmin,
            IRollupUser _rollupUser
        ) = _prepareRollupDeployment();

        rollupAdmin = _rollupAdmin;
        rollupUser = _rollupUser;

        //// deploy creator and set logic
        rollupCreator.setTemplates(
            bridgeCreator,
            ospEntry,
            challengeManager,
            _rollupAdmin,
            _rollupUser,
            upgradeExecutorLogic,
            address(new ValidatorWalletCreator()),
            deployHelper
        );

        token = new TestWETH9("Test", "TEST");
        vm.deal(deployer, 10 ether);
        IWETH9(address(token)).deposit{value: 10 ether}();

        vm.stopPrank();
    }

    function test_createEthRollup() public {
        vm.startPrank(deployer);

        // deployment params
        ISequencerInbox.MaxTimeVariation memory timeVars =
            ISequencerInbox.MaxTimeVariation(((60 * 60 * 24) / 15), 12, 60 * 60 * 24, 60 * 60);
        uint256[] memory miniStakeValues = new uint256[](3);
        miniStakeValues[0] = 1 ether;
        miniStakeValues[1] = 2 ether;
        miniStakeValues[2] = 3 ether;
        AssertionState memory emptyState = AssertionState(
            GlobalState([bytes32(0), bytes32(0)], [uint64(0), uint64(0)]),
            MachineStatus.FINISHED,
            bytes32(0)
        );
        Config memory config = Config({
            baseStake: 1000,
            chainId: 1337,
            chainConfig: "abc",
            minimumAssertionPeriod: 75,
            validatorAfkBlocks: 1234,
            confirmPeriodBlocks: 567,
            owner: rollupOwner,
            sequencerInboxMaxTimeVariation: timeVars,
            stakeToken: address(token),
            wasmModuleRoot: keccak256("wasm"),
            loserStakeEscrow: address(200),
            genesisAssertionState: emptyState,
            genesisInboxCount: 0,
            miniStakeValues: miniStakeValues,
            layerZeroBlockEdgeHeight: 2 ** 5,
            layerZeroBigStepEdgeHeight: 2 ** 5,
            layerZeroSmallStepEdgeHeight: 2 ** 5,
            anyTrustFastConfirmer: address(0),
            numBigStepLevel: 1,
            challengeGracePeriodBlocks: 10,
            bufferConfig: BufferConfig({threshold: 600, max: 14400, replenishRateInBasis: 500})
        });

        // prepare funds
        uint256 factoryDeploymentFunds = 1 ether;
        vm.deal(deployer, factoryDeploymentFunds);
        uint256 balanceBefore = deployer.balance;

        /// deploy rollup
        address[] memory batchPosters = new address[](1);
        batchPosters[0] = makeAddr("batch poster 1");
        address batchPosterManager = makeAddr("batch poster manager");
        address[] memory validators = new address[](2);
        validators[0] = makeAddr("validator1");
        validators[1] = makeAddr("validator2");

        RollupCreator.RollupDeploymentParams memory deployParams = RollupCreator
            .RollupDeploymentParams({
            config: config,
            batchPosters: batchPosters,
            validators: validators,
            maxDataSize: MAX_DATA_SIZE,
            nativeToken: address(0),
            deployFactoriesToL2: true,
            maxFeePerGasForRetryables: MAX_FEE_PER_GAS,
            batchPosterManager: batchPosterManager,
            feeTokenPricer: IFeeTokenPricer(address(0))
        });
        address rollupAddress =
            rollupCreator.createRollup{value: factoryDeploymentFunds}(deployParams);

        vm.stopPrank();

        /// common checks

        /// rollup creator
        assertEq(IOwnable(address(rollupCreator)).owner(), deployer, "Invalid rollupCreator owner");

        /// rollup proxy
        assertEq(_getPrimary(rollupAddress), address(rollupAdmin), "Invalid proxy primary impl");
        assertEq(_getSecondary(rollupAddress), address(rollupUser), "Invalid proxy secondary impl");

        /// rollup check
        RollupCore rollup = RollupCore(rollupAddress);
        assertTrue(address(rollup.sequencerInbox()) != address(0), "Invalid seqInbox");
        assertTrue(address(rollup.bridge()) != address(0), "Invalid bridge");
        assertTrue(address(rollup.inbox()) != address(0), "Invalid inbox");
        assertTrue(address(rollup.outbox()) != address(0), "Invalid outbox");
        assertTrue(address(rollup.rollupEventInbox()) != address(0), "Invalid rollupEventInbox");
        assertTrue(address(rollup.challengeManager()) != address(0), "Invalid challengeManager");
        assertTrue(rollup.isValidator(validators[0]), "Invalid validator set");
        assertTrue(rollup.isValidator(validators[1]), "Invalid validator set");
        assertTrue(rollup.sequencerInbox().isBatchPoster(batchPosters[0]), "Invalid batch poster");
        assertEq(
            rollup.sequencerInbox().batchPosterManager(),
            batchPosterManager,
            "Invalid batch poster manager"
        );
        assertEq(
            rollup.validatorAfkBlocks(), config.validatorAfkBlocks, "Invalid validatorAfkBlocks"
        );
        assertEq(
            rollup.confirmPeriodBlocks(), config.confirmPeriodBlocks, "Invalid confirmPeriodBlocks"
        );

        // check proxy admin for non-rollup contracts
        address proxyAdminExpectedAddress = computeCreateAddress(address(rollupCreator), 1);

        assertEq(
            _getProxyAdmin(address(rollup.sequencerInbox())),
            proxyAdminExpectedAddress,
            "Invalid seqInbox' proxyAdmin owner"
        );
        assertEq(
            _getProxyAdmin(address(rollup.bridge())),
            proxyAdminExpectedAddress,
            "Invalid bridge's proxyAdmin owner"
        );
        assertEq(
            rollup.inbox().getProxyAdmin(),
            proxyAdminExpectedAddress,
            "Invalid inbox' proxyAdmin owner"
        );
        assertEq(
            _getProxyAdmin(address(rollup.outbox())),
            proxyAdminExpectedAddress,
            "Invalid outbox' proxyAdmin owner"
        );
        assertEq(
            _getProxyAdmin(address(rollup.rollupEventInbox())),
            proxyAdminExpectedAddress,
            "Invalid rollupEventInbox' proxyAdmin owner"
        );
        assertEq(
            _getProxyAdmin(address(rollup.challengeManager())),
            proxyAdminExpectedAddress,
            "Invalid challengeManager's proxyAdmin owner"
        );

        // check upgrade executor owns proxyAdmin
        address upgradeExecutorExpectedAddress = computeCreateAddress(address(rollupCreator), 4);
        assertEq(
            ProxyAdmin(_getProxyAdmin(address(rollup.sequencerInbox()))).owner(),
            upgradeExecutorExpectedAddress,
            "Invalid proxyAdmin's owner"
        );

        // upgrade executor owns rollup
        assertEq(
            IOwnable(rollupAddress).owner(), upgradeExecutorExpectedAddress, "Invalid rollup owner"
        );
        assertEq(
            _getProxyAdmin(rollupAddress),
            upgradeExecutorExpectedAddress,
            "Invalid rollup's proxyAdmin owner"
        );

        // check rollupOwner has executor role
        AccessControlUpgradeable executor = AccessControlUpgradeable(upgradeExecutorExpectedAddress);
        assertTrue(
            executor.hasRole(keccak256("EXECUTOR_ROLE"), rollupOwner), "Invalid executor role"
        );

        // check funds are refunded
        uint256 balanceAfter = deployer.balance;
        uint256 factoryDeploymentCost =
            deployHelper.getDeploymentTotalCost(rollup.inbox(), MAX_FEE_PER_GAS);
        assertEq(balanceBefore - balanceAfter, factoryDeploymentCost, "Invalid balance");
    }

    function test_createErc20Rollup() public {
        address nativeToken =
            address(new ERC20PresetFixedSupply("Appchain Token", "App", 1_000_000 ether, deployer));

        _createERC20Rollup(nativeToken);
    }

    function test_createErc20RollupNoZeroTransfer() public {
        address nativeToken =
            address(new NoZeroTransferToken("Appchain Token", "App", 1_000_000 ether, deployer));

        _createERC20Rollup(nativeToken);
    }

    function _createERC20Rollup(
        address nativeToken
    ) internal {
        vm.startPrank(deployer);

        // deployment params
        ISequencerInbox.MaxTimeVariation memory timeVars =
            ISequencerInbox.MaxTimeVariation(((60 * 60 * 24) / 15), 12, 60 * 60 * 24, 60 * 60);
        uint256[] memory miniStakeValues = new uint256[](3);
        miniStakeValues[0] = 1 ether;
        miniStakeValues[1] = 2 ether;
        miniStakeValues[2] = 3 ether;
        AssertionState memory emptyState = AssertionState(
            GlobalState([bytes32(0), bytes32(0)], [uint64(0), uint64(0)]),
            MachineStatus.FINISHED,
            bytes32(0)
        );
        Config memory config = Config({
            baseStake: 1000,
            chainId: 1337,
            chainConfig: "abc",
            minimumAssertionPeriod: 75,
            validatorAfkBlocks: 1234,
            confirmPeriodBlocks: 567,
            owner: rollupOwner,
            sequencerInboxMaxTimeVariation: timeVars,
            stakeToken: address(token),
            wasmModuleRoot: keccak256("wasm"),
            loserStakeEscrow: address(200),
            genesisAssertionState: emptyState,
            genesisInboxCount: 0,
            miniStakeValues: miniStakeValues,
            layerZeroBlockEdgeHeight: 2 ** 5,
            layerZeroBigStepEdgeHeight: 2 ** 5,
            layerZeroSmallStepEdgeHeight: 2 ** 5,
            anyTrustFastConfirmer: address(0),
            numBigStepLevel: 1,
            challengeGracePeriodBlocks: 10,
            bufferConfig: BufferConfig({threshold: 600, max: 14400, replenishRateInBasis: 500})
        });

        // approve fee token to pay for deployment of L2 factories
        uint256 expectedCost = 0.1247 ether + 4 * (1400 * 100_000_000_000 + 100_000 * 1_000_000_000);
        IERC20(nativeToken).approve(address(rollupCreator), expectedCost);

        /// deploy rollup
        address[] memory batchPosters = new address[](1);
        batchPosters[0] = makeAddr("batch poster 1");
        address batchPosterManager = makeAddr("batch poster manager");
        address[] memory validators = new address[](2);
        validators[0] = makeAddr("validator1");
        validators[1] = makeAddr("validator2");

        IFeeTokenPricer feeTokenPricer = IFeeTokenPricer(makeAddr("feeTokenPricer"));
        RollupCreator.RollupDeploymentParams memory deployParams = RollupCreator
            .RollupDeploymentParams({
            config: config,
            batchPosters: batchPosters,
            validators: validators,
            maxDataSize: MAX_DATA_SIZE,
            nativeToken: nativeToken,
            deployFactoriesToL2: true,
            maxFeePerGasForRetryables: MAX_FEE_PER_GAS,
            batchPosterManager: batchPosterManager,
            feeTokenPricer: feeTokenPricer
        });

        vm.mockCall(
            address(feeTokenPricer),
            abi.encodeWithSelector(IFeeTokenPricer.getExchangeRate.selector),
            abi.encode(uint256(16.421e18))
        );

        address rollupAddress = rollupCreator.createRollup(deployParams);

        vm.stopPrank();

        _postCreateERC20RollupChecks(
            config, rollupAddress, batchPosterManager, nativeToken, validators, batchPosters
        );
    }

    function _postCreateERC20RollupChecks(
        Config memory config,
        address rollupAddress,
        address batchPosterManager,
        address nativeToken,
        address[] memory validators,
        address[] memory batchPosters
    ) internal {
        /// common checks

        /// rollup creator
        assertEq(IOwnable(address(rollupCreator)).owner(), deployer, "Invalid rollupCreator owner");

        /// rollup proxy
        assertEq(_getPrimary(rollupAddress), address(rollupAdmin), "Invalid proxy primary impl");
        assertEq(_getSecondary(rollupAddress), address(rollupUser), "Invalid proxy secondary impl");

        /// rollup check
        RollupCore rollup = RollupCore(rollupAddress);
        assertTrue(address(rollup.sequencerInbox()) != address(0), "Invalid seqInbox");
        assertTrue(address(rollup.bridge()) != address(0), "Invalid bridge");
        assertTrue(address(rollup.inbox()) != address(0), "Invalid inbox");
        assertTrue(address(rollup.outbox()) != address(0), "Invalid outbox");
        assertTrue(address(rollup.rollupEventInbox()) != address(0), "Invalid rollupEventInbox");
        assertTrue(address(rollup.challengeManager()) != address(0), "Invalid challengeManager");
        assertTrue(rollup.isValidator(validators[0]), "Invalid validator set");
        assertTrue(rollup.isValidator(validators[1]), "Invalid validator set");
        assertTrue(
            ISequencerInbox(address(rollup.sequencerInbox())).isBatchPoster(batchPosters[0]),
            "Invalid batch poster"
        );
        assertEq(
            ISequencerInbox(address(rollup.sequencerInbox())).batchPosterManager(),
            batchPosterManager,
            "Invalid batch poster manager"
        );
        assertEq(
            rollup.validatorAfkBlocks(), config.validatorAfkBlocks, "Invalid validatorAfkBlocks"
        );
        assertEq(
            rollup.confirmPeriodBlocks(), config.confirmPeriodBlocks, "Invalid confirmPeriodBlocks"
        );

        // native token check
        IBridge bridge = RollupCore(address(rollupAddress)).bridge();
        assertEq(
            IERC20Bridge(address(bridge)).nativeToken(), nativeToken, "Invalid native token ref"
        );

        // check proxy admin for non-rollup contracts
        address proxyAdminExpectedAddress = computeCreateAddress(address(rollupCreator), 1);

        assertEq(
            _getProxyAdmin(address(rollup.sequencerInbox())),
            proxyAdminExpectedAddress,
            "Invalid seqInbox' proxyAdmin owner"
        );
        assertEq(
            _getProxyAdmin(address(rollup.bridge())),
            proxyAdminExpectedAddress,
            "Invalid bridge's proxyAdmin owner"
        );
        assertEq(
            _getProxyAdmin(address(rollup.inbox())),
            proxyAdminExpectedAddress,
            "Invalid inbox' proxyAdmin owner"
        );
        assertEq(
            _getProxyAdmin(address(rollup.outbox())),
            proxyAdminExpectedAddress,
            "Invalid outbox' proxyAdmin owner"
        );
        assertEq(
            _getProxyAdmin(address(rollup.rollupEventInbox())),
            proxyAdminExpectedAddress,
            "Invalid rollupEventInbox' proxyAdmin owner"
        );
        assertEq(
            _getProxyAdmin(address(rollup.challengeManager())),
            proxyAdminExpectedAddress,
            "Invalid challengeManager's proxyAdmin owner"
        );

        // check upgrade executor owns proxyAdmin
        address upgradeExecutorExpectedAddress = computeCreateAddress(address(rollupCreator), 4);
        assertEq(
            ProxyAdmin(_getProxyAdmin(address(rollup.sequencerInbox()))).owner(),
            upgradeExecutorExpectedAddress,
            "Invalid proxyAdmin's owner"
        );

        // upgrade executor owns rollup
        assertEq(
            IOwnable(rollupAddress).owner(), upgradeExecutorExpectedAddress, "Invalid rollup owner"
        );
        assertEq(
            _getProxyAdmin(rollupAddress),
            upgradeExecutorExpectedAddress,
            "Invalid rollup's proxyAdmin owner"
        );

        // check rollupOwner has executor role
        AccessControlUpgradeable executor = AccessControlUpgradeable(upgradeExecutorExpectedAddress);
        assertTrue(
            executor.hasRole(keccak256("EXECUTOR_ROLE"), rollupOwner), "Invalid executor role"
        );
    }

    function test_upgrade() public {
        vm.startPrank(deployer);

        // deployment params
        ISequencerInbox.MaxTimeVariation memory timeVars =
            ISequencerInbox.MaxTimeVariation(((60 * 60 * 24) / 15), 12, 60 * 60 * 24, 60 * 60);
        uint256[] memory miniStakeValues = new uint256[](3);
        miniStakeValues[0] = 1 ether;
        miniStakeValues[1] = 2 ether;
        miniStakeValues[2] = 3 ether;
        AssertionState memory emptyState = AssertionState(
            GlobalState([bytes32(0), bytes32(0)], [uint64(0), uint64(0)]),
            MachineStatus.FINISHED,
            bytes32(0)
        );
        Config memory config = Config({
            baseStake: 1000,
            chainId: 1337,
            chainConfig: "abc",
            minimumAssertionPeriod: 75,
            validatorAfkBlocks: 1234,
            confirmPeriodBlocks: 567,
            owner: rollupOwner,
            sequencerInboxMaxTimeVariation: timeVars,
            stakeToken: address(token),
            wasmModuleRoot: keccak256("wasm"),
            loserStakeEscrow: address(200),
            genesisAssertionState: emptyState,
            genesisInboxCount: 0,
            miniStakeValues: miniStakeValues,
            layerZeroBlockEdgeHeight: 2 ** 5,
            layerZeroBigStepEdgeHeight: 2 ** 5,
            layerZeroSmallStepEdgeHeight: 2 ** 5,
            anyTrustFastConfirmer: address(0),
            numBigStepLevel: 1,
            challengeGracePeriodBlocks: 10,
            bufferConfig: BufferConfig({threshold: 600, max: 14400, replenishRateInBasis: 500})
        });

        // prepare funds
        uint256 factoryDeploymentFunds = 0.2 ether;
        vm.deal(deployer, factoryDeploymentFunds);

        /// deploy rollup
        address[] memory batchPosters = new address[](1);
        batchPosters[0] = makeAddr("batch poster 1");
        address batchPosterManager = makeAddr("batch poster manager");
        address[] memory validators = new address[](2);
        validators[0] = makeAddr("validator1");
        validators[1] = makeAddr("validator2");

        RollupCreator.RollupDeploymentParams memory deployParams = RollupCreator
            .RollupDeploymentParams({
            config: config,
            batchPosters: batchPosters,
            validators: validators,
            maxDataSize: MAX_DATA_SIZE,
            nativeToken: address(0),
            deployFactoriesToL2: true,
            maxFeePerGasForRetryables: MAX_FEE_PER_GAS,
            batchPosterManager: batchPosterManager,
            feeTokenPricer: IFeeTokenPricer(address(0))
        });
        address rollupAddress =
            rollupCreator.createRollup{value: factoryDeploymentFunds}(deployParams);

        vm.stopPrank();

        //// upgrade inbox
        RollupCore rollup = RollupCore(rollupAddress);
        address inbox = address(rollup.inbox());
        address proxyAdmin = computeCreateAddress(address(rollupCreator), 1);
        IUpgradeExecutor upgradeExecutor =
            IUpgradeExecutor(computeCreateAddress(address(rollupCreator), 4));

        Dummy newLogicImpl = new Dummy();
        bytes memory data = abi.encodeWithSelector(
            ProxyUpgradeAction.perform.selector, address(proxyAdmin), inbox, address(newLogicImpl)
        );

        address upgradeAction = address(new ProxyUpgradeAction());
        vm.prank(rollupOwner);
        upgradeExecutor.execute(upgradeAction, data);

        // check upgrade was successful
        assertEq(_getImpl(inbox), address(newLogicImpl));
    }

    function _prepareRollupDeployment()
        internal
        returns (
            IOneStepProofEntry ospEntry,
            IEdgeChallengeManager challengeManager,
            IRollupAdmin rollupAdminLogic,
            IRollupUser rollupUserLogic
        )
    {
        //// deploy challenge stuff
        ospEntry = new OneStepProofEntry(
            new OneStepProver0(),
            new OneStepProverMemory(),
            new OneStepProverMath(),
            new OneStepProverHostIo()
        );
        challengeManager = new EdgeChallengeManager();

        //// deploy rollup logic
        rollupAdminLogic = IRollupAdmin(new RollupAdminLogic());
        rollupUserLogic = IRollupUser(new RollupUserLogic());

        return (ospEntry, challengeManager, rollupAdminLogic, rollupUserLogic);
    }

    function _getProxyAdmin(
        address proxy
    ) internal view returns (address) {
        bytes32 adminSlot = bytes32(uint256(keccak256("eip1967.proxy.admin")) - 1);
        return address(uint160(uint256(vm.load(proxy, adminSlot))));
    }

    function _getImpl(
        address proxy
    ) internal view returns (address) {
        bytes32 implSlot = bytes32(uint256(keccak256("eip1967.proxy.implementation")) - 1);
        return address(uint160(uint256(vm.load(proxy, implSlot))));
    }

    function _getPrimary(
        address proxy
    ) internal view returns (address) {
        bytes32 primarySlot = bytes32(uint256(keccak256("eip1967.proxy.implementation")) - 1);
        return address(uint160(uint256(vm.load(proxy, primarySlot))));
    }

    function _getSecondary(
        address proxy
    ) internal view returns (address) {
        bytes32 secondarySlot =
            bytes32(uint256(keccak256("eip1967.proxy.implementation.secondary")) - 1);
        return address(uint160(uint256(vm.load(proxy, secondarySlot))));
    }
}

contract ProxyUpgradeAction {
    function perform(address admin, address payable target, address newLogic) public payable {
        ProxyAdmin(admin).upgrade(TransparentUpgradeableProxy(target), newLogic);
    }
}

contract Dummy {
    function dummy() public {}
}
