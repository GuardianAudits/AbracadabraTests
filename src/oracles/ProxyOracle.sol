// SPDX-License-Identifier: MIT
pragma solidity >=0.8.0;

import "BoringSolidity/interfaces/IERC20.sol";
import "BoringSolidity/BoringOwnable.sol";
import "interfaces/IOracle.sol";
import "forge-std/Test.sol";

/// @title ProxyOracle
/// @author 0xMerlin
/// @notice Oracle used for getting the price of an oracle implementation
contract ProxyOracle is IOracle, BoringOwnable {
    IOracle public oracleImplementation;

    uint256 public mockPrice;

    event LogOracleImplementationChange(IOracle indexed oldOracle, IOracle indexed newOracle);

    function setMockPrice(uint256 _mockPrice) external {
        console.log("CALLED SET");
        mockPrice = _mockPrice;
    }

    function changeOracleImplementation(IOracle newOracle) external onlyOwner {
        IOracle oldOracle = oracleImplementation;
        oracleImplementation = newOracle;
        emit LogOracleImplementationChange(oldOracle, newOracle);
    }

    function decimals() external view returns (uint8) {
        return oracleImplementation.decimals();
    }

    // Get the latest exchange rate
    /// @inheritdoc IOracle
    function get(bytes calldata data) public override returns (bool, uint256) {
        if (mockPrice != 0) return (true, mockPrice);
        return oracleImplementation.get(data);
    }

    // Check the last exchange rate without any state changes
    /// @inheritdoc IOracle
    function peek(bytes calldata data) public view override returns (bool, uint256) {
        if (mockPrice != 0) return (true, mockPrice);
        return oracleImplementation.peek(data);
    }

    // Check the current spot exchange rate without any state changes
    /// @inheritdoc IOracle
    function peekSpot(bytes calldata data) external view override returns (uint256 rate) {
        if (mockPrice != 0) return mockPrice;
        return oracleImplementation.peekSpot(data);
    }

    /// @inheritdoc IOracle
    function name(bytes calldata) public pure override returns (string memory) {
        return "Proxy Oracle";
    }

    /// @inheritdoc IOracle
    function symbol(bytes calldata) public pure override returns (string memory) {
        return "Proxy";
    }
}
