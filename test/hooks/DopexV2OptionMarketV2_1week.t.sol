// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import "forge-std/Test.sol";

import {IUniswapV3Factory} from "@uniswap/v3-core/contracts/interfaces/IUniswapV3Factory.sol";
import {IUniswapV3Pool} from "@uniswap/v3-core/contracts/interfaces/IUniswapV3Pool.sol";

import {UniswapV3TestLib} from "../uniswap-v3-utils/UniswapV3TestLib.sol";
import {ERC20Mock} from "../mocks/ERC20Mock.sol";
import {TickMath} from "@uniswap/v3-core/contracts/libraries/TickMath.sol";
import {LiquidityAmounts} from "v3-periphery/libraries/LiquidityAmounts.sol";

import {DopexV2PositionManager} from "../../src/DopexV2PositionManager.sol";
import {UniswapV3SingleTickLiquidityHarnessV2} from "../harness/UniswapV3SingleTickLiquidityHandlerV2.harness.sol";
import {UniswapV3SingleTickLiquidityHandlerV2} from "../../src/handlers/UniswapV3SingleTickLiquidityHandlerV2.sol";
import {DopexV2OptionMarketV2} from "../../src/DopexV2OptionMarketV2.sol";

import {OptionPricingV2} from "../pricing/OptionPricingV2.sol";
import {DopexV2ClammFeeStrategyV2} from "../../src/pricing/fees/DopexV2ClammFeeStrategyV2.sol";
import {SwapRouterSwapper} from "../../src/swapper/SwapRouterSwapper.sol";
import {AutoExerciseTimeBased} from "../../src/periphery/AutoExerciseTimeBased.sol";

import {IOptionPricingV2} from "../../src/pricing/IOptionPricingV2.sol";
import {IHandler} from "../../src/interfaces/IHandler.sol";
import {ISwapper} from "../../src/interfaces/ISwapper.sol";
import {IOptionMarket} from "../../src/interfaces/IOptionMarket.sol";

import {BoundedTTLHook_1Week} from "../../src/handlers/hooks/BoundedTTLHook_1Week.sol";

contract optionMarketTest is Test {
    using TickMath for int24;

    address ETH; // token1
    address LUSD; // token0

    ERC20Mock token0;
    ERC20Mock token1;

    UniswapV3TestLib uniswapV3TestLib;
    IUniswapV3Pool pool;

    OptionPricingV2 op;
    SwapRouterSwapper srs;

    uint24 fee = 500;

    uint160 initSqrtPriceX96 = 1771845812700903892492222464; // 1 ETH = 2000 LUSD

    int24 tickLowerCalls = -76260; // ~2050
    int24 tickUpperCalls = -76250; // ~2048

    int24 tickLowerPuts = -75770; // ~1950
    int24 tickUpperPuts = -75760; // ~1952

    uint256 premiumAmountCalls = 100;
    uint256 premiumAmountPuts = 100;

    uint256 optionIdCalls;
    uint256 optionIdPuts;

    address alice = makeAddr("alice"); // main LP
    address bob = makeAddr("bob"); // protocol LP
    address jason = makeAddr("jason"); // protocol LP
    address trader = makeAddr("trader"); // option buyer
    address garbage = makeAddr("garbage"); // garbage address
    address feeToAutoExercise = makeAddr("feeToAutoExercise"); // auto exercise fee to
    address autoExercisoor = makeAddr("autoExercisoor"); // auto exciseroor role

    DopexV2PositionManager positionManager;
    UniswapV3SingleTickLiquidityHarnessV2 positionManagerHarness;
    DopexV2OptionMarketV2 optionMarket;
    UniswapV3SingleTickLiquidityHandlerV2 uniV3Handler;
    DopexV2ClammFeeStrategyV2 feeStrategy;
    AutoExerciseTimeBased autoExercise;
    BoundedTTLHook_1Week hook;
    address hookAddress;

    function setUp() public {
        vm.warp(1693352493);

        ETH = address(new ERC20Mock());
        LUSD = address(new ERC20Mock());

        uniswapV3TestLib = new UniswapV3TestLib();
        pool = IUniswapV3Pool(
            uniswapV3TestLib.deployUniswapV3PoolAndInitializePrice(
                ETH,
                LUSD,
                fee,
                initSqrtPriceX96
            )
        );

        token0 = ERC20Mock(pool.token0());
        token1 = ERC20Mock(pool.token1());

        positionManager = new DopexV2PositionManager();

        uniV3Handler = new UniswapV3SingleTickLiquidityHandlerV2(
            address(uniswapV3TestLib.factory()),
            0xa598dd2fba360510c5a8f02f44423a4468e902df5857dbce3ca162a43a3a31ff,
            address(uniswapV3TestLib.swapRouter())
        );

        positionManagerHarness = new UniswapV3SingleTickLiquidityHarnessV2(
            uniswapV3TestLib,
            positionManager,
            uniV3Handler
        );

        op = new OptionPricingV2(500, 1e8);
        srs = new SwapRouterSwapper(address(uniswapV3TestLib.swapRouter()));

        feeStrategy = new DopexV2ClammFeeStrategyV2();

        optionMarket = new DopexV2OptionMarketV2(
            address(positionManager),
            address(op),
            address(feeStrategy),
            ETH,
            LUSD,
            address(pool)
        );

        // Add 0.15% fee to the market
        feeStrategy.registerOptionMarket(address(optionMarket), 350000);

        uint256[] memory ttls = new uint256[](2);
        ttls[0] = 1 weeks;
        ttls[1] = 2 weeks;

        uint256[] memory IVs = new uint256[](2);
        IVs[0] = 100;
        IVs[1] = 200;

        address feeCollector = makeAddr("feeCollector");

        op.updateIVs(ttls, IVs);
        optionMarket.updateAddress(
            feeCollector,
            address(0),
            address(feeStrategy),
            address(op),
            address(this),
            true,
            address(pool),
            true
        );
        uniswapV3TestLib.addLiquidity(
            UniswapV3TestLib.AddLiquidityStruct({
                user: alice,
                pool: pool,
                desiredTickLower: -78245, // 2500
                desiredTickUpper: -73136, // 1500
                desiredAmount0: 5_000_000e18,
                desiredAmount1: 0,
                requireMint: true
            })
        );

        positionManager.updateWhitelistHandlerWithApp(
            address(uniV3Handler),
            address(optionMarket),
            true
        );

        positionManager.updateWhitelistHandler(address(uniV3Handler), true);

        uniV3Handler.updateWhitelistedApps(address(positionManager), true);

        autoExercise = new AutoExerciseTimeBased();

        autoExercise.updateFeeTo(feeToAutoExercise);

        autoExercise.grantRole(keccak256("EXECUTOR"), autoExercisoor);

        hook = new BoundedTTLHook_1Week();
        hookAddress = address(hook);
        hook.updateWhitelistedAppsStatus(address(optionMarket), true);

        // for calls
        positionManagerHarness.mintPosition(
            token0,
            token1,
            0,
            5e18,
            -76260, // ~2050,
            -76250, // ~2048,
            pool,
            hookAddress,
            bob
        );

        positionManagerHarness.mintPosition(
            token0,
            token1,
            0,
            5e18,
            -76260, // ~2050,
            -76250, // ~2048,
            pool,
            hookAddress,
            jason
        );

        // for puts
        positionManagerHarness.mintPosition(
            token0,
            token1,
            10_000e18,
            0,
            -75770, // ~1950,
            -75760, // ~1952,
            pool,
            hookAddress,
            bob
        );

        positionManagerHarness.mintPosition(
            token0,
            token1,
            10_000e18,
            0,
            -75770, // ~1950,
            -75760, // ~1952,
            pool,
            hookAddress,
            jason
        );
    }

    function testBuyCallOption() public {
        vm.startPrank(trader);
        uint256 l = LiquidityAmounts.getLiquidityForAmount1(
            tickLowerCalls.getSqrtRatioAtTick(),
            tickUpperCalls.getSqrtRatioAtTick(),
            5e18
        );

        uint256 _premiumAmountCalls = optionMarket.getPremiumAmount(
            false,
            block.timestamp + 1 weeks,
            optionMarket.getPricePerCallAssetViaTick(pool, tickUpperCalls),
            optionMarket.getCurrentPricePerCallAsset(pool),
            5e18
        );

        uint256 _fee = optionMarket.getFee(0, _premiumAmountCalls);
        uint256 cost = _premiumAmountCalls + _fee;
        token1.mint(trader, cost);
        token1.approve(address(optionMarket), cost);

        DopexV2OptionMarketV2.OptionTicks[]
            memory opTicks = new DopexV2OptionMarketV2.OptionTicks[](1);

        opTicks[0] = DopexV2OptionMarketV2.OptionTicks({
            _handler: uniV3Handler,
            pool: pool,
            hook: hookAddress,
            tickLower: tickLowerCalls,
            tickUpper: tickUpperCalls,
            liquidityToUse: l
        });

        optionMarket.mintOption(
            DopexV2OptionMarketV2.OptionParams({
                optionTicks: opTicks,
                tickLower: tickLowerCalls,
                tickUpper: tickUpperCalls,
                ttl: 1 weeks,
                isCall: true,
                maxCostAllowance: cost
            })
        );

        (
            IHandler _handler,
            IUniswapV3Pool _pool,
            address _hook,
            int24 tickLower,
            int24 tickUpper,
            uint256 liquidityToUse
        ) = optionMarket.opTickMap(1, 0);

        vm.stopPrank();
    }

    function testBuyPutOption() public {
        vm.startPrank(trader);

        uint256 l = LiquidityAmounts.getLiquidityForAmount0(
            tickLowerPuts.getSqrtRatioAtTick(),
            tickUpperPuts.getSqrtRatioAtTick(),
            10_000e18
        );

        uint256 _premiumAmountPuts = optionMarket.getPremiumAmount(
            true,
            block.timestamp + 1 weeks,
            optionMarket.getPricePerCallAssetViaTick(pool, tickLowerPuts),
            optionMarket.getCurrentPricePerCallAsset(pool),
            (10_000e18 * 1e18) /
                optionMarket.getPricePerCallAssetViaTick(pool, tickLowerPuts)
        );

        uint256 _fee = optionMarket.getFee(0, _premiumAmountPuts);
        uint256 cost = _premiumAmountPuts + _fee;
        token0.mint(trader, cost);
        token0.approve(address(optionMarket), cost);

        DopexV2OptionMarketV2.OptionTicks[]
            memory opTicks = new DopexV2OptionMarketV2.OptionTicks[](1);

        opTicks[0] = DopexV2OptionMarketV2.OptionTicks({
            _handler: uniV3Handler,
            pool: pool,
            hook: hookAddress,
            tickLower: tickLowerPuts,
            tickUpper: tickUpperPuts,
            liquidityToUse: l
        });

        optionMarket.mintOption(
            DopexV2OptionMarketV2.OptionParams({
                optionTicks: opTicks,
                tickLower: tickLowerPuts,
                tickUpper: tickUpperPuts,
                ttl: 1 weeks,
                isCall: false,
                maxCostAllowance: cost
            })
        );

        (
            IHandler _handler,
            IUniswapV3Pool _pool,
            address _hook,
            int24 tickLower,
            int24 tickUpper,
            uint256 liquidityToUse
        ) = optionMarket.opTickMap(1, 0);

        vm.stopPrank();
    }

    function testFail_BuyCallOption() public {
        vm.startPrank(trader);
        uint256 l = LiquidityAmounts.getLiquidityForAmount1(
            tickLowerCalls.getSqrtRatioAtTick(),
            tickUpperCalls.getSqrtRatioAtTick(),
            5e18
        );

        uint256 _premiumAmountCalls = optionMarket.getPremiumAmount(
            false,
            block.timestamp + 1 hours,
            optionMarket.getPricePerCallAssetViaTick(pool, tickUpperCalls),
            optionMarket.getCurrentPricePerCallAsset(pool),
            5e18
        );

        uint256 _fee = optionMarket.getFee(0, _premiumAmountCalls);
        uint256 cost = _premiumAmountCalls + _fee;
        token1.mint(trader, cost);
        token1.approve(address(optionMarket), cost);

        DopexV2OptionMarketV2.OptionTicks[]
            memory opTicks = new DopexV2OptionMarketV2.OptionTicks[](1);

        opTicks[0] = DopexV2OptionMarketV2.OptionTicks({
            _handler: uniV3Handler,
            pool: pool,
            hook: hookAddress,
            tickLower: tickLowerCalls,
            tickUpper: tickUpperCalls,
            liquidityToUse: l
        });

        optionMarket.mintOption(
            DopexV2OptionMarketV2.OptionParams({
                optionTicks: opTicks,
                tickLower: tickLowerCalls,
                tickUpper: tickUpperCalls,
                ttl: 2 weeks,
                isCall: true,
                maxCostAllowance: cost
            })
        );

        (
            IHandler _handler,
            IUniswapV3Pool _pool,
            address _hook,
            int24 tickLower,
            int24 tickUpper,
            uint256 liquidityToUse
        ) = optionMarket.opTickMap(1, 0);

        vm.stopPrank();
    }
}