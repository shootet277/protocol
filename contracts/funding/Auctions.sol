/*

    Copyright 2019 The Hydro Protocol Foundation

    Licensed under the Apache License, Version 2.0 (the "License");
    you may not use this file except in compliance with the License.
    You may obtain a copy of the License at

        http://www.apache.org/licenses/LICENSE-2.0

    Unless required by applicable law or agreed to in writing, software
    distributed under the License is distributed on an "AS IS" BASIS,
    WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
    See the License for the specific language governing permissions and
    limitations under the License.

*/

pragma solidity ^0.5.8;
pragma experimental ABIEncoderV2;

import "./LendingPool.sol";
import "../lib/Store.sol";
import "../lib/SafeMath.sol";
import "../lib/Types.sol";
import "../lib/Events.sol";
import "../lib/Decimal.sol";
import "../lib/Transfer.sol";

import "./CollateralAccounts.sol";

library Auctions {
    using SafeMath for uint256;
    using Auction for Types.Auction;

    /**
     * Liquidate a collateral account
     */
    function liquidate(
        Store.State storage state,
        address user,
        uint16 marketID
    )
        internal
        returns (bool, uint32)
    {
        Types.CollateralAccountDetails memory details = CollateralAccounts.getDetails(
            state,
            user,
            marketID
        );

        require(details.liquidatable, "ACCOUNT_NOT_LIQUIDABLE");

        Types.Market storage market = state.markets[marketID];
        Types.CollateralAccount storage account = state.accounts[user][marketID];

        LendingPool.repay(
            state,
            user,
            marketID,
            market.baseAsset,
            account.balances[market.baseAsset]
        );

        LendingPool.repay(
            state,
            user,
            marketID,
            market.quoteAsset,
            account.balances[market.quoteAsset]
        );

        address collateralAsset;
        address debtAsset;

        uint256 leftBaseAssetDebt = LendingPool.getAmountBorrowed(
            state,
            market.baseAsset,
            user,
            marketID
        );

        uint256 leftQuoteAssetDebt = LendingPool.getAmountBorrowed(
            state,
            market.quoteAsset,
            user,
            marketID
        );

        if (leftBaseAssetDebt == 0 && leftQuoteAssetDebt == 0) {
            // no auction
            return (false, 0);
        }

        account.status = Types.CollateralAccountStatus.Liquid;

        if(account.balances[market.baseAsset] > 0) {
            // quote asset is debt, base asset is collateral
            collateralAsset = market.baseAsset;
            debtAsset = market.quoteAsset;
        } else {
            // base asset is debt, quote asset is collateral
            collateralAsset = market.quoteAsset;
            debtAsset = market.baseAsset;
        }

        uint32 newAuctionID = create(
            state,
            marketID,
            user,
            msg.sender,
            debtAsset,
            collateralAsset
        );

        return (true, newAuctionID);
    }

    function fillAuctionWithRatioLessOrEqualThanOne(
        Store.State storage state,
        Types.Auction storage auction,
        uint256 ratio,
        uint256 repayAmount
    )
        internal
        returns (uint256, uint256) // bidderRepay collateral
    {
        uint256 leftDebtAmount = LendingPool.getAmountBorrowed(
            state,
            auction.debtAsset,
            auction.borrower,
            auction.marketID
        );

        // get remaining collateral
        uint256 leftCollateralAmount = state.accounts[auction.borrower][auction.marketID].balances[auction.collateralAsset];

        state.accounts[auction.borrower][auction.marketID].balances[auction.debtAsset] = SafeMath.add(
            state.accounts[auction.borrower][auction.marketID].balances[auction.debtAsset],
            repayAmount
        );

        // borrower pays back to the lending pool
        uint256 actualRepay = LendingPool.repay(
            state,
            auction.borrower,
            auction.marketID,
            auction.debtAsset,
            repayAmount
        );

        // compute how much collateral is divided up amongst the bidder, auction initiator, and borrower
        state.balances[msg.sender][auction.debtAsset] = SafeMath.sub(
            state.balances[msg.sender][auction.debtAsset],
            actualRepay
        );

        if (actualRepay < repayAmount) {
            state.accounts[auction.borrower][auction.marketID].balances[auction.debtAsset] = 0;
        }

        uint256 collateralToProcess = leftCollateralAmount.mul(actualRepay).div(leftDebtAmount);
        uint256 collateralForBidder = Decimal.mulFloor(collateralToProcess, ratio);

        uint256 collateralForInitiator = Decimal.mulFloor(collateralToProcess.sub(collateralForBidder), state.auction.initiatorRewardRatio);
        uint256 collateralForBorrower = collateralToProcess.sub(collateralForBidder).sub(collateralForInitiator);

        // update remaining collateral ammount
        state.accounts[auction.borrower][auction.marketID].balances[auction.collateralAsset] = SafeMath.sub(
            state.accounts[auction.borrower][auction.marketID].balances[auction.collateralAsset],
            collateralToProcess
        );

        // send a portion of collateral to the bidder
        state.balances[msg.sender][auction.collateralAsset] = SafeMath.add(
            state.balances[msg.sender][auction.collateralAsset],
            collateralForBidder
        );

        // send a portion of collateral to the initiator
        state.balances[auction.initiator][auction.collateralAsset] = SafeMath.add(
            state.balances[auction.initiator][auction.collateralAsset],
            collateralForInitiator
        );

        // send a portion of collateral to the borrower
        state.balances[auction.borrower][auction.collateralAsset] = SafeMath.add(
            state.balances[auction.borrower][auction.collateralAsset],
            collateralForBorrower
        );

        Events.logFillAuction(auction.id, repayAmount);
        return (actualRepay, collateralForBidder);
    }

    /**

     * Msg.sender only need to afford bidderRepayAmount and get collateralAmount
     * insurance and suppliers will cover the badDebtAmount
     */
    function fillAuctionWithRatioGreaterThanOne(
        Store.State storage state,
        Types.Auction storage auction,
        uint256 ratio,
        uint256 bidderRepayAmount
    )
        internal
        returns (uint256, uint256) // bidderRepay collateral
    {

        uint256 leftDebtAmount = LendingPool.getAmountBorrowed(
            state,
            auction.debtAsset,
            auction.borrower,
            auction.marketID
        );

        uint256 leftCollateralAmount = state.accounts[auction.borrower][auction.marketID].balances[auction.collateralAsset];

        uint256 repayAmount = Decimal.mulFloor(bidderRepayAmount, ratio);

        state.accounts[auction.borrower][auction.marketID].balances[auction.debtAsset] = SafeMath.add(
            state.accounts[auction.borrower][auction.marketID].balances[auction.debtAsset],
            repayAmount
        );

        // auction when ratio>1 cash -= actualBidderRepay
        // To avoid cash overflow, we add cash temporarily here and sub immediately after
        state.cash[auction.debtAsset] = state.cash[auction.debtAsset].add(repayAmount);

        uint256 actualRepay = LendingPool.repay(
            state,
            auction.borrower,
            auction.marketID,
            auction.debtAsset,
            repayAmount
        );

        uint256 actualBidderRepay = bidderRepayAmount;
        if (actualRepay < repayAmount) {
            actualBidderRepay = Decimal.divCeil(actualRepay, ratio);
        }

        // gather repay capital
        LendingPool.claimInsurance(state, auction.debtAsset, actualRepay.sub(actualBidderRepay));
        state.balances[msg.sender][auction.debtAsset] = SafeMath.sub(
            state.balances[msg.sender][auction.debtAsset],
            actualBidderRepay
        );

        // state.cash[auction.debtAsset] = state.cash[auction.debtAsset].add(actualRepay);
        // state.cash[auction.debtAsset] = state.cash[auction.debtAsset].sub(repayAmount);
        // state.cash[auction.debtAsset] = state.cash[auction.debtAsset].sub(actualBidderRepay);
        state.cash[auction.debtAsset] = state.cash[auction.debtAsset].sub(repayAmount.add(actualBidderRepay).sub(actualRepay));

        // update collateralAmount
        uint256 collateralForBidder = leftCollateralAmount.mul(actualRepay).div(leftDebtAmount);

        state.accounts[auction.borrower][auction.marketID].balances[auction.collateralAsset] = SafeMath.sub(
            state.accounts[auction.borrower][auction.marketID].balances[auction.collateralAsset],
            collateralForBidder
        );

        // bidder receive collateral
        state.balances[msg.sender][auction.collateralAsset] = SafeMath.add(
            state.balances[msg.sender][auction.collateralAsset],
            collateralForBidder
        );

        return (repayAmount, collateralForBidder);
    }

    // ensure repay no more than repayAmount
    function fillAuctionWithAmount(
        Store.State storage state,
        uint32 auctionID,
        uint256 repayAmount
    )
        external
    {
        Types.Auction storage auction = state.auction.auctions[auctionID];
        uint256 ratio = auction.ratio(state);

        if (ratio <= Decimal.one()){
            fillAuctionWithRatioLessOrEqualThanOne(state, auction, ratio, repayAmount);
        } else {
            fillAuctionWithRatioGreaterThanOne(state, auction, ratio, repayAmount);
        }

        // reset account state if all debts are paid
        uint256 leftDebtAmount = LendingPool.getAmountBorrowed(
            state,
            auction.debtAsset,
            auction.borrower,
            auction.marketID
        );

        if (leftDebtAmount == 0) {
            endAuction(state, auction);
        }
    }

    /**
     * Mark an auction as finished.
     * An auction typically ends either when it becomes fully filled, or when it expires and is closed
     */
    function endAuction(
        Store.State storage state,
        Types.Auction storage auction
    )
        internal
    {
        auction.status = Types.AuctionStatus.Finished;

        Types.CollateralAccount storage account = state.accounts[auction.borrower][auction.marketID];
        account.status = Types.CollateralAccountStatus.Normal;

        for (uint i = 0; i < state.auction.currentAuctions.length; i++){
            if (state.auction.currentAuctions[i] == auction.id){
                state.auction.currentAuctions[i] = state.auction.currentAuctions[state.auction.currentAuctions.length-1];
                state.auction.currentAuctions.length--;
            }
        }

        Events.logAuctionFinished(auction.id);
    }

    /**
     * Create a new auction and save it in global state
     */
    function create(
        Store.State storage state,
        uint16 marketID,
        address borrower,
        address initiator,
        address debtAsset,
        address collateralAsset
    )
        internal
        returns (uint32)
    {
        uint32 id = state.auction.auctionsCount++;

        Types.Auction memory auction = Types.Auction({
            id: id,
            status: Types.AuctionStatus.InProgress,
            startBlockNumber: uint32(block.number),
            marketID: marketID,
            borrower: borrower,
            initiator: initiator,
            debtAsset: debtAsset,
            collateralAsset: collateralAsset
        });

        state.auction.auctions[id] = auction;
        state.auction.currentAuctions.push(id);

        Events.logAuctionCreate(id);

        return id;
    }

    function getAuctionDetails(
        Store.State storage state,
        uint32 auctionID
    )
        internal
        view
        returns (Types.AuctionDetails memory details)
    {
        Types.Auction memory auction = state.auction.auctions[auctionID];

        details.debtAsset = auction.debtAsset;
        details.collateralAsset = auction.collateralAsset;

        details.leftDebtAmount = LendingPool.getAmountBorrowed(
            state,
            auction.debtAsset,
            auction.borrower,
            auction.marketID
        );

        details.leftCollateralAmount = state.accounts[auction.borrower][auction.marketID].balances[auction.collateralAsset];
        details.ratio = auction.ratio(state);
    }
}