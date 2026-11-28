import { encodeAbiParameters, encodePacked, type Address, type Hex } from "viem";
import { ADDR, ADDR_F1, ADDR_M2 } from "./addresses.js";
import type { Caveat, JipsaPolicy } from "./delegation.js";

/** `IERC20.transfer(address,uint256)` 셀렉터 */
export const TRANSFER_SELECTOR = "0xa9059cbb" as const satisfies Hex;

/** 기간 enforcer의 기간 길이 — 1일 */
export const PERIOD_DURATION_1D = 86_400n;

/** 기간 enforcer의 기간 길이 — 1시간 (라이브 데모의 한도 기간) */
export const PERIOD_DURATION_1H = 3_600n;

/**
 * `startDate` 기본값에 적용하는 안전 여유 (초).
 *
 * ⚠️ 기간 enforcer는 `require(block.timestamp >= startDate)`를 강제한다
 * (ERC20PeriodTransferEnforcer.sol:199 — `transfer-not-started`).
 * 서명하는 쪽의 벽시계가 체인 `block.timestamp`보다 조금이라도 앞서면 **첫 리딤이
 * 실패한다.** 포크 환경에서는 체인 시각이 수십 초 뒤처져 항상 실패한다 (실측 36초).
 *
 * 기간 길이가 1일이므로 몇 분 과거로 당겨도 일간 한도 의미는 달라지지 않는다.
 * 정확한 값이 필요하면 `startDateFromChain()`으로 체인 시각을 직접 읽어 넘길 것.
 */
export const PERIOD_START_SKEW_BUFFER = 300n;

/**
 * 체인의 최신 블록 시각을 `startDate`로 쓴다 — 가장 정확한 방법.
 * @param client `getBlock`을 제공하는 viem PublicClient
 */
export async function startDateFromChain(client: {
  getBlock: () => Promise<{ timestamp: bigint }>;
}): Promise<bigint> {
  return (await client.getBlock()).timestamp;
}

const EMPTY_ARGS = "0x" as const satisfies Hex;

// ---------------------------------------------------------------------------
// terms 인코딩 — 각 enforcer의 getTermsInfo() 소스를 열어 맞춘 것이다 (추측 금지).
// ---------------------------------------------------------------------------

/**
 * 출처: lib/delegation-framework/src/enforcers/AllowedTargetsEnforcer.sol `getTermsInfo`
 * `terms.length % 20 == 0`, 20바이트 주소를 이어 붙인다.
 */
export function allowedTargetsTerms(targets: readonly Address[]): Hex {
  return encodePacked(
    targets.map(() => "address"),
    [...targets],
  );
}

/**
 * 출처: lib/delegation-framework/src/enforcers/AllowedMethodsEnforcer.sol `getTermsInfo`
 * `terms.length % 4 == 0`, 4바이트 셀렉터를 이어 붙인다.
 */
export function allowedMethodsTerms(selectors: readonly Hex[]): Hex {
  return encodePacked(
    selectors.map(() => "bytes4"),
    [...selectors],
  );
}

/**
 * 출처: lib/delegation-framework/src/enforcers/TimestampEnforcer.sol `getTermsInfo`
 * `terms.length == 32` — `uint128 after || uint128 before`.
 * after=0 이면 하한 없음.
 */
export function timestampTerms(validUntil: number, validAfter = 0): Hex {
  return encodePacked(["uint128", "uint128"], [BigInt(validAfter), BigInt(validUntil)]);
}

/**
 * 출처: src/enforcers/JipsaPerTxCapEnforcer.sol `getTermsInfo`
 * `terms.length == 52` — `address token || uint256 cap`.
 */
export function perTxCapTerms(token: Address, cap: bigint): Hex {
  return encodePacked(["address", "uint256"], [token, cap]);
}

/**
 * 출처: lib/delegation-framework/src/enforcers/ERC20TransferAmountEnforcer.sol `getTermsInfo`
 * `terms.length == 52` — `address token || uint256 maxTokens`.
 */
export function totalBudgetTerms(token: Address, totalBudget: bigint): Hex {
  return encodePacked(["address", "uint256"], [token, totalBudget]);
}

/**
 * 출처: lib/delegation-framework/src/enforcers/ERC20PeriodTransferEnforcer.sol `getTermsInfo`
 * `terms.length == 116` — `address token || uint256 periodAmount || uint256 periodDuration || uint256 startDate`.
 */
export function periodTransferTerms(
  token: Address,
  periodAmount: bigint,
  startDate: bigint,
  periodDuration: bigint = PERIOD_DURATION_1D,
): Hex {
  return encodePacked(
    ["address", "uint256", "uint256", "uint256"],
    [token, periodAmount, periodDuration, startDate],
  );
}

/**
 * 출처: src/enforcers/DojangCaveatEnforcer.sol `getTermsInfo`
 * `terms.length == 128` — `abi.encode(gate, registry, token, verifiedRecipientOnly)`.
 * ⚠️ 다른 enforcer들과 달리 packed가 아니라 **abi.encode**다.
 */
export function dojangTerms(
  gate: Address,
  registry: Address,
  token: Address,
  verifiedRecipientOnly: boolean,
): Hex {
  return encodeAbiParameters(
    [{ type: "address" }, { type: "address" }, { type: "address" }, { type: "bool" }],
    [gate, registry, token, verifiedRecipientOnly],
  );
}

// ---------------------------------------------------------------------------
// 조합
// ---------------------------------------------------------------------------

/**
 * JIPSA 표준 caveat 7종을 **확정된 순서로** 만든다.
 *
 * ① AllowedTargets ② AllowedMethods ③ Timestamp
 * ④ **JipsaPerTxCap** ⑤ ERC20TransferAmount ⑥ ERC20PeriodTransfer ⑦ Dojang
 *
 * ⚠️ **순서를 바꾸지 말 것.** caveat은 배열 순서대로 실행되므로 차단 사유가 순서에
 *    의존한다. 건당 상한을 금액 검사 앞에 두어야 과다 청구가 `PerTxCapExceeded`로
 *    걸린다 (뒤에 두면 기간 상한이 먼저 걸려 데모 대본과 어긋난다 — 실측 확인).
 *    Dojang은 외부 컨트랙트(gate·registry) 조회라 가장 비싸므로 맨 뒤.
 *    회귀 테스트: test/erc7710/DemoScenario.t.sol
 *
 * ⚠️ **누적 상한(⑤)을 빼지 말 것.** JipsaPerTxCap은 실행 1건당 금액만 보는 무상태
 *    enforcer라, 건당 상한만 넣으면 상한 이하 리딤을 반복해 잔액 전체가 빠진다.
 *    회귀 테스트: test/erc7710/CumulativeDrain.t.sol
 *
 * @param startDate 기간 enforcer의 기준 시각(unix 초).
 *        생략하면 로컬 시각에서 `PERIOD_START_SKEW_BUFFER`만큼 뺀 값을 쓴다 —
 *        체인 시각보다 앞서면 첫 리딤이 `transfer-not-started`로 실패하기 때문이다.
 *        가능하면 `startDateFromChain(client)`로 체인 시각을 넘길 것.
 */
export function buildCaveats(policy: JipsaPolicy, startDate?: bigint): Caveat[] {
  const start =
    startDate ?? BigInt(Math.floor(Date.now() / 1000)) - PERIOD_START_SKEW_BUFFER;

  return [
    { enforcer: ADDR.allowedTargetsEnforcer, terms: allowedTargetsTerms([ADDR.tKRW]), args: EMPTY_ARGS },
    { enforcer: ADDR.allowedMethodsEnforcer, terms: allowedMethodsTerms([TRANSFER_SELECTOR]), args: EMPTY_ARGS },
    { enforcer: ADDR.timestampEnforcer, terms: timestampTerms(policy.validUntil), args: EMPTY_ARGS },
    { enforcer: ADDR.perTxCapEnforcer, terms: perTxCapTerms(ADDR.tKRW, policy.perTxCap), args: EMPTY_ARGS },
    {
      enforcer: ADDR.erc20TransferAmountEnforcer,
      terms: totalBudgetTerms(ADDR.tKRW, policy.totalBudget),
      args: EMPTY_ARGS,
    },
    {
      enforcer: ADDR.periodTransferEnforcer,
      terms: periodTransferTerms(ADDR.tKRW, policy.dailyCap, start, policy.periodDuration ?? PERIOD_DURATION_1D),
      args: EMPTY_ARGS,
    },
    {
      enforcer: ADDR.dojangEnforcer,
      terms: dojangTerms(ADDR.dojangGate, ADDR.bindingRegistry, ADDR.tKRW, policy.verifiedRecipientOnly),
      args: EMPTY_ARGS,
    },
  ];
}

// ---------------------------------------------------------------------------
// F1 자동 충전 — 메인 지갑 →(충전 위임)→ 지출용 계정 →(지출 위임)→ 에이전트
// 설계: docs/design/F1_Refill.md
// ---------------------------------------------------------------------------

/**
 * `DelegationManager.ANY_DELEGATE` — 누구나 리딤할 수 있는 위임의 delegate 값.
 * 출처: lib/delegation-framework/src/DelegationManager.sol `ANY_DELEGATE = address(0xa11)`
 * 충전 위임은 조건이 전부 enforcer에 있으므로 실행자를 지정하지 않는다.
 */
export const ANY_DELEGATE = "0x0000000000000000000000000000000000000a11" as const satisfies Address;

/**
 * 출처: src/enforcers/RefillThresholdEnforcer.sol `getTermsInfo`
 * `terms.length == 192` — `abi.encode(gate, registry, token, spender, threshold, refillAmount)`.
 * ⚠️ packed가 아니라 **abi.encode**다. `refillAmount == 0`이면 enforcer가 `ZeroRefillAmount`로 거부한다.
 */
export function refillThresholdTerms(
  gate: Address,
  registry: Address,
  token: Address,
  spender: Address,
  threshold: bigint,
  refillAmount: bigint,
): Hex {
  return encodeAbiParameters(
    [
      { type: "address" },
      { type: "address" },
      { type: "address" },
      { type: "address" },
      { type: "uint256" },
      { type: "uint256" },
    ],
    [gate, registry, token, spender, threshold, refillAmount],
  );
}

/**
 * 출처: src/enforcers/BoundDelegatorEnforcer.sol `getTermsInfo`
 * `terms.length == 128` — `DojangCaveatEnforcer`와 **같은 형식**
 * `abi.encode(gate, registry, token, verifiedRecipientOnly)`.
 */
export function boundDelegatorTerms(
  gate: Address,
  registry: Address,
  token: Address,
  verifiedRecipientOnly: boolean,
): Hex {
  return dojangTerms(gate, registry, token, verifiedRecipientOnly);
}

/**
 * 출처: lib/delegation-framework/src/enforcers/LimitedCallsEnforcer.sol `getTermsInfo`
 * `terms.length == 32` — `uint256 limit`.
 */
export function limitedCallsTerms(limit: bigint): Hex {
  return encodePacked(["uint256"], [limit]);
}

/** 충전 위임 정책 (메인 지갑이 한 번 서명) */
export interface RefillPolicy {
  /** 충전 수신처 — 주인에게 바인딩된 지출용 계정 */
  spender: Address;
  /** 지출용 계정 잔액이 이 값 **미만**일 때만 충전 */
  threshold: bigint;
  /** 1회 충전량 — 전송액이 정확히 이 값이어야 한다 */
  refillAmount: bigint;
  /** 기간당 충전 합계 상한 (메인 지갑 유출 상한) */
  periodCap: bigint;
  /** 재서명 전 총 충전 횟수 */
  maxRefills: bigint;
  /** unix 초 */
  validUntil: number;
  /** 기간 길이 (초). 기본 1일 */
  periodDuration?: bigint;
}

/** F1 enforcer 주소 — `ADDR_F1`이 비어 있는 동안에는 인자로 넘긴다 */
export interface F1EnforcerAddresses {
  refillThresholdEnforcer: Address;
  boundDelegatorEnforcer: Address;
  limitedCallsEnforcer: Address;
}

function resolveF1Addresses(
  override: Partial<F1EnforcerAddresses> | undefined,
  needed: readonly (keyof F1EnforcerAddresses)[],
): F1EnforcerAddresses {
  const merged = { ...ADDR_F1, ...override };
  const missing = needed.filter((k) => !merged[k]);
  if (missing.length > 0) {
    throw new Error(
      `F1 enforcer 주소가 없습니다: ${missing.join(", ")} — 배포 후 ADDR_F1을 채우거나 인자로 넘기세요`,
    );
  }
  return merged as F1EnforcerAddresses;
}

function defaultStartDate(startDate?: bigint): bigint {
  return startDate ?? BigInt(Math.floor(Date.now() / 1000)) - PERIOD_START_SKEW_BUFFER;
}

/**
 * 충전 위임 caveat 묶음을 **확정된 순서로** 만든다.
 *
 * ① Timestamp ② **RefillThreshold** ③ ERC20PeriodTransfer ④ LimitedCalls
 *
 * view 검사(①②)를 앞에, 카운터를 쓰는 검사(③④)를 뒤에 둔다. revert 시 카운터도 되돌아가므로
 * 순서는 안전성이 아니라 차단 사유에만 영향을 준다 — 잔액 조건은 ②, 기간 한도는 ③, 횟수 소진은 ④에서 걸린다.
 * 회귀 테스트: test/erc7710/Refill.t.sol, test/erc7710/RefillScenario.t.sol
 *
 * `JipsaPerTxCap`은 넣지 않는다 — ②가 전송액을 `refillAmount`와 정확히 일치시키므로 중복이다.
 * 이 묶음으로 만든 위임의 delegate는 `ANY_DELEGATE`로 둔다.
 *
 * 손실 상한 (고정 창 하나): 메인 유출 ≤ min(periodCap, refillAmount × 남은 횟수).
 *
 * @param startDate 기간 enforcer 기준 시각 — `buildCaveats`와 같은 규칙 (생략 시 로컬 시각 − 여유)
 * @param addresses F1 enforcer 주소. 생략하면 `ADDR_F1`을 쓴다
 */
export function buildRefillCaveats(
  policy: RefillPolicy,
  startDate?: bigint,
  addresses?: Partial<F1EnforcerAddresses>,
): Caveat[] {
  if (policy.refillAmount <= 0n) throw new Error("refillAmount는 0보다 커야 합니다");
  if (policy.refillAmount > policy.periodCap) {
    throw new Error("refillAmount가 periodCap보다 크면 충전이 한 번도 통과하지 못합니다");
  }
  if (policy.maxRefills <= 0n) throw new Error("maxRefills는 0보다 커야 합니다");

  const f1 = resolveF1Addresses(addresses, ["refillThresholdEnforcer", "limitedCallsEnforcer"]);
  const start = defaultStartDate(startDate);

  return [
    { enforcer: ADDR.timestampEnforcer, terms: timestampTerms(policy.validUntil), args: EMPTY_ARGS },
    {
      enforcer: f1.refillThresholdEnforcer,
      terms: refillThresholdTerms(
        ADDR.dojangGate,
        ADDR.bindingRegistry,
        ADDR.tKRW,
        policy.spender,
        policy.threshold,
        policy.refillAmount,
      ),
      args: EMPTY_ARGS,
    },
    {
      enforcer: ADDR.periodTransferEnforcer,
      terms: periodTransferTerms(
        ADDR.tKRW,
        policy.periodCap,
        start,
        policy.periodDuration ?? PERIOD_DURATION_1D,
      ),
      args: EMPTY_ARGS,
    },
    { enforcer: f1.limitedCallsEnforcer, terms: limitedCallsTerms(policy.maxRefills), args: EMPTY_ARGS },
  ];
}

/**
 * 지출 위임(지출용 계정 → 에이전트) caveat 묶음을 **확정된 순서로** 만든다.
 *
 * ① Timestamp ② JipsaPerTxCap ③ ERC20PeriodTransfer ④ ERC20TransferAmount ⑤ **BoundDelegator**
 *
 * `buildCaveats`와 같은 금액 검사 순서에, 책임 귀속 검사를 Dojang 대신 BoundDelegator로 바꾼 것이다.
 * 지출용 계정은 도장이 없으므로 Dojang enforcer로는 바인딩된 에이전트도 통과하지 못한다.
 * 회귀 테스트: test/erc7710/BoundDelegator.t.sol
 *
 * @param policy `JipsaPolicy` 그대로 — `agent`가 delegate, `dailyCap`이 기간 한도
 */
export function buildSpendCaveats(
  policy: JipsaPolicy,
  startDate?: bigint,
  addresses?: Partial<F1EnforcerAddresses>,
): Caveat[] {
  const f1 = resolveF1Addresses(addresses, ["boundDelegatorEnforcer"]);
  const start = defaultStartDate(startDate);

  return [
    { enforcer: ADDR.timestampEnforcer, terms: timestampTerms(policy.validUntil), args: EMPTY_ARGS },
    { enforcer: ADDR.perTxCapEnforcer, terms: perTxCapTerms(ADDR.tKRW, policy.perTxCap), args: EMPTY_ARGS },
    {
      enforcer: ADDR.periodTransferEnforcer,
      terms: periodTransferTerms(ADDR.tKRW, policy.dailyCap, start, policy.periodDuration ?? PERIOD_DURATION_1D),
      args: EMPTY_ARGS,
    },
    {
      enforcer: ADDR.erc20TransferAmountEnforcer,
      terms: totalBudgetTerms(ADDR.tKRW, policy.totalBudget),
      args: EMPTY_ARGS,
    },
    {
      enforcer: f1.boundDelegatorEnforcer,
      terms: boundDelegatorTerms(ADDR.dojangGate, ADDR.bindingRegistry, ADDR.tKRW, policy.verifiedRecipientOnly),
      args: EMPTY_ARGS,
    },
  ];
}

// ---------------------------------------------------------------------------
// M2-1 결제 게이트 — 지출용 계정 →(게이트 위임, 수임자 = 게이트)→ PaymentGate → 상점 수신처
// 설계: docs/design/M2_PaymentGate.md
// ---------------------------------------------------------------------------

/** 게이트 위임 정책 (지출용 계정이 서명) */
export interface GatePolicy {
  /** 수임자 — 결제 게이트 주소. 생략하면 `ADDR_M2.paymentGate` */
  gate?: Address;
  perTxCap: bigint;
  /** 기간당 합계 상한 */
  periodCap: bigint;
  /** 기간 길이 (초). 기본 1시간 */
  periodDuration?: bigint;
  /** 누적 총액 */
  totalBudget: bigint;
  /** unix 초 */
  validUntil: number;
}

export interface GateAddresses {
  token: Address;
  timestampEnforcer: Address;
  allowedTargetsEnforcer: Address;
  allowedMethodsEnforcer: Address;
  perTxCapEnforcer: Address;
  periodTransferEnforcer: Address;
  erc20TransferAmountEnforcer: Address;
}

/** 게이트 위임의 수임자 (정책 → `ADDR_M2`) — 없으면 예외 */
export function resolveGate(policy: Pick<GatePolicy, "gate">): Address {
  const gate = policy.gate ?? ADDR_M2.paymentGate;
  if (!gate) {
    throw new Error("결제 게이트 주소가 없습니다 — 배포 후 ADDR_M2.paymentGate를 채우거나 policy.gate로 넘기세요");
  }
  return gate;
}

/**
 * 게이트 위임 caveat 묶음을 **확정된 순서로** 만든다.
 *
 * ① Timestamp ② AllowedTargets[token] ③ AllowedMethods[transfer] ④ JipsaPerTxCap
 * ⑤ ERC20PeriodTransfer ⑥ ERC20TransferAmount
 *
 * `BoundDelegatorEnforcer`는 넣지 않는다 — 그 enforcer는 리딤하는 주소(여기서는 게이트)가 주인에게
 * 묶였는지 보는데 게이트는 묶인 주소가 아니다. 같은 확인을 게이트가 호출자(에이전트)에 대해 직접 한다
 * (`CallerNotBound`). 수신처는 게이트가 생성자에서 고정한 주소뿐이다.
 * 회귀 테스트: test/erc7710/PaymentGate.t.sol
 *
 * @param addresses 다른 체인·로컬 배포용. 생략하면 GIWA Sepolia 주소
 * @param startDate 기간 enforcer 기준 시각 — `buildCaveats`와 같은 규칙 (생략 시 로컬 시각 − 여유)
 */
export function buildGateCaveats(
  policy: GatePolicy,
  addresses?: Partial<GateAddresses>,
  startDate?: bigint,
): Caveat[] {
  if (policy.perTxCap <= 0n) throw new Error("perTxCap은 0보다 커야 합니다");
  if (policy.perTxCap > policy.periodCap) {
    throw new Error("perTxCap이 periodCap보다 크면 결제가 한 번도 통과하지 못합니다");
  }
  const a: GateAddresses = {
    token: ADDR.tKRW,
    timestampEnforcer: ADDR.timestampEnforcer,
    allowedTargetsEnforcer: ADDR.allowedTargetsEnforcer,
    allowedMethodsEnforcer: ADDR.allowedMethodsEnforcer,
    perTxCapEnforcer: ADDR.perTxCapEnforcer,
    periodTransferEnforcer: ADDR.periodTransferEnforcer,
    erc20TransferAmountEnforcer: ADDR.erc20TransferAmountEnforcer,
    ...addresses,
  };
  const start = defaultStartDate(startDate);
  return [
    { enforcer: a.timestampEnforcer, terms: timestampTerms(policy.validUntil), args: EMPTY_ARGS },
    { enforcer: a.allowedTargetsEnforcer, terms: allowedTargetsTerms([a.token]), args: EMPTY_ARGS },
    { enforcer: a.allowedMethodsEnforcer, terms: allowedMethodsTerms([TRANSFER_SELECTOR]), args: EMPTY_ARGS },
    { enforcer: a.perTxCapEnforcer, terms: perTxCapTerms(a.token, policy.perTxCap), args: EMPTY_ARGS },
    {
      enforcer: a.periodTransferEnforcer,
      terms: periodTransferTerms(a.token, policy.periodCap, start, policy.periodDuration ?? PERIOD_DURATION_1H),
      args: EMPTY_ARGS,
    },
    {
      enforcer: a.erc20TransferAmountEnforcer,
      terms: totalBudgetTerms(a.token, policy.totalBudget),
      args: EMPTY_ARGS,
    },
  ];
}
