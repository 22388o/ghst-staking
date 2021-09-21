// SPDX-License-Identifier: MIT
pragma solidity 0.8.1;

import "../libraries/AppStorage.sol";
import "../libraries/LibDiamond.sol";
import "../libraries/LibERC20.sol";
import "../interfaces/IERC20.sol";
import "../interfaces/IERC1155TokenReceiver.sol";
import "../libraries/LibMeta.sol";

interface IERC1155Marketplace {
    function updateBatchERC1155Listing(
        address _erc1155TokenAddress,
        uint256[] calldata _erc1155TypeIds,
        address _owner
    ) external;
}

interface IERC20Mintable {
    function mint(address _to, uint256 _amount) external;

    function burn(address _to, uint256 _amount) external;
}

contract StakingFacet {
    AppStorage internal s;
    bytes4 internal constant ERC1155_BATCH_ACCEPTED = 0xbc197c81; // Return value from `onERC1155BatchReceived` call if a contract accepts receipt (i.e `bytes4(keccak256("onERC1155BatchReceived(address,address,uint256[],uint256[],bytes)"))`).
    event TransferBatch(address indexed _operator, address indexed _from, address indexed _to, uint256[] _ids, uint256[] _values);
    event Transfer(address indexed _from, address indexed _to, uint256 _value);
    event PoolTokensRate(uint256 _newRate);
    event GhstUsdcRate(uint256 _newRate);
    event RateManagerAdded(address indexed rateManager_);
    event RateManagerRemoved(address indexed rateManager_);
    event GhstWethRate(uint256 _newRate);

    function initiateEpoch(PoolRates[] calldata _pools) external onlyRateManager {
        require(s.currentEpoch == 0, "StakingFacet: Can only be called on first epoch");

        Epoch storage firstEpoch = s.epochToEpochInfo[0];
        firstEpoch.beginTime = block.timestamp;

        //Update the pool rates for each pool in this epoch
        for (uint256 index = 0; index < _pools.length; index++) {
            PoolRates poolRate = _pools[index];
            s.epochToPoolRate[s.currentEpoch][poolRate._poolAddress] = poolRate._rate;
            s.poolTokenToReceiptToken[poolRate._poolAddress] = poolrate._poolReceiptToken;

            s.supportedPools.push(poolRate._poolAddress);
        }
    }

    function increaseEpoch(PoolRates[] calldata _pools) external onlyRateManager returns (uint256 epoch_) {
        Epoch storage epochNow = s.epochToEpochInfo[s.currentEpoch];
        epochNow.endTime = block.timestamp;

        s.currentEpoch++;
        Epoch storage newEpoch = s.epochToEpochInfo[s.currentEpoch];
        newEpoch.beginTime = block.timestamp;

        //Update the pool rates for each pool in this epoch
        for (uint256 index = 0; index < _pools.length; index++) {
            PoolRates poolRate = _pools[index];
            s.epochToPoolRate[s.currentEpoch][poolRate._poolAddress] = poolRate._rate;
        }

        return s.currentEpoch;
    }

    function addPool(PoolRates calldata _epochPoolRate) external onlyRateManager {}

    function epochFrens(address _account) public view returns (uint256 frens_) {
        Account storage account = s.accounts[_account];
        // this cannot underflow or overflow
        uint256 timePeriod = block.timestamp - account.lastFrensUpdate;
        frens_ = account.frens;
        // 86400 the number of seconds in 1 day
        // 100 frens are generated for each LP token over 24 hours

        //How many epochs behind is the user? For each epoch they are behind, we will need to include that time

        if (s.currentEpoch == 0) frens += frens();
        else {
            for (uint256 index = 0; index < s.supportedPools.length; index++) {
                address poolAddress = s.supportedPools[index];
                uint256 poolCurrentRate = s.epochToPoolRate[s.currentEpoch][poolAddress];

                uint256 epochsBehind = s.currentEpoch - s.accounts[_account].userCurrentEpoch;

                //Historic epoch must always be one behind (check logic)
                for (uint256 i = 0; i < epochsBehind; i++) {
                    uint256 historicEpoch = s.currentEpoch - i;

                    //Parameters of epoch0 are the same as the previous version

                    uint256 poolHistoricRate = s.epochToPoolRate[historicEpoch][poolAddress];

                    //How long did this historic epoch last?
                    Epoch memory epoch = s.epochToEpochInfo[historicEpoch];
                    uint256 duration = epoch.endTime - epoch.beginTime;

                    uint256 stakedTokens = s.accounts[_account].accountStakedTokens[poolAddress];

                    uint256 accumulatedFrens = (stakedTokens * poolHistoricRate * duration) / 24 hours;

                    frens_ += accumulatedFrens;
                }
            }
        }
    }

    function frens(address _account) public view returns (uint256 frens_) {
        //This function is deprecated after epoch0. Use the epochFrens method instead.
        if (s.currentEpoch != 0) return 0;

        Account storage account = s.accounts[_account];
        // this cannot underflow or overflow
        uint256 timePeriod = block.timestamp - account.lastFrensUpdate;
        frens_ = account.frens;
        // 86400 the number of seconds in 1 day
        // 100 frens are generated for each LP token over 24 hours
        frens_ += ((account.poolTokens * s.poolTokensRate) * timePeriod) / 24 hours;

        frens_ += ((account.ghstUsdcPoolTokens * s.ghstUsdcRate) * timePeriod) / 24 hours;
        // 1 fren is generated for each GHST over 24 hours
        frens_ += (account.ghst * timePeriod) / 24 hours;

        //Add in frens for GHST-WETH
        frens_ += ((account.ghstWethPoolTokens * s.ghstWethRate) * timePeriod) / 24 hours;
    }

    function bulkFrens(address[] calldata _accounts) public view returns (uint256[] memory frens_) {
        frens_ = new uint256[](_accounts.length);
        for (uint256 i; i < _accounts.length; i++) {
            frens_[i] = epochFrens(_accounts[i]);
        }
    }

    function updateFrens() internal {
        address sender = LibMeta.msgSender();
        Account storage account = s.accounts[sender];
        account.frens = epochFrens(sender);
        account.lastFrensUpdate = uint40(block.timestamp);
    }

    function updateAccounts(address[] calldata _accounts) external onlyRateManager {
        for (uint256 i; i < _accounts.length; i++) {
            address accountAddress = _accounts[i];
            Account storage account = s.accounts[accountAddress];
            account.frens = epochFrens(accountAddress);
            account.lastFrensUpdate = uint40(block.timestamp);
        }
    }

    function _migrateToV2(address _account) internal {
        uint256 ghst_ = s.accounts[_account].ghst;
        uint256 poolTokens_ = s.accounts[_account].poolTokens;
        uint256 ghstUsdcPoolToken_ = s.accounts[_account].ghstUsdcPoolTokens;
        uint256 ghstWethPoolToken_ = s.accounts[_account].ghstWethPoolTokens;

        //Set balances for all of the V1 pools

        s.accounts[_account].accountStakedTokens[s.ghstContract] = ghst_;
        s.accounts[_account].accountStakedTokens[s.poolContract] = poolTokens_;
        s.accounts[_account].accountStakedTokens[s.ghstUsdcPoolToken] = ghstUsdcPoolToken_;
        s.accounts[_account].accountStakedTokens[s.ghstWethPoolToken] = ghstWethPoolToken_;

        //Set balances for all of the receipt tokens

        //Set migrated to true
        s.accounts[_address].hasMigrated = true;
    }

    function stakeIntoPool(address _poolContractAddress, uint256 _amount) external {
        updateFrens();
        address sender = LibMeta.msgSender();
        if (!s.accounts[sender].hasMigrated) _migrateToV2(sender);

        //Credit the user's with their new LP token balance
        s.accounts[sender].accountStakedTokens[_poolContractAddress] += _amount;

        //The original stkGHST-QUICK LP token is minted from the Diamond, not an external contract
        if (_poolContractAddress == s.poolContract) {
            account.ghstStakingTokens += _poolTokens;
            s.ghstStakingTokensTotalSupply += _poolTokens;
            emit Transfer(address(0), sender, _poolTokens);
        } else {
            //Use mintable for minting stkGHST- token
            address stkTokenAddress = s.poolTokenToReceiptToken[_poolContractAddress];
            IERC20Mintable(stkTokenAddress).mint(sender, _amount);
        }

        //Transfer the LP tokens into the Diamond
        LibERC20.transferFrom(_poolContractAddress, sender, address(this), _amount);
    }

    function withdrawFromPool(address _poolContractAddress, uint256 _amount) external {
        //GHST
        updateFrens();
        address sender = LibMeta.msgSender();

        if (!s.accounts[sender].hasMigrated) _migrateToV2(sender);

        uint256 bal;
        address receiptTokenAddress = s.poolTokenToReceiptToken[_poolContractAddress];
        uint256 stakedBalance = s.accounts[sender].accountStakedTokens[_poolContractAddress];
        //Balances for these must be handled separately
        if (_poolContractAddress == s.ghstContract) {
            bal = stakedBalance;
        } else if (_poolContractAddress == s.poolContract) {
            bal = stakedBalance;
        } else {
            //Checking the balance of the stkGHST- token here
            bal = IERC20(receiptTokenAddress).balanceOf(sender);
        }

        //This is actually only required for receipt tokens
        require(bal >= _amount, "StakingFacet: Can't withdraw more tokens than staked");
        require(s.accounts[sender].accountStakedTokens[_poolContractAddress] >= _amount, "Can't withdraw more poolTokens than in account");

        s.accounts[sender].accountStakedTokens[_poolContractAddress] -= _amount;

        if (_poolContractAddress == s.poolContract) {
            account.ghstStakingTokens -= _amount;
            s.ghstStakingTokensTotalSupply -= _poolTokens;

            /*
            s.accounts[sender].ghstStakingTokens = bal - _poolTokens;
            s.ghstStakingTokensTotalSupply -= _poolTokens;
            */
            uint256 accountPoolTokens = s.accounts[sender].poolTokens;
            require(accountPoolTokens >= _poolTokens, "Can't withdraw more poolTokens than in account");
            // s.accounts[sender].poolTokens = accountPoolTokens - _poolTokens;
            emit Transfer(sender, address(0), _poolTokens);
            // LibERC20.transfer(s.poolContract, sender, _poolTokens);
        } else {
            IERC20Mintable(receiptTokenAddress).burn(sender, _amount);
            uint256 accountPoolTokens = s.accounts[sender].ghstUsdcPoolTokens;

            // s.accounts[sender].ghstUsdcPoolTokens = accountPoolTokens - _poolTokens;
            // LibERC20.transfer(s.ghstUsdcPoolToken, sender, _poolTokens);
        }

        LibERC20.transfer(_poolContractAddress, sender, _amount);
    }

    /*  Deprecated staking methods */
    function stakeGhst(uint256 _ghstValue) external {
        stakeIntoPool(s.ghstContract, _ghstValue);
    }

    function stakePoolTokens(uint256 _poolTokens) external {
        stakeIntoPool(s.poolContract, _poolTokens);
    }

    function stakeGhstUsdcPoolTokens(uint256 _poolTokens) external {
        stakeIntoPool(s.ghstUsdcPoolToken, _poolTokens);
    }

    function stakeGhstWethPoolTokens(uint256 _poolTokens) external {
        stakeIntoPool(s.ghstWethPoolToken, _poolTokens);
    }

    function getGhstUsdcPoolToken() external view returns (address) {
        return s.ghstUsdcPoolToken;
    }

    function getStkGhstUsdcToken() external view returns (address) {
        return s.stkGhstUsdcToken;
    }

    function getGhstWethPoolToken() external view returns (address) {
        return s.ghstWethPoolToken;
    }

    function getStkGhstWethToken() external view returns (address) {
        return s.stkGhstWethToken;
    }

    function staked(address _account)
        external
        view
        returns (
            uint256 ghst_,
            uint256 poolTokens_,
            uint256 ghstUsdcPoolToken_,
            uint256 ghstWethPoolToken_
        )
    {
        ghst_ = s.accounts[_account].ghst;
        poolTokens_ = s.accounts[_account].poolTokens;
        ghstUsdcPoolToken_ = s.accounts[_account].ghstUsdcPoolTokens;
        ghstWethPoolToken_ = s.accounts[_account].ghstWethPoolTokens;
    }

    /* Deprecated Withdraw methods */

    function withdrawGhstStake(uint256 _ghstValue) external {
        withdrawFromPool(s.ghstContract, _ghstValue);
    }

    function withdrawPoolStake(uint256 _poolTokens) external {
        withdrawFromPool(s.poolContract, _poolTokens);
    }

    function withdrawGhstUsdcPoolStake(uint256 _poolTokens) external {
        withdrawFromPool(s.ghstUsdcPoolToken, _poolTokens);
    }

    function withdrawGhstWethPoolStake(uint256 _poolTokens) external {
        withdrawFromPool(s.ghstWethPoolToken, _poolTokens);
    }

    function claimTickets(uint256[] calldata _ids, uint256[] calldata _values) external {
        require(_ids.length == _values.length, "Staking: _ids not the same length as _values");
        updateFrens();
        address sender = LibMeta.msgSender();
        uint256 frensBal = s.accounts[sender].frens;
        for (uint256 i; i < _ids.length; i++) {
            uint256 id = _ids[i];
            uint256 value = _values[i];
            require(id < 7, "Staking: Ticket not found");
            uint256 l_ticketCost = ticketCost(id);
            uint256 cost = l_ticketCost * value;
            require(cost / l_ticketCost == value, "Staking: multiplication overflow");
            require(frensBal >= cost, "Staking: Not enough frens points");
            frensBal -= cost;
            s.tickets[id].accountBalances[sender] += value;
            s.tickets[id].totalSupply += uint96(value);
        }
        s.accounts[sender].frens = frensBal;
        emit TransferBatch(sender, address(0), sender, _ids, _values);
        uint256 size;
        assembly {
            size := extcodesize(sender)
        }
        if (size > 0) {
            require(
                ERC1155_BATCH_ACCEPTED == IERC1155TokenReceiver(sender).onERC1155BatchReceived(sender, address(0), _ids, _values, new bytes(0)),
                "Staking: Ticket transfer rejected/failed"
            );
        }
    }

    function convertTickets(uint256[] calldata _ids, uint256[] calldata _values) external {
        require(_ids.length == _values.length, "Staking: _ids not the same length as _values");
        address sender = LibMeta.msgSender();
        uint256 totalCost;
        uint256 dropTicketId = 6;
        uint256 dropTicketCost = ticketCost(dropTicketId);
        for (uint256 i; i < _ids.length; i++) {
            uint256 id = _ids[i];
            uint256 value = _values[i];
            // Can't convert drop ticket itself to another drop ticket
            require(id != dropTicketId, "Staking: Cannot convert Drop Ticket");
            uint256 l_ticketCost = ticketCost(id);
            uint256 cost = l_ticketCost * value;
            require(cost / l_ticketCost == value, "Staking: multiplication overflow");
            require(s.tickets[id].accountBalances[sender] >= value, "Staking: Not enough Ticket balance");
            totalCost += cost;

            s.tickets[id].accountBalances[sender] -= value;
            s.tickets[id].totalSupply -= uint96(value);
        }
        require(totalCost > 0, "Staking: Invalid Ticket Ids and Values");
        require(totalCost % dropTicketCost == 0, "Staking: Cannot partially convert Drop Tickets");

        emit TransferBatch(sender, sender, address(0), _ids, _values);

        uint256 newDropTickets = totalCost / dropTicketCost;
        uint256[] memory eventTicketIds = new uint256[](1);
        eventTicketIds[0] = dropTicketId;

        uint256[] memory eventTicketValues = new uint256[](1);
        eventTicketValues[0] = newDropTickets;

        s.tickets[dropTicketId].accountBalances[sender] += newDropTickets;
        s.tickets[dropTicketId].totalSupply += uint96(newDropTickets);

        if (s.aavegotchiDiamond != address(0)) {
            IERC1155Marketplace(s.aavegotchiDiamond).updateBatchERC1155Listing(address(this), _ids, sender);
        }
        emit TransferBatch(sender, address(0), sender, eventTicketIds, eventTicketValues);

        uint256 size;
        assembly {
            size := extcodesize(sender)
        }
        if (size > 0) {
            require(
                ERC1155_BATCH_ACCEPTED ==
                    IERC1155TokenReceiver(sender).onERC1155BatchReceived(sender, address(0), eventTicketIds, eventTicketValues, new bytes(0)),
                "Staking: Ticket transfer rejected/failed"
            );
        }
    }

    function ticketCost(uint256 _id) public pure returns (uint256 _frensCost) {
        if (_id == 0) {
            _frensCost = 50e18;
        } else if (_id == 1) {
            _frensCost = 250e18;
        } else if (_id == 2) {
            _frensCost = 500e18;
        } else if (_id == 3) {
            _frensCost = 2_500e18;
        } else if (_id == 4) {
            _frensCost = 10_000e18;
        } else if (_id == 5) {
            _frensCost = 50_000e18;
        } else if (_id == 6) {
            _frensCost = 10_000e18;
        } else {
            revert("Staking: _id does not exist");
        }
    }

    modifier onlyRateManager() {
        require(isRateManager(msg.sender), "StakingFacet: Must be rate manager");
        _;
    }

    function isRateManager(address account) public view returns (bool) {
        return s.rateManagers[account];
    }

    function addRateManagers(address[] calldata rateManagers_) external {
        LibDiamond.enforceIsContractOwner();
        for (uint256 index = 0; index < rateManagers_.length; index++) {
            s.rateManagers[rateManagers_[index]] = true;
            emit RateManagerAdded(rateManagers_[index]);
        }
    }

    function removeRateManagers(address[] calldata rateManagers_) external {
        LibDiamond.enforceIsContractOwner();
        for (uint256 index = 0; index < rateManagers_.length; index++) {
            s.rateManagers[rateManagers_[index]] = false;
            emit RateManagerRemoved(rateManagers_[index]);
        }
    }
}
