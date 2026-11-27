# ZIPSA Contracts

**ZIPSA ties every AI agent execution to a verified owner. Limits are enforced by the contract, not a server.**

Live on [GIWA Sepolia](https://docs.giwa.io) (chain ID 91342). Built on the audited
[MetaMask delegation-framework](https://github.com/MetaMask/delegation-framework) v1.3.0
(ERC-7710 / EIP-7702) with [Dojang](https://docs.giwa.io/giwa-ecosystem/dojang/contracts)
Verified Address as the identity source.

## How it works

1. **The owner's EOA becomes a smart account (EIP-7702).** One type-4 transaction points the
   owner's address at `EIP7702StatelessDeleGator`. No funds move, no deposit is required.
2. **The owner signs a policy delegation (EIP-712).** The delegation names the agent and carries
   seven caveats: allowed target, allowed method, expiry, per-transaction cap, cumulative cap,
   period cap, and a Dojang check that the recipient is verified and the agent is bound to a
   verified owner.
3. **The agent requests an execution.** It calls `DelegationManager.redeemDelegations`; the
   payment leaves the owner's balance directly, inside the policy.
4. **Anything outside the policy reverts. The owner can revoke at any time.** Every caveat
   enforcer runs on-chain for every redemption. `disableDelegation` from the owner stops the
   agent immediately.
5. **Automatic refill.** The main wallet signs one conditional refill delegation
   to a spending account that is bound to the same verified owner. Anyone can execute a refill,
   but only while the spending account's balance is below the threshold, and every refill is
   bounded by a period cap and a total refill count.

## Deployed contracts (GIWA Sepolia)

All 15 contracts are verified on Blockscout. Total deployment gas: **12,316,997** (initial 12 contracts: 10,841,972; automatic-refill enforcers: 1,475,025).

Written by ZIPSA:

| Contract | Role | Address |
|---|---|---|
| `JipsaSettlementToken` (tKRW) | Test settlement token, 6 decimals, EIP-2612 permit | [`0x1E743C166FaeeEe5b840A471a6760535AE4076B0`](https://sepolia-explorer.giwa.io/address/0x1E743C166FaeeEe5b840A471a6760535AE4076B0) |
| `DojangVerifiedGate` | Reads Dojang `isVerified` for a configured set of issuers | [`0xD13aE574E53F2D14F71411383CcEeC9c16529fc3`](https://sepolia-explorer.giwa.io/address/0xD13aE574E53F2D14F71411383CcEeC9c16529fc3) |
| `OwnerBindingRegistry` | Binds an agent wallet to a verified owner (propose → accept) | [`0x6ef7F805fBCaA49cbfc11C861E2EC051549433C7`](https://sepolia-explorer.giwa.io/address/0x6ef7F805fBCaA49cbfc11C861E2EC051549433C7) |
| `DojangCaveatEnforcer` | ERC-7710 caveat: recipient verified, agent bound, owner verified | [`0x8C9c8437C27003f3d86F438c7147668d9cC5948C`](https://sepolia-explorer.giwa.io/address/0x8C9c8437C27003f3d86F438c7147668d9cC5948C) |
| `JipsaPerTxCapEnforcer` | ERC-7710 caveat: per-transaction amount cap | [`0xdea5DF3357e0EEf6A841d3639d115eb57b42B642`](https://sepolia-explorer.giwa.io/address/0xdea5DF3357e0EEf6A841d3639d115eb57b42B642) |
| `RefillThresholdEnforcer` | ERC-7710 caveat: refill only a bound spending account, only below its balance threshold, exact refill amount, owner verified | [`0x7BA5Ef6dFb5712db79A4802FE16B31389242b95C`](https://sepolia-explorer.giwa.io/address/0x7BA5Ef6dFb5712db79A4802FE16B31389242b95C) |
| `BoundDelegatorEnforcer` | ERC-7710 caveat: delegating account and agent bound to the same verified owner, optional verified recipient | [`0xeBF1D1C0f1D982f7FeFB6aE0d84bcceF6E6c636f`](https://sepolia-explorer.giwa.io/address/0xeBF1D1C0f1D982f7FeFB6aE0d84bcceF6E6c636f) |

From the delegation-framework (v1.3.0, deployed unchanged):

| Contract | Role | Address |
|---|---|---|
| `DelegationManager` | Validates delegations and runs caveats on redemption | [`0x46C7b0aaC0Cde81744823a305FBb86D31D4F7F89`](https://sepolia-explorer.giwa.io/address/0x46C7b0aaC0Cde81744823a305FBb86D31D4F7F89) |
| `EIP7702StatelessDeleGator` | Account implementation the owner's EOA delegates to | [`0x50bC6Ac159bd85838Af8A42Fd482B8f633FeA38D`](https://sepolia-explorer.giwa.io/address/0x50bC6Ac159bd85838Af8A42Fd482B8f633FeA38D) |
| `AllowedTargetsEnforcer` | Caveat: allowed call target | [`0x977156e9b7Ae812C542FDbE3eEa0b93Fe87C0371`](https://sepolia-explorer.giwa.io/address/0x977156e9b7Ae812C542FDbE3eEa0b93Fe87C0371) |
| `AllowedMethodsEnforcer` | Caveat: allowed function selector | [`0x816E3D68470E84Db37799ECA14dc9EBD86b37591`](https://sepolia-explorer.giwa.io/address/0x816E3D68470E84Db37799ECA14dc9EBD86b37591) |
| `ERC20TransferAmountEnforcer` | Caveat: cumulative transfer cap | [`0x4cC2931c6dB25aAaA6360b802b7987f2A39eF559`](https://sepolia-explorer.giwa.io/address/0x4cC2931c6dB25aAaA6360b802b7987f2A39eF559) |
| `ERC20PeriodTransferEnforcer` | Caveat: per-period transfer cap | [`0x73e8aEF3aD187524FD44B8f9b5B700689FE41071`](https://sepolia-explorer.giwa.io/address/0x73e8aEF3aD187524FD44B8f9b5B700689FE41071) |
| `TimestampEnforcer` | Caveat: validity window | [`0x972298257A69792B0219900D8A2C9DAeC8094cC6`](https://sepolia-explorer.giwa.io/address/0x972298257A69792B0219900D8A2C9DAeC8094cC6) |
| `LimitedCallsEnforcer` | Caveat: total number of redemptions | [`0x96efFEEe819Db13e6bb0A63F2057dF0Eca204533`](https://sepolia-explorer.giwa.io/address/0x96efFEEe819Db13e6bb0A63F2057dF0Eca204533) |

External dependencies on GIWA Sepolia: `DojangScroll`
[`0xd5077b67dcb56caC8b270C7788FC3E6ee03F17B9`](https://sepolia-explorer.giwa.io/address/0xd5077b67dcb56caC8b270C7788FC3E6ee03F17B9)
and EntryPoint v0.7
[`0x0000000071727De22E5E9d8BAf0edAc6f37da032`](https://sepolia-explorer.giwa.io/address/0x0000000071727De22E5E9d8BAf0edAc6f37da032).

Caveat order is fixed and matters, because caveats run in array order and the revert reason
depends on which one fires first: AllowedTargets → AllowedMethods → Timestamp → JipsaPerTxCap →
ERC20TransferAmount → ERC20PeriodTransfer → Dojang. `JipsaPerTxCapEnforcer` is stateless and
must always be paired with the cumulative cap; see `test/erc7710/CumulativeDrain.t.sol`.

## On-chain record

One full cycle on GIWA Sepolia in block order: binding, payment, two policy refusals, and
revocation. Refused attempts stay on chain with their revert reason, same as the successes.
Each link opens the transaction on Blockscout.

| Step | Transaction | Result |
|---|---|---|
| Owner EOA converted with EIP-7702 (type-4) | [`0x47aa…cf50`](https://sepolia-explorer.giwa.io/tx/0x47aaba300d9553e870e43b9b4e024532ed5e3a2c6cd6f7342e09d0534e1ecf50) | success, 36,844 gas |
| `proposeBinding`, owner proposes the agent wallet | [`0x61b0…12bc`](https://sepolia-explorer.giwa.io/tx/0x61b0effaad0f7ac98ebe5a0ee1c484320a01d51d62a18ea2cd6cf2200d7912bc) | success, 130,056 gas |
| `acceptBinding`, agent accepts | [`0x9f5f…cb00`](https://sepolia-explorer.giwa.io/tx/0x9f5f134873eb1f01bd94de3bc9ad226f498eac9d464190d7ecddb52d945acb00) | success, 195,047 gas |
| `enableDelegation` | [`0x2a04…b641`](https://sepolia-explorer.giwa.io/tx/0x2a04cd442e5ca58a469699fd30db06b3b432ae328140ed98183fd90d7107b641) | success, 80,592 gas |
| `redeemDelegations`, 2 tKRW paid from the owner's balance | [`0xaf5e…8b55`](https://sepolia-explorer.giwa.io/tx/0xaf5ea45f01f3089caeb368088dc653b4eab25340b3b08e71a04938ffd55a8b55) | success, 393,987 gas |
| `redeemDelegations`, 5,000 tKRW against a 50 tKRW per-transaction cap | [`0x1751…675b`](https://sepolia-explorer.giwa.io/tx/0x175141601a69c44f27eac0b7a425ba3ab12c3681aa8af0187e979f965f5d675b) | **reverted** · `PerTxCapExceeded`, 132,665 gas |
| `redeemDelegations` to an unverified recipient (`0x…dEaD`) | [`0x0b3a…d105`](https://sepolia-explorer.giwa.io/tx/0x0b3aeccc29bebcc6287f198bbb42bbd915a7f81597305bba676e532f363ad105) | **reverted** · `RecipientNotVerified`, 272,320 gas |
| `disableDelegation` by the owner | [`0x3ccf…ae46`](https://sepolia-explorer.giwa.io/tx/0x3ccf4056b174357ba8889c0c168f99ea8b34b436f4f0f5539a57f2332cd4ae46) | success, 102,557 gas |
| `redeemDelegations` right after revocation | [`0x5bb1…d9ef`](https://sepolia-explorer.giwa.io/tx/0x5bb13c0b52de61175637a42bf2228bda1f377316c9887a23bd06850ba8b8d9ef) | **reverted** · `CannotUseADisabledDelegation`, 73,073 gas |

### Automatic refill

One run on GIWA Sepolia on 2026-11-27, in block order. The main wallet is the owner account from
the cycle above. It signed one refill delegation open to any executor: refill 40 tKRW when the
spending account [`0x7c15…78Eb`](https://sepolia-explorer.giwa.io/address/0x7c15B921D9ab30c111588ED6409545c2519078Eb) holds less than 30 tKRW, at most
120 tKRW per day and 5 refills in total. The keeper [`0x8f2d…7328`](https://sepolia-explorer.giwa.io/address/0x8f2dA7cA5846fc8FBCDF52FE397A668012c57328)
that executes the refills is an ordinary address with no special rights. The agent spends from
the spending account under a 15 tKRW per-transaction cap.

| Step | Transaction | Result |
|---|---|---|
| Spending account EOA converted with EIP-7702 (type-4) | [`0x5c2d…e598`](https://sepolia-explorer.giwa.io/tx/0x5c2d05f941e9e666eb17c4e7ee116ea94802a51bbadf1177420361f2d3e3e598) | success, 36,844 gas |
| `proposeBinding`, main wallet proposes the spending account | [`0x7f4b…3abf`](https://sepolia-explorer.giwa.io/tx/0x7f4bfa21c4f1151732fb7326723be7094bf286ae1e6d44e4d1bb9085eaab3abf) | success, 130,056 gas |
| `acceptBinding`, spending account accepts | [`0xa626…052e`](https://sepolia-explorer.giwa.io/tx/0xa626b43d1817942bf1e8adf3a32200d008a79b20f42b9aa2b3a1328c8361052e) | success, 177,947 gas |
| `redeemDelegations` by the agent, 10 tKRW paid from the spending account | [`0x5025…c453`](https://sepolia-explorer.giwa.io/tx/0x5025574a3582d3381d900381223167732b838e48f4f87428540146b4732cc453) | success, 349,970 gas |
| `redeemDelegations` by the keeper, refill 1: 40 tKRW from the main wallet to the spending account | [`0xfef7…1a7c`](https://sepolia-explorer.giwa.io/tx/0xfef75b40872e9c240f7a940b682297fcf8543b858b5defff80e4260f71001a7c) | success, 407,395 gas |
| `redeemDelegations` by the agent, 16 tKRW against a 15 tKRW per-transaction cap | [`0xa8d2…f273`](https://sepolia-explorer.giwa.io/tx/0xa8d2375f867aef27faacc8318bff003f79e8ccedf13501998baca0385eb3f273) | **reverted** · `PerTxCapExceeded`, 104,839 gas |
| `redeemDelegations` by the agent to an unverified recipient (`0x…dEaD`) | [`0xd88d…5f66`](https://sepolia-explorer.giwa.io/tx/0xd88d5c3d8ef8aeac48a428463e052352a6c9e953ec6ba51fdc6408f7ff755f66) | **reverted** · `RecipientNotVerified`, 244,290 gas |
| `redeemDelegations` by the keeper, refill 2: 40 tKRW | [`0x87c3…f09a`](https://sepolia-explorer.giwa.io/tx/0x87c3da7f4a7a06ffbe080b4e4f96eb75c61624c71068ce08bbb40a5af7eaf09a) | success, 292,762 gas |
| `redeemDelegations` by the keeper, refill 3: 40 tKRW, period cap of 120 tKRW reached | [`0x0e81…21f7`](https://sepolia-explorer.giwa.io/tx/0x0e817c0662083b974879730a1911bfc553bb95117482d6834c57facda58921f7) | success, 292,762 gas |
| `redeemDelegations` by the keeper, fourth refill in the same period | [`0x2491…25e7`](https://sepolia-explorer.giwa.io/tx/0x24919b05370cbaf29738add2877e7c08c033df86a5c0f3e6d41080430f3e25e7) | **reverted** · `ERC20PeriodTransferEnforcer:transfer-amount-exceeded`, 207,825 gas |
| `redeemDelegations` by the agent, 10 tKRW with the spending account empty | [`0x432b…631b`](https://sepolia-explorer.giwa.io/tx/0x432bb6cfb2991b26fd7710954dba63caaf3bd408d7f0e1900cc74db0e880631b) | **reverted** · `ERC20InsufficientBalance`, 279,634 gas |
| `disableDelegation` of the refill delegation by the main wallet | [`0x74c7…daee`](https://sepolia-explorer.giwa.io/tx/0x74c7e72a91b0432d33266889908dcdce2446f53a058cfa7561c762786a41daee) | success, 84,150 gas |
| `redeemDelegations` by the keeper right after revocation | [`0xa89e…fc73`](https://sepolia-explorer.giwa.io/tx/0xa89e901ac21dba2dc65772ffa197099dc89ea74bd3768ad3d6dcf80624befc73) | **reverted** · `CannotUseADisabledDelegation`, 63,162 gas |

The main wallet sent out 120 tKRW in three refills, equal to the period cap. Once the cap was
reached the refills stopped, and the agent stopped when the spending account ran out.

Revert data from any of these can be decoded with `decodeRevert` in
`packages/delegation/src/errors.ts`, which bundles the DelegationManager and enforcer error ABIs.

## Build and test

```bash
git submodule update --init --recursive
forge build
forge test                        # 55 passed, 9 skipped (fork-only), 64 total
FOUNDRY_PROFILE=fork forge test   # runs the 9 fork tests against the pinned block in foundry.toml

pnpm install
pnpm -F @jipsa/delegation typecheck
pnpm -F @jipsa/delegation test    # 26 passed, 5 skipped (need a local fork), 31 total
```

Fork tests skip under the default profile (chain ID is not GIWA Sepolia) and run only with
`FOUNDRY_PROFILE=fork`. The RPC URL and block are pinned in
`foundry.toml` under `[profile.fork]`. The delegation package tests that need a chain
skip unless `OWNER_PRIVATE_KEY` and an anvil fork at `ANVIL_RPC_URL` are present.

Deploying a fresh stack:

```bash
cp .env.example .env              # set PRIVATE_KEY (deployer); forge reads .env automatically
forge script script/DeployErc7710.s.sol --rpc-url giwa_sepolia --broadcast \
  --verify --verifier blockscout --verifier-url https://sepolia-explorer.giwa.io/api/
```

`packages/delegation` is the TypeScript side: addresses, ABIs, caveat term encoding, the
EIP-712 delegation signature, and revert decoding. See its [README](packages/delegation/README.md).

## Scope

Testnet demo. tKRW is an uncollateralized test token, not a stablecoin. Delegations cover a
single token. Contracts are immutable, with no upgrade proxy.

`PolicyAccount.sol`, `script/Deploy.s.sol` and the two `PolicyAccount` tests are an earlier
deposit-based design kept as a fallback; they are not part of the deployed EIP-7702 stack.

Before mainnet: operational roles move to a multisig and timelock.

Contract names use JIPSA, the name used at GASOK submission.

## Links

- https://zipsa.xyz
- https://x.com/ZIPSA_GIWA
- hello@zipsa.xyz

## License

[MIT](LICENSE). The bundled `lib/delegation-framework` is dual-licensed MIT / Apache-2.0 by
ConsenSys Software Inc.
