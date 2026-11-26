// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import {Delegation, Caveat} from "delegation-framework/src/utils/Types.sol";

import {DojangCaveatEnforcer} from "../../src/enforcers/DojangCaveatEnforcer.sol";
import {JipsaPerTxCapEnforcer} from "../../src/enforcers/JipsaPerTxCapEnforcer.sol";
import {BoundDelegatorEnforcer} from "../../src/enforcers/BoundDelegatorEnforcer.sol";
import {F1TestBase} from "./F1TestBase.sol";

/// @notice F1 지출 경로 — 계획서 1-4절 8~10번.
///
/// @dev 지출 위임: 지출용 계정(delegator, 도장 없음) → 에이전트. caveat 순서는
///      ① 만료 ② 건당 ③ 기간 ④ 총액 ⑤ BoundDelegator (docs/design/F1_Refill.md 4절).
///      막히는 케이스는 "조건이 맞으면 통과"하는 대조 케이스와 쌍으로 둔다.
contract BoundDelegatorTest is F1TestBase {
    uint256 constant SPENDING_FUNDS = 1_000e6;

    address otherOwner = makeAddr("otherOwner");
    address otherAgent = makeAddr("otherAgent");

    function setUp() public override {
        super.setUp();
        _setSpendingBalance(SPENDING_FUNDS);

        // 다른 검증된 주인과 그 에이전트
        gate.setVerified(otherOwner, true);
        _bind(otherOwner, otherAgent);
    }

    function _spendTo(address to_, uint256 amount_) internal view returns (bytes memory) {
        return _transferExec(to_, amount_);
    }

    // ---------- 8. 같은 주인에게 묶인 에이전트만 지출용 계정에서 쓸 수 있다 ----------

    function test_BoundAgentSpendsFromSpendingAccount() public {
        Delegation memory d_ = _spendDelegation();

        _redeem(agent, d_, _spendTo(merchant, SPEND_PER_TX));

        assertEq(token.balanceOf(merchant), SPEND_PER_TX);
        assertEq(token.balanceOf(spending), SPENDING_FUNDS - SPEND_PER_TX);
        assertEq(token.balanceOf(main), FUNDING, "main wallet untouched by spend path");
    }

    function test_RevertWhen_AgentUnbound() public {
        address unboundAgent_ = makeAddr("unboundAgent");
        Delegation memory d_ = _signSpend(spendingPk, spending, unboundAgent_, _spendCaveats(true));

        vm.expectRevert(abi.encodeWithSelector(BoundDelegatorEnforcer.AgentNotBound.selector, unboundAgent_, main));
        _redeem(unboundAgent_, d_, _spendTo(merchant, SPEND_PER_TX));

        // 대조: 같은 주인에게 바인딩되면 같은 위임으로 통과
        _bind(main, unboundAgent_);
        _redeem(unboundAgent_, d_, _spendTo(merchant, SPEND_PER_TX));
        assertEq(token.balanceOf(merchant), SPEND_PER_TX);
    }

    /// @dev D4의 근거: 기존 DojangCaveatEnforcer는 delegator 자신을 주인으로 보므로
    ///      도장 없는 지출용 계정의 위임에서는 바인딩된 에이전트도 통과하지 못한다.
    function test_DojangEnforcerRejectsSpendingAccountDelegator() public {
        DojangCaveatEnforcer dojang_ = new DojangCaveatEnforcer();
        Caveat[] memory c_ = _spendCaveats(true);
        c_[4] = Caveat({enforcer: address(dojang_), terms: _boundTerms(true), args: hex""});
        Delegation memory d_ = _signSpend(spendingPk, spending, agent, c_);

        vm.expectRevert(abi.encodeWithSelector(DojangCaveatEnforcer.AgentNotBound.selector, agent, spending));
        _redeem(agent, d_, _spendTo(merchant, SPEND_PER_TX));

        // 대조: 같은 terms로 BoundDelegator를 쓰면 통과
        _redeem(agent, _spendDelegation(), _spendTo(merchant, SPEND_PER_TX));
        assertEq(token.balanceOf(merchant), SPEND_PER_TX);
    }

    // ---------- 9. 건당 한도 초과, 미검증 수신처는 막힌다 ----------

    function test_RevertWhen_PerTxCapExceeded() public {
        Delegation memory d_ = _spendDelegation();

        vm.expectRevert(
            abi.encodeWithSelector(JipsaPerTxCapEnforcer.PerTxCapExceeded.selector, SPEND_PER_TX + 1, SPEND_PER_TX)
        );
        _redeem(agent, d_, _spendTo(merchant, SPEND_PER_TX + 1));

        // 대조: 한도 이내면 통과
        _redeem(agent, d_, _spendTo(merchant, SPEND_PER_TX));
        assertEq(token.balanceOf(merchant), SPEND_PER_TX);
    }

    function test_RevertWhen_RecipientNotVerified() public {
        Delegation memory d_ = _spendDelegation();

        vm.expectRevert(abi.encodeWithSelector(BoundDelegatorEnforcer.RecipientNotVerified.selector, stranger));
        _redeem(agent, d_, _spendTo(stranger, SPEND_PER_TX));

        // 대조: 수신처가 도장을 받으면 같은 위임으로 통과
        gate.setVerified(stranger, true);
        _redeem(agent, d_, _spendTo(stranger, SPEND_PER_TX));
        assertEq(token.balanceOf(stranger), SPEND_PER_TX);
    }

    function test_UnverifiedRecipientPassesWhenFlagOff() public {
        Delegation memory d_ = _signSpend(spendingPk, spending, agent, _spendCaveats(false));

        _redeem(agent, d_, _spendTo(stranger, SPEND_PER_TX));
        assertEq(token.balanceOf(stranger), SPEND_PER_TX);
    }

    // ---------- 10. 다른 주인에게 묶인 에이전트, 바인딩 없는 지출용 계정은 막힌다 ----------

    function test_RevertWhen_AgentBoundToAnotherOwner() public {
        Delegation memory d_ = _signSpend(spendingPk, spending, otherAgent, _spendCaveats(true));

        vm.expectRevert(abi.encodeWithSelector(BoundDelegatorEnforcer.AgentNotBound.selector, otherAgent, main));
        _redeem(otherAgent, d_, _spendTo(merchant, SPEND_PER_TX));

        // 대조: 다른 주인이 해지하고 이 주인에게 다시 바인딩되면 통과
        vm.prank(otherOwner);
        registry.revokeBinding(otherAgent);
        _bind(main, otherAgent);
        _redeem(otherAgent, d_, _spendTo(merchant, SPEND_PER_TX));
        assertEq(token.balanceOf(merchant), SPEND_PER_TX);
    }

    function test_RevertWhen_SpendingAccountUnbound() public {
        Delegation memory d_ = _spendDelegation();

        // 대조: 해지 전에는 통과
        _redeem(agent, d_, _spendTo(merchant, SPEND_PER_TX));

        vm.prank(main);
        registry.revokeBinding(spending);

        vm.expectRevert(abi.encodeWithSelector(BoundDelegatorEnforcer.DelegatorNotBound.selector, spending));
        _redeem(agent, d_, _spendTo(merchant, SPEND_PER_TX));
    }

    function test_RevertWhen_SpendingAccountNeverBound() public {
        (address loose_, uint256 loosePk_) = makeAddrAndKey("looseSpending");
        _etch7702(loose_);
        token.mint(loose_, SPENDING_FUNDS);
        Delegation memory d_ = _signSpend(loosePk_, loose_, agent, _spendCaveats(true));

        vm.expectRevert(abi.encodeWithSelector(BoundDelegatorEnforcer.DelegatorNotBound.selector, loose_));
        _redeem(agent, d_, _spendTo(merchant, SPEND_PER_TX));

        // 대조: 주인에게 바인딩되면 통과
        _bind(main, loose_);
        _redeem(agent, d_, _spendTo(merchant, SPEND_PER_TX));
        assertEq(token.balanceOf(merchant), SPEND_PER_TX);
    }

    /// @dev 지출용 계정과 에이전트가 각각 다른 주인에게 묶여 있으면 막힌다
    ///      (지출용 계정의 주인 = otherOwner, 에이전트의 주인 = main)
    function test_RevertWhen_SpendingAccountBoundToAnotherOwner() public {
        (address othersSpending_, uint256 othersSpendingPk_) = makeAddrAndKey("othersSpending");
        _etch7702(othersSpending_);
        token.mint(othersSpending_, SPENDING_FUNDS);
        _bind(otherOwner, othersSpending_);
        Delegation memory d_ = _signSpend(othersSpendingPk_, othersSpending_, agent, _spendCaveats(true));

        vm.expectRevert(abi.encodeWithSelector(BoundDelegatorEnforcer.AgentNotBound.selector, agent, otherOwner));
        _redeem(agent, d_, _spendTo(merchant, SPEND_PER_TX));

        // 대조: 그 주인의 에이전트는 통과
        Delegation memory ok_ = _signSpend(othersSpendingPk_, othersSpending_, otherAgent, _spendCaveats(true));
        _redeem(otherAgent, ok_, _spendTo(merchant, SPEND_PER_TX));
        assertEq(token.balanceOf(merchant), SPEND_PER_TX);
    }

    function test_RevertWhen_OwnerStampRevoked() public {
        Delegation memory d_ = _spendDelegation();
        gate.setVerified(main, false);

        vm.expectRevert(abi.encodeWithSelector(BoundDelegatorEnforcer.OwnerNotVerified.selector, main));
        _redeem(agent, d_, _spendTo(merchant, SPEND_PER_TX));

        // 대조: 도장이 복구되면 통과
        gate.setVerified(main, true);
        _redeem(agent, d_, _spendTo(merchant, SPEND_PER_TX));
        assertEq(token.balanceOf(merchant), SPEND_PER_TX);
    }

    // ---------- 실행 형태·terms ----------

    function test_RevertWhen_InvalidTermsLength() public {
        Caveat[] memory c_ = _spendCaveats(true);
        c_[4].terms = abi.encodePacked(address(gate));
        Delegation memory d_ = _signSpend(spendingPk, spending, agent, c_);

        vm.expectRevert(abi.encodeWithSelector(BoundDelegatorEnforcer.InvalidTermsLength.selector, 20));
        _redeem(agent, d_, _spendTo(merchant, SPEND_PER_TX));

        // 대조: 기본 위임(정상 terms)으로는 통과
        _redeem(agent, _spendDelegation(), _spendTo(merchant, SPEND_PER_TX));
        assertEq(token.balanceOf(merchant), SPEND_PER_TX);
    }

    // ---------- 가스 측정용: 지출 1회 ----------

    /// @dev forge snapshot 값에는 테스트 측 비용이 섞인다. 리딤 자체는 --gas-report 의 redeemDelegations 행.
    function test_Gas_OneSpend() public {
        Delegation memory d_ = _spendDelegation();
        _redeem(agent, d_, _spendTo(merchant, SPEND_PER_TX));
    }
}
