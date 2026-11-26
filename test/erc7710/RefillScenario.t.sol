// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {Delegation} from "delegation-framework/src/utils/Types.sol";

import {F1TestBase} from "./F1TestBase.sol";

/// @notice F1 시나리오 — 계획서 1-4절 11번.
///
/// @dev 지출 → 잔액 부족 → 충전 → 지출을 반복하다 기간 한도에 닿으면 충전이 멈추고,
///      **메인 지갑에서 나간 총액이 기간 한도를 넘지 않는다.** 다음 기간에는 다시 열린다.
///
///      손실 상한 (docs/design/F1_Refill.md 6절): 고정 창 하나에서 메인 유출 ≤ min(P, R·n).
///      지출 위임의 기간 한도(SPEND_PERIOD_CAP)는 충전 기간 한도보다 크게 두어,
///      메인 유출을 묶는 것이 충전 쪽 caveat임을 드러낸다.
contract RefillScenarioTest is F1TestBase {
    function setUp() public override {
        super.setUp();
        // 지출용 계정은 빈 상태에서 시작한다 (B₀ = 0)
        assertEq(token.balanceOf(spending), 0);
    }

    /// @dev 고정 창 하나를 끝까지 돈다: 지출할 잔액이 없으면 충전하고, 충전이 기간 한도에
    ///      막히면 멈춘다. 매 단계 메인 유출 ≤ PERIOD_CAP 을 확인한다.
    /// @return mainOut_ 이 창에서 메인 지갑이 내보낸 총액
    /// @return spent_ 이 창에서 에이전트가 가맹점에 지출한 총액
    function _runWindow(Delegation memory refillD, Delegation memory spendD) internal returns (uint256 mainOut_, uint256 spent_) {
        uint256 mainBefore_ = token.balanceOf(main);
        uint256 merchantBefore_ = token.balanceOf(merchant);
        uint256 refills_;

        for (uint256 i = 0; i < 100; i++) {
            if (token.balanceOf(spending) < SPEND_PER_TX) {
                // 잔액 부족 → 충전 (잔액 < SPEND_PER_TX < THRESHOLD 이므로 잔액 조건은 항상 참)
                if ((refills_ + 1) * REFILL > PERIOD_CAP) {
                    // 기간 한도에 닿아 충전이 멈춘다
                    vm.expectRevert(bytes("ERC20PeriodTransferEnforcer:transfer-amount-exceeded"));
                    _redeem(keeper, refillD, _refillExec());
                    break;
                }
                _redeem(keeper, refillD, _refillExec());
                refills_++;
            }

            _redeem(agent, spendD, _transferExec(merchant, SPEND_PER_TX));
            assertLe(mainBefore_ - token.balanceOf(main), PERIOD_CAP, "main outflow within period cap");
        }

        mainOut_ = mainBefore_ - token.balanceOf(main);
        spent_ = token.balanceOf(merchant) - merchantBefore_;
    }

    // ---------- 11. 반복 지출·충전이 기간 한도에서 멈추고, 다음 기간에 다시 열린다 ----------

    function test_Scenario_SpendRefillLoopStopsAtPeriodCap() public {
        // 위임 구조체는 storage로 복사할 수 없어(동적 Caveat 배열) 테스트마다 메모리에 만든다
        Delegation memory refillD = _refillDelegation();
        Delegation memory spendD = _spendDelegation();

        // ---- 기간 1 ----
        (uint256 out1_, uint256 spent1_) = _runWindow(refillD, spendD);

        assertLe(out1_, PERIOD_CAP, "window 1: main outflow <= period cap");
        assertEq(out1_, PERIOD_CAP, "window 1: refills used the full period cap");
        // B₀ = 0 이므로 에이전트 지출 총액 = 메인 유출 (지출용 계정에 남은 잔액 + 지출 = 충전 합계)
        assertEq(spent1_ + token.balanceOf(spending), out1_);
        assertLe(spent1_, PERIOD_CAP, "window 1: loss <= B0 + period cap");

        // 충전이 멈춘 뒤 지출용 계정 잔액이 바닥나면 지출도 멈춘다
        uint256 left_ = token.balanceOf(spending);
        assertLt(left_, SPEND_PER_TX);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, spending, left_, SPEND_PER_TX)
        );
        _redeem(agent, spendD, _transferExec(merchant, SPEND_PER_TX));

        // 같은 기간 안에서는 시간이 지나도 충전이 열리지 않는다
        vm.warp(startDate + PERIOD - 1);
        vm.expectRevert(bytes("ERC20PeriodTransferEnforcer:transfer-amount-exceeded"));
        _redeem(keeper, refillD, _refillExec());

        // ---- 기간 2: 한도가 다시 열린다 ----
        vm.warp(startDate + PERIOD);
        (uint256 out2_,) = _runWindow(refillD, spendD);

        assertLe(out2_, PERIOD_CAP, "window 2: main outflow <= period cap");
        assertEq(out2_, PERIOD_CAP, "window 2: refill reopened up to the full period cap");

        // 재서명 전 전체 상한: 메인 유출 ≤ R × N
        assertLe(FUNDING - token.balanceOf(main), REFILL * MAX_REFILLS);
    }

    /// @dev 탈취된 에이전트는 열린 충전 위임도 리딤할 수 있으므로 한 tx 배치에
    ///      [충전, 지출, 지출, 충전, 지출, 지출, 지출] 을 섞을 수 있다. 상한을 묶는 것은
    ///      시간이 아니라 기간 한도라서, 같은 tx 안에서도 메인 유출은 PERIOD_CAP 을 넘지 않는다.
    function test_Scenario_BatchedSpendRefillInOneTxStillCapped() public {
        Delegation memory refillD = _refillDelegation();
        Delegation memory spendD = _spendDelegation();
        Delegation[] memory ds_ = new Delegation[](7);
        bytes[] memory execs_ = new bytes[](7);
        bool[7] memory isRefill_ = [true, false, false, true, false, false, false];
        for (uint256 i = 0; i < 7; i++) {
            ds_[i] = isRefill_[i] ? refillD : spendD;
            execs_[i] = isRefill_[i] ? _refillExec() : _transferExec(merchant, SPEND_PER_TX);
        }

        _redeemBatch(agent, ds_, execs_);
        assertEq(FUNDING - token.balanceOf(main), PERIOD_CAP);
        assertEq(token.balanceOf(merchant), 5 * SPEND_PER_TX);

        // 세 번째 충전을 끼운 배치는 tx 전체가 되돌아간다
        Delegation[] memory more_ = new Delegation[](2);
        bytes[] memory moreExecs_ = new bytes[](2);
        more_[0] = refillD;
        moreExecs_[0] = _refillExec();
        more_[1] = spendD;
        moreExecs_[1] = _transferExec(merchant, SPEND_PER_TX);

        vm.expectRevert(bytes("ERC20PeriodTransferEnforcer:transfer-amount-exceeded"));
        _redeemBatch(agent, more_, moreExecs_);

        assertLe(FUNDING - token.balanceOf(main), PERIOD_CAP, "main outflow <= period cap within one tx");
    }
}
