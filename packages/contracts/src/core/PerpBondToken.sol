// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";

import "./AccessRoles.sol";

/**
 * @title PerpBondToken
 * @notice Transferable receipt token for the PerpBond vault.
 *         Only the Vault can mint/burn; users cannot redeem principal.
 *
 * Design:
 * - ERC20 + EIP-2612 permit (gasless approvals)
 * - Governor can rotate the `vault` address if needed
 * - 18 decimals; vault handles USDC(6) accounting and share math
 */
contract PerpBondToken is ERC20, ERC20Permit, AccessRoles {
    /// @notice The only address allowed to mint/burn receipt shares.
    address public vault;

    /*//////////////////////////////////////////////////////////////////////////
                                       Events
    //////////////////////////////////////////////////////////////////////////*/
    event VaultUpdated(address indexed oldVault, address indexed newVault);

    /*//////////////////////////////////////////////////////////////////////////
                                      Modifiers
    //////////////////////////////////////////////////////////////////////////*/
    modifier onlyVault() {
        if (msg.sender != vault) revert Unauthorized();
        _;
    }

    /*//////////////////////////////////////////////////////////////////////////
                                    Constructor
    //////////////////////////////////////////////////////////////////////////*/

    /// @param name_      ERC20 name (e.g., "PerpBond")
    /// @param symbol_    ERC20 symbol (e.g., "PBOND")
    /// @param governor_  Access role: governor
    /// @param guardian_  Access role: guardian
    /// @param keeper_    Access role: keeper
    /// @param treasury_  Access role: treasury
    /// @param vault_     Initial vault address (minter/burner)
    constructor(
        string memory name_,
        string memory symbol_,
        address governor_,
        address guardian_,
        address keeper_,
        address treasury_,
        address vault_
    )
        ERC20(name_, symbol_)
        ERC20Permit(name_)
        AccessRoles(governor_, guardian_, keeper_, treasury_)
    {
        _setVault(vault_);
    }

    /*//////////////////////////////////////////////////////////////////////////
                                   ERC20 params
    //////////////////////////////////////////////////////////////////////////*/
    function decimals() public pure override returns (uint8) {
        return 18;
    }

    /*//////////////////////////////////////////////////////////////////////////
                                  Admin functions
    //////////////////////////////////////////////////////////////////////////*/

    /// @notice Governor may rotate the vault if upgraded or replaced.
    function setVault(address newVault) external onlyGovernor {
        _setVault(newVault);
    }

    function _setVault(address newVault) internal {
        if (newVault == address(0)) revert ZeroAddress();
        address old = vault;
        vault = newVault;
        emit VaultUpdated(old, newVault);
    }

    /*//////////////////////////////////////////////////////////////////////////
                                   Mint / Burn
    //////////////////////////////////////////////////////////////////////////*/

    /// @notice Mint receipt shares to `to`. Only callable by the Vault.
    function mint(address to, uint256 amount) external onlyVault {
        _mint(to, amount);
    }

    /// @notice Burn receipt shares from `from`. Only callable by the Vault.
    function burn(address from, uint256 amount) external onlyVault {
        _burn(from, amount);
    }
}
