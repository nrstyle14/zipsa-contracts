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

## Deployed contracts (GIWA Sepolia)

All 12 contracts are verified on Blockscout. Total deployment gas: **10,841,972**.

Written by ZIPSA:

| Contract | Role | Address |
|---|---|---|
| `JipsaSettlementToken` (tKRW) | Test settlement token, 6 decimals, EIP-2612 permit | [`0x1E743C166FaeeEe5b840A471a6760535AE4076B0`](https://sepolia-explorer.giwa.io/address/0x1E743C166FaeeEe5b840A471a6760535AE4076B0) |
| `DojangVerifiedGate` | Reads Dojang `isVerified` for a configured set of issuers | [`0xD13aE574E53F2D14F71411383CcEeC9c16529fc3`](https://sepolia-explorer.giwa.io/address/0xD13aE574E53F2D14F71411383CcEeC9c16529fc3) |
| `OwnerBindingRegistry` | Binds an agent wallet to a verified owner (propose → accept) | [`0x6ef7F805fBCaA49cbfc11C861E2EC051549433C7`](https://sepolia-explorer.giwa.io/address/0x6ef7F805fBCaA49cbfc11C861E2EC051549433C7) |
| `DojangCaveatEnforcer` | ERC-7710 caveat: recipient verified, agent bound, owner verified | [`0x8C9c8437C27003f3d86F438c7147668d9cC5948C`](https://sepolia-explorer.giwa.io/address/0x8C9c8437C27003f3d86F438c7147668d9cC5948C) |
| `JipsaPerTxCapEnforcer` | ERC-7710 caveat: per-transaction amount cap | [`0xdea5DF3357e0EEf6A841d3639d115eb57b42B642`](https://sepolia-explorer.giwa.io/address/0xdea5DF3357e0EEf6A841d3639d115eb57b42B642) |

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

External dependencies on GIWA Sepolia: `DojangScroll`
[`0xd5077b67dcb56caC8b270C7788FC3E6ee03F17B9`](https://sepolia-explorer.giwa.io/address/0xd5077b67dcb56caC8b270C7788FC3E6ee03F17B9)
and EntryPoint v0.7
[`0x0000000071727De22E5E9d8BAf0edAc6f37da032`](https://sepolia-explorer.giwa.io/address/0x0000000071727De22E5E9d8BAf0edAc6f37da032).

Caveat order is fixed and matters, because caveats run in array order and the revert reason
depends on which one fires first: AllowedTargets → AllowedMethods → Timestamp → JipsaPerTxCap →
ERC20TransferAmount → ERC20PeriodTransfer → Dojang. `JipsaPerTxCapEnforcer` is stateless and
must always be paired with the cumulative cap; see `test/erc7710/CumulativeDrain.t.sol`.

## On-chain record

One full cycle on GIWA Sepolia, in order. Each link opens the transaction on Blockscout.

| Step | Transaction | Result |
|---|---|---|
| Owner EOA converted with EIP-7702 (type-4) | [`0x47aa…cf50`](https://sepolia-explorer.giwa.io/tx/0x47aaba300d9553e870e43b9b4e024532ed5e3a2c6cd6f7342e09d0534e1ecf50) | success, 36,844 gas |
| `enableDelegation` | [`0x2a04…b641`](https://sepolia-explorer.giwa.io/tx/0x2a04cd442e5ca58a469699fd30db06b3b432ae328140ed98183fd90d7107b641) | success, 80,592 gas |
| `redeemDelegations`, 2 tKRW paid from the owner's balance | [`0xaf5e…8b55`](https://sepolia-explorer.giwa.io/tx/0xaf5ea45f01f3089caeb368088dc653b4eab25340b3b08e71a04938ffd55a8b55) | success, 393,987 gas |
| `disableDelegation` by the owner | [`0x3ccf…ae46`](https://sepolia-explorer.giwa.io/tx/0x3ccf4056b174357ba8889c0c168f99ea8b34b436f4f0f5539a57f2332cd4ae46) | success, 102,557 gas |
| `redeemDelegations` right after revocation | [`0x5bb1…9def`](https://sepolia-explorer.giwa.io/tx/0x5bb13c0b52de61175637a42bf2228bda1f377316c9887a23bd06850ba8b8d9ef) | **reverted**, 73,073 gas |

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
