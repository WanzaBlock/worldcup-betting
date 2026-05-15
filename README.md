# Smart Contract Engineer Home Task

## Overview
This project implements a World Cup Betting system with a Reputation System on the blockchain, deployed on Base Sepolia testnet.

## Contract

| Contract | Address | Network |
|---|---|---|
| WorldCupBetting | `0x3fb9F86DE0FB5a96a877e018133830c60337283F` | Base Sepolia |

## Contract Description

### WorldCupBetting
Parimutuel prediction market supporting ETH and ERC20 collateral, a secondary position market, and a 2% platform fee on winning payouts.

## Tech Stack
- Solidity ^0.8.30
- Foundry (forge, cast)
- OpenZeppelin Contracts
- Base Sepolia Testnet (Chain ID: 84532)

## Setup & Installation

```bash
git clone https://github.com/WanzaBlock/worldcup-betting.git
cd worldcup-betting
forge install
```

## Run Tests

```bash
forge test -vv
```

47 tests passing — covering market creation, ETH/ERC20 betting, payouts, secondary market, fee withdrawal, reentrancy protection, and fuzz testing.

## Deployment

```bash
export PRIVATE_KEY=0xyour_private_key
export BASE_SEPOLIA_RPC=https://sepolia.base.org

forge script script/Deploy.s.sol:Deploy \
  --rpc-url $BASE_SEPOLIA_RPC \
  --private-key $PRIVATE_KEY \
  --broadcast -vvv
```

## Verify on Basescan

- [WorldCupBetting](https://sepolia.basescan.org/address/0x3fb9F86DE0FB5a96a877e018133830c60337283F)

## Notes
- Deployed to Base Sepolia as the Ethereum Devnet equivalent
- Contracts are linked: WorldCupBetting references ReputationSystem for score updates
