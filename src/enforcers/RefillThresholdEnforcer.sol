// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import {ExecutionLib} from "@erc7579/lib/ExecutionLib.sol";
import {CaveatEnforcer} from "delegation-framework/src/enforcers/CaveatEnforcer.sol";
import {ModeCode} from "delegation-framework/src/utils/Types.sol";
import {IVerifiedGate} from "../interfaces/IVerifiedGate.sol";
import {OwnerBindingRegistry} from "../OwnerBindingRegistry.sol";

/// @title RefillThresholdEnforcer
/// @notice 메인 지갑 → 지출용 계정 자동 충전 위임의 조건을 리딤 시점에 강제한다.
///
/// @dev 충전 위임은 `ANY_DELEGATE`로 발급되어 누구나 실행할 수 있다. 조건이 전부 여기 있으므로
///      실행자를 믿을 필요가 없고, 따라서 `_redeemer`는 쓰지 않는다. 통과 조건:
///
///      1. 실행이 terms 토큰의 `transfer(spender, refillAmount)` 단일 호출이고 value가 0
///      2. 수신처 지출용 계정이 레지스트리상 **이 delegator(주인)에게** 바인딩
///      3. 주인(delegator)의 도장이 유효
///      4. 지출용 계정의 terms 토큰 잔액이 기준 미만
///
///      전송액을 상한이 아니라 **정확히** `refillAmount`로 묶는다. 상한만 두면 열린 실행자가
///      잔액이 기준 미만인 동안 1 wei 충전을 반복해 `LimitedCallsEnforcer`의 총 횟수를
///      태워 자동 충전을 멈출 수 있다.
///
///      토큰도 이 안에서 실행 대상과 묶는다. 다른 caveat에 맡기면 잔액은 토큰 A로 보고
///      송금은 토큰 B로 하는 조합이 가능해진다.
///
///      기간 한도·총 횟수·만료는 이 enforcer가 아니라 `ERC20PeriodTransferEnforcer`·
///      `LimitedCallsEnforcer`·`TimestampEnforcer`와 조합해 건다. 설계: docs/design/F1_Refill.md
contract RefillThresholdEnforcer is CaveatEnforcer {
    using ExecutionLib for bytes;

    /// @dev IERC20.transfer.selector. OZ를 import하면 우리 OZ(^0.8.24)가
    ///      이 파일의 0.8.23 컴파일 단위로 끌려오므로 상수로 둔다.
    bytes4 private constant TRANSFER_SELECTOR = 0xa9059cbb;
    /// @dev IERC20.balanceOf.selector. 같은 이유로 상수로 둔다.
    bytes4 private constant BALANCE_OF_SELECTOR = 0x70a08231;

    /// @dev `abi.encode(address, address, address, address, uint256, uint256)` — 정적 타입 6개 × 32바이트
    uint256 private constant TERMS_LENGTH = 192;

    // ---- DojangCaveatEnforcer와 같은 시그니처 (셀렉터 동일 → 기존 디코더 재사용) ----
    error InvalidTermsLength(uint256 length);
    error InvalidExecutionLength(uint256 length);
    error InvalidContract(address target, address expected);
    error InvalidMethod(bytes4 selector);
    error OwnerNotVerified(address owner);

    // ---- 신규 ----
    error ZeroRefillAmount();
    error InvalidValue(uint256 value);
    error InvalidRecipient(address to, address spender);
    error InvalidRefillAmount(uint256 amount, uint256 expected);
    error SpenderNotBound(address spender, address delegator);
    /// @dev `balanceOf` 호출이 실패했거나 반환 길이가 32바이트 미만
    error BalanceQueryFailed(address token, address spender);
    error BalanceNotBelowThreshold(uint256 balance, uint256 threshold);

    /// @param _terms `abi.encode(IVerifiedGate gate, OwnerBindingRegistry registry, address token,
    ///               address spender, uint256 threshold, uint256 refillAmount)` (192 bytes)
    /// @param _delegator 충전 위임을 서명한 메인 지갑 (7702 코드 보유)
    function beforeHook(
        bytes calldata _terms,
        bytes calldata,
        ModeCode _mode,
        bytes calldata _executionCallData,
        bytes32,
        address _delegator,
        address
    )
        public
        view
        override
        onlySingleCallTypeMode(_mode)
        onlyDefaultExecutionMode(_mode)
    {
        // 상태를 쓰지 않으므로 view로 좁힌다. 지역변수 없이 인자만 넘긴다 (stack too deep 회피)
        _enforce(_terms, _executionCallData, _delegator);
    }

    /// @dev 판정 순서: terms → 실행 형태 → 수신처 → 금액 → 바인딩 → 주인 도장 → 잔액.
    ///      순수 검사를 먼저, 귀속(바인딩·도장)을 다음, 외부 토큰 잔액을 마지막에 본다.
    function _enforce(bytes calldata _terms, bytes calldata _executionCallData, address _delegator) internal view {
        (
            IVerifiedGate gate_,
            OwnerBindingRegistry registry_,
            address token_,
            address spender_,
            uint256 threshold_,
            uint256 refillAmount_
        ) = getTermsInfo(_terms);

        _checkExecution(_executionCallData, token_, spender_, refillAmount_);

        // 지출용 계정이 이 주인에게 귀속되어 있어야 한다 — 다른 주인의 계정으로는 충전하지 않는다
        if (registry_.ownerOf(spender_) != _delegator) revert SpenderNotBound(spender_, _delegator);

        // 주인 도장 유효성 재확인 (KYC 무효화 시 즉시 정지)
        if (!gate_.isVerified(_delegator)) revert OwnerNotVerified(_delegator);

        {
            uint256 balance_ = _balanceOf(token_, spender_);
            if (balance_ >= threshold_) revert BalanceNotBelowThreshold(balance_, threshold_);
        }
    }

    /// @dev 실행이 `token.transfer(spender, refillAmount)` 단일 호출이고 value가 0인지 확인한다.
    ///      calldata 디코딩 변수는 스코프 블록에 가둬 수명을 줄인다 (stack too deep 회피).
    function _checkExecution(
        bytes calldata _executionCallData,
        address _token,
        address _spender,
        uint256 _refillAmount
    )
        internal
        pure
    {
        (address target_, uint256 value_, bytes calldata callData_) = _executionCallData.decodeSingle();

        if (callData_.length != 68) revert InvalidExecutionLength(callData_.length);
        if (bytes4(callData_[0:4]) != TRANSFER_SELECTOR) revert InvalidMethod(bytes4(callData_[0:4]));
        if (target_ != _token) revert InvalidContract(target_, _token);
        // 토큰이 payable이어도 메인 지갑의 네이티브 코인이 따라 나가지 않게 한다
        if (value_ != 0) revert InvalidValue(value_);

        {
            address to_ = address(bytes20(callData_[16:36]));
            if (to_ != _spender) revert InvalidRecipient(to_, _spender);
        }
        {
            uint256 amount_ = uint256(bytes32(callData_[36:68]));
            if (amount_ != _refillAmount) revert InvalidRefillAmount(amount_, _refillAmount);
        }
    }

    /// @dev `IERC20(token).balanceOf(account)`를 staticcall로 읽는다.
    ///      실패·짧은 반환은 데이터 없는 revert 대신 원인이 드러나는 에러로 바꾼다.
    function _balanceOf(address _token, address _account) internal view returns (uint256 balance_) {
        (bool ok_, bytes memory ret_) = _token.staticcall(abi.encodeWithSelector(BALANCE_OF_SELECTOR, _account));
        if (!ok_ || ret_.length < 32) revert BalanceQueryFailed(_token, _account);
        balance_ = abi.decode(ret_, (uint256));
    }

    /// @notice terms를 디코딩·검증한다.
    /// @dev `refillAmount == 0`은 거부한다 — 0 전송이 통과하면 총 횟수만 소진된다.
    ///      `threshold == 0`은 잔액 조건이 항상 거짓이라 충전이 막히는 쪽(fail-closed)이므로 허용한다.
    function getTermsInfo(bytes calldata _terms)
        public
        pure
        returns (
            IVerifiedGate gate_,
            OwnerBindingRegistry registry_,
            address token_,
            address spender_,
            uint256 threshold_,
            uint256 refillAmount_
        )
    {
        if (_terms.length != TERMS_LENGTH) revert InvalidTermsLength(_terms.length);
        // 튜플 할당에서 새 선언과 기존 반환 변수를 섞을 수 없어 주소는 따로 받는다
        address gateAddr_;
        address registryAddr_;
        (gateAddr_, registryAddr_, token_, spender_, threshold_, refillAmount_) =
            abi.decode(_terms, (address, address, address, address, uint256, uint256));
        if (refillAmount_ == 0) revert ZeroRefillAmount();
        gate_ = IVerifiedGate(gateAddr_);
        registry_ = OwnerBindingRegistry(registryAddr_);
    }
}
