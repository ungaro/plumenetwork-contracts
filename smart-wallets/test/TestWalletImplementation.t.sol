// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import { Test } from "forge-std/Test.sol";

import { Empty } from "../src/Empty.sol";
import { SmartWallet } from "../src/SmartWallet.sol";
import { TestWalletImplementation } from "../src/TestWalletImplementation.sol";
import { WalletFactory } from "../src/WalletFactory.sol";
import { WalletProxy } from "../src/WalletProxy.sol";
import { ISmartWallet } from "../src/interfaces/ISmartWallet.sol";

contract TestWalletImplementationTest is Test {

    address constant ADMIN_ADDRESS = 0xDE1509CC56D740997c70E1661BA687e950B4a241;
    bytes32 constant DEPLOY_SALT = keccak256("PlumeSmartWallets");

    /* forge coverage --ir-minimum */
    address constant EMPTY_ADDRESS = 0x0Ab1C3d2cCB7c314666185b317900a614e516feB;
    address constant WALLET_FACTORY_ADDRESS = 0x20bb256ADCDF463Cff377152FEa514d14A4464b7;
    address constant WALLET_PROXY_ADDRESS = 0x9CD5E3Ec9826647BBDBa85bBced53FB7aC8c13a0;

    /* forge test
    address constant EMPTY_ADDRESS = 0x14E90063Fb9d5F9a2b0AB941679F105C1A597C7C;
    address constant WALLET_FACTORY_ADDRESS = 0x69Fcc726062fE3d4a85621662419F01f44AaC3a3;
    address constant WALLET_PROXY_ADDRESS = 0x8b00A3552Ab0A39be5b8E14a6E832C8a26c19168;
    */
    TestWalletImplementation testWalletImplementation;

    // small hack to be excluded from coverage report
    function test() public { }

    function setUp() public {
        testWalletImplementation = new TestWalletImplementation();
    }

    function test_setters() public {
        assertEq(testWalletImplementation.value(), 0);
        testWalletImplementation.setValue(123);
        assertEq(testWalletImplementation.value(), 123);
    }

    function test_upgrade() public {
        vm.startPrank(ADMIN_ADDRESS);

        Empty empty = new Empty{ salt: DEPLOY_SALT }();
        WalletFactory walletFactory =
            new WalletFactory{ salt: DEPLOY_SALT }(ADMIN_ADDRESS, ISmartWallet(address(empty)));
        WalletProxy walletProxy = new WalletProxy{ salt: DEPLOY_SALT }(walletFactory);

        assertEq(address(empty), EMPTY_ADDRESS);
        assertEq(address(walletFactory), WALLET_FACTORY_ADDRESS);
        assertEq(address(walletProxy), WALLET_PROXY_ADDRESS);

        SmartWallet smartWallet = new SmartWallet();
        vm.expectEmit(false, false, false, true, address(walletFactory));
        emit WalletFactory.Upgraded(smartWallet);
        walletFactory.upgrade(smartWallet);
        assertEq(address(walletFactory.smartWallet()), address(smartWallet));

        // Must use low-level calls for smart wallets
        (bool success,) =
            ADMIN_ADDRESS.call(abi.encodeWithSelector(ISmartWallet.upgrade.selector, address(testWalletImplementation)));
        assertEq(success, true);

        vm.stopPrank();
    }

}
