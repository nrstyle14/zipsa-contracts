// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import {ExecutionLib} from "@erc7579/lib/ExecutionLib.sol";
import {CaveatEnforcer} from "delegation-framework/src/enforcers/CaveatEnforcer.sol";
import {ModeCode} from "delegation-framework/src/utils/Types.sol";
import {IVerifiedGate} from "../interfaces/IVerifiedGate.sol";
import {OwnerBindingRegistry} from "../OwnerBindingRegistry.sol";

/// @title BoundDelegatorEnforcer
/// @notice 지출용 계정 → 에이전트 지출 위임에서, 위임한 계정과 리딤하는 에이전트가
///         **같은 검증된 주인**에게 바인딩되어 있는지 리딤 시점에 강제한다.
///
/// @dev `DojangCaveatEnforcer`는 delegator 자신을 주인으로 보고 delegator의 도장을 요구한다.
///      지출용 계정은 도장이 없는 주인의 두 번째 EOA이므로 그대로는 쓸 수 없다. 이 enforcer는
///      주인을 레지스트리에서 한 단계 거슬러 올라가 찾는다.
///
///      1. 수신처가 Dojang 도장 보유자인지 (terms 플래그로 on/off)
///      2. delegator(지출용 계정)가 레지스트리상 주인에게 바인딩되어 있는지 → 그 주인을 책임자로 본다
///      3. 리딤하는 에이전트가 **같은 주인**에게 바인딩되어 있는지
///      4. 그 주인의 도장이 여전히 유효한지
///
///      3번이 핵심이다. "아무 검증된 주인에게든 묶여 있으면 통과"시키면 다른 주인의 에이전트가
///      이 지출용 계정의 위임을 리딤할 수 있다.
///
///      terms는 `DojangCaveatEnforcer`와 같은 형식이고, 겹치는 에러는 시그니처를 그대로 쓴다
///      (셀렉터 동일 → 기존 인코더·디코더 재사용). 설계: docs/design/F1_Refill.md 4절
contract BoundDelegatorEnforcer is CaveatEnforcer {
    using ExecutionLib for bytes;

    /// @dev IERC20.transfer.selector. OZ를 import하면 우리 OZ(^0.8.24)가
    ///      이 파일의 0.8.23 컴파일 단위로 끌려오므로 상수로 둔다.
    bytes4 private constant TRANSFER_SELECTOR = 0xa9059cbb;

    // ---- DojangCaveatEnforcer와 같은 시그니처 ----
    error InvalidTermsLength(uint256 length);
    error InvalidExecutionLength(uint256 length);
    error InvalidContract(address target, address expected);
    error InvalidMethod(bytes4 selector);
    error RecipientNotVerified(address to);
    /// @dev 둘째 인자는 delegator가 아니라 **delegator의 주인**이다 (시그니처만 같고 의미가 한 단계 위)
    error AgentNotBound(address redeemer, address owner);
    error OwnerNotVerified(address owner);

    // ---- 신규 ----
    /// @dev 위임한 계정이 레지스트리상 어떤 주인에게도 바인딩되어 있지 않다
    error DelegatorNotBound(address delegator);

    /// @param _terms `abi.encode(IVerifiedGate gate, OwnerBindingRegistry registry, address token, bool verifiedRecipientOnly)`
    /// @param _delegator 위임한 지출용 계정 (7702 코드 보유, 주인에게 바인딩)
    /// @param _redeemer 리딤을 시도하는 에이전트
    function beforeHook(
        bytes calldata _terms,
        bytes calldata,
        ModeCode _mode,
        bytes calldata _executionCallData,
        bytes32,
        address _delegator,
        address _redeemer
    )
        public
        view
        override
        onlySingleCallTypeMode(_mode)
        onlyDefaultExecutionMode(_mode)
    {
        // 상태를 쓰지 않으므로 view로 좁힌다. 지역변수 없이 인자만 넘긴다 (stack too deep 회피)
        _enforce(_terms, _executionCallData, _delegator, _redeemer);
    }

    /// @dev 수신처 도장 → delegator 바인딩 → 에이전트 바인딩 일치 → 주인 도장 순서로 확인한다.
    ///      `DojangCaveatEnforcer`와 같은 순서에 "주인 찾기" 한 단계를 끼운 것이다.
    ///      calldata 디코딩 변수는 스코프 블록에 가둬 수명을 줄인다 (stack too deep 회피).
    function _enforce(
        bytes calldata _terms,
        bytes calldata _executionCallData,
        address _delegator,
        address _redeemer
    )
        internal
        view
    {
        (IVerifiedGate gate_, OwnerBindingRegistry registry_, address token_, bool verifiedRecipientOnly_) =
            getTermsInfo(_terms);

        {
            (address target_,, bytes calldata callData_) = _executionCallData.decodeSingle();

            if (callData_.length != 68) revert InvalidExecutionLength(callData_.length);
            if (bytes4(callData_[0:4]) != TRANSFER_SELECTOR) revert InvalidMethod(bytes4(callData_[0:4]));
            if (target_ != token_) revert InvalidContract(target_, token_);

            // 1. 수신처 도장 (프롬프트 인젝션으로 임의 주소에 송금하려는 시도 차단)
            if (verifiedRecipientOnly_) {
                address to_ = address(bytes20(callData_[16:36]));
                if (!gate_.isVerified(to_)) revert RecipientNotVerified(to_);
            }
        }

        // 2. 위임한 계정의 주인 — 바인딩이 없으면 책임자가 없다
        address owner_ = registry_.ownerOf(_delegator);
        if (owner_ == address(0)) revert DelegatorNotBound(_delegator);

        // 3. 에이전트가 같은 주인에게 귀속되어 있어야 한다
        if (registry_.ownerOf(_redeemer) != owner_) revert AgentNotBound(_redeemer, owner_);

        // 4. 주인 도장 유효성 재확인 (KYC 무효화 시 즉시 정지)
        if (!gate_.isVerified(owner_)) revert OwnerNotVerified(owner_);
    }

    function getTermsInfo(bytes calldata _terms)
        public
        pure
        returns (
            IVerifiedGate gate_,
            OwnerBindingRegistry registry_,
            address token_,
            bool verifiedRecipientOnly_
        )
    {
        if (_terms.length != 128) revert InvalidTermsLength(_terms.length);
        // 튜플 할당에서 새 선언과 기존 반환 변수를 섞을 수 없어 따로 받는다
        (address gateAddr_, address registryAddr_, address tokenAddr_, bool onlyVerified_) =
            abi.decode(_terms, (address, address, address, bool));
        gate_ = IVerifiedGate(gateAddr_);
        registry_ = OwnerBindingRegistry(registryAddr_);
        token_ = tokenAddr_;
        verifiedRecipientOnly_ = onlyVerified_;
    }
}
