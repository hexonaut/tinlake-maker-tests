// Copyright (C) 2021 Centrifuge

// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU Affero General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.
//
// This program is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
// GNU Affero General Public License for more details.
//
// You should have received a copy of the GNU Affero General Public License
// along with this program.  If not, see <https://www.gnu.org/licenses/>.

pragma solidity >=0.5.15 <0.6.0;
pragma experimental ABIEncoderV2;

import "ds-test/test.sol";
import "tinlake/test/system/lender/mkr/mkr_basic.t.sol";
import "tinlake/test/mock/mock.sol";
import "tinlake-maker-lib/mgr.sol";
import "dss/vat.sol";
import {DaiJoin} from "dss/join.sol";
import {Spotter} from "dss/spot.sol";

import "../lib/tinlake-maker-lib/src/mgr.sol";

contract VowMock is Mock {
    function fess(uint256 tab) public {
        values_uint["fess_tab"] = tab;
    }
}

contract TinlakeMkrTest is MKRBasicSystemTest {
    // Decimals & precision
    uint256 constant MILLION  = 10 ** 6;
    uint256 constant RAY      = 10 ** 27;
    uint256 constant RAD      = 10 ** 45;

    TinlakeManager public mgr;
    Vat public vat;
    Spotter public spotter;
    DaiJoin public daiJoin;
    VowMock vow;
    bytes32 ilk;

    uint lastRateUpdate;
    uint stabilityFee;

    bool warpCalled = false;

    function setUp() public {
        // setup Tinlake contracts with mocked maker adapter
        super.setUp();
        // replace mocked maker adapter with maker and adapter
        setUpMgrAndMaker();
    }

    function spellTinlake() public {
        vat.init(ilk);

        vat.rely(address(mgr));
        daiJoin.rely(address(mgr));

        // Set the global debt ceiling
        vat.file("Line", 1_468_750_000 * RAD);
        // Set the NS2DRP-A debt ceiling
        vat.file(ilk, "line", 5 * MILLION * RAD);
        // Set the NS2DRP-A dust
        vat.file(ilk, "dust", 0);

        //tinlake system tests work with 110%
        uint mat =  110 * RAY / 100;
        spotter.file(ilk, "mat", mat);

        // Update DROP spot value in Vat
        //spotter.poke(ilk);
        // assume a constant price with safety margin
        uint spot = mat;
        vat.file(ilk, "spot", spot);
        lastRateUpdate = now;
    }

    // updates the interest rate in maker contracts
    function dripMakerDebt() public {
        (,uint prevRateIndex,,,) = vat.ilks(ilk);
        uint newRateIndex = rmul(rpow(stabilityFee, now - lastRateUpdate, ONE), prevRateIndex);
        lastRateUpdate = now;
        (uint ink, uint art) = vat.urns(ilk, address(mgr));
        vat.fold(ilk, address(vow), int(newRateIndex-prevRateIndex));
    }

    function setStabilityFee(uint fee) public {
        stabilityFee = fee;
    }

    function makerEvent(bytes32 name, bool) public {
        if(name == "live") {
            // Global settlement not triggered
            mgr.cage();
        } else if(name == "glad") {
            // Write-off not triggered
            mgr.tell();
            mgr.sink();
        } else if(name  == "safe") {
            // Soft liquidation not triggered
            mgr.tell();
        }
    }

    function warp(uint plusTime) public {
        if (warpCalled == false)  {
            warpCalled = true;
            // init maker rate update mock
            lastRateUpdate = now;
        }
        hevm.warp(now + plusTime);
        // maker debt should be always up to date
        dripMakerDebt();
    }

    // creates all relevant mkr contracts to test the mgr
    function mkrDeploy() public {
        vat = new Vat();
        daiJoin = new DaiJoin(address(vat), currency_);
        vow = new VowMock();
        ilk = "DROP";
        vat.rely(address(daiJoin));
        spotter = new Spotter(address(vat));
        vat.rely(address(spotter));
    }

    function setUpMgrAndMaker() public {
        mkrDeploy();

        // create mgr contract
        mgr = new TinlakeManager(address(vat), currency_, address(daiJoin), address(vow), address(seniorToken),
        address(seniorOperator), address(clerk), address(seniorTranche), ilk);

        // accept Tinlake MGR in Maker
        spellTinlake();

        // depend mgr in Tinlake clerk
        clerk.depend("mgr", address(mgr));

        // depend Maker contracts in clerk
        clerk.depend("spotter", address(spotter));
        clerk.depend("vat", address(vat));

        // give testcase the right to modify drop token holders
        root.relyContract(address(seniorMemberlist), address(this));
        // add mgr as drop token holder
        seniorMemberlist.updateMember(address(mgr), uint(-1));
    }

    function testDebtIncrease() public {
        setStabilityFee(uint(1000000115165872987700711356));   // 1 % day
        uint juniorAmount = 200 ether;
        uint mkrAmount = 500 ether;
        uint borrowAmount = 300 ether;
        _setUpDraw(mkrAmount, juniorAmount, borrowAmount);
        lastRateUpdate = now;
       warp(1 days);
        dripMakerDebt();
        uint expectedDebt = 101 ether;
        assertEqTol(clerk.debt(), expectedDebt, "testMKRHarvest#1");
    }

    function testMKRHarvest() public {
        setStabilityFee(uint(1000000115165872987700711356));   // 1 % day
        uint juniorAmount = 200 ether;
        uint mkrAmount = 500 ether;
        uint borrowAmount = 300 ether;
        _setUpDraw(mkrAmount, juniorAmount, borrowAmount);
        warp(1 days);
        uint expectedDebt = 101 ether;
        assertEqTol(clerk.debt(), expectedDebt, "testMKRHarvest#1");

        warp(3 days);

        uint seniorPrice = mkrAssessor.calcSeniorTokenPrice();
        uint juniorPrice = mkrAssessor.calcJuniorTokenPrice();

        uint lockedCollateralDAI = rmul(clerk.cdpink(), seniorPrice);
        // profit => diff between the DAI value of the locked collateral in the cdp & the actual cdp debt including protection buffer
        uint profitDAI = safeSub(lockedCollateralDAI, clerk.calcOvercollAmount(clerk.debt()));
        uint preSeniorAsset = safeAdd(assessor.seniorDebt(), assessor.seniorBalance_());

        uint preJuniorStake = clerk.juniorStake();

        clerk.harvest();

        uint newJuniorPrice = mkrAssessor.calcJuniorTokenPrice();
        uint newSeniorPrice =  mkrAssessor.calcSeniorTokenPrice();

        assertEq(newJuniorPrice, juniorPrice);
        assertEq(preJuniorStake, safeAdd(clerk.juniorStake(), profitDAI));
        assertEq(safeSub(preSeniorAsset,profitDAI), safeAdd(assessor.seniorDebt(), assessor.seniorBalance_()));
    }

    function testOnDemandDrawWithStabilityFee() public {
        uint fee = 1000000564701133626865910626; // 5% per day
        setStabilityFee(fee);
        uint juniorAmount = 200 ether;
        uint mkrAmount = 500 ether;
        uint borrowAmount = 300 ether;
        _setUpDraw(mkrAmount, juniorAmount, borrowAmount);
       warp(1 days);
        assertEq(clerk.debt(), 105 ether, "testStabilityFee#2");
    }

    function testLoanRepayWipe() public {
        uint fee = 1000000564701133626865910626; // 5% per day
        setStabilityFee(fee);
        uint juniorAmount = 200 ether;
        uint mkrAmount = 500 ether;
        uint borrowAmount = 300 ether;

        _setUpDraw(mkrAmount, juniorAmount, borrowAmount);

        warp(1 days);
        uint expectedDebt = 105 ether;
        assertEq(clerk.debt(), expectedDebt, "testLoanRepayWipe#1");

        uint repayAmount = 50 ether;
        repayDefaultLoan(repayAmount);

        // reduces clerk debt
        assertEqTol(clerk.debt(), safeSub(expectedDebt, repayAmount), "testLoanRepayWipe#2");
        assertEq(reserve.totalBalance(), 0, "testLoanRepayWipe#3");
    }

    function testMKRHeal() public {
        // high stability fee: 10% a day
        uint fee = uint(1000001103127689513476993126);
        setStabilityFee(fee);

        // sanity check
        uint juniorAmount = 200 ether;
        uint mkrAmount = 500 ether;
        uint borrowAmount = 300 ether;
        _setUpDraw(mkrAmount, juniorAmount, borrowAmount);

        warp(1 days);
        uint expectedDebt = 110 ether;

        uint seniorPrice = mkrAssessor.calcSeniorTokenPrice();
        uint lockedCollateralDAI = rmul(clerk.cdpink(), seniorPrice);
        assertEqTol(clerk.debt(), expectedDebt, "testMKRHeal#1");

        uint wantedLocked = clerk.calcOvercollAmount(clerk.debt());
        assertTrue(wantedLocked > lockedCollateralDAI);

        uint amountOfDROP = clerk.cdpink();

        clerk.heal();
        // heal should have minted additional DROP tokens
        lockedCollateralDAI = rmul(clerk.cdpink(), seniorPrice);
        assertEqTol(lockedCollateralDAI, wantedLocked, "testMKRHeal#2");
        assertTrue(clerk.cdpink() > amountOfDROP);
    }

    function testFailMKRSinkTooHigh() public {
        uint juniorAmount = 200 ether;
        uint mkrAmount = 500 ether;
        uint borrowAmount = 300 ether;
        _setUpDraw(mkrAmount, juniorAmount, borrowAmount);

        uint sinkAmount = 401 ether;
        clerk.sink(sinkAmount);
    }

    function testVaultLiquidation() public {
        _setUpOngoingMKR();
        uint juniorTokenPrice = mkrAssessor.calcJuniorTokenPrice();

        // liquidation
        makerEvent("live", false);

        assertTrue(mkrAssessor.calcJuniorTokenPrice() <  juniorTokenPrice);
        // no currency in reserve
        assertEq(reserve.totalBalance(),  0);

        // repay loans and everybody redeems
        repayAllDebtDefaultLoan();
        assertEq(mkrAssessor.currentNAV(), 0);
        // reserve should keep the currency no automatic clerk.wipe
        assertTrue(reserve.totalBalance() > 0);

        _mkrLiquidationPostAssertions();
    }

    function testVaultLiquidation2() public {
        _setUpOngoingMKR();
        makerEvent("glad", false);
        _mkrLiquidationPostAssertions();
    }

    function testVaultLiquidation3() public {
        _setUpOngoingMKR();
        makerEvent("safe", false);
        _mkrLiquidationPostAssertions();
    }

    function testFailLiqDraw() public {
        _setUpOngoingMKR();
        makerEvent("glad", false);
        clerk.draw(1);
    }

    function testFailLiqSink() public {
        _setUpOngoingMKR();
        makerEvent("glad", false);
        clerk.sink(1);
    }

    function testFailLiqWipe() public {
        _setUpOngoingMKR();
        makerEvent("glad", false);
        // repay loans and everybody redeems
        repayAllDebtDefaultLoan();
        assertTrue(reserve.totalBalance() > 0);
        clerk.wipe(1);
    }

}
