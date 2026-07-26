# lunch.fun V4 tax hooks

Uniswap V4 hooks powering [lunch.fun](https://lunch.fun) tax-launch coins on Robinhood Chain (chain id 4663).
Both hooks skim a creator-configurable buy/sell tax on swap via a delta-flag return
(`beforeSwapReturnDelta` / `afterSwapReturnDelta`), accrue it per pool, and pay it out through a
pull-based `distribute()` → `owed` → `claim()` ledger.

## Contracts

- **`src/LunchTaxHook.sol`** — ETH-native tax launches. Every pool's currency0 is native ETH; tax accrues
  and pays out in ETH directly (`accruedEth`, `owed(address)`).
  Deployed: [`0xf7521Cf0bB7C11e2D2794189412614Cf2e29a0cC`](https://robinhoodchain.blockscout.com/address/0xf7521Cf0bB7C11e2D2794189412614Cf2e29a0cC)
  on Robinhood Chain.

- **`src/LunchTaxHookPair.sol`** — stock/USDG-pair tax launches. The pool's quote currency can sit at
  either currency slot (`quoteIsC0`); tax accrues in the quote token (`accruedQuote`) and is converted to
  WETH at claim time via a configured SwapRouter02 path, falling back to the raw quote token if no route
  exists.
  Deployed: [`0x4Eb1976978756Bd56802d8162f2271844924e0cc`](https://robinhoodchain.blockscout.com/address/0x4Eb1976978756Bd56802d8162f2271844924e0cc)
  on Robinhood Chain.

Both are UUPS-upgradeable proxies (`src/base/LunchUpgradeable.sol`) owned by lunch.fun's governance
address. `src/LunchTokenPlain.sol` is the plain ERC20 launched by both.

## Build

```
forge install
forge build
```

## License

MIT
