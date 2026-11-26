// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import {ExecutionLib} from "@erc7579/lib/ExecutionLib.sol";
import {IDelegationManager} from "delegation-framework/src/interfaces/IDelegationManager.sol";
import {EncoderLib} from "delegation-framework/src/libraries/EncoderLib.sol";
import {Delegation, Caveat} from "delegation-framework/src/utils/Types.sol";

import {RefillThresholdEnforcer} from "../../src/enforcers/RefillThresholdEnforcer.sol";
import {F1TestBase} from "./F1TestBase.sol";

/// @notice F1 충전 경로 — 계획서 1-4절 1~7번.
///
/// @dev 계정·caveat 셋업은 F1TestBase. 충전 위임은 delegate = ANY_DELEGATE 로 발급하고,
///      caveat 순서는 ① 만료 ② RefillThreshold ③ 기간 한도 ④ 총 횟수 (docs/design/F1_Refill.md 2절).
///      지출은 이 파일의 관심사가 아니므로 지출용 계정 키로 직접 송금해 잔액을 낮춘다.
///
///      막히는 케이스는 "조건이 맞으면 통과"하는 대조 케이스와 쌍으로 둔다.
contract RefillTest is F1TestBase {
    function _revertBelow(bytes4 selector_, uint256 balance_) internal pure returns (bytes memory) {
        return abi.encodeWithSelector(selector_, balance_, THRESHOLD);
    }

    // ---------- D5: 지출용 계정 바인딩 ----------

    function test_D5_SpendingAccountBindsToOwner() public view {
        assertEq(registry.ownerOf(spending), main);
        assertTrue(registry.isAccountableAgent(spending));
        assertEq(spending.code.length, 23, "spending account is a 7702 account");
    }

    // ---------- 1. 잔액이 기준 미만이면 충전된다 ----------

    function test_RefillWhenBelowThreshold() public {
        Delegation memory d_ = _refillDelegation();

        _redeem(keeper, d_, _refillExec());

        assertEq(token.balanceOf(spending), REFILL);
        assertEq(token.balanceOf(main), FUNDING - REFILL);
    }

    function test_RefillWhenOneBelowThreshold() public {
        Delegation memory d_ = _refillDelegation();
        _setSpendingBalance(THRESHOLD - 1);

        _redeem(keeper, d_, _refillExec());

        assertEq(token.balanceOf(spending), THRESHOLD - 1 + REFILL);
    }

    // ---------- 2. 잔액이 기준 이상이면 막힌다 ----------

    function test_RevertWhen_BalanceAtThreshold() public {
        Delegation memory d_ = _refillDelegation();
        _setSpendingBalance(THRESHOLD);

        vm.expectRevert(_revertBelow(RefillThresholdEnforcer.BalanceNotBelowThreshold.selector, THRESHOLD));
        _redeem(keeper, d_, _refillExec());
    }

    function test_RevertWhen_BalanceAboveThreshold() public {
        Delegation memory d_ = _refillDelegation();
        _setSpendingBalance(THRESHOLD + 1);

        vm.expectRevert(_revertBelow(RefillThresholdEnforcer.BalanceNotBelowThreshold.selector, THRESHOLD + 1));
        _redeem(keeper, d_, _refillExec());

        // 대조: 지출로 기준 아래가 되면 같은 위임으로 충전된다
        _setSpendingBalance(THRESHOLD - 1);
        _redeem(keeper, d_, _refillExec());
        assertEq(token.balanceOf(spending), THRESHOLD - 1 + REFILL);
    }

    // ---------- 3. 수신처 불일치 · 바인딩 없음 · 주인 도장 무효 ----------

    function test_RevertWhen_RecipientIsNotSpender() public {
        Delegation memory d_ = _refillDelegation();

        vm.expectRevert(
            abi.encodeWithSelector(RefillThresholdEnforcer.InvalidRecipient.selector, stranger, spending)
        );
        _redeem(keeper, d_, _transferExec(stranger, REFILL));

        // 대조: 수신처가 지출용 계정이면 통과
        _redeem(keeper, d_, _refillExec());
        assertEq(token.balanceOf(spending), REFILL);
        assertEq(token.balanceOf(stranger), 0);
    }

    function test_RevertWhen_SpenderNotBound() public {
        address unbound_ = makeAddr("unbound");
        _etch7702(unbound_);
        Delegation memory d_ = _signRefill(_refillCaveats(unbound_, PERIOD_CAP, MAX_REFILLS), 1);

        vm.expectRevert(abi.encodeWithSelector(RefillThresholdEnforcer.SpenderNotBound.selector, unbound_, main));
        _redeem(keeper, d_, _transferExec(unbound_, REFILL));

        // 대조: 바인딩하면 같은 위임으로 충전된다
        _bind(main, unbound_);
        _redeem(keeper, d_, _transferExec(unbound_, REFILL));
        assertEq(token.balanceOf(unbound_), REFILL);
    }

    function test_RevertWhen_SpenderBoundToAnotherOwner() public {
        address otherOwner_ = makeAddr("otherOwner");
        address othersSpending_ = makeAddr("othersSpending");
        gate.setVerified(otherOwner_, true);
        _bind(otherOwner_, othersSpending_);

        Delegation memory d_ = _signRefill(_refillCaveats(othersSpending_, PERIOD_CAP, MAX_REFILLS), 1);

        vm.expectRevert(
            abi.encodeWithSelector(RefillThresholdEnforcer.SpenderNotBound.selector, othersSpending_, main)
        );
        _redeem(keeper, d_, _transferExec(othersSpending_, REFILL));

        // 대조: 다른 주인이 해지하고 이 주인에게 다시 바인딩되면 통과
        vm.prank(otherOwner_);
        registry.revokeBinding(othersSpending_);
        _bind(main, othersSpending_);
        _redeem(keeper, d_, _transferExec(othersSpending_, REFILL));
        assertEq(token.balanceOf(othersSpending_), REFILL);
    }

    function test_RevertWhen_OwnerStampRevoked() public {
        Delegation memory d_ = _refillDelegation();
        gate.setVerified(main, false);

        vm.expectRevert(abi.encodeWithSelector(RefillThresholdEnforcer.OwnerNotVerified.selector, main));
        _redeem(keeper, d_, _refillExec());

        // 대조: 도장이 복구되면 통과
        gate.setVerified(main, true);
        _redeem(keeper, d_, _refillExec());
        assertEq(token.balanceOf(spending), REFILL);
    }

    // ---------- 3-부속. 실행 형태 (결정 A: 정확한 충전량, 토큰·value 묶기) ----------

    function test_RevertWhen_DustRefill() public {
        Delegation memory d_ = _refillDelegation();

        // 1 wei 충전으로 총 횟수를 태우는 공격
        vm.expectRevert(abi.encodeWithSelector(RefillThresholdEnforcer.InvalidRefillAmount.selector, 1, REFILL));
        _redeem(stranger, d_, _transferExec(spending, 1));

        // 상한 이하라도 정확하지 않으면 막힌다
        vm.expectRevert(
            abi.encodeWithSelector(RefillThresholdEnforcer.InvalidRefillAmount.selector, REFILL - 1, REFILL)
        );
        _redeem(stranger, d_, _transferExec(spending, REFILL - 1));

        // 대조: 정확한 충전량은 통과하고, 막힌 시도는 횟수를 쓰지 않았다
        _redeem(stranger, d_, _refillExec());
        assertEq(limitedCalls.callCounts(address(delegationManager), EncoderLib._getDelegationHash(d_)), 1);
    }

    function test_RevertWhen_OtherTokenMoved() public {
        Delegation memory d_ = _refillDelegation();

        bytes memory exec_ = ExecutionLib.encodeSingle(
            address(otherToken), 0, abi.encodeWithSelector(token.transfer.selector, spending, REFILL)
        );
        vm.expectRevert(
            abi.encodeWithSelector(RefillThresholdEnforcer.InvalidContract.selector, address(otherToken), address(token))
        );
        _redeem(keeper, d_, exec_);
        // 대조: 같은 위임으로 정상 충전은 통과
        _redeem(keeper, d_, _refillExec());
        assertEq(token.balanceOf(spending), REFILL);
    }

    function test_RevertWhen_NonZeroValue() public {
        Delegation memory d_ = _refillDelegation();
        vm.deal(main, 1 ether);

        bytes memory exec_ = ExecutionLib.encodeSingle(
            address(token), 1, abi.encodeWithSelector(token.transfer.selector, spending, REFILL)
        );
        vm.expectRevert(abi.encodeWithSelector(RefillThresholdEnforcer.InvalidValue.selector, 1));
        _redeem(keeper, d_, exec_);
        // 대조: 같은 위임으로 정상 충전은 통과
        _redeem(keeper, d_, _refillExec());
        assertEq(token.balanceOf(spending), REFILL);
    }

    function test_RevertWhen_NotTransfer() public {
        Delegation memory d_ = _refillDelegation();

        bytes memory exec_ = ExecutionLib.encodeSingle(
            address(token), 0, abi.encodeWithSelector(token.approve.selector, spending, REFILL)
        );
        vm.expectRevert(
            abi.encodeWithSelector(RefillThresholdEnforcer.InvalidMethod.selector, token.approve.selector)
        );
        _redeem(keeper, d_, exec_);
        // 대조: 같은 위임으로 정상 충전은 통과
        _redeem(keeper, d_, _refillExec());
        assertEq(token.balanceOf(spending), REFILL);
    }

    function test_RevertWhen_ZeroRefillAmountInTerms() public {
        Caveat[] memory c_ = _refillCaveats(spending, PERIOD_CAP, MAX_REFILLS);
        c_[1].terms = abi.encode(address(gate), address(registry), address(token), spending, THRESHOLD, uint256(0));
        Delegation memory d_ = _signRefill(c_, 1);

        vm.expectRevert(RefillThresholdEnforcer.ZeroRefillAmount.selector);
        _redeem(keeper, d_, _transferExec(spending, 0));

        // 대조: 기본 위임(정상 terms)으로는 통과
        _redeem(keeper, _refillDelegation(), _refillExec());
        assertEq(token.balanceOf(spending), REFILL);
    }

    function test_RevertWhen_InvalidTermsLength() public {
        Caveat[] memory c_ = _refillCaveats(spending, PERIOD_CAP, MAX_REFILLS);
        c_[1].terms = abi.encode(address(gate), address(registry), address(token), false);
        Delegation memory d_ = _signRefill(c_, 1);

        vm.expectRevert(abi.encodeWithSelector(RefillThresholdEnforcer.InvalidTermsLength.selector, 128));
        _redeem(keeper, d_, _refillExec());

        // 대조: 기본 위임(정상 terms)으로는 통과
        _redeem(keeper, _refillDelegation(), _refillExec());
        assertEq(token.balanceOf(spending), REFILL);
    }

    /// @dev terms 토큰이 코드 없는 주소면 balanceOf 가 빈 반환으로 "성공"한다.
    ///      이를 잔액 0으로 읽지 않고 BalanceQueryFailed 로 막는다 (fail-closed).
    function test_RevertWhen_BalanceQueryFails() public {
        address noCode_ = makeAddr("noCodeToken");
        Caveat[] memory c_ = _refillCaveats(spending, PERIOD_CAP, MAX_REFILLS);
        c_[1].terms = abi.encode(address(gate), address(registry), noCode_, spending, THRESHOLD, REFILL);
        Delegation memory d_ = _signRefill(c_, 1);

        bytes memory exec_ =
            ExecutionLib.encodeSingle(noCode_, 0, abi.encodeWithSelector(token.transfer.selector, spending, REFILL));
        vm.expectRevert(abi.encodeWithSelector(RefillThresholdEnforcer.BalanceQueryFailed.selector, noCode_, spending));
        _redeem(keeper, d_, exec_);

        // 대조: 기본 위임(정상 terms)으로는 통과
        _redeem(keeper, _refillDelegation(), _refillExec());
        assertEq(token.balanceOf(spending), REFILL);
    }

    // ---------- 4. 기간 한도에 닿으면 막히고, 다음 기간에 다시 열린다 ----------

    function test_RevertWhen_PeriodCapReached_ReopensNextPeriod() public {
        Delegation memory d_ = _refillDelegation();

        // PERIOD_CAP = 2 × REFILL
        _redeem(keeper, d_, _refillExec());
        _setSpendingBalance(0);
        _redeem(keeper, d_, _refillExec());
        _setSpendingBalance(0);

        vm.expectRevert(bytes("ERC20PeriodTransferEnforcer:transfer-amount-exceeded"));
        _redeem(keeper, d_, _refillExec());
        assertEq(token.balanceOf(main), FUNDING - PERIOD_CAP, "main outflow capped by period");

        // 다음 기간
        vm.warp(block.timestamp + PERIOD);
        _redeem(keeper, d_, _refillExec());
        assertEq(token.balanceOf(main), FUNDING - PERIOD_CAP - REFILL);
    }

    // ---------- 5. 총 횟수를 다 쓰면 막힌다 ----------

    function test_RevertWhen_TotalRefillsExhausted() public {
        // 기간 한도를 넉넉히 두어 총 횟수에 먼저 닿게 한다
        Delegation memory d_ = _signRefill(_refillCaveats(spending, FUNDING, MAX_REFILLS), 1);

        for (uint256 i = 0; i < MAX_REFILLS; i++) {
            _setSpendingBalance(0);
            _redeem(keeper, d_, _refillExec());
        }
        assertEq(token.balanceOf(main), FUNDING - REFILL * MAX_REFILLS);

        _setSpendingBalance(0);
        vm.expectRevert(bytes("LimitedCallsEnforcer:limit-exceeded"));
        _redeem(keeper, d_, _refillExec());

        // 기간이 바뀌어도 총 횟수는 돌아오지 않는다 (재서명 전 자동 정지)
        vm.warp(block.timestamp + PERIOD);
        vm.expectRevert(bytes("LimitedCallsEnforcer:limit-exceeded"));
        _redeem(keeper, d_, _refillExec());
        assertEq(token.balanceOf(main), FUNDING - REFILL * MAX_REFILLS);
    }

    // ---------- 6. 아무 주소나 실행해도 결과가 같다 ----------

    function test_AnyExecutorSameOutcome() public {
        Delegation memory d_ = _refillDelegation();
        address[4] memory executors_ = [keeper, stranger, main, spending];

        uint256 snap_ = vm.snapshotState();
        for (uint256 i = 0; i < executors_.length; i++) {
            vm.revertToState(snap_);
            _redeem(executors_[i], d_, _refillExec());
            assertEq(token.balanceOf(spending), REFILL);
            assertEq(token.balanceOf(main), FUNDING - REFILL);
        }

        // 막히는 결과도 실행자와 무관하다
        for (uint256 i = 0; i < executors_.length; i++) {
            vm.revertToState(snap_);
            _setSpendingBalance(THRESHOLD);
            vm.expectRevert(_revertBelow(RefillThresholdEnforcer.BalanceNotBelowThreshold.selector, THRESHOLD));
            _redeem(executors_[i], d_, _refillExec());
        }
    }

    function test_ExecutorsShareOneBudget() public {
        Delegation memory d_ = _refillDelegation();

        // 실행자를 바꿔도 기간 한도는 위임 하나에 공유된다
        _redeem(keeper, d_, _refillExec());
        _setSpendingBalance(0);
        _redeem(stranger, d_, _refillExec());
        _setSpendingBalance(0);

        vm.expectRevert(bytes("ERC20PeriodTransferEnforcer:transfer-amount-exceeded"));
        _redeem(makeAddr("thirdExecutor"), d_, _refillExec());
    }

    // ---------- 7. 바인딩 해지 · 위임 철회 ----------

    function test_RevertWhen_BindingRevoked() public {
        Delegation memory d_ = _refillDelegation();

        // 대조: 해지 전에는 통과
        _redeem(keeper, d_, _refillExec());
        _setSpendingBalance(0);

        vm.prank(main);
        registry.revokeBinding(spending);

        vm.expectRevert(abi.encodeWithSelector(RefillThresholdEnforcer.SpenderNotBound.selector, spending, main));
        _redeem(keeper, d_, _refillExec());
    }

    function test_RevertWhen_DelegationDisabled() public {
        Delegation memory d_ = _refillDelegation();

        // 대조: 철회 전에는 통과
        _redeem(keeper, d_, _refillExec());
        _setSpendingBalance(0);

        vm.prank(main);
        delegationManager.disableDelegation(d_);

        vm.expectRevert(IDelegationManager.CannotUseADisabledDelegation.selector);
        _redeem(keeper, d_, _refillExec());
    }

    // ---------- 만료 ----------

    function test_RevertWhen_RefillDelegationExpired() public {
        Delegation memory d_ = _refillDelegation();

        // 대조: 만료 직전에는 통과
        vm.warp(uint256(expiry) - 1);
        _redeem(keeper, d_, _refillExec());
        _setSpendingBalance(0);

        vm.warp(uint256(expiry));

        vm.expectRevert(bytes("TimestampEnforcer:expired-delegation"));
        _redeem(keeper, d_, _refillExec());
    }

    // ---------- 가스 측정용: 충전 1회 ----------

    /// @dev forge snapshot 값에는 위임 서명(vm.sign)·해싱 같은 테스트 측 비용이 섞인다.
    ///      리딤 호출 자체의 가스는 `forge test --gas-report` 의 redeemDelegations 행으로 본다.
    ///      BoundDelegator.t.sol 의 test_Gas_OneSpend 와 같은 형태로 둔다.
    function test_Gas_OneRefill() public {
        Delegation memory d_ = _refillDelegation();
        _redeem(keeper, d_, _refillExec());
    }
}
