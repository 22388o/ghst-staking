// SPDX-License-Identifier: MIT
pragma solidity ^0.7.1;

struct Account {
    uint96 ghst;
    uint96 uniV2PoolTokens;
    uint96 frens;
    uint32 lastUpdate;
}

struct Ticket {
    // user address => balance
    mapping(address => uint256) accountBalances;
    string uri;
    uint96 totalSupply;
}

struct AppStorage {
    mapping(address => mapping(address => bool)) approved;
    mapping(address => Account) accounts;
    mapping(uint256 => Ticket) tickets;
    // enables us to add additional map slots here
    bytes32[1000] emptyMapSlots;
    address ghstContract;
    address uniV2PoolContract;
    string ticketsBaseUri;
}

/*
struct Account {
    uint96 ghst;
    uint96 uniV2PoolTokens;
    uint32 lastUpdate;
    uint104 frens;
}

struct Ticket {
    // user address => balance
    mapping(address => uint256) accountBalances;
    uint96 totalSupply;
}

struct AppStorage {
    mapping(address => mapping(address => bool)) approved;
    mapping(address => Account) accounts;
    mapping(uint256 => Ticket) tickets;
    address ghstContract;
    address uniV2PoolContract;
    string ticketsBaseUri;
}
*/
