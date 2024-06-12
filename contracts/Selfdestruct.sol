// https://ethereum.stackexchange.com/a/145050
pragma solidity ^0.8;

contract Selfdestruct {
    fallback() external payable {
        selfdestruct(payable(tx.origin));
    }
}