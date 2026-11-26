import { describe, expect, it } from "vitest";
import type { Address, Hex } from "viem";
import { ADDR, ADDR_F1, DEMO, tkrw } from "../src/addresses.js";
import {
  ANY_DELEGATE,
  boundDelegatorTerms,
  buildRefillCaveats,
  buildSpendCaveats,
  dojangTerms,
  limitedCallsTerms,
  periodTransferTerms,
  refillThresholdTerms,
  type F1EnforcerAddresses,
  type RefillPolicy,
} from "../src/caveats.js";
import type { JipsaPolicy } from "../src/delegation.js";
import { decodeRevert, errorSelectors } from "../src/errors.js";

/**
 * F1 자동 충전 인코더·에러 해석.
 *
 * 기대값은 **Foundry `cast`로 뽑은 것**이다 — viem 출력을 다시 적은 스냅샷이 아니다.
 *
 * 재생성:
 *   cast abi-encode "f(address,address,address,address,uint256,uint256)" \
 *     <dojangGate> <bindingRegistry> <tKRW> 0x1111111111111111111111111111111111111111 300000000 500000000
 *   cast sig "BalanceNotBelowThreshold(uint256,uint256)"
 *   cast calldata "BalanceNotBelowThreshold(uint256,uint256)" 300000000 300000000
 */
const SPENDER = "0x1111111111111111111111111111111111111111" as const satisfies Address;

const CAST = {
  refillTerms:
    "0x000000000000000000000000d13ae574e53f2d14f71411383cceec9c16529fc30000000000000000000000006ef7f805fbcaa49cbfc11c861e2ec051549433c70000000000000000000000001e743c166faeeee5b840a471a6760535ae4076b000000000000000000000000011111111111111111111111111111111111111110000000000000000000000000000000000000000000000000000000011e1a300000000000000000000000000000000000000000000000000000000001dcd6500",
  boundTerms:
    "0x000000000000000000000000d13ae574e53f2d14f71411383cceec9c16529fc30000000000000000000000006ef7f805fbcaa49cbfc11c861e2ec051549433c70000000000000000000000001e743c166faeeee5b840a471a6760535ae4076b00000000000000000000000000000000000000000000000000000000000000001",
  limitedCalls5: "0x0000000000000000000000000000000000000000000000000000000000000005",
  selectors: {
    BalanceNotBelowThreshold: "0xc2d1f941",
    SpenderNotBound: "0xa4cef42d",
    InvalidRecipient: "0xa0d6e75a",
    InvalidRefillAmount: "0xb8025143",
    InvalidValue: "0x6072742c",
    ZeroRefillAmount: "0xfb06caa0",
    BalanceQueryFailed: "0xe707155d",
    DelegatorNotBound: "0x0eab6995",
    AgentNotBound: "0x9adcbfe0",
  },
  revertBelowThreshold:
    "0xc2d1f9410000000000000000000000000000000000000000000000000000000011e1a3000000000000000000000000000000000000000000000000000000000011e1a300",
  revertDelegatorNotBound: "0x0eab69950000000000000000000000001111111111111111111111111111111111111111",
  revertLimitExceeded:
    "0x08c379a0000000000000000000000000000000000000000000000000000000000000002000000000000000000000000000000000000000000000000000000000000000234c696d6974656443616c6c73456e666f726365723a6c696d69742d65786365656465640000000000000000000000000000000000000000000000000000000000",
} as const;

/** 인자로 넘기는 경로(다른 체인·로컬 배포)를 확인하기 위한 테스트용 주소 */
const F1: F1EnforcerAddresses = {
  refillThresholdEnforcer: "0x000000000000000000000000000000000000F101",
  boundDelegatorEnforcer: "0x000000000000000000000000000000000000F102",
  limitedCallsEnforcer: "0x000000000000000000000000000000000000F103",
};

const START_DATE = 1_790_000_000n;

const REFILL: RefillPolicy = {
  spender: SPENDER,
  threshold: tkrw(300),
  refillAmount: tkrw(500),
  periodCap: tkrw(1_000),
  maxRefills: 5n,
  validUntil: 1_800_000_000,
};

const SPEND: JipsaPolicy = {
  totalBudget: tkrw(50_000),
  perTxCap: tkrw(200),
  dailyCap: tkrw(5_000),
  validUntil: 1_800_000_000,
  verifiedRecipientOnly: true,
  agent: DEMO.agent,
};

describe("F1 terms 인코딩 (cast 기준값)", () => {
  it("refillThresholdTerms = abi.encode 192바이트", () => {
    const terms = refillThresholdTerms(
      ADDR.dojangGate,
      ADDR.bindingRegistry,
      ADDR.tKRW,
      SPENDER,
      tkrw(300),
      tkrw(500),
    );
    expect(terms.toLowerCase()).toBe(CAST.refillTerms);
    expect((terms.length - 2) / 2).toBe(192);
  });

  it("boundDelegatorTerms = Dojang과 같은 128바이트 형식", () => {
    const terms = boundDelegatorTerms(ADDR.dojangGate, ADDR.bindingRegistry, ADDR.tKRW, true);
    expect(terms.toLowerCase()).toBe(CAST.boundTerms);
    expect(terms).toBe(dojangTerms(ADDR.dojangGate, ADDR.bindingRegistry, ADDR.tKRW, true));
  });

  it("limitedCallsTerms = uint256 32바이트", () => {
    expect(limitedCallsTerms(5n)).toBe(CAST.limitedCalls5);
  });

  it("ANY_DELEGATE = DelegationManager의 address(0xa11)", () => {
    expect(BigInt(ANY_DELEGATE)).toBe(0xa11n);
  });
});

describe("충전 위임 caveat 묶음", () => {
  it("순서: Timestamp → RefillThreshold → Period → LimitedCalls", () => {
    const c = buildRefillCaveats(REFILL, START_DATE, F1);
    expect(c.map((x) => x.enforcer)).toEqual([
      ADDR.timestampEnforcer,
      F1.refillThresholdEnforcer,
      ADDR.periodTransferEnforcer,
      F1.limitedCallsEnforcer,
    ]);
    expect(c[1]!.terms.toLowerCase()).toBe(CAST.refillTerms);
    expect(c[2]!.terms).toBe(periodTransferTerms(ADDR.tKRW, tkrw(1_000), START_DATE));
    expect(c[3]!.terms).toBe(CAST.limitedCalls5);
  });

  it("JipsaPerTxCap은 넣지 않는다 (정확한 충전량 검사와 중복)", () => {
    const c = buildRefillCaveats(REFILL, START_DATE, F1);
    expect(c.map((x) => x.enforcer)).not.toContain(ADDR.perTxCapEnforcer);
  });

  it("주소를 넘기지 않으면 ADDR_F1(GIWA Sepolia 배포 주소)을 쓴다", () => {
    const c = buildRefillCaveats(REFILL, START_DATE);
    expect(c[1]!.enforcer).toBe("0x7BA5Ef6dFb5712db79A4802FE16B31389242b95C");
    expect(c[3]!.enforcer).toBe("0x96efFEEe819Db13e6bb0A63F2057dF0Eca204533");
  });

  it("주소가 비어 있으면 만들 수 없다", () => {
    expect(() =>
      buildRefillCaveats(REFILL, START_DATE, { refillThresholdEnforcer: undefined, limitedCallsEnforcer: undefined }),
    ).toThrow(/refillThresholdEnforcer, limitedCallsEnforcer/);
  });

  it("충전이 한 번도 통과할 수 없는 정책은 거부한다", () => {
    expect(() => buildRefillCaveats({ ...REFILL, refillAmount: 0n }, START_DATE, F1)).toThrow();
    expect(() => buildRefillCaveats({ ...REFILL, refillAmount: tkrw(1_001) }, START_DATE, F1)).toThrow();
    expect(() => buildRefillCaveats({ ...REFILL, maxRefills: 0n }, START_DATE, F1)).toThrow();
  });
});

describe("지출 위임 caveat 묶음", () => {
  it("순서: Timestamp → PerTxCap → Period → TransferAmount → BoundDelegator", () => {
    const c = buildSpendCaveats(SPEND, START_DATE, F1);
    expect(c.map((x) => x.enforcer)).toEqual([
      ADDR.timestampEnforcer,
      ADDR.perTxCapEnforcer,
      ADDR.periodTransferEnforcer,
      ADDR.erc20TransferAmountEnforcer,
      F1.boundDelegatorEnforcer,
    ]);
    expect(c[4]!.terms.toLowerCase()).toBe(CAST.boundTerms);
  });

  it("Dojang enforcer를 쓰지 않는다 (지출용 계정은 도장이 없다)", () => {
    const c = buildSpendCaveats(SPEND, START_DATE, F1);
    expect(c.map((x) => x.enforcer)).not.toContain(ADDR.dojangEnforcer);
  });

  it("주소를 넘기지 않으면 ADDR_F1(GIWA Sepolia 배포 주소)을 쓴다", () => {
    expect(buildSpendCaveats(SPEND, START_DATE)[4]!.enforcer).toBe("0xeBF1D1C0f1D982f7FeFB6aE0d84bcceF6E6c636f");
  });

  it("주소가 비어 있으면 만들 수 없다", () => {
    expect(() => buildSpendCaveats(SPEND, START_DATE, { boundDelegatorEnforcer: undefined })).toThrow(
      /boundDelegatorEnforcer/,
    );
  });
});

describe("F1 에러 해석", () => {
  it("셀렉터가 cast sig와 일치한다", () => {
    const sel = errorSelectors();
    for (const [name, expected] of Object.entries(CAST.selectors)) {
      expect(sel[name], name).toBe(expected);
    }
  });

  it("BalanceNotBelowThreshold(잔액, 기준)를 해석한다", () => {
    const d = decodeRevert(CAST.revertBelowThreshold as Hex);
    expect(d?.reason).toBe("BalanceNotBelowThreshold");
    expect(d?.args).toEqual([tkrw(300), tkrw(300)]);
    expect(d?.label).toContain("충전 기준 이상");
  });

  it("DelegatorNotBound(지출용 계정)를 해석한다", () => {
    const d = decodeRevert(CAST.revertDelegatorNotBound as Hex);
    expect(d?.reason).toBe("DelegatorNotBound");
    expect(d?.args).toEqual([SPENDER]);
  });

  it("LimitedCalls require 문자열을 해석한다", () => {
    const d = decodeRevert(CAST.revertLimitExceeded as Hex);
    expect(d?.reason).toBe("LimitedCallsEnforcer:limit-exceeded");
    expect(d?.label).toBe("위임의 총 사용 횟수를 다 썼습니다");
  });
});
