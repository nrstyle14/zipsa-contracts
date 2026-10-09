# @jipsa/delegation

Shared TypeScript package that assembles, serializes and redeems ERC-7710 delegations. The side that issues a delegation (the owner) and the side that executes it (the agent) must use the same encoding, so it lives in one place.

## Why this package exists

Caveat `terms` encoding differs per enforcer (packed vs `abi.encode`, fixed lengths),
the EIP-712 signing payload excludes `signature` and `args`, and the delegation hash
is a struct hash, not an EIP-712 typed-data hash. If the dashboard and the agent each
implemented this on their own they would inevitably drift. It is built here, and only here.

## Where the constants come from

The EIP-712 domain, `ROOT_AUTHORITY`, ModeCode and the type hashes were all read from
the `lib/delegation-framework` v1.3.0 source, and each constant carries a comment with
the file and line number it came from. **No value is guessed.**

## How the encoding is verified

The expected values in `test/encoding.test.ts` are not snapshots; they are **values
produced by Solidity**.

```bash
forge script script/PrintCaveats.s.sol   # regenerate the expected values
pnpm test
```

If the TS and Solidity encodings diverge, the tests break. This is how a bug in
`getDelegationHash` was actually caught (the caveat hash array was concatenated with
`abi.encode`; the original uses `abi.encodePacked`).

`test/roundtrip.test.ts` verifies the sign → redeem round trip against an anvil fork of
GIWA Sepolia. It skips automatically when anvil or the owner key is missing.

```bash
anvil --fork-url https://sepolia-rpc-flashblocks.giwa.io --port 8545
set -a; source ../../.env; set +a
pnpm test
```

## Caution

- **Do not reorder the caveats.** The revert reason depends on the order (see the `buildCaveats` comment).
- **Do not drop the cumulative cap.** A per-transaction cap alone does not stop repeated redemptions.
- **Use chain time for `startDate`.** If the local wall clock runs ahead, the period enforcer
  rejects the first redemption with `transfer-not-started`. `startDateFromChain(client)` is recommended.
- **Do not send in batch mode.** All of our caveats except Timestamp are single-mode only.
