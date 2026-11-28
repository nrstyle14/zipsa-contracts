# M2-1 결제 게이트 — 설계

상태: **테스트넷 배포** — GIWA Sepolia `0xF188B4261CC1AA1491a234Ebc5c7E4E9854f0d38` (블록 42458920, Blockscout 검증). 브랜치 `feat/m2-payment-gate`. 외부 검토를 거치지 않은 테스트넷 데모용이다.

---

## 0. 구조

```
메인 지갑 (주인, 도장, 7702) ─충전 위임→ 지출용 계정 (7702, 주인에게 바인딩)
                                              │  게이트 위임 — delegate = PaymentGate
                                              ▼
에이전트 (주인에게 바인딩) ──payDelegated──► PaymentGate ──redeemDelegations──► DelegationManager
                                              │                                    │ 지출용 계정에서 transfer
                                              └─ 확인: 토큰·책임자 도장·호출자 귀속      ▼
                                                                               상점 수신처 (불변)
```

| # | 결정 |
|---|---|
| P1 | 상점은 게이트로 돈을 받는다. 돈은 게이트에 머물지 않고 결제 계정에서 수신처로 바로 간다 |
| P2 | 에이전트 경로는 승인(approve) 없이 위임으로 만든다. 지출용 계정이 수임자 = 게이트인 위임에 서명한다. `redeemDelegations`는 호출자가 수임자여야 하므로 그 위임은 게이트만 쓸 수 있다 |
| P3 | 사람 경로 `pay`(승인 뒤 `transferFrom`)를 함께 둔다. 입금 관문 방식 B의 원형이다 |
| P4 | 수신처 `destination`은 생성자에서 고정한다. 위임을 가진 누구도 다른 곳으로 보내게 할 수 없다 |
| P5 | `payDelegated`의 호출자 귀속 확인은 끌 수 없다. 위임은 공개돼도 되는 값이므로, 이것이 없으면 위임을 본 아무나 결제를 일으킬 수 있다 |
| P6 | 기존 컨트랙트(enforcer 4종, 레지스트리, 게이트, `lib/`)는 고치지 않는다. 업그레이드 프록시 없음 |

## 1. 프레임워크 사실 (코드 근거)

- `DelegationManager.redeemDelegations`: `delegations_[0].delegate != msg.sender && != ANY_DELEGATE`이면 `InvalidDelegate` (lib/delegation-framework/src/DelegationManager.sol:156). 게이트가 호출자이므로 수임자 = 게이트면 통과한다.
- enforcer 훅의 `_redeemer`는 게이트다. 그래서 `BoundDelegatorEnforcer`(리딤하는 주소가 주인에게 묶였는지 확인)는 게이트 위임에 넣을 수 없다. 같은 확인을 게이트가 `msg.sender`(에이전트)에 대해 한다.
- 실행 모드는 `ModeLib.encodeSimpleSingle()`. 우리 금액 caveat은 single 모드에서만 통과한다.
- enforcer가 되돌리면 그 에러가 그대로 올라온다. 게이트는 try/catch를 하지 않는다.

## 2. 인터페이스

```solidity
function pay(address token, uint256 amount, bytes32 ref) external;
function payDelegated(bytes calldata permissionContext, address token, uint256 amount, bytes32 ref) external;
function responsibleOf(address payer) public view returns (address);
function setTokenAllowed(address token, bool allowed) external;   // admin
function setRequireVerifiedPayer(bool required) external;         // admin

event Paid(bytes32 indexed ref, address indexed payer, address indexed responsible,
           address caller, address token, uint256 amount);
```

## 3. 검사 순서

공통(두 경로):

1. `amount == 0` → `ZeroAmount`
2. 허용 토큰이 아니면 → `TokenNotAllowed(token)`
3. 이미 낸 주문 번호 → `RefAlreadyPaid(ref)`
4. 책임자 = 결제자가 도장 보유면 자신, 아니면 `registry.ownerOf(결제자)`. 0이고 `requireVerifiedPayer`면 → `PayerNotAccountable(payer)`
5. `requireVerifiedPayer`이고 책임자 도장이 무효면 → `PayerNotVerified(responsible)`

`payDelegated`만:

- context의 위임이 1장이 아니면 → `InvalidDelegationChain(length)`. 결제자 = 그 위임의 delegator
- 책임자가 0이면 → `PayerNotAccountable` (`requireVerifiedPayer`와 무관)
- `registry.ownerOf(msg.sender) != 책임자` → `CallerNotBound(caller, responsible)` (끌 수 없음)
- `redeemDelegations([context], [single], [transfer(destination, amount)])`

마무리: 수신처 잔액 증가분이 정확히 `amount`가 아니면 → `PaymentNotReceived`. `refPaid[ref] = true`는 외부 호출 전에 쓰고, 재진입 잠금을 둔다. `Paid` 발생.

## 4. 게이트 위임 caveat (지출용 계정이 서명, 수임자 = 게이트)

① Timestamp ② AllowedTargets[tKRW] ③ AllowedMethods[transfer] ④ JipsaPerTxCap ⑤ ERC20PeriodTransfer(1시간) ⑥ ERC20TransferAmount

- 건당 한도를 기간·총액 앞에 두어 과다 청구가 `PerTxCapExceeded`로 걸린다(기존 묶음과 같은 이유).
- 누적 상한(⑥)을 빼지 않는다. `JipsaPerTxCap`은 무상태라 단독으로는 반복 결제로 잔액이 빠진다.
- 수신처 도장 검사는 넣지 않는다. 수신처는 게이트가 고정한 한 곳뿐이다.
- 인코더: `packages/delegation`의 `buildGateCaveats(policy, addresses?, startDate?)`, calldata는 `payDelegatedCalldata(delegation, amount, ref)`.

라이브 데모 값: 건당 15, 시간당 200, 총액 100,000 tKRW, 만료 2026-12-31. 충전 위임의 시간당 120이 먼저 닿도록 게이트의 시간당 한도를 더 크게 잡았다.

## 5. 테스트 (`test/erc7710/PaymentGate.t.sol`)

F1 셋업을 그대로 쓴다. 막히는 경우는 통과하는 대조 경우와 쌍이다.

| # | 경우 | 기대 |
|---|---|---|
| G1 | 묶인 에이전트가 허용 토큰으로 `payDelegated` | 수신처 +amount, `Paid(ref, 지출용, 주인, 에이전트)`, 게이트 잔액 0 |
| G2 | 허용되지 않은 토큰 | `TokenNotAllowed` |
| G3 | 묶이지 않은 주소가 같은 위임으로 호출 | `CallerNotBound` |
| G4 | 다른 주인에게 묶인 에이전트 | `CallerNotBound` |
| G5 | 주인 도장 무효 | `PayerNotVerified` |
| G6 | 결제 계정이 누구에게도 묶이지 않음 | `PayerNotAccountable` |
| G7 | 건당 한도 초과 | `PerTxCapExceeded`가 그대로 올라옴 |
| G8 | 시간당 한도 도달 → 다음 시간 | `transfer-amount-exceeded` → 성공 |
| G9 | 게이트 위임 철회 뒤 | `CannotUseADisabledDelegation` |
| G10 | 같은 `ref` 두 번 | `RefAlreadyPaid` |
| G11 | `pay`: 도장 있는 사람 / 책임자 없음 / 주인 도장 무효 | 성공 / `PayerNotAccountable` / `PayerNotVerified` |
| G12 | `requireVerifiedPayer` 끔: G5 / G3 / 책임자 0 | 성공 / `CallerNotBound` / `PayerNotAccountable` |
| G13 | 관리자가 아닌 설정 변경 | `NotAdmin` |
| G14 | 위임 2장짜리 context | `InvalidDelegationChain` |

추가: 금액 0, 빈 결제 계정의 토큰 에러 전달, 수신처 고정.

## 6. 한계

- 한도 안에서의 잘못된 지출은 막지 못한다. 게이트가 정하는 것은 "누가 책임지는 결제인가"와 "묶인 에이전트만 쓸 수 있는가"이다.
- 에이전트 키와 위임이 함께 유출되면 위임 한도 안에서는 쓸 수 있다. 손실 상한은 위임 한도다.
- 관리자(배포자 EOA)는 허용 토큰과 도장 요구를 바꿀 수 있다. 호출자 귀속 확인과 수신처는 바꿀 수 없다. 메인넷 전에는 관리자를 다중 서명으로 옮긴다.
