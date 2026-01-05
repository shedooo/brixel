# Brixel Token Smart Contract

This project implements a Clarity smart contract for a compliant, metadata-rich fungible token called `rwa-token` on the Stacks blockchain. It is designed for real-world asset (RWA) tokenization, with advanced compliance, admin controls, and asset metadata features.

---

## Features

- **Fungible Token:**  
  Implements a standard fungible token (`rwa-token`) with a supply cap.

- **Compliance Controls:**  
  - KYC approval and expiry for users  
  - Account freezing/unfreezing  
  - Emergency batch freeze  
  - Pausing/unpausing the contract

- **Admin Functions:**  
  - Ownership transfer  
  - Reserve ratio management  
  - Batch KYC updates

- **Token Operations:**  
  - Minting with metadata  
  - Transfer with compliance checks  
  - Burning tokens

- **Metadata System:**  
  - Enhanced metadata for each minted asset  
  - Asset backing and valuation tracking  
  - Metadata update functionality

- **Query Functions:**  
  - Get metadata, asset backing, balances, KYC status, contract info, etc.

---

## Usage

### Deployment

Deploy the contract using the Stacks CLI or your preferred development environment.

### Main Functions

- **Mint Tokens:**  
  Mint new tokens with asset metadata (owner only).
  ```clarity
  (mint amount metadata)
  ```

- **Transfer Tokens:**  
  Transfer tokens between users (with compliance checks).
  ```clarity
  (transfer recipient amount)
  ```

- **Burn Tokens:**  
  Burn tokens from your balance.
  ```clarity
  (burn amount)
  ```

- **Set KYC:**  
  Approve or revoke KYC for users (owner only).
  ```clarity
  (set-kyc user approved expiry-height)
  ```

- **Freeze/Unfreeze Accounts:**  
  Freeze or unfreeze user accounts (owner only).
  ```clarity
  (freeze-account user)
  (unfreeze-account user)
  ```

- **Pause/Unpause Contract:**  
  Temporarily halt all token operations (owner only).
  ```clarity
  (pause)
  (unpause)
  ```

- **Update Metadata:**  
  Update asset metadata (owner only).
  ```clarity
  (update-metadata id new-metadata)
  ```

### Query Functions

- **Get Metadata:**  
  ```clarity
  (get-enhanced-metadata id)
  (get-metadata id)
  ```

- **Get Asset Backing:**  
  ```clarity
  (get-asset-backing id)
  ```

- **Get Token Balance:**  
  ```clarity
  (get-token-balance user)
  ```

- **Get Contract Info:**  
  ```clarity
  (get-contract-info)
  ```

---

## Error Codes

- `u401`: Unauthorized
- `u402`: Not KYC approved
- `u403`: Account frozen
- `u404`: Contract paused
- `u405`: Insufficient balance
- `u406`: Invalid amount
- `u407`: Supply cap exceeded
- `u408`: Metadata not found
- `u409`: Invalid metadata

---

## License

MIT License

---

## Author

shedrach madaki

---

## File Structure

- brixel.clar — Main smart contract

---

## Notes

- All admin functions are restricted to the contract owner.
- KYC and freeze checks are enforced for all token operations.
- Metadata is stored and can be updated for each asset minted.

---

For more details, review the contract code in brixel.clar.
