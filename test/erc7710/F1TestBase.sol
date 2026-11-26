// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import {Test} from "forge-std/Test.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import {IEntryPoint} from "@account-abstraction/interfaces/IEntryPoint.sol";
import {ModeLib} from "@erc7579/lib/ModeLib.sol";
import {ExecutionLib} from "@erc7579/lib/ExecutionLib.sol";

import {DelegationManager} from "delegation-framework/src/DelegationManager.sol";
import {IDelegationManager} from "delegation-framework/src/interfaces/IDelegationManager.sol";
import {EIP7702StatelessDeleGator} from "delegation-framework/src/EIP7702/EIP7702StatelessDeleGator.sol";
import {EncoderLib} from "delegation-framework/src/libraries/EncoderLib.sol";
import {Delegation, Caveat, ModeCode} from "delegation-framework/src/utils/Types.sol";
import {ERC20PeriodTransferEnforcer} from "delegation-framework/src/enforcers/ERC20PeriodTransferEnforcer.sol";
import {ERC20TransferAmountEnforcer} from "delegation-framework/src/enforcers/ERC20TransferAmountEnforcer.sol";
import {LimitedCallsEnforcer} from "delegation-framework/src/enforcers/LimitedCallsEnforcer.sol";
import {TimestampEnforcer} from "delegation-framework/src/enforcers/TimestampEnforcer.sol";

import {JipsaSettlementToken} from "../../src/JipsaSettlementToken.sol";
import {MockVerifiedGate} from "../../src/gates/MockVerifiedGate.sol";
import {OwnerBindingRegistry} from "../../src/OwnerBindingRegistry.sol";
import {JipsaPerTxCapEnforcer} from "../../src/enforcers/JipsaPerTxCapEnforcer.sol";
import {RefillThresholdEnforcer} from "../../src/enforcers/RefillThresholdEnforcer.sol";
import {BoundDelegatorEnforcer} from "../../src/enforcers/BoundDelegatorEnforcer.sol";

/// @notice F1 테스트 공통 셋업 — 계정 셋과 충전·지출 위임 caveat 묶음.
///
/// @dev 메인 지갑(주인, 도장, 7702) ─충전 위임(ANY_DELEGATE)→ 지출용 계정(7702, 주인에게 바인딩)
///      ─지출 위임→ 에이전트(주인에게 바인딩). 두 위임은 서명 키가 다르고(메인 / 지출용) 해시가
///      달라 기간·횟수 카운터가 서로 독립이다. caveat 순서는 docs/design/F1_Refill.md 2·4절.
abstract contract F1TestBase is Test {
    JipsaSettlementToken token;
    JipsaSettlementToken otherToken;
    MockVerifiedGate gate;
    OwnerBindingRegistry registry;
    DelegationManager delegationManager;
    EIP7702StatelessDeleGator deleGatorImpl;

    TimestampEnforcer timestamps;
    RefillThresholdEnforcer refillThreshold;
    ERC20PeriodTransferEnforcer periodCap;
    LimitedCallsEnforcer limitedCalls;
    JipsaPerTxCapEnforcer perTxCap;
    ERC20TransferAmountEnforcer totalBudget;
    BoundDelegatorEnforcer boundDelegator;

    address main;
    uint256 mainPk;
    address spending;
    uint256 spendingPk;
    address agent = makeAddr("agent");
    address merchant = makeAddr("merchant");
    address keeper = makeAddr("keeper");
    address stranger = makeAddr("stranger");
    address sink = makeAddr("sink");

    // 충전 위임
    uint256 constant FUNDING = 100_000e6;
    uint256 constant THRESHOLD = 300e6;
    uint256 constant REFILL = 500e6;
    uint256 constant PERIOD_CAP = 1_000e6; // 하루 2회분
    uint256 constant PERIOD = 1 days;
    uint256 constant MAX_REFILLS = 5;

    // 지출 위임
    uint256 constant SPEND_PER_TX = 200e6;
    uint256 constant SPEND_PERIOD_CAP = 5_000e6;
    uint256 constant SPEND_TOTAL = 50_000e6;

    uint64 expiry;
    uint256 startDate;

    function setUp() public virtual {
        (main, mainPk) = makeAddrAndKey("main");
        (spending, spendingPk) = makeAddrAndKey("spending");
        expiry = uint64(block.timestamp + 30 days);
        startDate = block.timestamp;

        token = new JipsaSettlementToken();
        otherToken = new JipsaSettlementToken();
        gate = new MockVerifiedGate();
        registry = new OwnerBindingRegistry(gate);
        delegationManager = new DelegationManager(address(this));
        deleGatorImpl = new EIP7702StatelessDeleGator(
            IDelegationManager(address(delegationManager)), IEntryPoint(makeAddr("entryPoint"))
        );

        timestamps = new TimestampEnforcer();
        refillThreshold = new RefillThresholdEnforcer();
        periodCap = new ERC20PeriodTransferEnforcer();
        limitedCalls = new LimitedCallsEnforcer();
        perTxCap = new JipsaPerTxCapEnforcer();
        totalBudget = new ERC20TransferAmountEnforcer();
        boundDelegator = new BoundDelegatorEnforcer();

        _etch7702(main);
        _etch7702(spending);

        gate.setVerified(main, true);
        gate.setVerified(merchant, true);
        // D5: 지출용 계정을 에이전트와 같은 방식으로 바인딩 (주인 제안 → 지출용 계정 수락)
        _bind(main, spending);
        _bind(main, agent);

        token.mint(main, FUNDING);
        otherToken.mint(main, FUNDING);
    }

    // ---------- 계정 ----------

    function _etch7702(address account_) internal {
        vm.etch(account_, bytes.concat(hex"ef0100", abi.encodePacked(address(deleGatorImpl))));
    }

    function _bind(address owner_, address account_) internal {
        vm.prank(owner_);
        registry.proposeBinding(account_);
        vm.prank(account_);
        registry.acceptBinding(owner_);
    }

    // ---------- 서명·리딤 ----------

    function _sign(uint256 pk_, Delegation memory d_) internal view returns (Delegation memory) {
        bytes32 typedDataHash_ = MessageHashUtils.toTypedDataHash(
            delegationManager.getDomainHash(), EncoderLib._getDelegationHash(d_)
        );
        (uint8 v_, bytes32 r_, bytes32 s_) = vm.sign(pk_, typedDataHash_);
        d_.signature = abi.encodePacked(r_, s_, v_);
        return d_;
    }

    function _redeem(address caller_, Delegation memory d_, bytes memory executionCallData_) internal {
        Delegation[] memory ds_ = new Delegation[](1);
        ds_[0] = d_;
        bytes[] memory execs_ = new bytes[](1);
        execs_[0] = executionCallData_;
        _redeemBatch(caller_, ds_, execs_);
    }

    /// @dev 배치 항목마다 위임 1장(체인 길이 1). 항목 i는 before → 실행 → after를 끝낸 뒤 i+1로 간다.
    function _redeemBatch(address caller_, Delegation[] memory ds_, bytes[] memory execs_) internal {
        uint256 n_ = ds_.length;
        bytes[] memory permissionContexts_ = new bytes[](n_);
        ModeCode[] memory modes_ = new ModeCode[](n_);
        for (uint256 i = 0; i < n_; i++) {
            Delegation[] memory chain_ = new Delegation[](1);
            chain_[0] = ds_[i];
            permissionContexts_[i] = abi.encode(chain_);
            modes_[i] = ModeLib.encodeSimpleSingle();
        }

        vm.prank(caller_);
        delegationManager.redeemDelegations(permissionContexts_, modes_, execs_);
    }

    function _transferExec(address to_, uint256 amount_) internal view returns (bytes memory) {
        return ExecutionLib.encodeSingle(address(token), 0, abi.encodeWithSelector(token.transfer.selector, to_, amount_));
    }

    // ---------- 충전 위임 ----------

    function _refillTerms(address spender_) internal view returns (bytes memory) {
        return abi.encode(address(gate), address(registry), address(token), spender_, THRESHOLD, REFILL);
    }

    /// @dev ① 만료 ② RefillThreshold ③ 기간 한도 ④ 총 횟수
    function _refillCaveats(address spender_, uint256 periodCap_, uint256 maxRefills_)
        internal
        view
        returns (Caveat[] memory c_)
    {
        c_ = new Caveat[](4);
        c_[0] = Caveat({
            enforcer: address(timestamps), terms: abi.encodePacked(uint128(0), uint128(expiry)), args: hex""
        });
        c_[1] = Caveat({enforcer: address(refillThreshold), terms: _refillTerms(spender_), args: hex""});
        c_[2] = Caveat({
            enforcer: address(periodCap),
            terms: abi.encodePacked(address(token), periodCap_, PERIOD, startDate),
            args: hex""
        });
        c_[3] = Caveat({enforcer: address(limitedCalls), terms: abi.encodePacked(maxRefills_), args: hex""});
    }

    function _signRefill(Caveat[] memory caveats_, uint256 salt_) internal view returns (Delegation memory) {
        return _sign(
            mainPk,
            Delegation({
                delegate: delegationManager.ANY_DELEGATE(),
                delegator: main,
                authority: delegationManager.ROOT_AUTHORITY(),
                caveats: caveats_,
                salt: salt_,
                signature: hex""
            })
        );
    }

    /// @dev 기본 충전 위임: 지출용 계정, 기간 한도 PERIOD_CAP, 총 MAX_REFILLS회
    function _refillDelegation() internal view returns (Delegation memory) {
        return _signRefill(_refillCaveats(spending, PERIOD_CAP, MAX_REFILLS), 0);
    }

    function _refillExec() internal view returns (bytes memory) {
        return _transferExec(spending, REFILL);
    }

    // ---------- 지출 위임 ----------

    function _boundTerms(bool verifiedRecipientOnly_) internal view returns (bytes memory) {
        return abi.encode(address(gate), address(registry), address(token), verifiedRecipientOnly_);
    }

    /// @dev ① 만료 ② 건당 ③ 기간 ④ 총액 ⑤ BoundDelegator
    function _spendCaveats(bool verifiedRecipientOnly_) internal view returns (Caveat[] memory c_) {
        c_ = new Caveat[](5);
        c_[0] = Caveat({
            enforcer: address(timestamps), terms: abi.encodePacked(uint128(0), uint128(expiry)), args: hex""
        });
        c_[1] = Caveat({enforcer: address(perTxCap), terms: abi.encodePacked(address(token), SPEND_PER_TX), args: hex""});
        c_[2] = Caveat({
            enforcer: address(periodCap),
            terms: abi.encodePacked(address(token), SPEND_PERIOD_CAP, PERIOD, startDate),
            args: hex""
        });
        c_[3] = Caveat({enforcer: address(totalBudget), terms: abi.encodePacked(address(token), SPEND_TOTAL), args: hex""});
        c_[4] = Caveat({enforcer: address(boundDelegator), terms: _boundTerms(verifiedRecipientOnly_), args: hex""});
    }

    function _signSpend(uint256 delegatorPk_, address delegator_, address delegate_, Caveat[] memory caveats_)
        internal
        view
        returns (Delegation memory)
    {
        return _sign(
            delegatorPk_,
            Delegation({
                delegate: delegate_,
                delegator: delegator_,
                authority: delegationManager.ROOT_AUTHORITY(),
                caveats: caveats_,
                salt: 0,
                signature: hex""
            })
        );
    }

    /// @dev 기본 지출 위임: 지출용 계정 → 에이전트, 수신처 도장 필수
    function _spendDelegation() internal view returns (Delegation memory) {
        return _signSpend(spendingPk, spending, agent, _spendCaveats(true));
    }

    // ---------- 잔액 조작 ----------

    /// @dev 지출용 계정 잔액을 정확히 `target_`로 맞춘다 (지출 경로를 대신해 직접 송금·민팅)
    function _setSpendingBalance(uint256 target_) internal {
        uint256 bal_ = token.balanceOf(spending);
        if (bal_ > target_) {
            vm.prank(spending);
            assertTrue(token.transfer(sink, bal_ - target_));
        } else if (bal_ < target_) {
            token.mint(spending, target_ - bal_);
        }
    }
}
