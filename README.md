# Ethernaut Motorbike Solution (After Decun Upgrade)
Following the Decun upgrade, the `selfdestruct` opcode behavior has been modified (EIP-6780). This change means that the selfdestruct no longer removes the contract code from the blockchain, rendering the Motorbike challenge seemingly unsolvable. However, there is a new approach to tackle this, which we will outline in this write-up.

## The solution before the upgrade

> Ethernaut's motorbike has a brand-new upgradeable engine design.
>
> Would you be able to `selfdestruct` its engine and make the motorbike unusable?

### Analysis

Our goal is to `selfdestruct` the `Engine`. Let's look at it first.

There are only 2 external/public functions: `initialize` and `upgradeAndCall`. Since the `upgradeAndCall` function looks more interesting, let's examine it first.

![Engine](./images/Engine.png)

#### `upgradeAndCall`

The function first calls `_authorizeUpgrade()`, which will check if `msg.sender == upgrader`. So we need to control `upgrader` to make it ourself. There is only one place that we can control it: `initialize`. Let's examine it.

```solidity
// Upgrade the implementation of the proxy to `newImplementation`
// subsequently execute the function call
function upgradeToAndCall(address newImplementation, bytes memory data) external payable {
    _authorizeUpgrade();
    _upgradeToAndCall(newImplementation, data);
}

// Restrict to upgrader role
function _authorizeUpgrade() internal view {
    require(msg.sender == upgrader, "Can't upgrade");
}
```

#### `initialize`

The `initialize` function has an [`initializer` modifier](https://github.com/OpenZeppelin/openzeppelin-contracts/blob/v3.4.2/contracts/proxy/Initializable.sol#L36), which will check if the contract is initialized yet. In this case, it's not, so we can make the `upgrader` ourselves. Let's go back to the `upgradeAndCall` function.

```solidity
function initialize() external initializer {
    horsePower = 1000;
    upgrader = msg.sender;
}
```

```solidity
contract Initializable {
  bool private initialized;
  // [...]
  modifier initializer() {
    require(_initializing || _isConstructor() || !_initialized, "Initializable: contract is already initialized");
  }
  // [...]
}
```

```shell
# check if it's initialized or not
> cast storage $ENGINE -r $RPC 0x0
0x0000000000000000000000000000000000000000000000000000000000000000
```

#### `upgradeAndCall`

The `upgradeToAndCall` then calls `_upgradeToAndCall`, which will delegate the call to `newImplementation` which we control. So if we set `newImplementation` to a contract that will call `selfdestruct`, the challenge will be solved.

```solidity
// Upgrade the implementation of the proxy to `newImplementation`
// subsequently execute the function call
function upgradeToAndCall(address newImplementation, bytes memory data) external payable {
    _authorizeUpgrade();
    _upgradeToAndCall(newImplementation, data);
}

// Perform implementation upgrade with security checks for UUPS proxies, and additional setup call.
function _upgradeToAndCall(address newImplementation, bytes memory data) internal {
    // Initial upgrade and setup call
    _setImplementation(newImplementation);
    if (data.length > 0) {
        (bool success,) = newImplementation.delegatecall(data);
        require(success, "Call failed");
    }
}
```

## The solution after the upgrade

The `selfdestruct` function will no longer remove the contract code after the upgrade, so the above solution will not work.

If we take a look into [EIP-6780](https://eips.ethereum.org/EIPS/eip-6780):

> This EIP changes the functionality of the `SELFDESTRUCT` opcode. The new functionality will be only to send all Ether in the account to the target, except that the current behaviour is preserved when `SELFDESTRUCT` is called in the same transaction a contract was created.

So, we can still delete the `Engine` contract code if it's within the same transaction of its creation. 

When is the `Engine` contract code created? It is created when you hit the `Get new instance` button. But how can we make it to be in the same transaction as our solve script? We can use a contract! 

I'm going to create a contract that does the following:

1. Create the `Motorbike` level instance.
2. Solve it using the above solution.
3. Submit the instance.

To do so, we need to inspect the Ethernaut's code.

### Ethernaut

#### [`createLevelInstance`](https://github.com/OpenZeppelin/ethernaut/blob/c8ad2e45f6ce11d2d66fb699f07ffee1ab275577/contracts/src/Ethernaut.sol#L51-L65)

It will first check if the level exists. In our case, it is [Motorbike Factory](https://github.com/OpenZeppelin/ethernaut/blob/c8ad2e45f6ce11d2d66fb699f07ffee1ab275577/contracts/src/levels/MotorbikeFactory.sol). Next, it will call `_level.createInstance` and return the **instance address**, which we need to keep track of.

From now on, our goal is to get the instance address. The `instance` is not returned from `createLevelInstance`, so we must look elsewhere. Notice that all of this needs to be done on-chain since we need to make all of these within one transaction. The next line `emittedInstances[instance]` is useless for us. The last line `emit LevelInstanceCreatedLog` will emit the instance address, but it is still useless since we can't get the event log on-chain as stated in the below document. So the only place left is `statistics.createNewInstance`. Let's examine it.

```solidity
function createLevelInstance(Level _level) public payable {
    // Ensure level is registered.
    require(registeredLevels[address(_level)], "This level doesn't exists");

    // Get level factory to create an instance.
    address instance = _level.createInstance{value: msg.value}(msg.sender);

    // Store emitted instance relationship with player and level.
    emittedInstances[instance] = EmittedInstanceData(msg.sender, _level, false);

    statistics.createNewInstance(instance, address(_level), msg.sender);

    // Retrieve created instance via logs.
    emit LevelInstanceCreatedLog(msg.sender, instance, address(_level));
}
```

> ##### Events
>
> These logs are associated with the address of the contract that emitted them, are incorporated into the blockchain, and stay there as long as a block is accessible (forever as of now, but this might change in the future). The Log and its event data are not accessible from within contracts (not even from the contract that created them).
>
> https://docs.soliditylang.org/en/latest/contracts.html#events

#### [`statistics.createNewInstance`](https://github.com/OpenZeppelin/ethernaut/blob/c8ad2e45f6ce11d2d66fb699f07ffee1ab275577/contracts/src/metrics/Statistics.sol#L69-L94)

Look at `playerStats[player][level] = LevelInstance(instance,...)`. It look promising! But `playerStats` is private so we can not access it on-chain. So it looks impossible to get the instance address. Is there any other way to get the instance address on-chain?

```solidity
mapping(address => mapping(address => LevelInstance)) private playerStats;
// [...]
function createNewInstance(address instance, address level, address player)
    external
    onlyEthernaut
    levelExistsCheck(level)
{
    if (!doesPlayerExist(player)) {
        players.push(player);
        playerExists[player] = true;
    }
    // If it is the first instance of the level
    if (playerStats[player][level].instance == address(0)) {
        levelFirstInstanceCreationTime[player][level] = block.timestamp;
    }
    playerStats[player][level] = LevelInstance(
        instance,
        false,
        block.timestamp,
        0,
        playerStats[player][level].timeSubmitted.length != 0
            ? playerStats[player][level].timeSubmitted
            : new uint256[](0)
    );
    levelStats[level].noOfInstancesCreated++;
    globalNoOfInstancesCreated++;
    globalNoOfInstancesCreatedByPlayer[player]++;
}
```

#### Calculate address ourselves

The address of the deployed contract is actually predictable! If we take a look at the [Ethereum Yellow Paper](https://ethereum.github.io/yellowpaper/paper.pdf), `7. Contract Creation`, it reads:

> The address of the new account is defined as being the rightmost 160 bits of the Keccak-256 hash of the [RLP encoding](https://ethereum.org/en/developers/docs/data-structures-and-encoding/rlp/) of the structure containing only the sender and the account nonce.

There is already an [MIT-licensed Solidity code for us to use to predict the address](https://github.com/OoXooOx/Predict-smart-contract-address/blob/main/AddressPredictorCreateOpcode.sol)! By the way, the code generated by ChatGPT does not work.

The `computeCreateAddress(address deployer, uint256 nonce)` function takes two parameters: `deployer`, which we already have, and `nonce`. The [post](https://ethereum.stackexchange.com/questions/2701/do-the-contracts-of-ethereum-have-the-access-to-the-nonce-of-the-blocks) states that we can not get `nonce` on-chain. It's technically correct, but the nonce can be actually inferred!

##### Get nonce on-chain

We can check [if an address is a contract](https://ethereum.stackexchange.com/questions/15641/how-does-a-contract-find-out-if-another-address-is-a-contract), so we can do something like the below, which tries all the possible nonce and generates addresses based on it until it gets to an address that is not a contract. But it will cost us a lot of gas.

```solidity
function getNonce(address _addr) public view returns (uint256 nonce) {
    for (; ; nonce = nonce + 1) {
        address contractAddress = computeCreateAddress(_addr, nonce);
        if (!isContract(contractAddress)) return nonce;
    }
}
function isContract(address _addr) public view returns (bool) {
    uint32 size;
    assembly {
        size := extcodesize(_addr)
    }
    return (size > 0);
}
function computeCreateAddress(address deployer, uint256 nonce) public pure returns (address);
```

We got all we needed to solve the challenge! Let's start exploiting!

### Exploitation

See [contracts/Exploit.sol](https://github.com/Ching367436/ethernaut-motorbike-solution-after-decun-upgrade/blob/main/contracts/Exploit.sol).
My successful exploitation tx is [here](https://sepolia.etherscan.io/tx/0x6501dc5cbaf7e7851462bae7c675bfc8bfdda672966e446f3a377f0e1f917156).
