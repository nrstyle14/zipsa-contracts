// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import {IDelegationManager} from "delegation-framework/src/interfaces/IDelegationManager.sol";
import {AllowedTargetsEnforcer} from "delegation-framework/src/enforcers/AllowedTargetsEnforcer.sol";
import {AllowedMethodsEnforcer} from "delegation-framework/src/enforcers/AllowedMethodsEnforcer.sol";
import {Delegation, Caveat} from "delegation-framework/src/utils/Types.sol";

import {F1TestBase} from "./F1TestBase.sol";
import {PaymentGate} from "../../src/PaymentGate.sol";
import {IVerifiedGate} from "../../src/interfaces/IVerifiedGate.sol";
import {JipsaPerTxCapEnforcer} from "../../src/enforcers/JipsaPerTxCapEnforcer.sol";

/// @notice 결제 게이트 G1~G14 (docs/design/M2_PaymentGate.md 5절).
///
/// @dev F1 셋업(메인 지갑 → 지출용 계정 → 에이전트)을 그대로 쓰고, 지출용 계정이 **수임자 = 게이트**인
///      게이트 위임에 서명한다. caveat: Timestamp → AllowedTargets → AllowedMethods → PerTxCap →
///      ERC20Period(1시간) → ERC20TransferAmount. 막히는 경우는 통과하는 대조 경우와 쌍으로 둔다.
contract PaymentGateTest is F1TestBase {
    PaymentGate payGate;
    AllowedTargetsEnforcer allowedTargets;
    AllowedMethodsEnforcer allowedMethods;

    address otherOwner = makeAddr("otherOwner");
    address otherAgent = makeAddr("otherAgent");
    address human;
    address unverifiedHuman = makeAddr("unverifiedHuman");

    uint256 constant GATE_PER_TX = 15e6;
    uint256 constant GATE_HOURLY = 200e6;
    uint256 constant GATE_TOTAL = 100_000e6;
    uint256 constant HOUR = 3600;
    uint256 constant PRICE = 10e6;

    event Paid(
        bytes32 indexed ref,
        address indexed payer,
        address indexed responsible,
        address caller,
        address token,
        uint256 amount
    );

    function setUp() public override {
        super.setUp();
        allowedTargets = new AllowedTargetsEnforcer();
        allowedMethods = new AllowedMethodsEnforcer();
        payGate = new PaymentGate(
            IVerifiedGate(address(gate)), registry, address(delegationManager), merchant, address(this)
        );
        payGate.setTokenAllowed(address(token), true);

        gate.setVerified(otherOwner, true);
        _bind(otherOwner, otherAgent);

        human = makeAddr("human");
        gate.setVerified(human, true);
        token.mint(human, 1_000e6);
        token.mint(unverifiedHuman, 1_000e6);

        token.mint(spending, 1_000e6);
        otherToken.mint(spending, 1_000e6);
    }

    // ---------- 게이트 위임 ----------

    /// @dev ① 만료 ② 대상 토큰 ③ transfer만 ④ 건당 ⑤ 기간(1시간) ⑥ 총액
    function _gateCaveats(address token_) internal view returns (Caveat[] memory c_) {
        c_ = new Caveat[](6);
        c_[0] = Caveat({
            enforcer: address(timestamps), terms: abi.encodePacked(uint128(0), uint128(expiry)), args: hex""
        });
        c_[1] = Caveat({enforcer: address(allowedTargets), terms: abi.encodePacked(token_), args: hex""});
        c_[2] = Caveat({enforcer: address(allowedMethods), terms: abi.encodePacked(bytes4(0xa9059cbb)), args: hex""});
        c_[3] = Caveat({enforcer: address(perTxCap), terms: abi.encodePacked(token_, GATE_PER_TX), args: hex""});
        c_[4] = Caveat({
            enforcer: address(periodCap),
            terms: abi.encodePacked(token_, GATE_HOURLY, HOUR, startDate),
            args: hex""
        });
        c_[5] = Caveat({enforcer: address(totalBudget), terms: abi.encodePacked(token_, GATE_TOTAL), args: hex""});
    }

    function _gateDelegation(address token_) internal view returns (Delegation memory) {
        return _signSpend(spendingPk, spending, address(payGate), _gateCaveats(token_));
    }

    function _ctx(Delegation memory d_) internal pure returns (bytes memory) {
        Delegation[] memory ds_ = new Delegation[](1);
        ds_[0] = d_;
        return abi.encode(ds_);
    }

    function _payAs(address caller_, Delegation memory d_, uint256 amount_, bytes32 ref_) internal {
        vm.prank(caller_);
        payGate.payDelegated(_ctx(d_), address(token), amount_, ref_);
    }

    // ---------- G1 ----------

    function test_G1_boundAgentPaysDelegated() public {
        Delegation memory d_ = _gateDelegation(address(token));
        uint256 before_ = token.balanceOf(merchant);

        vm.expectEmit(true, true, true, true, address(payGate));
        emit Paid(bytes32("order-1"), spending, main, agent, address(token), PRICE);
        _payAs(agent, d_, PRICE, "order-1");

        assertEq(token.balanceOf(merchant), before_ + PRICE);
        assertEq(token.balanceOf(address(payGate)), 0, "gate holds nothing");
        assertTrue(payGate.refPaid("order-1"));
    }

    // ---------- G2 ----------

    function test_G2_tokenNotAllowed() public {
        Delegation memory d_ = _gateDelegation(address(otherToken));
        vm.expectRevert(abi.encodeWithSelector(PaymentGate.TokenNotAllowed.selector, address(otherToken)));
        vm.prank(agent);
        payGate.payDelegated(_ctx(d_), address(otherToken), PRICE, "order-2");

        // 대조: 허용 토큰이면 통과
        _payAs(agent, _gateDelegation(address(token)), PRICE, "order-2");
    }

    // ---------- G3 ----------

    function test_G3_unboundCallerWithSameDelegation() public {
        Delegation memory d_ = _gateDelegation(address(token));
        vm.expectRevert(abi.encodeWithSelector(PaymentGate.CallerNotBound.selector, stranger, main));
        _payAs(stranger, d_, PRICE, "order-3");

        _payAs(agent, d_, PRICE, "order-3");
    }

    // ---------- G4 ----------

    function test_G4_agentBoundToOtherOwner() public {
        Delegation memory d_ = _gateDelegation(address(token));
        vm.expectRevert(abi.encodeWithSelector(PaymentGate.CallerNotBound.selector, otherAgent, main));
        _payAs(otherAgent, d_, PRICE, "order-4");

        _payAs(agent, d_, PRICE, "order-4");
    }

    // ---------- G5 ----------

    function test_G5_ownerDojangInvalid() public {
        Delegation memory d_ = _gateDelegation(address(token));
        gate.setVerified(main, false);
        vm.expectRevert(abi.encodeWithSelector(PaymentGate.PayerNotVerified.selector, main));
        _payAs(agent, d_, PRICE, "order-5");

        gate.setVerified(main, true);
        _payAs(agent, d_, PRICE, "order-5");
    }

    // ---------- G6 ----------

    function test_G6_payerNotBoundToAnyone() public {
        Delegation memory d_ = _gateDelegation(address(token));
        vm.prank(main);
        registry.revokeBinding(spending);
        vm.expectRevert(abi.encodeWithSelector(PaymentGate.PayerNotAccountable.selector, spending));
        _payAs(agent, d_, PRICE, "order-6");

        _bind(main, spending);
        _payAs(agent, d_, PRICE, "order-6");
    }

    // ---------- G7 ----------

    function test_G7_perTxCapBubblesUp() public {
        Delegation memory d_ = _gateDelegation(address(token));
        vm.expectRevert(
            abi.encodeWithSelector(JipsaPerTxCapEnforcer.PerTxCapExceeded.selector, 5_000e6, GATE_PER_TX)
        );
        _payAs(agent, d_, 5_000e6, "order-7");

        _payAs(agent, d_, GATE_PER_TX, "order-7");
    }

    // ---------- G8 ----------

    function test_G8_hourlyCapThenReopens() public {
        Delegation memory d_ = _gateDelegation(address(token));
        // 200 / 10 = 20회까지 통과
        for (uint256 i = 0; i < 20; i++) {
            _payAs(agent, d_, PRICE, bytes32(i + 1));
        }
        vm.expectRevert(bytes("ERC20PeriodTransferEnforcer:transfer-amount-exceeded"));
        _payAs(agent, d_, PRICE, bytes32(uint256(100)));

        vm.warp(block.timestamp + HOUR);
        _payAs(agent, d_, PRICE, bytes32(uint256(100)));
    }

    // ---------- G9 ----------

    function test_G9_revokedDelegation() public {
        Delegation memory d_ = _gateDelegation(address(token));
        _payAs(agent, d_, PRICE, "before-revoke");

        vm.prank(spending);
        delegationManager.disableDelegation(d_);
        vm.expectRevert(IDelegationManager.CannotUseADisabledDelegation.selector);
        _payAs(agent, d_, PRICE, "after-revoke");
    }

    // ---------- G10 ----------

    function test_G10_sameRefTwice() public {
        Delegation memory d_ = _gateDelegation(address(token));
        _payAs(agent, d_, PRICE, "dup");
        vm.expectRevert(abi.encodeWithSelector(PaymentGate.RefAlreadyPaid.selector, bytes32("dup")));
        _payAs(agent, d_, PRICE, "dup");
    }

    // ---------- G11 ----------

    function test_G11_payApproved() public {
        vm.startPrank(human);
        token.approve(address(payGate), PRICE);
        vm.expectEmit(true, true, true, true, address(payGate));
        emit Paid(bytes32("human-1"), human, human, human, address(token), PRICE);
        payGate.pay(address(token), PRICE, "human-1");
        vm.stopPrank();
        assertEq(token.balanceOf(merchant), PRICE);

        vm.startPrank(unverifiedHuman);
        token.approve(address(payGate), PRICE);
        // 도장도 귀속도 없으면 책임자가 없다 → PayerNotAccountable. 귀속은 있으나 주인 도장이 없으면 PayerNotVerified.
        vm.expectRevert(abi.encodeWithSelector(PaymentGate.PayerNotAccountable.selector, unverifiedHuman));
        payGate.pay(address(token), PRICE, "human-2");
        vm.stopPrank();

        address unverifiedOwner_ = makeAddr("unverifiedOwner");
        gate.setVerified(unverifiedOwner_, true); // 바인딩 제안은 도장이 있어야 하므로 묶은 뒤 무효화
        _bind(unverifiedOwner_, unverifiedHuman);
        gate.setVerified(unverifiedOwner_, false);
        vm.startPrank(unverifiedHuman);
        vm.expectRevert(abi.encodeWithSelector(PaymentGate.PayerNotVerified.selector, unverifiedOwner_));
        payGate.pay(address(token), PRICE, "human-2");
        vm.stopPrank();
    }

    // ---------- G12 ----------

    function test_G12_requireOffStillChecksCaller() public {
        Delegation memory d_ = _gateDelegation(address(token));
        payGate.setRequireVerifiedPayer(false);
        gate.setVerified(main, false);

        // G5 상황: 이제 통과
        _payAs(agent, d_, PRICE, "off-1");

        // G3 상황: 여전히 CallerNotBound
        vm.expectRevert(abi.encodeWithSelector(PaymentGate.CallerNotBound.selector, stranger, main));
        _payAs(stranger, d_, PRICE, "off-2");

        // 책임자 0인 결제 계정은 요구를 꺼도 막힌다
        vm.prank(main);
        registry.revokeBinding(spending);
        vm.expectRevert(abi.encodeWithSelector(PaymentGate.PayerNotAccountable.selector, spending));
        _payAs(agent, d_, PRICE, "off-3");
    }

    // ---------- G13 ----------

    function test_G13_onlyAdmin() public {
        vm.startPrank(stranger);
        vm.expectRevert(abi.encodeWithSelector(PaymentGate.NotAdmin.selector, stranger));
        payGate.setTokenAllowed(address(otherToken), true);
        vm.expectRevert(abi.encodeWithSelector(PaymentGate.NotAdmin.selector, stranger));
        payGate.setRequireVerifiedPayer(false);
        vm.stopPrank();

        payGate.setTokenAllowed(address(otherToken), true);
        assertTrue(payGate.tokenAllowed(address(otherToken)));
    }

    // ---------- G14 ----------

    function test_G14_twoDelegationChain() public {
        Delegation memory d_ = _gateDelegation(address(token));
        Delegation[] memory ds_ = new Delegation[](2);
        ds_[0] = d_;
        ds_[1] = d_;
        vm.expectRevert(abi.encodeWithSelector(PaymentGate.InvalidDelegationChain.selector, uint256(2)));
        vm.prank(agent);
        payGate.payDelegated(abi.encode(ds_), address(token), PRICE, "chain-2");

        _payAs(agent, d_, PRICE, "chain-2");
    }

    // ---------- 추가 ----------

    function test_zeroAmount() public {
        Delegation memory d_ = _gateDelegation(address(token));
        vm.expectRevert(PaymentGate.ZeroAmount.selector);
        _payAs(agent, d_, 0, "zero");
    }

    /// @dev 지출용 계정이 비면 토큰 에러가 그대로 올라온다 (drain 시나리오의 마지막 장면)
    function test_emptyPayerBubblesTokenError() public {
        Delegation memory d_ = _gateDelegation(address(token));
        _setSpendingBalance(5e6);
        vm.expectRevert();
        _payAs(agent, d_, PRICE, "empty");
    }

    /// @dev 수신처는 생성자에서 고정 — 위임을 가진 사람도 다른 곳으로 보낼 수 없다
    function test_destinationIsFixed() public view {
        assertEq(payGate.destination(), merchant);
    }
}
