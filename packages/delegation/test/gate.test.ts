import { describe, expect, it } from "vitest";
import { toFunctionSelector, type Hex } from "viem";
import { ABI } from "../src/abis.js";
import { ADDR, ADDR_M2, DEMO, tkrw } from "../src/addresses.js";
import { buildGateCaveats, periodTransferTerms, PERIOD_DURATION_1H, resolveGate } from "../src/caveats.js";
import { ROOT_AUTHORITY, type Delegation } from "../src/delegation.js";
import { decodeRevert, errorSelectors } from "../src/errors.js";
import { payDelegatedCalldata } from "../src/redeem.js";

/**
 * M2-1 결제 게이트 인코더·에러 해석.
 *
 * 기대값은 **Foundry `cast`로 뽑은 것**이다 — viem 출력을 다시 적은 스냅샷이 아니다.
 *
 * 재생성:
 *   cast sig "payDelegated(bytes,address,uint256,bytes32)"
 *   cast abi-encode --packed "f(address,uint256,uint256,uint256)" <tKRW> 200000000 3600 1795000000
 *   CTX=$(cast abi-encode "f((address,address,bytes32,(address,bytes,bytes)[],uint256,bytes)[])" \
 *     "[(<gate>,<spending>,0xff…ff,[(<timestampEnforcer>,0x01,0x)],7,0xabcd)]")
 *   cast calldata "payDelegated(bytes,address,uint256,bytes32)" $CTX <tKRW> 10000000 <"order-1" bytes32>
 */
const CAST = {
  payDelegated: "0x414b7cd0",
  pay: "0x5e5571ac",
  selectors: {
    ZeroAmount: "0x1f2a2005",
    TokenNotAllowed: "0x94403b70",
    RefAlreadyPaid: "0xd98ff382",
    PayerNotAccountable: "0x40380c6f",
    PayerNotVerified: "0x3327bece",
    CallerNotBound: "0x10573333",
    InvalidDelegationChain: "0xec22b2ef",
    PaymentNotReceived: "0x390ec438",
    NotAdmin: "0x17a84242",
    ERC20InsufficientBalance: "0xe450d38c",
  },
  periodTerms1h:
    "0x1e743c166faeeee5b840a471a6760535ae4076b0000000000000000000000000000000000000000000000000000000000bebc2000000000000000000000000000000000000000000000000000000000000000e10000000000000000000000000000000000000000000000000000000006afd86c0",
  revertCallerNotBound:
    "0x1057333300000000000000000000000011111111111111111111111111111111111111110000000000000000000000007d558deaf66985ae1358d96152ef1b7a28857a6c",
  payDelegatedCalldata: "0x414b7cd000000000000000000000000000000000000000000000000000000000000000800000000000000000000000001e743c166faeeee5b840a471a6760535ae4076b000000000000000000000000000000000000000000000000000000000009896806f726465722d31000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000260000000000000000000000000000000000000000000000000000000000000002000000000000000000000000000000000000000000000000000000000000000010000000000000000000000000000000000000000000000000000000000000020000000000000000000000000f188b4261cc1aa1491a234ebc5c7e4e9854f0d380000000000000000000000007c15b921d9ab30c111588ed6409545c2519078ebffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff00000000000000000000000000000000000000000000000000000000000000c0000000000000000000000000000000000000000000000000000000000000000700000000000000000000000000000000000000000000000000000000000001c000000000000000000000000000000000000000000000000000000000000000010000000000000000000000000000000000000000000000000000000000000020000000000000000000000000972298257a69792b0219900d8a2c9daec8094cc6000000000000000000000000000000000000000000000000000000000000006000000000000000000000000000000000000000000000000000000000000000a00000000000000000000000000000000000000000000000000000000000000001010000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000002abcd000000000000000000000000000000000000000000000000000000000000",
} as const;

const GATE = "0xF188B4261CC1AA1491a234Ebc5c7E4E9854f0d38" as const;
const SPENDING = "0x7c15B921D9ab30c111588ED6409545c2519078Eb" as const;
const ORDER_1 = "0x6f726465722d3100000000000000000000000000000000000000000000000000" as const satisfies Hex;

describe("결제 게이트 주소", () => {
  it("ADDR_M2.paymentGate 가 배포 주소", () => {
    expect(ADDR_M2.paymentGate).toBe(GATE);
    expect(resolveGate({})).toBe(GATE);
  });
});

describe("payDelegated 인코딩", () => {
  it("셀렉터가 cast 와 같다", () => {
    expect(toFunctionSelector("payDelegated(bytes,address,uint256,bytes32)")).toBe(CAST.payDelegated);
    expect(toFunctionSelector("pay(address,uint256,bytes32)")).toBe(CAST.pay);
    const fns = ABI.paymentGate.filter((f) => f.type === "function").map((f) => (f as { name: string }).name);
    expect(fns).toContain("payDelegated");
  });

  it("calldata 가 cast 와 바이트 단위로 같다", () => {
    const d: Delegation = {
      delegate: GATE,
      delegator: SPENDING,
      authority: ROOT_AUTHORITY,
      caveats: [{ enforcer: ADDR.timestampEnforcer, terms: "0x01", args: "0x" }],
      salt: 7n,
      signature: "0xabcd",
    };
    expect(payDelegatedCalldata(d, tkrw(10), ORDER_1).toLowerCase()).toBe(CAST.payDelegatedCalldata);
  });
});

describe("게이트 위임 caveat", () => {
  const policy = { perTxCap: tkrw(15), periodCap: tkrw(200), totalBudget: tkrw(100_000), validUntil: 1798675200 };

  it("순서: Timestamp → AllowedTargets → AllowedMethods → PerTxCap → Period → TransferAmount", () => {
    const c = buildGateCaveats(policy, undefined, 1795000000n);
    expect(c.map((x) => x.enforcer)).toEqual([
      ADDR.timestampEnforcer,
      ADDR.allowedTargetsEnforcer,
      ADDR.allowedMethodsEnforcer,
      ADDR.perTxCapEnforcer,
      ADDR.periodTransferEnforcer,
      ADDR.erc20TransferAmountEnforcer,
    ]);
    expect(c[4]!.terms).toBe(CAST.periodTerms1h);
    expect(c[1]!.terms.toLowerCase()).toBe(ADDR.tKRW.toLowerCase());
    expect(c[2]!.terms).toBe("0xa9059cbb");
  });

  it("기간 기본값은 1시간", () => {
    expect(periodTransferTerms(ADDR.tKRW, tkrw(200), 1795000000n, PERIOD_DURATION_1H)).toBe(CAST.periodTerms1h);
  });

  it("건당이 기간 한도보다 크면 거부", () => {
    expect(() => buildGateCaveats({ ...policy, perTxCap: tkrw(300) })).toThrow();
  });
});

describe("게이트 에러", () => {
  it("셀렉터 표가 cast 와 같다", () => {
    const sel = errorSelectors();
    for (const [name, s] of Object.entries(CAST.selectors)) expect(sel[name], name).toBe(s);
  });

  it("CallerNotBound 를 이름·인자·한국어 문장으로 푼다", () => {
    const r = decodeRevert(CAST.revertCallerNotBound);
    expect(r?.reason).toBe("CallerNotBound");
    expect((r?.args?.[1] as string).toLowerCase()).toBe(DEMO.owner.toLowerCase());
    expect(r?.label).toContain("묶여 있지 않습니다");
  });
});
