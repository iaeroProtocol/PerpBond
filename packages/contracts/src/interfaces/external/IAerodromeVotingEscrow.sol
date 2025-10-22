// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title IAerodromeVotingEscrow
/// @notice Interface for Aerodrome's NFT-based Voting Escrow (veAERO)
/// @dev Aerodrome uses ERC721-based voting escrow where each position is an NFT
interface IAerodromeVotingEscrow {
    /// @notice Create a new lock (mints an NFT)
    /// @param _value Amount of AERO to lock
    /// @param _lockDuration Duration in seconds (must be aligned to weeks)
    /// @return tokenId The NFT token ID representing the lock
    function createLock(uint256 _value, uint256 _lockDuration) external returns (uint256 tokenId);

    /// @notice Create a permanent lock (mints an NFT with permanent lock)
    /// @param _value Amount of AERO to lock permanently
    /// @return tokenId The NFT token ID representing the permanent lock
    function createLockFor(uint256 _value, address _to) external returns (uint256 tokenId);

    /// @notice Increase the amount locked in an existing NFT
    /// @param tokenId The NFT token ID
    /// @param _value Additional amount to lock
    function increaseAmount(uint256 tokenId, uint256 _value) external;

    /// @notice Extend the unlock time for an NFT
    /// @param tokenId The NFT token ID
    /// @param _lockDuration New lock duration (must be > current)
    function increaseUnlockTime(uint256 tokenId, uint256 _lockDuration) external;

    /// @notice Convert a regular lock to a permanent lock
    /// @param tokenId The NFT token ID
    function lockPermanent(uint256 tokenId) external;

    /// @notice Unlock a permanent lock (convert back to time-locked)
    /// @param tokenId The NFT token ID
    function unlockPermanent(uint256 tokenId) external;

    /// @notice Withdraw from an expired lock (burns the NFT)
    /// @param tokenId The NFT token ID
    function withdraw(uint256 tokenId) external;

    /// @notice Merge two NFT positions into one
    /// @param _from Token ID to merge from (will be burned)
    /// @param _to Token ID to merge into
    function merge(uint256 _from, uint256 _to) external;

    /// @notice Split an NFT into two positions
    /// @param tokenId Token ID to split
    /// @param amount Amount to split off into new NFT
    /// @return newTokenId The new NFT token ID
    function split(uint256 tokenId, uint256 amount) external returns (uint256 newTokenId);

    /// @notice Get the voting power of an NFT at current block
    /// @param tokenId The NFT token ID
    /// @return Voting power balance
    function balanceOfNFT(uint256 tokenId) external view returns (uint256);

    /// @notice Get the locked amount for an NFT
    /// @param tokenId The NFT token ID
    /// @return amount Locked amount
    function locked(uint256 tokenId) external view returns (uint256 amount);

    /// @notice Check if an NFT is permanently locked
    /// @param tokenId The NFT token ID
    /// @return True if permanently locked
    function permanentLockBalance(uint256 tokenId) external view returns (bool);

    /// @notice Get the owner of an NFT
    /// @param tokenId The NFT token ID
    /// @return Owner address
    function ownerOf(uint256 tokenId) external view returns (address);
}

/// @title IAerodromeVoter
/// @notice Interface for Aerodrome's Voter contract for gauge voting
interface IAerodromeVoter {
    /// @notice Vote for gauge weights with an NFT
    /// @param tokenId The veAERO NFT token ID
    /// @param pools Array of pool/gauge addresses to vote for
    /// @param weights Array of weights (sum must be <= 100%)
    function vote(uint256 tokenId, address[] calldata pools, uint256[] calldata weights) external;

    /// @notice Reset votes for an NFT (removes all votes)
    /// @param tokenId The veAERO NFT token ID
    function reset(uint256 tokenId) external;

    /// @notice Poke voting to update weights
    /// @param tokenId The veAERO NFT token ID
    function poke(uint256 tokenId) external;

    /// @notice Claim bribes for voted gauges
    /// @param bribes Array of bribe contract addresses
    /// @param tokens Array of token addresses to claim per bribe
    /// @param tokenId The veAERO NFT token ID
    function claimBribes(address[] calldata bribes, address[][] calldata tokens, uint256 tokenId) external;

    /// @notice Claim gauge fees
    /// @param fees Array of fee contract addresses
    /// @param tokens Array of token addresses to claim per fee
    /// @param tokenId The veAERO NFT token ID
    function claimFees(address[] calldata fees, address[][] calldata tokens, uint256 tokenId) external;
}
