/*

  Copyright 2017 Loopring Project Ltd (Loopring Foundation).

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
pragma solidity 0.4.23;
pragma experimental "v0.5.0";
pragma experimental "ABIEncoderV2";

import "./lib/Claimable.sol";
import "./lib/ERC20.sol";
import "./lib/MathUint.sol";
import "./BrokerTracker.sol";
import "./TokenTransferDelegate.sol";


/// @title An Implementation of TokenTransferDelegate.
/// @author Daniel Wang - <daniel@loopring.org>.
contract TokenTransferDelegateImpl is TokenTransferDelegate, Claimable {
    using MathUint for uint;

    uint8   public  walletSplitPercentage       = 0;

    constructor(
        uint8   _walletSplitPercentage
        )
        public
    {
        require(_walletSplitPercentage >= 0 && _walletSplitPercentage <= 100);
        walletSplitPercentage = _walletSplitPercentage;
    }
    struct AddressInfo {
        address previous;
        uint32  index;
        bool    authorized;
    }

    mapping(address => AddressInfo) public addressInfos;
    address public latestAddress;

    modifier onlyAuthorized()
    {
        require(addressInfos[msg.sender].authorized);
        _;
    }

    /// @dev Disable default function.
    function ()
        payable
        external
    {
        revert();
    }

    function authorizeAddress(
        address addr
        )
        onlyOwner
        external
    {
        AddressInfo storage addrInfo = addressInfos[addr];

        if (addrInfo.index != 0) { // existing
            if (addrInfo.authorized == false) { // re-authorize
                addrInfo.authorized = true;
                emit AddressAuthorized(addr, addrInfo.index);
            }
        } else {
            address prev = latestAddress;
            if (prev == 0x0) {
                addrInfo.index = 1;
                addrInfo.authorized = true;
            } else {
                addrInfo.previous = prev;
                addrInfo.index = addressInfos[prev].index + 1;

            }
            addrInfo.authorized = true;
            latestAddress = addr;
            emit AddressAuthorized(addr, addrInfo.index);
        }
    }

    function deauthorizeAddress(
        address addr
        )
        onlyOwner
        external
    {
        uint32 index = addressInfos[addr].index;
        if (index != 0) {
            addressInfos[addr].authorized = false;
            emit AddressDeauthorized(addr, index);
        }
    }

    function getLatestAuthorizedAddresses(
        uint max
        )
        external
        view
        returns (address[] addresses)
    {
        addresses = new address[](max);
        address addr = latestAddress;
        AddressInfo memory addrInfo;
        uint count = 0;

        while (addr != 0x0 && count < max) {
            addrInfo = addressInfos[addr];
            if (addrInfo.index == 0) {
                break;
            }
            addresses[count++] = addr;
            addr = addrInfo.previous;
        }
    }

    function transferToken(
        address token,
        address from,
        address to,
        uint    value
        )
        onlyAuthorized
        external
    {
        if (value > 0 && from != to && to != 0x0) {
            require(
                ERC20(token).transferFrom(from, to, value)
            );
        }
    }

    function batchTransferToken(
        address lrcAddr,
        address miner,
        bytes32[] batch
        )
        onlyAuthorized
        external
    {
        require(batch.length % 9 == 0, "invalid batch");

        address prevOwner = address(batch[batch.length - 9]);

        for (uint i = 0; i < batch.length; i += 9) {
            address owner = address(batch[i]);
            address signer = address(batch[i + 1]);
            address tracker = address(batch[i + 2]);

            // Pay token to previous order, or to miner as previous order's
            // margin split or/and this order's margin split.
            address token = address(batch[i + 3]);
            uint amount;

            // Here batch[i + 4] has been checked not to be 0.
            if (owner != prevOwner) {
                amount = uint(batch[i + 4]);
                require(
                    ERC20(token).transferFrom(
                        owner,
                        prevOwner,
                        amount
                    )
                );

                if (tracker != 0x0) {
                    require(
                        BrokerTracker(tracker).onTokenSpent(
                            owner,
                            signer,
                            token,
                            amount
                        )
                    );
                }
            }

            // Miner pays LRx fee to order owner
            amount = uint(batch[i + 6]);
            if (amount != 0 && miner != owner) {
                require(
                    ERC20(lrcAddr).transferFrom(
                        miner,
                        owner,
                        amount
                    )
                );
            }

            // Split margin-split income between miner and wallet
            splitPayFee(
                token,
                owner,
                miner,
                signer,
                tracker,
                address(batch[i + 8]),
                uint(batch[i + 5])
            );

            // Split LRC fee income between miner and wallet
            splitPayFee(
                lrcAddr,
                owner,
                miner,
                signer,
                tracker,
                address(batch[i + 8]),
                uint(batch[i + 7])
            );

            prevOwner = owner;
        }
    }

    function isAddressAuthorized(
        address addr
        )
        public
        view
        returns (bool)
    {
        return addressInfos[addr].authorized;
    }

    function splitPayFee(
        address token,
        address owner,
        address miner,
        address broker,
        address tracker,
        address wallet,
        uint    fee
        )
        internal
    {
        if (fee == 0) {
            return;
        }

        uint walletFee = (wallet == 0x0) ? 0 : fee.mul(walletSplitPercentage) / 100;
        uint minerFee = fee - walletFee;

        if (walletFee > 0 && wallet != owner) {
            require(
                ERC20(token).transferFrom(
                    owner,
                    wallet,
                    walletFee
                )
            );
        }

        if (minerFee > 0 && miner != 0x0 && miner != owner) {
            require(
                ERC20(token).transferFrom(
                    owner,
                    miner,
                    minerFee
                )
            );
        }

        if (broker != 0x0) {
            require(
                BrokerTracker(tracker).onTokenSpent(
                    owner,
                    broker,
                    token,
                    fee
                )
            );
        }
    }

    function addCancelled(bytes32 orderHash, uint cancelAmount)
        onlyAuthorized
        external
    {
        cancelled[orderHash] = cancelled[orderHash].add(cancelAmount);
    }

    function addCancelledOrFilled(bytes32 orderHash, uint cancelOrFillAmount)
        onlyAuthorized
        external
    {
        cancelledOrFilled[orderHash] = cancelledOrFilled[orderHash].add(cancelOrFillAmount);
    }

    function setCutoffs(uint t)
        onlyAuthorized
        external
    {
        cutoffs[tx.origin] = t;
    }

    function setTradingPairCutoffs(bytes20 tokenPair, uint t)
        onlyAuthorized
        external
    {
        tradingPairCutoffs[tx.origin][tokenPair] = t;
    }

    function checkCutoffsBatch(address[] owners, bytes20[] tradingPairs, uint[] validSince)
        external
        view
    {
        uint len = owners.length;
        require(len == tradingPairs.length);
        require(len == validSince.length);

        for(uint i = 0; i < len; i++) {
            require(validSince[i] > tradingPairCutoffs[owners[i]][tradingPairs[i]]);  // order trading pair is cut off
            require(validSince[i] > cutoffs[owners[i]]);                              // order is cut off
        }
    }

}