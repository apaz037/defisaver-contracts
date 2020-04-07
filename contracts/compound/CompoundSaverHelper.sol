pragma solidity ^0.5.0;

import "./helpers/CEtherInterface.sol";
import "../interfaces/CTokenInterface.sol";
import "./helpers/ComptrollerInterface.sol";
import "../mcd/Discount.sol";
import "../DS/DSMath.sol";
import "../DS/DSProxy.sol";

contract CompoundOracle {
    function getUnderlyingPrice(address cToken) external view returns (uint);
}

contract CompoundSaverHelper is DSMath {

    address payable public constant WALLET_ID = 0x322d58b9E75a6918f7e7849AEe0fF09369977e08;
    address public constant DISCOUNT_ADDRESS = 0x1b14E8D511c9A4395425314f849bD737BAF8208F;

    uint public constant SERVICE_FEE = 400; // 0.25% Fee
    address public constant ETH_ADDRESS = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;
    address public constant CETH_ADDRESS = 0x4Ddc2D193948926D02f9B1fE9e1daa0718270ED5;
    address public constant COMPTROLLER = 0x3d9819210A31b4961b30EF54bE2aeD79B9c9Cd3B;

    address public constant COMPOUND_LOGGER = 0x3DD0CDf5fFA28C6847B4B276e2fD256046a44bb7;
    address public constant COMPOUND_ORACLE = 0x1D8aEdc9E924730DD3f9641CDb4D1B92B848b4bd;

    /// @notice Helper method to payback the Compound debt
    function paybackDebt(uint _amount, address _cBorrowToken, address _borrowToken, address _user) internal {
        uint wholeDebt = CTokenInterface(_cBorrowToken).borrowBalanceCurrent(address(this));

        if (_amount > wholeDebt) {
            ERC20(_borrowToken).transfer(_user, (_amount - wholeDebt));
            _amount = wholeDebt;
        }

        approveCToken(_borrowToken, _cBorrowToken);

        if (_borrowToken == ETH_ADDRESS) {
            CEtherInterface(_cBorrowToken).repayBorrow.value(_amount)();
        } else {
            require(CTokenInterface(_cBorrowToken).repayBorrow(_amount) == 0);
        }
    }

    /// @notice Calculates the fee amount
    /// @param _amount Amount that is converted
    function getFee(uint _amount, address _user, address _tokenAddr) internal returns (uint feeAmount) {
        uint fee = SERVICE_FEE;

        if (Discount(DISCOUNT_ADDRESS).isCustomFeeSet(_user)) {
            fee = Discount(DISCOUNT_ADDRESS).getCustomServiceFee(_user);
        }

        feeAmount = (fee == 0) ? 0 : (_amount / fee);

        // fee can't go over 20% of the whole amount
        if (feeAmount > (_amount / 5)) {
            feeAmount = _amount / 5;
        }

        ERC20(_tokenAddr).transfer(WALLET_ID, feeAmount);
    }

    /// @notice Enters the market for the collatera and borrow tokens
    function enterMarket(address _cTokenAddrColl, address _cTokenAddrBorrow) internal {
        address[] memory markets = new address[](2);
        markets[0] = _cTokenAddrColl;
        markets[1] = _cTokenAddrBorrow;

        ComptrollerInterface(COMPTROLLER).enterMarkets(markets);
    }

    /// @notice Approves CToken contract to pull underlying tokens from the DSProxy
    function approveCToken(address _tokenAddr, address _cTokenAddr) internal {
        if (_tokenAddr != ETH_ADDRESS) {
            ERC20(_tokenAddr).approve(_cTokenAddr, uint(-1));
        }
    }

    /// @notice Returns the underlying address of the cToken asset
    function getUnderlyingAddr(address _cTokenAddress) internal returns (address) {
        if (_cTokenAddress == CETH_ADDRESS) {
            return ETH_ADDRESS;
        } else {
            return CTokenInterface(_cTokenAddress).underlying();
        }
    }

    /// @notice Returns the owner of the DSProxy that called the contract
    function getUserAddress() internal view returns (address) {
        DSProxy proxy = DSProxy(uint160(address(this)));

        return proxy.owner();
    }

    /// @notice Returns the maximum amount of collateral available to withdraw
    /// @dev Due to rounding errors the result is - 1% wei from the exact amount
    function getMaxCollateral(address _cCollAddress) public returns (uint) {
        (, uint liquidityInEth, ) = ComptrollerInterface(COMPTROLLER).getAccountLiquidity(address(this));
        uint usersBalance = CTokenInterface(_cCollAddress).balanceOfUnderlying(address(this));

        if (liquidityInEth == 0) return usersBalance;

        if (_cCollAddress == CETH_ADDRESS) {
            if (liquidityInEth > usersBalance) return usersBalance;

            return liquidityInEth;
        }

        uint ethPrice = CompoundOracle(COMPOUND_ORACLE).getUnderlyingPrice(_cCollAddress);
        uint liquidityInToken = wdiv(liquidityInEth, ethPrice);

        if (liquidityInToken > usersBalance) return usersBalance;

        return sub(liquidityInToken, (liquidityInToken / 100)); // cut off 1% due to rounding issues
    }

    /// @notice Returns the maximum amount of borrow amount available
    /// @dev Due to rounding errors the result is - 1% wei from the exact amount
    function getMaxBorrow(address _cBorrowAddress) public returns (uint) {
        (, uint liquidityInEth, ) = ComptrollerInterface(COMPTROLLER).getAccountLiquidity(address(this));

        if (_cBorrowAddress == CETH_ADDRESS) return liquidityInEth;

        uint ethPrice = CompoundOracle(COMPOUND_ORACLE).getUnderlyingPrice(_cBorrowAddress);
        uint liquidityInToken = wdiv(liquidityInEth, ethPrice);

        return sub(liquidityInToken, (liquidityInToken / 100)); // cut off 1% due to rounding issues
    }
}