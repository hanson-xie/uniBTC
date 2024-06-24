pragma solidity ^0.8.9;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

interface IMintableContract is IERC20 {
    function mint(address account, uint256 amount) external;
    function burn(uint256 amount) external;
    function burnFrom(address account, uint256 amount) external;
}

interface ISGNFeeQuerier {
    function feeBase() external view returns (uint256);
    function feePerByte() external view returns (uint256);
}