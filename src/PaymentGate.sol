// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import {ModeLib} from "@erc7579/lib/ModeLib.sol";
import {ExecutionLib} from "@erc7579/lib/ExecutionLib.sol";
import {IDelegationManager} from "delegation-framework/src/interfaces/IDelegationManager.sol";
import {Delegation, ModeCode} from "delegation-framework/src/utils/Types.sol";
import {IVerifiedGate} from "./interfaces/IVerifiedGate.sol";
import {OwnerBindingRegistry} from "./OwnerBindingRegistry.sol";

/// @title PaymentGate
/// @notice 상점이 돈을 받는 문. 결제가 들어올 때 **허용 토큰, 결제 책임자의 도장, 호출자의 귀속**을
///         확인하고 하나라도 어긋나면 되돌린다. 돈은 게이트에 머물지 않고 결제 계정에서 수신처로 바로 간다.
///
/// @dev 두 경로:
///      - `pay`          : 결제자 본인이 미리 승인한 금액에서 `transferFrom(결제자 → 수신처)`.
///      - `payDelegated` : 결제 계정(지출용 계정)이 **수임자 = 이 게이트**인 위임에 서명해 두고, 에이전트가
///                         게이트를 부르면 게이트가 `DelegationManager.redeemDelegations`로 결제 계정에서
///                         `transfer(destination, amount)`를 실행한다. 위임의 caveat(건당·기간·총액 한도,
///                         만료, 대상·메서드 제한)은 기존 enforcer가 그대로 검사한다. 승인(approve)이 없다.
///
///      `payDelegated`의 호출자 귀속 확인은 끌 수 없다. 위임은 공개돼도 되는 값이므로, 이 확인이 없으면
///      위임을 본 아무나 게이트를 불러 결제를 일으킬 수 있다.
///
///      설계: docs/design/M2_PaymentGate.md · 테스트넷 데모용, 업그레이드 프록시 없음, `destination` 불변.
contract PaymentGate {
    /// @dev IERC20 셀렉터. OZ를 import하면 OZ(^0.8.24)가 이 파일의 0.8.23 컴파일 단위로 끌려오므로 상수로 둔다.
    bytes4 private constant TRANSFER_SELECTOR = 0xa9059cbb; // transfer(address,uint256)
    bytes4 private constant TRANSFER_FROM_SELECTOR = 0x23b872dd; // transferFrom(address,address,uint256)
    bytes4 private constant BALANCE_OF_SELECTOR = 0x70a08231; // balanceOf(address)

    IVerifiedGate public immutable verifiedGate;
    OwnerBindingRegistry public immutable registry;
    address public immutable delegationManager;
    /// @notice 상점 수신처. 바꿀 수 없다.
    address public immutable destination;
    /// @notice 허용 토큰·도장 요구 설정 권한
    address public admin;

    mapping(address => bool) public tokenAllowed;
    bool public requireVerifiedPayer;
    /// @notice 주문 번호 중복 결제 방지
    mapping(bytes32 => bool) public refPaid;

    uint256 private _locked = 1;

    event Paid(
        bytes32 indexed ref,
        address indexed payer,
        address indexed responsible,
        address caller,
        address token,
        uint256 amount
    );
    event TokenAllowedSet(address indexed token, bool allowed);
    event RequireVerifiedPayerSet(bool required);

    error ZeroAmount();
    error TokenNotAllowed(address token);
    error RefAlreadyPaid(bytes32 ref);
    /// @dev 책임자를 찾을 수 없음 (도장도 없고 레지스트리 귀속도 없음)
    error PayerNotAccountable(address payer);
    error PayerNotVerified(address responsible);
    error CallerNotBound(address caller, address responsible);
    /// @dev 위임이 정확히 1장이 아님
    error InvalidDelegationChain(uint256 length);
    error PaymentNotReceived(uint256 expected, uint256 received);
    error NotAdmin(address caller);
    error Reentrancy();
    error TokenCallFailed();
    error ZeroAddress();

    modifier nonReentrant() {
        if (_locked != 1) revert Reentrancy();
        _locked = 2;
        _;
        _locked = 1;
    }

    modifier onlyAdmin() {
        if (msg.sender != admin) revert NotAdmin(msg.sender);
        _;
    }

    constructor(
        IVerifiedGate verifiedGate_,
        OwnerBindingRegistry registry_,
        address delegationManager_,
        address destination_,
        address admin_
    ) {
        if (
            address(verifiedGate_) == address(0) || address(registry_) == address(0)
                || delegationManager_ == address(0) || destination_ == address(0) || admin_ == address(0)
        ) revert ZeroAddress();
        verifiedGate = verifiedGate_;
        registry = registry_;
        delegationManager = delegationManager_;
        destination = destination_;
        admin = admin_;
        requireVerifiedPayer = true;
        emit RequireVerifiedPayerSet(true);
    }

    // ------------------------------------------------------------------
    // 결제
    // ------------------------------------------------------------------

    /// @notice 사람이 직접 내는 경로. 결제자가 `token.approve(gate, amount)`를 먼저 해 둔다.
    function pay(address token, uint256 amount, bytes32 ref) external nonReentrant {
        address responsible_ = _checkCommon(msg.sender, token, amount, ref);
        refPaid[ref] = true;

        uint256 before_ = _balanceOf(token, destination);
        _call(token, abi.encodeWithSelector(TRANSFER_FROM_SELECTOR, msg.sender, destination, amount));
        _checkReceived(token, before_, amount);

        emit Paid(ref, msg.sender, responsible_, msg.sender, token, amount);
    }

    /// @notice 에이전트 경로. `permissionContext`는 `abi.encode(Delegation[])`이며 위임은 정확히 1장,
    ///         그 위임의 수임자는 이 게이트여야 한다(DelegationManager가 확인).
    function payDelegated(bytes calldata permissionContext, address token, uint256 amount, bytes32 ref)
        external
        nonReentrant
    {
        Delegation[] memory delegations_ = abi.decode(permissionContext, (Delegation[]));
        if (delegations_.length != 1) revert InvalidDelegationChain(delegations_.length);
        address payer_ = delegations_[0].delegator;

        address responsible_ = _checkCommon(payer_, token, amount, ref);
        // 호출자 귀속 확인 — requireVerifiedPayer와 무관하게 항상
        if (responsible_ == address(0)) revert PayerNotAccountable(payer_);
        if (registry.ownerOf(msg.sender) != responsible_) revert CallerNotBound(msg.sender, responsible_);

        refPaid[ref] = true;
        uint256 before_ = _balanceOf(token, destination);

        bytes[] memory contexts_ = new bytes[](1);
        contexts_[0] = permissionContext;
        ModeCode[] memory modes_ = new ModeCode[](1);
        modes_[0] = ModeLib.encodeSimpleSingle();
        bytes[] memory executions_ = new bytes[](1);
        executions_[0] =
            ExecutionLib.encodeSingle(token, 0, abi.encodeWithSelector(TRANSFER_SELECTOR, destination, amount));
        // enforcer가 되돌리면 그 에러가 그대로 올라온다 (try/catch 없음)
        IDelegationManager(delegationManager).redeemDelegations(contexts_, modes_, executions_);

        _checkReceived(token, before_, amount);
        emit Paid(ref, payer_, responsible_, msg.sender, token, amount);
    }

    /// @notice 결제 계정의 책임자 — 도장이 있으면 자신, 아니면 레지스트리상 주인 (없으면 0)
    function responsibleOf(address payer) public view returns (address) {
        if (verifiedGate.isVerified(payer)) return payer;
        return registry.ownerOf(payer);
    }

    // ------------------------------------------------------------------
    // 관리
    // ------------------------------------------------------------------

    function setTokenAllowed(address token, bool allowed) external onlyAdmin {
        tokenAllowed[token] = allowed;
        emit TokenAllowedSet(token, allowed);
    }

    function setRequireVerifiedPayer(bool required) external onlyAdmin {
        requireVerifiedPayer = required;
        emit RequireVerifiedPayerSet(required);
    }

    // ------------------------------------------------------------------
    // 내부
    // ------------------------------------------------------------------

    /// @dev 공통 검사 1~5 (개발문서 2-4절 순서). 책임자를 돌려준다 (요구가 꺼져 있으면 0일 수 있음).
    function _checkCommon(address payer_, address token_, uint256 amount_, bytes32 ref_)
        internal
        view
        returns (address responsible_)
    {
        if (amount_ == 0) revert ZeroAmount();
        if (!tokenAllowed[token_]) revert TokenNotAllowed(token_);
        if (refPaid[ref_]) revert RefAlreadyPaid(ref_);
        responsible_ = responsibleOf(payer_);
        if (requireVerifiedPayer) {
            if (responsible_ == address(0)) revert PayerNotAccountable(payer_);
            if (!verifiedGate.isVerified(responsible_)) revert PayerNotVerified(responsible_);
        }
    }

    function _checkReceived(address token_, uint256 before_, uint256 amount_) internal view {
        uint256 received_ = _balanceOf(token_, destination) - before_;
        if (received_ != amount_) revert PaymentNotReceived(amount_, received_);
    }

    function _balanceOf(address token_, address who_) internal view returns (uint256) {
        (bool ok_, bytes memory ret_) = token_.staticcall(abi.encodeWithSelector(BALANCE_OF_SELECTOR, who_));
        if (!ok_ || ret_.length < 32) revert TokenCallFailed();
        return abi.decode(ret_, (uint256));
    }

    /// @dev 토큰 호출. 실패하면 원래 revert 데이터를 그대로 올린다 (ERC20InsufficientBalance 등).
    function _call(address token_, bytes memory data_) internal {
        (bool ok_, bytes memory ret_) = token_.call(data_);
        if (!ok_) {
            assembly ("memory-safe") {
                revert(add(ret_, 32), mload(ret_))
            }
        }
        if (ret_.length != 0 && !abi.decode(ret_, (bool))) revert TokenCallFailed();
    }
}
