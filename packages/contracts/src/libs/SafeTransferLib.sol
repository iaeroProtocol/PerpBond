// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Permit.sol";

import "./ErrorsEvents.sol"; // for IErrors

/// @title SafeTransferLib
/// @notice Safe ERC-20 transfers/approvals compatible with non-standard tokens (e.g., USDT)
/// @dev    - Accepts no-return tokens and strict-boolean return tokens
///         - Uses shared IErrors (TransferFailed / ApproveFailed / ZeroAddress)
///         - Includes permit, increase/decrease allowance helpers, and ETH transfer
library SafeTransferLib {
    /*//////////////////////////////////////////////////////////////
                             ERC20 TRANSFERS
    //////////////////////////////////////////////////////////////*/

    function safeTransfer(IERC20 token, address to, uint256 amount) internal {
        if (address(token) == address(0) || to == address(0)) revert IErrors.ZeroAddress();

        _callOptionalBoolReturn(
            address(token),
            abi.encodeWithSelector(token.transfer.selector, to, amount),
            true // revert with TransferFailed on bad return
        );
    }

    function safeTransferFrom(IERC20 token, address from, address to, uint256 amount) internal {
        if (address(token) == address(0) || from == address(0) || to == address(0)) revert IErrors.ZeroAddress();

        _callOptionalBoolReturn(
            address(token),
            abi.encodeWithSelector(token.transferFrom.selector, from, to, amount),
            true // revert with TransferFailed on bad return
        );
    }

    /*//////////////////////////////////////////////////////////////
                           ERC20 APPROVALS
    //////////////////////////////////////////////////////////////*/

    /// @notice Strict "safeApprove" (will revert if the token misbehaves).
    /// @dev    For stubborn tokens (e.g., old USDT) prefer forceApprove().
    function safeApprove(IERC20 token, address spender, uint256 amount) internal {
        if (address(token) == address(0)) revert IErrors.ZeroAddress();

        _callOptionalBoolReturn(
            address(token),
            abi.encodeWithSelector(token.approve.selector, spender, amount),
            false // map to ApproveFailed on bad return
        );
    }

    /// @notice Approve with a safe two-step fallback: try target amount; if it fails, set to 0 then try again.
    /// @dev    Needed for tokens that require allowance to be zero before changing to a new non-zero value.
    function forceApprove(IERC20 token, address spender, uint256 amount) internal {
        if (address(token) == address(0)) revert IErrors.ZeroAddress();

        // 1) Try direct approve(amount)
        (bool ok, bytes memory ret) = address(token).call(
            abi.encodeWithSelector(token.approve.selector, spender, amount)
        );
        if (_didSucceed(ok, ret)) return;

        // 2) Try approve(0)
        (ok, ret) = address(token).call(abi.encodeWithSelector(token.approve.selector, spender, 0));
        if (!_didSucceed(ok, ret)) revert IErrors.ApproveFailed();

        // 3) Try approve(amount) again
        (ok, ret) = address(token).call(abi.encodeWithSelector(token.approve.selector, spender, amount));
        if (!_didSucceed(ok, ret)) revert IErrors.ApproveFailed();
    }

    function safeIncreaseAllowance(IERC20 token, address spender, uint256 addedValue) internal {
        uint256 current = token.allowance(address(this), spender);
        forceApprove(token, spender, current + addedValue);
    }

    function safeDecreaseAllowance(IERC20 token, address spender, uint256 subtractedValue) internal {
        uint256 current = token.allowance(address(this), spender);
        if (subtractedValue > current) revert IErrors.ApproveFailed(); // underflow guard
        forceApprove(token, spender, current - subtractedValue);
    }

    /*//////////////////////////////////////////////////////////////
                                  PERMIT
    //////////////////////////////////////////////////////////////*/

    /// @notice Safe EIP-2612 permit; verifies nonce increment.
    function safePermit(
        IERC20Permit token,
        address owner,
        address spender,
        uint256 value,
        uint256 deadline,
        uint8 v, bytes32 r, bytes32 s
    ) internal {
        uint256 nonceBefore = token.nonces(owner);
        token.permit(owner, spender, value, deadline, v, r, s);
        uint256 nonceAfter = token.nonces(owner);
        if (nonceAfter != nonceBefore + 1) revert IErrors.ApproveFailed();
    }

    /*//////////////////////////////////////////////////////////////
                                   ETH
    //////////////////////////////////////////////////////////////*/

    function safeTransferETH(address to, uint256 value) internal {
        if (to == address(0)) revert IErrors.ZeroAddress();
        (bool success, ) = to.call{value: value}("");
        if (!success) revert IErrors.TransferFailed();
    }

    /*//////////////////////////////////////////////////////////////
                           INTERNAL UTILITIES
    //////////////////////////////////////////////////////////////*/

    /// @dev Low-level call that accepts non-standard ERC-20 return data.
    ///      If `strictTransfer` is true, map failures to TransferFailed; otherwise map to ApproveFailed.
    function _callOptionalBoolReturn(address token, bytes memory data, bool strictTransfer) private {
        (bool ok, bytes memory ret) = token.call(data);
        if (!_didSucceed(ok, ret)) {
            if (strictTransfer) revert IErrors.TransferFailed();
            revert IErrors.ApproveFailed();
        }
    }

    /// @dev Consider call successful if:
    ///      - it didn't revert; AND
    ///      - it returned no data; OR it returned at least 32 bytes that decode to true.
    function _didSucceed(bool ok, bytes memory ret) private pure returns (bool) {
        if (!ok) return false;
        if (ret.length == 0) return true; // non-standard tokens
        if (ret.length >= 32) {
            // Some tokens return 32-byte values; treat non-zero as true
            return abi.decode(ret, (bool));
        }
        // Unexpected short return; be conservative
        return false;
    }
}
