// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import {Script, console} from "forge-std/Script.sol";

import {PaymentGate} from "../src/PaymentGate.sol";
import {IVerifiedGate} from "../src/interfaces/IVerifiedGate.sol";
import {OwnerBindingRegistry} from "../src/OwnerBindingRegistry.sol";

/// @notice 결제 게이트(M2-1) 배포 + 허용 토큰 설정. 관리자는 배포자.
///
/// 사용 (값은 직접 넣지 말고 환경변수로):
///   forge script script/DeployPaymentGate.s.sol --rpc-url "$RPC_URL" --broadcast \
///     --verify --verifier blockscout --verifier-url https://sepolia-explorer.giwa.io/api/
///
/// 환경변수:
///   PRIVATE_KEY         배포 키
///   GATE_ADDRESS        DojangVerifiedGate
///   REGISTRY_ADDRESS    OwnerBindingRegistry
///   DELEGATION_MANAGER  DelegationManager (프레임워크 v1.3.0)
///   DESTINATION         상점 수신처 — 바꿀 수 없다
///   TOKEN_ADDRESS       허용할 토큰 (tKRW)
///
/// @dev GIWA Sepolia(91342)가 아니면 배포하지 않는다. 다른 체인에 실수로 배포하는 것을 막는다.
contract DeployPaymentGate is Script {
    uint256 constant GIWA_SEPOLIA = 91342;

    error WrongChain(uint256 chainId);
    error NoCodeAt(string name, address target);

    function run() external returns (PaymentGate gate_) {
        if (block.chainid != GIWA_SEPOLIA) revert WrongChain(block.chainid);

        address verified_ = vm.envAddress("GATE_ADDRESS");
        address registry_ = vm.envAddress("REGISTRY_ADDRESS");
        address manager_ = vm.envAddress("DELEGATION_MANAGER");
        address destination_ = vm.envAddress("DESTINATION");
        address token_ = vm.envAddress("TOKEN_ADDRESS");
        if (verified_.code.length == 0) revert NoCodeAt("GATE_ADDRESS", verified_);
        if (registry_.code.length == 0) revert NoCodeAt("REGISTRY_ADDRESS", registry_);
        if (manager_.code.length == 0) revert NoCodeAt("DELEGATION_MANAGER", manager_);
        if (token_.code.length == 0) revert NoCodeAt("TOKEN_ADDRESS", token_);

        uint256 pk_ = vm.envUint("PRIVATE_KEY");
        address admin_ = vm.addr(pk_);
        console.log("chainId:            ", block.chainid);
        console.log("deployer (admin):   ", admin_);
        console.log("destination (fixed):", destination_);

        vm.startBroadcast(pk_);
        gate_ = new PaymentGate(
            IVerifiedGate(verified_), OwnerBindingRegistry(registry_), manager_, destination_, admin_
        );
        gate_.setTokenAllowed(token_, true);
        vm.stopBroadcast();

        console.log("PaymentGate:        ", address(gate_));
        console.log("Next: put the address in packages/delegation/src/addresses.ts (ADDR_M2.paymentGate) and README.");
    }
}
