// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import "BoringSolidity/ERC20.sol";
import "utils/BaseTest.sol";
import "script/GmxV2.s.sol";
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";
import "./utils/CauldronTestLib.sol";
import "./mocks/ExchangeRouterMock.sol";
import {ICauldronV4GmxV2} from "interfaces/ICauldronV4GmxV2.sol";
import {IGmRouterOrder, GmRouterOrderParams} from "periphery/GmxV2CauldronOrderAgent.sol";
import {IGmxV2DepositCallbackReceiver, IGmxV2Deposit, IGmxV2EventUtils} from "interfaces/IGmxV2.sol";
import {LiquidationHelper} from "periphery/LiquidationHelper.sol";
import {Address} from "openzeppelin-contracts/utils/Address.sol";
import {IWETH} from "interfaces/IWETH.sol";

interface DepositHandler {
    struct SetPricesParams {
        uint256 signerInfo;
        address[] tokens;
        uint256[] compactedMinOracleBlockNumbers;
        uint256[] compactedMaxOracleBlockNumbers;
        uint256[] compactedOracleTimestamps;
        uint256[] compactedDecimals;
        uint256[] compactedMinPrices;
        uint256[] compactedMinPricesIndexes;
        uint256[] compactedMaxPrices;
        uint256[] compactedMaxPricesIndexes;
        bytes[] signatures;
        address[] priceFeedTokens;
        address[] realtimeFeedTokens;
        bytes[] realtimeFeedData;
    }

    function executeDeposit(bytes32 key, SetPricesParams calldata oracleParams) external;
}

interface IMockOracle {
    function setMockPrice(uint256 _price) external;
}

contract GmxV2Test is BaseTest {
    using SafeTransferLib for address;

    IGmCauldronOrderAgent orderAgent;
    GmxV2Script.MarketDeployment gmETHDeployment;
    GmxV2Script.MarketDeployment gmBTCDeployment;
    GmxV2Script.MarketDeployment gmARBDeployment;

    event LogOrderCanceled(address indexed user, address indexed order);
    event LogAddCollateral(address indexed from, address indexed to, uint256 share);
    error ErrMinOutTooLarge();

    address constant GM_BTC_WHALE = 0x8d16D32f785D0B11fDa5E443FCC39610f91a50A8;
    address constant GM_ETH_WHALE = 0xA329Ac2efFFea563159897d7828866CFaeD42167;
    address constant GM_ARB_WHALE = 0x8E52cA5A7a9249431F03d60D79DDA5EAB4930178;
    address constant MIM_WHALE = 0x27807dD7ADF218e1f4d885d54eD51C70eFb9dE50;
    address constant GMX_EXECUTOR = 0xf1e1B2F4796d984CCb8485d43db0c64B83C1FA6d;

    address gmBTC;
    address gmETH;
    address gmARB;
    address usdc;
    address mim;
    address weth;
    address masterContract;
    IBentoBoxV1 box;
    ExchangeRouterMock exchange;
    IGmxV2ExchangeRouter router;

    function setUp() public override {
        fork(ChainId.Arbitrum, 139685420);
        super.setUp();

        GmxV2Script script = new GmxV2Script();
        script.setTesting(true);

        (masterContract, orderAgent, gmETHDeployment, gmBTCDeployment, gmARBDeployment) = script.deploy();

        box = IBentoBoxV1(toolkit.getAddress(block.chainid, "degenBox"));
        mim = toolkit.getAddress(block.chainid, "mim");
        gmBTC = toolkit.getAddress(block.chainid, "gmx.v2.gmBTC");
        gmETH = toolkit.getAddress(block.chainid, "gmx.v2.gmETH");
        weth = toolkit.getAddress(block.chainid, "weth");
        gmARB = toolkit.getAddress(block.chainid, "gmx.v2.gmARB");
        router = IGmxV2ExchangeRouter(toolkit.getAddress(block.chainid, "gmx.v2.exchangeRouter"));
        usdc = toolkit.getAddress(block.chainid, "usdc");
        exchange = new ExchangeRouterMock(ERC20(address(0)), ERC20(address(0)));

        // Alice just made it
        deal(usdc, alice, 100_000e6);
        pushPrank(GM_BTC_WHALE);
        gmBTC.safeTransfer(alice, 100_000 ether);
        popPrank();
        pushPrank(GM_ETH_WHALE);
        gmETH.safeTransfer(alice, 100_000 ether);
        popPrank();
        pushPrank(GM_ARB_WHALE);
        gmARB.safeTransfer(alice, 100_000 ether);
        popPrank();

        // put 1m mim inside the cauldrons
        pushPrank(MIM_WHALE);
        mim.safeTransfer(address(box), 3_000_000e18);
        popPrank();

        box.deposit(IERC20(mim), address(box), address(gmETHDeployment.cauldron), 1_000_000e18, 0);
        box.deposit(IERC20(mim), address(box), address(gmBTCDeployment.cauldron), 1_000_000e18, 0);
        box.deposit(IERC20(mim), address(box), address(gmARBDeployment.cauldron), 1_000_000e18, 0);

        pushPrank(box.owner());
        box.whitelistMasterContract(masterContract, true);
        popPrank();
    }

    function test_CreateDepositWithZeroTokens() public {
        uint256 usdcAmountOut = 5_000e6;

        exchange.setTokens(ERC20(mim), ERC20(usdc));
        deal(usdc, address(exchange), usdcAmountOut);

        // Leveraging needs to be splitted into 2 transaction since
        // the order needs to be picked up by the gmx executor
        {
            pushPrank(alice);
            uint8 numActions = 5;
            uint8 i;
            uint8[] memory actions = new uint8[](numActions);
            uint256[] memory values = new uint256[](numActions);
            bytes[] memory datas = new bytes[](numActions);

            box.setMasterContractApproval(alice, masterContract, true, 0, 0, 0);
            gmETH.safeApprove(address(box), type(uint256).max);

            // Create Order
            actions[i] = 101;
            values[i] = 1 ether;
            datas[i++] = abi.encode(usdc, true, 0, 1 ether, type(uint128).max, 0);

            // Empty deposit reverts on the GMX side
            vm.expectRevert(bytes4(keccak256("EmptyDepositAmounts()")));
            gmETHDeployment.cauldron.cook{value: 1 ether}(actions, values, datas);
            popPrank();
        }

    }

    function test_CreateWithdrawalWithZeroTokens() public {
        uint256 usdcAmountOut = 5_000e6;

        exchange.setTokens(ERC20(mim), ERC20(usdc));
        deal(usdc, address(exchange), usdcAmountOut);

        // Leveraging needs to be splitted into 2 transaction since
        // the order needs to be picked up by the gmx executor
        {
            pushPrank(alice);
            uint8 numActions = 5;
            uint8 i;
            uint8[] memory actions = new uint8[](numActions);
            uint256[] memory values = new uint256[](numActions);
            bytes[] memory datas = new bytes[](numActions);

            box.setMasterContractApproval(alice, masterContract, true, 0, 0, 0);
            gmETH.safeApprove(address(box), type(uint256).max);

            // Create Order
            actions[i] = 101;
            values[i] = 1 ether;
            datas[i++] = abi.encode(usdc, false, 0, 1 ether, type(uint128).max, 0);

            // Empty deposit reverts on the GMX side
            vm.expectRevert(bytes4(keccak256("EmptyWithdrawalAmount()")));
            gmETHDeployment.cauldron.cook{value: 1 ether}(actions, values, datas);
            popPrank();
        }

    }

    function test_LiquidatePendingDeposit() public {
        uint256 usdcAmount = 5_000e6;

        deal(usdc, address(alice), usdcAmount);
        vm.prank(alice);
        IERC20(usdc).approve(address(box), usdcAmount);

        {
            pushPrank(alice);
            uint8 numActions = 2;
            uint8 i;
            uint8[] memory actions = new uint8[](numActions);
            uint256[] memory values = new uint256[](numActions);
            bytes[] memory datas = new bytes[](numActions);

            box.setMasterContractApproval(alice, masterContract, true, 0, 0, 0);

            // Bento Deposit
            actions[i] = 20;
            datas[i++] = abi.encode(usdc, address(orderAgent), usdcAmount, 0);

            // Create Order
            actions[i] = 101;
            values[i] = 1 ether;
            datas[i++] = abi.encode(usdc, true, usdcAmount, 1 ether, 5_000 ether, 0);

            gmETHDeployment.cauldron.cook{value: 1 ether}(actions, values, datas);
            popPrank();
        }

        // Borrow against the pending deposit
        {
            pushPrank(alice);
            uint8 numActions = 1;
            uint8 i;
            uint8[] memory actions = new uint8[](numActions);
            uint256[] memory values = new uint256[](numActions);
            bytes[] memory datas = new bytes[](numActions);

            // Alice has 5,000 USDC pending to be deposited
            // Her deposit is valued at the minOut which is 5,000 GM tokens
            // Price of GM tokens is currently ~$0.917
            // Therefore Alice has a collateral value of ~$4,585
            // The collateralization rate for GM tokens is 75%, therefore Alice can borrow up to ~3430 MIM
            // Alice borrows against her collateral value to reach a collateralization of

            // Borrow
            actions[i] = 5;
            datas[i++] = abi.encode(3_430 ether, alice);

            gmETHDeployment.cauldron.cook(actions, values, datas);
            popPrank();
        }

        // Alice is solvent
        assertTrue(gmETHDeployment.cauldron.isSolvent(alice));

        // Price of GM tokens goes down
        // Previous price => ~$0.917 (inverted = ~$1.089)
        // Price drops to 0.85 (inverted = ~$1.176)
        IMockOracle(address(gmETHDeployment.oracle)).setMockPrice(1176 * 1e15);

        // Alice's minOut of 5,000 GM tokens is now valued
        // 5,000 * 0.85 = $4250
        // 4,250 * 3/4 = 3187.50 MIM, which is less than here borrowed 3430 MIM

        // Alice is now insolvent
        assertFalse(gmETHDeployment.cauldron.isSolvent(alice));

        uint256 aliceBorrowPart = gmETHDeployment.cauldron.userBorrowPart(alice);

        pushPrank(MIM_WHALE);
        box.setMasterContractApproval(MIM_WHALE, masterContract, true, 0, 0, 0);
        mim.safeTransfer(address(box), 100_000e18);
        box.deposit(IERC20(mim), address(box), MIM_WHALE, 100_000e18, 0);

        // Allow request cancellation phase to pass
        uint256 requestExpirationAge = 1200;
        advanceBlocks(requestExpirationAge);

        // Account has to be liquidated, her deposit is cancelled in the process
        _liquidate(address(gmETHDeployment.cauldron), alice, aliceBorrowPart);

        uint256 aliceBorrowPartAfter = gmETHDeployment.cauldron.userBorrowPart(alice);

        // Alice's position is closed
        assertTrue(aliceBorrowPartAfter == 0);

        // Alice's order contract still corresponds to her
        address aliceOrder = address(ICauldronV4GmxV2(address(gmETHDeployment.cauldron)).orders(alice));

        assertTrue(aliceOrder != address(0));

        // Alice still has a portion of her collateral remaining
        // She is required to pay back her borrow amount value 
        // in addition to a 6% liquidation fee
        // Alice borrowed 3,430 MIM, now ~3,435 MIM with interest
        // Alice has to pay back 3,430 * 1.06 = $3635.80 worth of collateral
        // Alice deposited 5,000 USDC in her order so roughly 5,000 - 3,635.80 = ~1,364.20 USDC should remain

        uint256 orderBal = IERC20(usdc).balanceOf(aliceOrder);

        assertTrue(orderBal > 1355 * 1e6);
        assertTrue(orderBal < 1370 * 1e6);
    }

    function test_cannotCreateWithdrawMultipleOrders() public {
        uint8[] memory actions = new uint8[](1);
        uint256[] memory values = new uint256[](1);
        bytes[] memory datas = new bytes[](1);
        actions[0] = 101;
        values[0] = 1 ether;

        pushPrank(alice);
        box.setMasterContractApproval(alice, masterContract, true, 0, 0, 0);

        deal(usdc, address(box), 1 ether);

        pushPrank(GM_ETH_WHALE);
        gmETH.safeTransfer(address(box), 1 ether);
        box.deposit(IERC20(gmETH), address(box), address(orderAgent), 1 ether, 0);
        popPrank();

        datas[0] = abi.encode(gmETH, false, 1 ether, 1 ether, type(uint128).max, 0);
        gmETHDeployment.cauldron.cook{value: 1 ether}(actions, values, datas);

        vm.expectRevert(bytes4(keccak256("ErrOrderAlreadyExists()")));
        datas[0] = abi.encode(gmETH, false, 0.5 ether, 0.5 ether, type(uint128).max, 0);
        gmETHDeployment.cauldron.cook{value: 0.5 ether}(actions, values, datas);
    }

    function test_MultipleWithdrawOrders() public {
        uint256 usdcAmount = 5_000e6;

        deal(usdc, address(alice), usdcAmount);
        vm.prank(alice);
        IERC20(usdc).approve(address(box), usdcAmount);

        uint8 numActions = 2;
        uint8 i;
        uint8[] memory actions = new uint8[](numActions);
        uint256[] memory values = new uint256[](numActions);
        bytes[] memory datas = new bytes[](numActions);

        {
        pushPrank(alice);

        box.setMasterContractApproval(alice, masterContract, true, 0, 0, 0);

        // Bento Deposit
        actions[i] = 20;
        datas[i++] = abi.encode(usdc, address(orderAgent), usdcAmount, 0);

        // Create Order
        actions[i] = 101;
        values[i] = 1 ether;
        datas[i++] = abi.encode(usdc, true, usdcAmount, 1 ether, 5_000 ether, 0);

        gmETHDeployment.cauldron.cook{value: 1 ether}(actions, values, datas);
        }
        
        IGmRouterOrder order = ICauldronV4GmxV2(address(gmETHDeployment.cauldron)).orders(alice);

        deal(usdc, address(order), usdcAmount);

        assertEq(usdc.balanceOf(address(box)), 0);

        uint8[] memory withdrawActions = new uint8[](1);
        uint256[] memory withdrawValues = new uint256[](1);
        bytes[] memory withdrawDatas = new bytes[](1);

        withdrawActions[0] = 9;
        withdrawValues[0] = 1 ether;

        // Withdraw #1
        withdrawDatas[0] = abi.encode(usdc, alice, usdcAmount/4, false);
        gmETHDeployment.cauldron.cook{value: 1 ether}(withdrawActions, withdrawValues, withdrawDatas);

        assertEq(usdc.balanceOf(address(box)), 1250000000);
        assertEq(box.balanceOf(IERC20(usdc), alice), 1250000000);

        // Withdraw #2
        withdrawDatas[0] = abi.encode(usdc, alice, usdcAmount/4, false);
        gmETHDeployment.cauldron.cook{value: 1 ether}(withdrawActions, withdrawValues, withdrawDatas);

        assertEq(usdc.balanceOf(address(box)), 2500000000);
        assertEq(box.balanceOf(IERC20(usdc), alice),2500000000);

        // Withdraw #3
        withdrawDatas[0] = abi.encode(usdc, alice, usdcAmount/2, true);
        gmETHDeployment.cauldron.cook{value: 1 ether}(withdrawActions, withdrawValues, withdrawDatas);

        order = ICauldronV4GmxV2(address(gmETHDeployment.cauldron)).orders(alice);
        assertEq(address(order), 0x0000000000000000000000000000000000000000);
        assertEq(usdc.balanceOf(address(box)), 5000000000);
        
        assertEq(box.balanceOf(IERC20(usdc), alice),5000000000);
    }

    function test_CannotCreateOrderWithLongToken() public {
        uint256 wethAmount = 5e18;

        deal(weth, address(alice), wethAmount*2);
        vm.prank(alice);
        IERC20(weth).approve(address(box), wethAmount);

        uint8 numActions = 2;
        uint8 i;
        uint8[] memory actions = new uint8[](numActions);
        uint256[] memory values = new uint256[](numActions);
        bytes[] memory datas = new bytes[](numActions);

        {
        pushPrank(alice);

        box.setMasterContractApproval(alice, masterContract, true, 0, 0, 0);

        // Bento Deposit
        actions[i] = 20;
        datas[i++] = abi.encode(weth, address(orderAgent), wethAmount, 0);

        // Create Order
        actions[i] = 101;
        values[i] = 1 ether;
        datas[i++] = abi.encode(weth, true, wethAmount, 1 ether, 5_000 ether, 0);

        // Reverts due to the fact that we tried to create the order with a long token since long token
        vm.expectRevert("ERC20: transfer amount exceeds balance");
        gmETHDeployment.cauldron.cook{value: 1 ether}(actions, values, datas);
        }
    }

   function test_CannotCreateWithdrawalWithWrongToken() public {
        uint256 usdcAmountOut = 5_000e6;
        uint256 gmEthTokenOut = 5400 ether;

        exchange.setTokens(ERC20(mim), ERC20(usdc));
        deal(usdc, address(exchange), usdcAmountOut);

        {
            pushPrank(alice);
            uint8 numActions = 5;
            uint8 i;
            uint8[] memory actions = new uint8[](numActions);
            uint256[] memory values = new uint256[](numActions);
            bytes[] memory datas = new bytes[](numActions);

            box.setMasterContractApproval(alice, masterContract, true, 0, 0, 0);
            gmETH.safeApprove(address(box), type(uint256).max);

            // Bento Deposit
            actions[i] = 20;
            datas[i++] = abi.encode(gmETH, alice, 10_000 ether, 0);

            // Add collateral
            actions[i] = 10;
            datas[i++] = abi.encode(-1, alice, false);

            // Borrow
            actions[i] = 5;
            datas[i++] = abi.encode(5_000 ether, address(exchange));

            // Swap MIM -> USDC
            actions[i] = 30;
            datas[i++] = abi.encode(
                address(exchange),
                abi.encodeWithSelector(ExchangeRouterMock.swapAndDepositToDegenBox.selector, address(box), address(orderAgent)),
                false,
                false,
                uint8(1)
            );

            // Create Order
            actions[i] = 101;
            values[i] = 1 ether;
            datas[i++] = abi.encode(usdc, true, usdcAmountOut, 1 ether, type(uint128).max, 0);

            gmETHDeployment.cauldron.cook{value: 1 ether}(actions, values, datas);
            popPrank();
        }

        IGmRouterOrder order = ICauldronV4GmxV2(address(gmETHDeployment.cauldron)).orders(alice);
        pushPrank(GM_ETH_WHALE);
        gmETH.safeTransfer(address(order), gmEthTokenOut);

        pushPrank(router.depositHandler());
        _callAfterDepositExecution(IGmxV2DepositCallbackReceiver(address(order)));
        popPrank();

        popPrank();

        {
            pushPrank(alice);

            uint256 userCollateralShare = gmETHDeployment.cauldron.userCollateralShare(alice);
            uint256 amount = box.toAmount(IERC20(gmETH), userCollateralShare, false);

            uint8 numActions = 2;
            uint8 i;
            uint8[] memory actions = new uint8[](numActions);
            uint256[] memory values = new uint256[](numActions);
            bytes[] memory datas = new bytes[](numActions);

            actions[i] = 4;
            datas[i++] = abi.encode(userCollateralShare, address(orderAgent));

            actions[i] = 101;
            values[i] = 1 ether;
            
            // Try to withdraw gmBTC instead of gmETH
            datas[i++] = abi.encode(IERC20(gmBTC), false, amount, 1 ether, type(uint128).max, 0);

            // Reverts with underflow due to alice having no gmBTC balance
            vm.expectRevert("BoringMath: Underflow");
            gmETHDeployment.cauldron.cook{value: 1 ether}(actions, values, datas);
            popPrank();
        }
    }
   function test_CancelOrderWithActionCancelOrder() public {
        uint256 usdcAmount = 5_000e6;

        deal(usdc, address(alice), usdcAmount);
        vm.prank(alice);
        IERC20(usdc).approve(address(box), usdcAmount);

        uint8 numActions = 2;
        uint8 i;
        uint8[] memory actions = new uint8[](numActions);
        uint256[] memory values = new uint256[](numActions);
        bytes[] memory datas = new bytes[](numActions);

        {
        pushPrank(alice);

        box.setMasterContractApproval(alice, masterContract, true, 0, 0, 0);

        // Bento Deposit
        actions[i] = 20;
        datas[i++] = abi.encode(usdc, address(orderAgent), usdcAmount, 0);

        // Create Order
        actions[i] = 101;
        values[i] = 1 ether;
        datas[i++] = abi.encode(usdc, true, usdcAmount, 1 ether, 5_000 ether, 0);

        gmETHDeployment.cauldron.cook{value: 1 ether}(actions, values, datas);
        }
        
        IGmRouterOrder order = ICauldronV4GmxV2(address(gmETHDeployment.cauldron)).orders(alice);

        uint8[] memory cancelActions = new uint8[](1);
        uint256[] memory cancelValues = new uint256[](1);
        bytes[] memory cancelDatas = new bytes[](1);

        cancelActions[0] = 102;
        cancelValues[0] = 1 ether;
        cancelDatas[0] = abi.encode(usdc, true, usdcAmount, 1 ether, 5_000 ether, 0);

        uint256 timeIncrease = 1200;
        advanceBlocks(timeIncrease);

        gmETHDeployment.cauldron.cook{value: 1 ether}(cancelActions, cancelValues, cancelDatas);

        address aliceOrder = address(ICauldronV4GmxV2(address(gmETHDeployment.cauldron)).orders(alice));

        uint256 orderBal = IERC20(usdc).balanceOf(aliceOrder);

        assertEq(orderBal, 5000e6);
        assertTrue(gmETHDeployment.cauldron.isSolvent(alice));
    }


   function test_InsolventWithdrawLiquidated() public {
        uint256 usdcAmount = 5_000e6;

        deal(usdc, address(alice), usdcAmount);
        vm.prank(alice);
        IERC20(usdc).approve(address(box), usdcAmount);

        uint8 numActions = 2;
        uint8 i;
        uint8[] memory actions = new uint8[](numActions);
        uint256[] memory values = new uint256[](numActions);
        bytes[] memory datas = new bytes[](numActions);

        {
            pushPrank(alice);

            box.setMasterContractApproval(alice, masterContract, true, 0, 0, 0);

            // Bento Deposit
            actions[i] = 20;
            datas[i++] = abi.encode(usdc, address(orderAgent), usdcAmount, 0);

            // Create Order
            actions[i] = 101;
            values[i] = 1 ether;
            datas[i++] = abi.encode(usdc, true, usdcAmount, 1 ether, 5_000 ether, 0);

            gmETHDeployment.cauldron.cook{value: 1 ether}(actions, values, datas);
        }
        
        IGmRouterOrder order = ICauldronV4GmxV2(address(gmETHDeployment.cauldron)).orders(alice);

        deal(usdc, address(order), usdcAmount);

        assertEq(usdc.balanceOf(address(box)), 0);



        uint8[] memory withdrawActions = new uint8[](1);
        uint256[] memory withdrawValues = new uint256[](1);
        bytes[] memory withdrawDatas = new bytes[](1);

        withdrawActions[0] = 9;
        withdrawValues[0] = 1 ether;

        withdrawDatas[0] = abi.encode(usdc, alice, usdcAmount/4, false);
        gmETHDeployment.cauldron.cook{value: 1 ether}(withdrawActions, withdrawValues, withdrawDatas);


        {
            pushPrank(alice);
            uint8 numActions = 1;
            uint8 i;
            uint8[] memory actions = new uint8[](numActions);
            uint256[] memory values = new uint256[](numActions);
            bytes[] memory datas = new bytes[](numActions);

            actions[i] = 5;
            datas[i++] = abi.encode(3_430 ether, alice);

            gmETHDeployment.cauldron.cook(actions, values, datas);
            popPrank();
        }

        IMockOracle(address(gmETHDeployment.oracle)).setMockPrice(1176 * 1e15);

        pushPrank(MIM_WHALE);
        box.setMasterContractApproval(MIM_WHALE, masterContract, true, 0, 0, 0);
        mim.safeTransfer(address(box), 100_000e18);
        box.deposit(IERC20(mim), address(box), MIM_WHALE, 100_000e18, 0);

        uint256 aliceBorrowPart = gmETHDeployment.cauldron.userBorrowPart(alice);

        uint256 timeIncrease = 1200;
        advanceBlocks(timeIncrease);

        _liquidate(address(gmETHDeployment.cauldron), alice, aliceBorrowPart);
    }

   function test_MaxLeverageDeposit() public {
        //...
    }

   function test_WithdrawalGetsCancelled() public {
        //...
    }

   function test_DepositGetsCancelled() public {
        uint256 usdcAmount = 5_000e6;

        deal(usdc, address(alice), usdcAmount);
        vm.prank(alice);
        IERC20(usdc).approve(address(box), usdcAmount);

        uint8 numActions = 2;
        uint8 i;
        uint8[] memory actions = new uint8[](numActions);
        uint256[] memory values = new uint256[](numActions);
        bytes[] memory datas = new bytes[](numActions);

        {
        pushPrank(alice);

        box.setMasterContractApproval(alice, masterContract, true, 0, 0, 0);

        // Bento Deposit
        actions[i] = 20;
        datas[i++] = abi.encode(usdc, address(orderAgent), usdcAmount, 0);

        // Create Order
        actions[i] = 101;
        values[i] = 1 ether;
        datas[i++] = abi.encode(usdc, true, usdcAmount, 1 ether, type(uint96).max, type(uint96).max);

        gmETHDeployment.cauldron.cook{value: 1 ether}(actions, values, datas);
        }
        
        address aliceOrder = address(ICauldronV4GmxV2(address(gmETHDeployment.cauldron)).orders(alice));

        uint256 orderBal = IERC20(usdc).balanceOf(aliceOrder);

        console.log(orderBal);

    }


    function test_ActionCallWhileBlacklisted() public {
        uint256 usdcAmount = 5_000e6;

        deal(usdc, address(alice), usdcAmount);
        vm.prank(alice);
        IERC20(usdc).approve(address(box), usdcAmount);

        uint8 numActions = 2;
        uint8 i;
        uint8[] memory actions = new uint8[](numActions);
        uint256[] memory values = new uint256[](numActions);
        bytes[] memory datas = new bytes[](numActions);

        {
        pushPrank(alice);

        box.setMasterContractApproval(alice, masterContract, true, 0, 0, 0);

        // Bento Deposit
        actions[i] = 20;
        datas[i++] = abi.encode(usdc, address(orderAgent), usdcAmount, 0);

        // Create Order
        actions[i] = 101;
        values[i] = 1 ether;
        datas[i++] = abi.encode(usdc, true, usdcAmount, 1 ether, 5_000 ether, 0);

        gmETHDeployment.cauldron.cook{value: 1 ether}(actions, values, datas);
        }

        IGmRouterOrder order = ICauldronV4GmxV2(address(gmETHDeployment.cauldron)).orders(alice);

        bytes memory callData = abi.encode(
            IGmRouterOrder.withdrawFromOrder.selector,
            address(usdc),
            alice,
            usdcAmount / 2, 
            false
        );

        uint8[] memory callActions = new uint8[](1);
        uint256[] memory callValues = new uint256[](1);
        bytes[] memory callDatas = new bytes[](1);

        callActions[0] = 30;
        callValues[0] = 0;
        callDatas[0] = abi.encode(address(order), callData, false, false, uint8(0));

        vm.expectRevert(("Cauldron: can't call"));
        gmETHDeployment.cauldron.cook{value: 0 ether}(callActions, callValues, callDatas);
        popPrank();
    }

    function _liquidate(address cauldron, address account, uint256 borrowPart) internal {
        address[] memory users = new address[](1);
        users[0] = account;
        uint256[] memory maxBorrowParts = new uint256[](1);
        maxBorrowParts[0] = borrowPart;

        ICauldronV4(cauldron).liquidate(users, maxBorrowParts, address(this), address(0), new bytes(0));
    }

    // IGmxV2DepositCallbackReceiver.afterDepositExecution
    function _callAfterDepositExecution(IGmxV2DepositCallbackReceiver target) public {
        bytes32 key = bytes32(0);

        // Prepare the call data
        address[] memory longTokenSwapPath = new address[](0);
        address[] memory shortTokenSwapPath = new address[](0);

        IGmxV2Deposit.Addresses memory addresses = IGmxV2Deposit.Addresses(
            address(target),
            address(0),
            address(0),
            address(0),
            address(0),
            address(0),
            address(0),
            longTokenSwapPath,
            shortTokenSwapPath
        );

        IGmxV2Deposit.Numbers memory numbers = IGmxV2Deposit.Numbers(0, 0, 0, 0, 0, 0);
        IGmxV2Deposit.Flags memory flags = IGmxV2Deposit.Flags(false);
        IGmxV2Deposit.Props memory deposit = IGmxV2Deposit.Props(addresses, numbers, flags);

        bytes memory data = "";
        for (uint i = 0; i < 7; i++) {
            data = abi.encodePacked(data, hex"0000000000000000000000000000000000000000000000000000000000000000");
        }

        IGmxV2EventUtils.EventLogData memory eventData = abi.decode(data, (IGmxV2EventUtils.EventLogData));
        target.afterDepositExecution(key, deposit, eventData);
    }
}
