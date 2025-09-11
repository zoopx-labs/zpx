// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/**
 * @title Create2Deployer
 * @dev Minimal CREATE2 deployer for deterministic contract addresses.
 */
contract Create2Deployer {
    /**
     * @dev Emitted when a contract is deployed using CREATE2
     * @param addr Deployed contract address
     * @param salt Salt used for deployment
     */
    event Deployed(address indexed addr, bytes32 indexed salt);

    /**
     * @notice Deploy `bytecode` using CREATE2 and `salt`.
     * @dev Reverts if deployment fails.
     * @param salt Salt used for CREATE2
     * @param bytecode Contract creation bytecode
     * @return addr Deployed contract address
     */
    function deploy(bytes32 salt, bytes memory bytecode) external returns (address addr) {
        assembly {
            let encoded_data := add(bytecode, 0x20)
            let encoded_size := mload(bytecode)
            addr := create2(0, encoded_data, encoded_size, salt)
        }
        require(addr != address(0), "Create2Deployer: deploy failed");
        emit Deployed(addr, salt);
    }

    /**
     * @notice Compute the CREATE2 address for given salt and bytecode hash.
     * @param salt Salt used for CREATE2
     * @param bytecodeHash keccak256 hash of the creation bytecode
     * @return addr Computed contract address
     */
    function computeAddress(bytes32 salt, bytes32 bytecodeHash) external view returns (address addr) {
        // keccak256(0xff ++ address(this) ++ salt ++ keccak256(bytecode))[12:]
        bytes32 data = keccak256(abi.encodePacked(bytes1(0xff), address(this), salt, bytecodeHash));
        addr = address(uint160(uint256(data)));
    }
}
