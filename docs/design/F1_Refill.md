# F1 자동 충전 — 설계

상태: **확정** — 설계 보고의 결정 A~D를 권장안대로 채택. 브랜치 `feat/f1-refill`

---

## 0. 구조

```
메인 지갑 (주인, 도장 검증됨, 7702 계정)
   │  충전 위임 — delegate = ANY_DELEGATE, 조건이 맞을 때만
   ▼
지출용 계정 (주인의 두 번째 EOA, 7702 계정, 레지스트리상 주인에게 바인딩)
   │  지출 위임 — 건당·기간·총액 한도
   ▼
에이전트 (키만 보유, 레지스트리상 주인에게 바인딩)
```

| # | 결정 |
|---|---|
| D1 | 충전은 메인 지갑이 서명한 위임 한 장. 실행자는 누구나(`ANY_DELEGATE`). 조건이 전부 컨트랙트에 있으므로 실행자를 믿을 필요가 없다 |
| D2 | 신규 `RefillThresholdEnforcer` — 수신처 = terms의 지출용 계정, 그 계정이 이 주인에게 바인딩, 주인 도장 유효, 지출용 계정 잔액 < 기준일 때만 통과 |
| D3 | 기간 한도·총 횟수·만료는 기존 enforcer(`ERC20PeriodTransferEnforcer`, `LimitedCallsEnforcer`, `TimestampEnforcer`)로 조합. 1회 충전량은 결정 A에 따라 `RefillThresholdEnforcer`가 정확히 강제한다 |
| D4 | 신규 `BoundDelegatorEnforcer` — 지출 위임용. 위임한 계정과 에이전트가 같은 검증된 주인에게 바인딩되어 있는지 확인 |
| D5 | 지출용 계정은 기존 `OwnerBindingRegistry`에 에이전트와 같은 방식으로 바인딩 (주인 propose → 지출용 계정 accept) |
| D6 | `DojangCaveatEnforcer`, `JipsaPerTxCapEnforcer`, `OwnerBindingRegistry`, A1 브랜치는 수정하지 않는다 |
| D7 | 손실 상한은 6절의 식으로 표기 |

### 확정된 결정 (설계 보고)

| # | 결정 | 채택 |
|---|---|---|
| A | 먼지 충전 방지: `RefillThresholdEnforcer` terms에 `refillAmount`를 넣고 전송액이 **정확히 일치**해야 통과 | 채택. 충전 묶음에서 `JipsaPerTxCapEnforcer`는 뺀다 |
| B | 충전 caveat 순서 | Timestamp → RefillThreshold → ERC20Period → LimitedCalls |
| C | 신규 enforcer에서 7702 지정자 고정 | 하지 않는다 (`DojangCaveatEnforcer`와 일관) |
| D | `BoundDelegatorEnforcer` 에러 | `AgentNotBound(redeemer, owner)` 재사용(둘째 인자 = 주인), `DelegatorNotBound(address)` 신규 |

---

## 1. 프레임워크 사실 (코드 근거)

### 1-1. `ANY_DELEGATE`와 `_redeemer`

- `DelegationManager.redeemDelegations`는 `delegations_[0].delegate == ANY_DELEGATE (0xa11)`이면 호출자 검사를 건너뛴다(`DelegationManager.sol:156`). 임의 주소가 리딤할 수 있다.
- 훅의 `_redeemer`에는 `msg.sender`(임의 실행자)가 들어온다. **`RefillThresholdEnforcer`는 `_redeemer`를 쓰지 않는다.**
- `LimitedCallsEnforcer`·`ERC20PeriodTransferEnforcer`의 카운터 키는 `[DelegationManager][delegationHash]`다. 실행자가 누구든 같은 카운터를 공유한다.
- 배치는 항목마다 beforeHooks → 실행 → afterHooks를 끝내고 다음 항목으로 간다. 잔액 검사는 배치 안에서도 항목마다 최신 상태를 본다.
- 누구나 충전 위임을 authority로 하는 하위 위임을 만들 수 있지만, 루트 caveat은 delegator = 메인 지갑으로 그대로 실행된다. caveat을 더할 수는 있어도 뺄 수는 없다.

### 1-2. 레지스트리 바인딩 (D5)

`proposeBinding`/`acceptBinding`이 실패하는 조건은 다음뿐이다.

- 주인이 미검증 (propose·accept 두 시점 모두 확인)
- 대상이 이미 누군가에게 바인딩됨 (`AgentAlreadyBound`)
- 0 주소, 또는 `expectedOwner` ≠ 대기 중인 제안자

코드 길이 검사가 없으므로 7702 계정인 지출용 계정도 수락할 수 있다. 지출용 계정은 스스로 바인딩을 풀 수 없고 해지는 주인만 할 수 있다. 레지스트리상 지출용 계정은 "에이전트"와 같은 칸에 들어간다(`isAccountableAgent(spending) == true`).

### 1-3. 기존 enforcer terms

| enforcer | terms | 비고 |
|---|---|---|
| `JipsaPerTxCapEnforcer` | `encodePacked(address token, uint256 cap)` 52B | `amount > cap`만 거부 → 0·1 wei 통과 |
| `ERC20PeriodTransferEnforcer` | `token(20) ‖ periodAmount(32) ‖ periodDuration(32) ‖ startDate(32)` 116B | `startDate` 기준 고정 창. 첫 사용 시 `now ≥ startDate` |
| `LimitedCallsEnforcer` | `uint256 limit` 32B | beforeHook에서 카운트 증가 |
| `TimestampEnforcer` | `uint128 after ‖ uint128 before` 32B | 양쪽 strict 비교 |

---

## 2. 충전 위임 caveat 묶음

| 순서 | enforcer | terms |
|---|---|---|
| ① | `TimestampEnforcer` | `(0, expiry)` |
| ② | `RefillThresholdEnforcer` | 3절 |
| ③ | `ERC20PeriodTransferEnforcer` | `(token, P, periodDuration, startDate)` |
| ④ | `LimitedCallsEnforcer` | `N` |

- revert 시 ③④의 카운터 증가도 되돌아가므로 **순서는 안전성과 무관하고 revert 사유·가스에만 영향**을 준다.
- view 검사(①②)를 앞에, SSTORE가 있는 검사(③④)를 뒤에 둔다. 잔액 미충족은 ②에서, 기간 한도는 ③에서, 횟수 소진은 ④에서 걸린다.
- `JipsaPerTxCapEnforcer`는 ②의 정확 일치 검사와 중복이므로 넣지 않는다.

## 3. `RefillThresholdEnforcer`

### terms

`abi.encode(IVerifiedGate gate, OwnerBindingRegistry registry, address token, address spender, uint256 threshold, uint256 refillAmount)` — 192바이트

### 검사 순서 (`beforeHook`은 view, `_redeemer` 미사용)

1. terms 길이 192, `refillAmount != 0`
2. 실행 형태 — single·default 모드, callData 68B, `transfer` 셀렉터, `target == token`, `value == 0`
3. 수신처 == `spender`
4. 전송액 == `refillAmount`
5. `registry.ownerOf(spender) == delegator`
6. `gate.isVerified(delegator)`
7. `token.balanceOf(spender) < threshold`

토큰은 이 enforcer 안에서 실행 대상과 묶는다. 다른 caveat(`AllowedTargets` 등)에 기대면 잔액은 A 토큰, 송금은 B 토큰으로 하는 조합이 가능해진다. 순서는 순수 검사 → 귀속(바인딩·도장) → 외부 잔액 순이다.

### 에러

| 에러 | 비고 |
|---|---|
| `InvalidTermsLength(uint256 length)` | `DojangCaveatEnforcer`와 같은 시그니처 |
| `InvalidExecutionLength(uint256 length)` | 같음 |
| `InvalidContract(address target, address expected)` | 같음 |
| `InvalidMethod(bytes4 selector)` | 같음 |
| `OwnerNotVerified(address owner)` | 같음 |
| `ZeroRefillAmount()` | 신규 |
| `InvalidValue(uint256 value)` | 신규 |
| `InvalidRecipient(address to, address spender)` | 신규 |
| `InvalidRefillAmount(uint256 amount, uint256 expected)` | 신규 |
| `SpenderNotBound(address spender, address delegator)` | 신규 |
| `BalanceQueryFailed(address token, address spender)` | 신규 — `balanceOf` 실패 또는 반환 길이 부족 |
| `BalanceNotBelowThreshold(uint256 balance, uint256 threshold)` | 신규 |

`threshold = 0`이면 잔액 조건이 항상 거짓이라 충전이 영원히 막힌다(fail-closed). 따로 거부하지 않는다.

## 4. `BoundDelegatorEnforcer` (지출 위임)

terms는 `DojangCaveatEnforcer`와 같은 `abi.encode(IVerifiedGate gate, OwnerBindingRegistry registry, address token, bool verifiedRecipientOnly)` 128바이트.

| | `DojangCaveatEnforcer` | `BoundDelegatorEnforcer` |
|---|---|---|
| terms·실행 형태 검사 | 128B, transfer·토큰 | 같음 |
| 수신처 도장 옵션 | 있음 | 같음 (`RecipientNotVerified`) |
| 주인 | `_delegator` 자신 | `owner = registry.ownerOf(_delegator)`, 0이면 `DelegatorNotBound(delegator)` |
| 에이전트 바인딩 | `ownerOf(redeemer) == delegator` | `ownerOf(redeemer) == owner` → `AgentNotBound(redeemer, owner)` |
| 주인 도장 | `isVerified(delegator)` | `isVerified(owner)` → `OwnerNotVerified(owner)` |

같은 주인에 바인딩된 에이전트 A가 delegator가 되어 에이전트 B에게 위임하는 경우도 통과한다. 귀속 주인이 같으므로 의도와 맞다.

지출 위임 caveat 묶음: Timestamp → `JipsaPerTxCapEnforcer` → `ERC20PeriodTransferEnforcer` → `ERC20TransferAmountEnforcer` → `BoundDelegatorEnforcer`.

### A1과의 관계

A1 `AccountableOwnerEnforcer`에 계정 모델을 하나 추가하면 enforcer는 하나로 합쳐지지만, 머지 전인 A1의 terms(192B)·모델 enum을 바꾸고 A1 테스트를 다시 돌려야 한다. 지금은 따로 만들고 통합은 A1 정리 때 판단한다. A1의 7702 지정자 고정은 신규 enforcer에 넣지 않는다(결정 C). 재지정은 계정 키로만 가능하므로 남는 위험은 주인 본인의 실수·피싱이다.

---

## 5. 위험과 대응

| 위험 | 대응 |
|---|---|
| 먼지 충전(0·1 wei)으로 `LimitedCalls` 총 횟수를 소진시켜 자동 충전 정지 | `refillAmount` 정확 일치 (결정 A) |
| 잔액은 토큰 A로, 송금은 토큰 B로 | enforcer 안에서 `target == token` 확인 |
| `value > 0` 실행으로 메인 지갑의 네이티브 코인 이동 | `value == 0` 확인 |
| 악의적·잘못된 토큰 | 토큰은 주인이 서명한 terms에 있어 실행자가 바꿀 수 없다. 잘못 넣으면 terms 실수이고, `balanceOf`가 거짓이어도 유출은 기간·횟수 한도 안이다. `balanceOf` revert·토큰 pause는 충전 정지(DoS)일 뿐 손실이 아니다 |
| 탈취된 에이전트가 한 tx 배치에 [지출, 충전, 지출, 충전…] | 충전 위임은 열려 있어 에이전트도 리딤할 수 있다. 막는 것은 시간이 아니라 기간 한도·총 횟수다. 같은 블록·같은 tx에서도 상한은 유지된다 |
| 제3자가 지출용 계정에 입금해 잔액을 기준 이상으로 올려 충전을 막음 | 이 토큰은 `faucet()`으로 자기 앞 민팅이 가능해 비용이 없다. 결과는 지출용 계정 잔액 증가뿐이라 손실은 없다 |
| 충전 위임을 여러 장 서명 | salt마다 카운터가 따로라 상한이 장수만큼 곱해진다. 활성 충전 위임은 1장으로 운영한다 |
| 지출용 계정이 메인 지갑의 다른 Dojang 위임을 리딤 | 지출용 계정은 메인에 바인딩되므로, delegate가 `ANY_DELEGATE`이거나 지출용 계정인 Dojang 위임은 리딤 가능하다. 메인 지갑은 그런 위임을 발급하지 않는다 |
| 기간 경계 | 고정 창이므로 경계를 걸친 짧은 구간에 최대 2P가 나갈 수 있다 |
| 중단 | 주인이 `disableDelegation`으로 위임을 철회하거나 `revokeBinding`으로 지출용 계정 바인딩을 해지하면 즉시 막힌다 |

## 6. 손실 상한 (D7)

기호: B₀ 창 시작 시 지출용 잔액, T 기준, R 1회 충전량, P 충전 기간 한도, N 총 횟수, n 남은 횟수, S 지출 위임 기간 한도.

| 구분 | 식 |
|---|---|
| 메인 지갑 유출 (고정 창 1개) | ≤ min(P, R·n) |
| 손실 (에이전트 탈취, 고정 창 1개) | ≤ min(S, B₀ + min(P, R·n)) |
| 재서명 전 전체 메인 유출 | ≤ min(R·N, P·창 수) |
| 재서명 전 전체 손실 | ≤ B₀ + min(R·N, P·창 수) |
| 경계를 걸친 짧은 구간 | 메인 유출 ≤ 2P |
| 충전 직후 지출용 잔액 (외부 입금 없음) | < T + R |

시나리오 테스트는 고정 창 하나 안에서 "메인 지갑 유출 ≤ P"를 확인하고, 다음 창에서 충전이 다시 열리는 것을 확인한다.
