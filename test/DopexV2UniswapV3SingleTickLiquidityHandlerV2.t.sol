// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import "forge-std/Test.sol";

import {IUniswapV3Factory} from "@uniswap/v3-core/contracts/interfaces/IUniswapV3Factory.sol";
import {IUniswapV3Pool} from "@uniswap/v3-core/contracts/interfaces/IUniswapV3Pool.sol";

import {UniswapV3TestLib} from "./uniswap-v3-utils/UniswapV3TestLib.sol";
import {ERC20Mock} from "./mocks/ERC20Mock.sol";
import {TickMath} from "@uniswap/v3-core/contracts/libraries/TickMath.sol";
import {LiquidityAmounts} from "v3-periphery/libraries/LiquidityAmounts.sol";

import {DopexV2PositionManager} from "../src/DopexV2PositionManager.sol";
import {UniswapV3SingleTickLiquidityHarnessV2} from "./harness/UniswapV3SingleTickLiquidityHandlerV2.harness.sol";
import {UniswapV3SingleTickLiquidityHandlerV2} from "../src/handlers/UniswapV3SingleTickLiquidityHandlerV2.sol";

contract positionManagerHarnessTest is Test {
    using TickMath for int24;

    address ETH; // token1
    address LUSD; // token0

    ERC20Mock token0;
    ERC20Mock token1;

    UniswapV3TestLib uniswapV3TestLib;
    IUniswapV3Pool pool;

    uint24 fee = 500;

    uint160 initSqrtPriceX96 = 1771845812700903892492222464; // 1 ETH = 2000 LUSD

    address alice = makeAddr("alice"); // main LP
    address bob = makeAddr("bob"); // protocol LP
    address jason = makeAddr("jason"); // protocol LP
    address trader = makeAddr("trader"); // option buyer
    address garbage = makeAddr("garbage"); // garbage address
    address roger = makeAddr("roger"); // roger address
    address tango = makeAddr("tango"); // tango address

    DopexV2PositionManager positionManager;
    UniswapV3SingleTickLiquidityHarnessV2 positionManagerHarness;
    UniswapV3SingleTickLiquidityHandlerV2 uniV3Handler;

    function setUp() public {
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

        positionManager.updateWhitelistHandlerWithApp(
            address(uniV3Handler),
            garbage,
            true
        );

        positionManager.updateWhitelistHandler(address(uniV3Handler), true);

        uniV3Handler.updateWhitelistedApps(address(positionManager), true);
    }

    function testMintPosition() public {
        uint256 amount0 = 0;
        uint256 amount1 = 5e18;

        int24 tickLower = -77420; // 2299.8
        int24 tickUpper = -77410; // 2302.1

        positionManagerHarness.mintPosition(
            token0,
            token1,
            amount0,
            amount1,
            tickLower,
            tickUpper,
            pool,
            bob
        );

        positionManagerHarness.mintPosition(
            token0,
            token1,
            amount0,
            amount1,
            tickLower,
            tickUpper,
            pool,
            jason
        );
    }

    function testMintPositionWithOneSwap() public {
        uint256 amount0 = 0;
        uint256 amount1 = 5e18;

        uint256 amount01 = 10_000e18;
        uint256 amount11 = 0;

        int24 tickLower = -77420; // 2299.8
        int24 tickUpper = -77410; // 2302.1

        positionManagerHarness.mintPosition(
            token0,
            token1,
            amount0,
            amount1,
            tickLower,
            tickUpper,
            pool,
            bob
        );

        uniswapV3TestLib.performSwap(
            UniswapV3TestLib.SwapParamsStruct({
                user: garbage,
                pool: pool,
                amountIn: 2_000_000e18,
                zeroForOne: true,
                requireMint: true
            })
        );

        positionManagerHarness.mintPosition(
            token0,
            token1,
            amount01,
            amount11,
            tickLower,
            tickUpper,
            pool,
            jason
        );
    }

    function testMintPositionWithOneSwap2() public {
        uint256 amount0 = 0;
        uint256 amount1 = 5e18;

        uint256 amount01 = 10_000e18;
        uint256 amount11 = 0;

        int24 tickLower = -77420; // 2299.8
        int24 tickUpper = -77410; // 2302.1

        uniswapV3TestLib.performSwap(
            UniswapV3TestLib.SwapParamsStruct({
                user: garbage,
                pool: pool,
                amountIn: 2_000_000e18,
                zeroForOne: true,
                requireMint: true
            })
        );

        positionManagerHarness.mintPosition(
            token0,
            token1,
            amount01,
            amount11,
            tickLower,
            tickUpper,
            pool,
            bob
        );

        uniswapV3TestLib.performSwap(
            UniswapV3TestLib.SwapParamsStruct({
                user: garbage,
                pool: pool,
                amountIn: 910e18,
                zeroForOne: false,
                requireMint: true
            })
        );

        positionManagerHarness.mintPosition(
            token0,
            token1,
            amount0,
            amount1,
            tickLower,
            tickUpper,
            pool,
            jason
        );
    }

    function testMintPositionWithSwaps() public {
        uint256 amount0 = 0;
        uint256 amount1 = 5e18;

        int24 tickLower = -77420; // 2299.8
        int24 tickUpper = -77410; // 2302.1

        positionManagerHarness.mintPosition(
            token0,
            token1,
            amount0,
            amount1,
            tickLower,
            tickUpper,
            pool,
            bob
        );

        uniswapV3TestLib.performSwap(
            UniswapV3TestLib.SwapParamsStruct({
                user: garbage,
                pool: pool,
                amountIn: 2_000_000e18,
                zeroForOne: true,
                requireMint: true
            })
        );

        uniswapV3TestLib.performSwap(
            UniswapV3TestLib.SwapParamsStruct({
                user: garbage,
                pool: pool,
                amountIn: 910e18,
                zeroForOne: false,
                requireMint: true
            })
        );

        positionManagerHarness.mintPosition(
            token0,
            token1,
            amount0,
            amount1,
            tickLower,
            tickUpper,
            pool,
            jason
        );

        uniswapV3TestLib.performSwap(
            UniswapV3TestLib.SwapParamsStruct({
                user: garbage,
                pool: pool,
                amountIn: 2_000_000e18,
                zeroForOne: true,
                requireMint: true
            })
        );

        uniswapV3TestLib.performSwap(
            UniswapV3TestLib.SwapParamsStruct({
                user: garbage,
                pool: pool,
                amountIn: 910e18,
                zeroForOne: false,
                requireMint: true
            })
        );
    }

    function testBurnPosition() public {
        int24 tickLower = -77420;
        int24 tickUpper = -77410;

        testMintPositionWithSwaps();

        uint256 bobBalance = uniV3Handler.balanceOf(
            bob,
            positionManagerHarness.getTokenId(pool, tickLower, tickUpper)
        );

        uint256 jasonBalance = uniV3Handler.balanceOf(
            jason,
            positionManagerHarness.getTokenId(pool, tickLower, tickUpper)
        );

        positionManagerHarness.burnPosition(
            bobBalance,
            tickLower,
            tickUpper,
            pool,
            bob
        );

        positionManagerHarness.burnPosition(
            jasonBalance - 1, // since you can't reset the shares
            tickLower,
            tickUpper,
            pool,
            jason
        );
    }

    function testBurnPositionSmallValue() public {
        int24 tickLower = -77420;
        int24 tickUpper = -77410;

        positionManagerHarness.mintPosition(
            token0,
            token1,
            0,
            2,
            tickLower,
            tickUpper,
            pool,
            bob
        );

        uniswapV3TestLib.performSwap(
            UniswapV3TestLib.SwapParamsStruct({
                user: garbage,
                pool: pool,
                amountIn: 2_000_000e18,
                zeroForOne: true,
                requireMint: true
            })
        );

        positionManagerHarness.mintPosition(
            token0,
            token1,
            2,
            0,
            tickLower,
            tickUpper,
            pool,
            jason
        );

        uint256 bobBalance = uniV3Handler.balanceOf(
            bob,
            positionManagerHarness.getTokenId(pool, tickLower, tickUpper)
        );

        uint256 jasonBalance = uniV3Handler.balanceOf(
            jason,
            positionManagerHarness.getTokenId(pool, tickLower, tickUpper)
        );

        positionManagerHarness.burnPosition(
            bobBalance,
            tickLower,
            tickUpper,
            pool,
            bob
        );

        positionManagerHarness.burnPosition(
            jasonBalance - 1, // since you can't reset the shares
            tickLower,
            tickUpper,
            pool,
            jason
        );
    }

    function testUsePosition() public {
        testMintPositionWithSwaps();
        uint256 amount0 = 0;
        uint256 amount1 = 5e18;

        int24 tickLower = -77420;
        int24 tickUpper = -77410;

        positionManagerHarness.usePosition(
            amount0,
            amount1,
            tickLower,
            tickUpper,
            pool,
            garbage
        );

        uniswapV3TestLib.performSwap(
            UniswapV3TestLib.SwapParamsStruct({
                user: garbage,
                pool: pool,
                amountIn: 2_000_000e18,
                zeroForOne: true,
                requireMint: true
            })
        );

        uniswapV3TestLib.performSwap(
            UniswapV3TestLib.SwapParamsStruct({
                user: garbage,
                pool: pool,
                amountIn: 910e18,
                zeroForOne: false,
                requireMint: true
            })
        );
    }

    function testUnusePosition() public {
        testMintPosition();
        testUsePosition();

        uint256 amount0 = 0;
        uint256 amount1 = 5e18;

        int24 tickLower = -77420;
        int24 tickUpper = -77410;

        positionManagerHarness.unusePosition(
            token0,
            token1,
            amount0,
            amount1,
            0,
            1e18,
            tickLower,
            tickUpper,
            pool,
            garbage
        );

        uint256 bobBalance = uniV3Handler.balanceOf(
            bob,
            positionManagerHarness.getTokenId(pool, tickLower, tickUpper)
        );

        uint256 jasonBalance = uniV3Handler.balanceOf(
            jason,
            positionManagerHarness.getTokenId(pool, tickLower, tickUpper)
        );

        positionManagerHarness.burnPosition(
            bobBalance,
            tickLower,
            tickUpper,
            pool,
            bob
        );

        positionManagerHarness.burnPosition(
            jasonBalance - 1, // since you can't reset the shares
            tickLower,
            tickUpper,
            pool,
            jason
        );
    }

    function testDonation() public {
        testMintPosition();

        uint256 amount0 = 0;
        uint256 amount1 = 0;

        int24 tickLower = -77420;
        int24 tickUpper = -77410;

        vm.roll(block.number + 1);

        positionManagerHarness.donatePosition(
            token0,
            token1,
            amount0,
            amount1,
            0,
            1e18,
            tickLower,
            tickUpper,
            pool,
            garbage
        );

        vm.roll(block.number + 5);

        positionManagerHarness.mintPosition(
            token0,
            token1,
            0,
            5e18,
            tickLower,
            tickUpper,
            pool,
            roger
        );

        positionManagerHarness.mintPosition(
            token0,
            token1,
            0,
            5e18,
            tickLower,
            tickUpper,
            pool,
            tango
        );

        vm.roll(block.number + 10);

        uint256 bobBalance = uniV3Handler.balanceOf(
            bob,
            positionManagerHarness.getTokenId(pool, tickLower, tickUpper)
        );

        uint256 jasonBalance = uniV3Handler.balanceOf(
            jason,
            positionManagerHarness.getTokenId(pool, tickLower, tickUpper)
        );

        uint256 rogerBalance = uniV3Handler.balanceOf(
            roger,
            positionManagerHarness.getTokenId(pool, tickLower, tickUpper)
        );

        uint256 tangoBalance = uniV3Handler.balanceOf(
            tango,
            positionManagerHarness.getTokenId(pool, tickLower, tickUpper)
        );

        positionManagerHarness.burnPosition(
            bobBalance,
            tickLower,
            tickUpper,
            pool,
            bob
        );

        positionManagerHarness.burnPosition(
            jasonBalance,
            tickLower,
            tickUpper,
            pool,
            jason
        );
        positionManagerHarness.burnPosition(
            rogerBalance,
            tickLower,
            tickUpper,
            pool,
            roger
        );
        positionManagerHarness.burnPosition(
            tangoBalance - 1, // since you can't reset the shares
            tickLower,
            tickUpper,
            pool,
            tango
        );
    }

    function testPutOptionSim() public {
        uint256 amount0 = 10_000e18;
        uint256 amount1 = 0;

        int24 tickLower = -75770; // ~1950
        int24 tickUpper = -75760; // ~1952

        positionManagerHarness.mintPosition(
            token0,
            token1,
            amount0,
            amount1,
            tickLower,
            tickUpper,
            pool,
            bob
        );

        positionManagerHarness.mintPosition(
            token0,
            token1,
            amount0,
            amount1,
            tickLower,
            tickUpper,
            pool,
            jason
        );

        positionManagerHarness.usePosition(
            amount0,
            amount1,
            tickLower,
            tickUpper,
            pool,
            garbage
        );

        // console.log("Total Token 0 Borrowed", token0.balanceOf(garbage));

        UniswapV3SingleTickLiquidityHandlerV2.TokenIdInfo
            memory tki = uniV3Handler.getTokenIdData(
                uint256(
                    keccak256(
                        abi.encode(
                            address(uniV3Handler),
                            pool,
                            tickLower,
                            tickUpper
                        )
                    )
                )
            );
        // console.log(tl, ts, lu);

        uniswapV3TestLib.performSwap(
            UniswapV3TestLib.SwapParamsStruct({
                user: trader,
                pool: pool,
                amountIn: 200e18, // pushes to 1921
                zeroForOne: false,
                requireMint: true
            })
        );

        // console.log(uniswapV3TestLib.getCurrentSqrtPriceX96(pool));

        // uint256 amountToSwap = token0.balanceOf(garbage);

        // vm.startPrank(garbage);
        // token0.transfer(address(1), amountToSwap);
        // vm.stopPrank();

        uniswapV3TestLib.performSwap(
            UniswapV3TestLib.SwapParamsStruct({
                user: garbage,
                pool: pool,
                amountIn: token0.balanceOf(garbage), // pushes to 1925
                zeroForOne: true,
                requireMint: false
            })
        );

        // console.log("Total Token 1 after Swap", token1.balanceOf(garbage));
        // console.log(uniswapV3TestLib.getCurrentSqrtPriceX96(pool));

        (uint256 a0, uint256 a1) = LiquidityAmounts.getAmountsForLiquidity(
            uniswapV3TestLib.getCurrentSqrtPriceX96(pool),
            tickLower.getSqrtRatioAtTick(),
            tickUpper.getSqrtRatioAtTick(),
            tki.liquidityUsed
        );

        // console.log(a0, a1);

        positionManagerHarness.unusePosition(
            token0,
            token1,
            a0,
            a1,
            0,
            1,
            tickLower,
            tickUpper,
            pool,
            garbage
        );

        uniswapV3TestLib.performSwap(
            UniswapV3TestLib.SwapParamsStruct({
                user: garbage,
                pool: pool,
                amountIn: token1.balanceOf(garbage), // pushes to 1921
                zeroForOne: false,
                requireMint: false
            })
        );

        // console.log("Profit: ", token0.balanceOf(garbage));
    }

    function testCallOptionSim() public {
        uint256 amount0 = 0;
        uint256 amount1 = 5e18;

        int24 tickLower = -76260; // ~2050
        int24 tickUpper = -76250; // ~2048

        positionManagerHarness.mintPosition(
            token0,
            token1,
            amount0,
            amount1,
            tickLower,
            tickUpper,
            pool,
            bob
        );

        positionManagerHarness.mintPosition(
            token0,
            token1,
            amount0,
            amount1,
            tickLower,
            tickUpper,
            pool,
            jason
        );

        positionManagerHarness.usePosition(
            amount0,
            amount1,
            tickLower,
            tickUpper,
            pool,
            garbage
        );

        // console.log("Total Token 1 Borrowed", token1.balanceOf(garbage));

        UniswapV3SingleTickLiquidityHandlerV2.TokenIdInfo
            memory tki = uniV3Handler.getTokenIdData(
                uint256(
                    keccak256(
                        abi.encode(
                            address(uniV3Handler),
                            pool,
                            tickLower,
                            tickUpper
                        )
                    )
                )
            );
        // console.log(tl, ts, lu);

        uniswapV3TestLib.performSwap(
            UniswapV3TestLib.SwapParamsStruct({
                user: trader,
                pool: pool,
                amountIn: 400000e18, // pushes to 2078
                zeroForOne: true,
                requireMint: true
            })
        );

        // console.log(uniswapV3TestLib.getCurrentSqrtPriceX96(pool));

        uniswapV3TestLib.performSwap(
            UniswapV3TestLib.SwapParamsStruct({
                user: garbage,
                pool: pool,
                amountIn: token1.balanceOf(garbage), // pushes to 2076
                zeroForOne: false,
                requireMint: false
            })
        );

        // console.log("Total Token 1 after Swap", token1.balanceOf(garbage));
        // console.log(uniswapV3TestLib.getCurrentSqrtPriceX96(pool));

        (uint256 a0, uint256 a1) = LiquidityAmounts.getAmountsForLiquidity(
            uniswapV3TestLib.getCurrentSqrtPriceX96(pool),
            tickLower.getSqrtRatioAtTick(),
            tickUpper.getSqrtRatioAtTick(),
            tki.liquidityUsed
        );

        // console.log(a0, a1);

        positionManagerHarness.unusePosition(
            token0,
            token1,
            a0,
            a1,
            1,
            0,
            tickLower,
            tickUpper,
            pool,
            garbage
        );

        uniswapV3TestLib.performSwap(
            UniswapV3TestLib.SwapParamsStruct({
                user: garbage,
                pool: pool,
                amountIn: token0.balanceOf(garbage), // pushes to 1921
                zeroForOne: true,
                requireMint: false
            })
        );

        // console.log("Profit: ", token1.balanceOf(garbage));
    }

    function testReserveLiquidity() public {
        uint256 amount0 = 0;
        uint256 amount1 = 5e18;

        int24 tickLower = -76260; // ~2050
        int24 tickUpper = -76250; // ~2048

        positionManagerHarness.mintPosition(
            token0,
            token1,
            amount0,
            amount1,
            tickLower,
            tickUpper,
            pool,
            bob
        );

        positionManagerHarness.mintPosition(
            token0,
            token1,
            amount0,
            amount1,
            tickLower,
            tickUpper,
            pool,
            jason
        );

        positionManagerHarness.usePosition(
            amount0,
            10e18 - 3,
            tickLower,
            tickUpper,
            pool,
            garbage
        );

        vm.startPrank(bob);
        uint256 bobBalance = uniV3Handler.balanceOf(
            bob,
            positionManagerHarness.getTokenId(pool, tickLower, tickUpper)
        );

        uniV3Handler.reserveLiquidity(
            abi.encode(
                UniswapV3SingleTickLiquidityHandlerV2.BurnPositionParams({
                    pool: pool,
                    tickLower: tickLower,
                    tickUpper: tickUpper,
                    shares: uint128(bobBalance)
                })
            )
        );
        vm.stopPrank();

        positionManagerHarness.unusePosition(
            token0,
            token1,
            amount0,
            10e18 - 3,
            0,
            1,
            tickLower,
            tickUpper,
            pool,
            garbage
        );

        vm.warp(block.timestamp + 6 hours);
        vm.startPrank(bob);

        (uint256 bobReserveBalance, ) = uniV3Handler.reservedLiquidityPerUser(
            uint256(
                keccak256(
                    abi.encode(
                        address(uniV3Handler),
                        pool,
                        tickLower,
                        tickUpper
                    )
                )
            ),
            bob
        );

        uniV3Handler.withdrawReserveLiquidity(
            abi.encode(
                UniswapV3SingleTickLiquidityHandlerV2.BurnPositionParams({
                    pool: pool,
                    tickLower: tickLower,
                    tickUpper: tickUpper,
                    shares: uint128(bobReserveBalance)
                })
            )
        );
        vm.stopPrank();

        uint256 jasonBalance = uniV3Handler.balanceOf(
            jason,
            positionManagerHarness.getTokenId(pool, tickLower, tickUpper)
        );

        positionManagerHarness.burnPosition(
            jasonBalance - 1,
            tickLower,
            tickUpper,
            pool,
            jason
        );

        // UniswapV3SingleTickLiquidityHandlerV2.TokenIdInfo memory tki = uniV3Handler
        //     .getTokenIdData(
        //         uint256(
        //             keccak256(
        //                 abi.encode(
        //                     address(uniV3Handler),
        //                     pool,
        //                     tickLower,
        //                     tickUpper
        //                 )
        //             )
        //         )
        //     );
        // console.log("Total Liquidity", tki.totalLiquidity);
        // console.log("Total Supply", tki.totalSupply);
        // console.log("Liquidity Used", tki.liquidityUsed);
        // console.log("Total Reserve", tki.reservedLiquidity);
        // console.log("TokensOwed0", tki.tokensOwed0);
        // console.log("TokensOwed1", tki.tokensOwed1);
    }

    function testReserveLiquidityWithSwaps() public {
        uint256 amount0 = 0;
        uint256 amount1 = 5e18;

        int24 tickLower = -76260; // ~2050
        int24 tickUpper = -76250; // ~2048

        positionManagerHarness.mintPosition(
            token0,
            token1,
            amount0,
            amount1,
            tickLower,
            tickUpper,
            pool,
            bob
        );

        positionManagerHarness.mintPosition(
            token0,
            token1,
            amount0,
            amount1,
            tickLower,
            tickUpper,
            pool,
            jason
        );

        uniswapV3TestLib.performSwap(
            UniswapV3TestLib.SwapParamsStruct({
                user: garbage,
                pool: pool,
                amountIn: 2_000_000e18,
                zeroForOne: true,
                requireMint: true
            })
        );

        uniswapV3TestLib.performSwap(
            UniswapV3TestLib.SwapParamsStruct({
                user: garbage,
                pool: pool,
                amountIn: 910e18,
                zeroForOne: false,
                requireMint: true
            })
        );

        positionManagerHarness.usePosition(
            amount0,
            amount1,
            tickLower,
            tickUpper,
            pool,
            garbage
        );

        vm.startPrank(bob);
        uint256 bobBalance = uniV3Handler.balanceOf(
            bob,
            positionManagerHarness.getTokenId(pool, tickLower, tickUpper)
        );

        uniV3Handler.reserveLiquidity(
            abi.encode(
                UniswapV3SingleTickLiquidityHandlerV2.BurnPositionParams({
                    pool: pool,
                    tickLower: tickLower,
                    tickUpper: tickUpper,
                    shares: uint128(bobBalance)
                })
            )
        );
        vm.stopPrank();

        uniswapV3TestLib.performSwap(
            UniswapV3TestLib.SwapParamsStruct({
                user: garbage,
                pool: pool,
                amountIn: 2_000_000e18,
                zeroForOne: true,
                requireMint: true
            })
        );

        uniswapV3TestLib.performSwap(
            UniswapV3TestLib.SwapParamsStruct({
                user: garbage,
                pool: pool,
                amountIn: 910e18,
                zeroForOne: false,
                requireMint: true
            })
        );

        positionManagerHarness.unusePosition(
            token0,
            token1,
            amount0,
            amount1,
            0,
            1,
            tickLower,
            tickUpper,
            pool,
            garbage
        );

        uniswapV3TestLib.performSwap(
            UniswapV3TestLib.SwapParamsStruct({
                user: garbage,
                pool: pool,
                amountIn: 2_000_000e18,
                zeroForOne: true,
                requireMint: true
            })
        );

        uniswapV3TestLib.performSwap(
            UniswapV3TestLib.SwapParamsStruct({
                user: garbage,
                pool: pool,
                amountIn: 910e18,
                zeroForOne: false,
                requireMint: true
            })
        );

        vm.warp(block.timestamp + 6 hours);
        vm.startPrank(bob);

        (uint256 bobReserveBalance, ) = uniV3Handler.reservedLiquidityPerUser(
            uint256(
                keccak256(
                    abi.encode(
                        address(uniV3Handler),
                        pool,
                        tickLower,
                        tickUpper
                    )
                )
            ),
            bob
        );

        uniV3Handler.withdrawReserveLiquidity(
            abi.encode(
                UniswapV3SingleTickLiquidityHandlerV2.BurnPositionParams({
                    pool: pool,
                    tickLower: tickLower,
                    tickUpper: tickUpper,
                    shares: uint128(bobReserveBalance)
                })
            )
        );
        vm.stopPrank();

        uint256 jasonBalance = uniV3Handler.balanceOf(
            jason,
            positionManagerHarness.getTokenId(pool, tickLower, tickUpper)
        );

        positionManagerHarness.burnPosition(
            jasonBalance - 1,
            tickLower,
            tickUpper,
            pool,
            jason
        );
    }

    function testWithdrawWithoutLiquidityUsed() public {
        uint256 amount0 = 0;
        uint256 amount1 = 5e18;

        int24 tickLower = -76260; // ~2050
        int24 tickUpper = -76250; // ~2048

        positionManagerHarness.mintPosition(
            token0,
            token1,
            amount0,
            amount1,
            tickLower,
            tickUpper,
            pool,
            bob
        );

        positionManagerHarness.mintPosition(
            token0,
            token1,
            amount0,
            amount1,
            tickLower,
            tickUpper,
            pool,
            bob
        );

        positionManagerHarness.mintPosition(
            token0,
            token1,
            amount0,
            amount1,
            tickLower,
            tickUpper,
            pool,
            jason
        );

        vm.startPrank(bob);
        uint256 bobBalance = uniV3Handler.balanceOf(
            bob,
            positionManagerHarness.getTokenId(pool, tickLower, tickUpper)
        );

        uniV3Handler.reserveLiquidity(
            abi.encode(
                UniswapV3SingleTickLiquidityHandlerV2.BurnPositionParams({
                    pool: pool,
                    tickLower: tickLower,
                    tickUpper: tickUpper,
                    shares: uint128(bobBalance)
                })
            )
        );
        vm.stopPrank();

        vm.warp(block.timestamp + 6 hours);
        vm.startPrank(bob);
        (uint256 bobReserveBalance, ) = uniV3Handler.reservedLiquidityPerUser(
            uint256(
                keccak256(
                    abi.encode(
                        address(uniV3Handler),
                        pool,
                        tickLower,
                        tickUpper
                    )
                )
            ),
            bob
        );

        uniV3Handler.withdrawReserveLiquidity(
            abi.encode(
                UniswapV3SingleTickLiquidityHandlerV2.BurnPositionParams({
                    pool: pool,
                    tickLower: tickLower,
                    tickUpper: tickUpper,
                    shares: uint128(bobReserveBalance)
                })
            )
        );
        vm.stopPrank();

        uint256 jasonBalance = uniV3Handler.balanceOf(
            jason,
            positionManagerHarness.getTokenId(pool, tickLower, tickUpper)
        );

        positionManagerHarness.burnPosition(
            jasonBalance - 1,
            tickLower,
            tickUpper,
            pool,
            jason
        );
    }

    function testFail_WithdrawReserveBeforeCooldown() public {
        uint256 amount0 = 0;
        uint256 amount1 = 5e18;

        int24 tickLower = -76260; // ~2050
        int24 tickUpper = -76250; // ~2048

        positionManagerHarness.mintPosition(
            token0,
            token1,
            amount0,
            amount1,
            tickLower,
            tickUpper,
            pool,
            bob
        );

        positionManagerHarness.mintPosition(
            token0,
            token1,
            amount0,
            amount1,
            tickLower,
            tickUpper,
            pool,
            jason
        );

        positionManagerHarness.usePosition(
            amount0,
            10e18 - 3,
            tickLower,
            tickUpper,
            pool,
            garbage
        );

        vm.startPrank(bob);
        uint256 bobBalance = uniV3Handler.balanceOf(
            bob,
            positionManagerHarness.getTokenId(pool, tickLower, tickUpper)
        );

        uniV3Handler.reserveLiquidity(
            abi.encode(
                UniswapV3SingleTickLiquidityHandlerV2.BurnPositionParams({
                    pool: pool,
                    tickLower: tickLower,
                    tickUpper: tickUpper,
                    shares: uint128(bobBalance)
                })
            )
        );
        vm.stopPrank();

        positionManagerHarness.unusePosition(
            token0,
            token1,
            amount0,
            10e18 - 3,
            0,
            1,
            tickLower,
            tickUpper,
            pool,
            garbage
        );

        vm.startPrank(bob);
        (uint256 bobReserveBalance, ) = uniV3Handler.reservedLiquidityPerUser(
            uint256(
                keccak256(
                    abi.encode(
                        address(uniV3Handler),
                        pool,
                        tickLower,
                        tickUpper
                    )
                )
            ),
            bob
        );

        uniV3Handler.withdrawReserveLiquidity(
            abi.encode(
                UniswapV3SingleTickLiquidityHandlerV2.BurnPositionParams({
                    pool: pool,
                    tickLower: tickLower,
                    tickUpper: tickUpper,
                    shares: uint128(bobReserveBalance)
                })
            )
        );
        vm.stopPrank();
    }

    function testFail_WithdrawingReserveLiquidity() public {
        uint256 amount0 = 0;
        uint256 amount1 = 5e18;

        int24 tickLower = -76260; // ~2050
        int24 tickUpper = -76250; // ~2048

        positionManagerHarness.mintPosition(
            token0,
            token1,
            amount0,
            amount1,
            tickLower,
            tickUpper,
            pool,
            bob
        );

        positionManagerHarness.mintPosition(
            token0,
            token1,
            amount0,
            amount1,
            tickLower,
            tickUpper,
            pool,
            jason
        );

        positionManagerHarness.usePosition(
            amount0,
            amount1,
            tickLower,
            tickUpper,
            pool,
            garbage
        );

        positionManagerHarness.usePosition(
            amount0,
            amount1 - 3,
            tickLower,
            tickUpper,
            pool,
            garbage
        );

        vm.startPrank(bob);
        uint256 bobBalance = uniV3Handler.balanceOf(
            bob,
            positionManagerHarness.getTokenId(pool, tickLower, tickUpper)
        );

        uniV3Handler.reserveLiquidity(
            abi.encode(
                UniswapV3SingleTickLiquidityHandlerV2.BurnPositionParams({
                    pool: pool,
                    tickLower: tickLower,
                    tickUpper: tickUpper,
                    shares: uint128(bobBalance)
                })
            )
        );
        vm.stopPrank();

        positionManagerHarness.unusePosition(
            token0,
            token1,
            amount0,
            amount1,
            0,
            1,
            tickLower,
            tickUpper,
            pool,
            garbage
        );

        uint256 jasonBalance = uniV3Handler.balanceOf(
            jason,
            positionManagerHarness.getTokenId(pool, tickLower, tickUpper)
        );

        positionManagerHarness.burnPosition(
            jasonBalance - 1,
            tickLower,
            tickUpper,
            pool,
            jason
        );
    }

    function testFail_UsingReservedLiqudiity() public {
        uint256 amount0 = 0;
        uint256 amount1 = 5e18;

        int24 tickLower = -76260; // ~2050
        int24 tickUpper = -76250; // ~2048

        positionManagerHarness.mintPosition(
            token0,
            token1,
            amount0,
            amount1,
            tickLower,
            tickUpper,
            pool,
            bob
        );

        positionManagerHarness.mintPosition(
            token0,
            token1,
            amount0,
            amount1,
            tickLower,
            tickUpper,
            pool,
            jason
        );

        positionManagerHarness.usePosition(
            amount0,
            10e18 - 3,
            tickLower,
            tickUpper,
            pool,
            garbage
        );

        vm.startPrank(bob);
        uint256 bobBalance = uniV3Handler.balanceOf(
            bob,
            positionManagerHarness.getTokenId(pool, tickLower, tickUpper)
        );

        uniV3Handler.reserveLiquidity(
            abi.encode(
                UniswapV3SingleTickLiquidityHandlerV2.BurnPositionParams({
                    pool: pool,
                    tickLower: tickLower,
                    tickUpper: tickUpper,
                    shares: uint128(bobBalance)
                })
            )
        );
        vm.stopPrank();

        positionManagerHarness.unusePosition(
            token0,
            token1,
            amount0,
            amount1,
            0,
            1,
            tickLower,
            tickUpper,
            pool,
            garbage
        );

        positionManagerHarness.usePosition(
            amount0,
            amount1 / 2,
            tickLower,
            tickUpper,
            pool,
            garbage
        );
    }
}
