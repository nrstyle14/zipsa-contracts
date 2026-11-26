// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import {Script, console} from "forge-std/Script.sol";

import {RefillThresholdEnforcer} from "../src/enforcers/RefillThresholdEnforcer.sol";
import {BoundDelegatorEnforcer} from "../src/enforcers/BoundDelegatorEnforcer.sol";

/// @notice F1 자동 충전 enforcer 2종 배포 — `RefillThresholdEnforcer`, `BoundDelegatorEnforcer`.
///
/// 사용 (값은 직접 넣지 말고 환경변수로):
///   forge script script/DeployRefill.s.sol --rpc-url "$RPC_URL" --broadcast
///
/// 환경변수:
///   PRIVATE_KEY       배포 키 (기존 DeployErc7710.s.sol 과 같은 이름)
///   RPC_URL           배포 대상 RPC (명령의 --rpc-url 로만 쓴다)
///   GATE_ADDRESS      이미 배포된 Dojang 게이트 — terms 에 들어갈 값이라 코드 존재만 확인한다
///   REGISTRY_ADDRESS  이미 배포된 OwnerBindingRegistry — 같은 이유로 코드 존재만 확인한다
///
/// @dev 두 enforcer 는 생성자 인자가 없고 상태도 없다. 게이트·레지스트리·토큰은 위임마다
///      terms 로 넘기므로 배포 시점에 묶이지 않는다. 여기서 주소를 받는 것은 잘못된 네트워크에
///      배포하는 실수를 막기 위한 사전 확인뿐이다.
///
///      충전 위임 묶음에 필요한 `LimitedCallsEnforcer`(프레임워크 원본)는 이 스크립트가 배포하지 않는다.
contract DeployRefill is Script {
    error NoCodeAt(string name, address target);

    function run() external {
        address gate_ = vm.envAddress("GATE_ADDRESS");
        address registry_ = vm.envAddress("REGISTRY_ADDRESS");
        if (gate_.code.length == 0) revert NoCodeAt("GATE_ADDRESS", gate_);
        if (registry_.code.length == 0) revert NoCodeAt("REGISTRY_ADDRESS", registry_);

        uint256 pk_ = vm.envUint("PRIVATE_KEY");
        console.log("chainId:                   ", block.chainid);
        console.log("deployer:                  ", vm.addr(pk_));
        console.log("DojangVerifiedGate (terms):", gate_);
        console.log("OwnerBindingRegistry (terms):", registry_);

        vm.startBroadcast(pk_);
        RefillThresholdEnforcer refill_ = new RefillThresholdEnforcer();
        BoundDelegatorEnforcer bound_ = new BoundDelegatorEnforcer();
        vm.stopBroadcast();

        console.log("RefillThresholdEnforcer:   ", address(refill_));
        console.log("BoundDelegatorEnforcer:    ", address(bound_));
        console.log("");
        console.log("Next: put both addresses in packages/delegation/src/addresses.ts (ADDR_F1) and README.");
    }
}
