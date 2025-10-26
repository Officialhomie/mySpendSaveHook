# 🎯 SpendSave Protocol - Complete Transaction Proof

**New Deployment Date:** October 25, 2025  
**Network:** Base Sepolia (Chain ID: 84532)  
**Deployer:** 0x9aC2d5a0A0E88D459Ecfb68Bcbb94DFD7cdF1f09

---

## 📦 Deployed Contract Addresses

```
SpendSaveHook:     0xc4ABf9A7bf8300086BBad164b4c47B1Afbbf00Cc
SpendSaveStorage:  0xC95A40D1b2914a72319735Db73c14183bC641fA2
SavingStrategy:    0x871cF56eFA79EBe9332e49143927b5E91b047253
Savings:           0xf5b264234B88e1a1c9fA7FC8d27022b0B7670Ddc
```

---

## 🚀 Test 1: Pool Initialization

**Block:** 32,802,589  
**Total Gas:** 2,891,577  
**Total Cost:** 0.000002892 ETH

| # | Action | TX Hash | BaseScan |
|---|--------|---------|----------|
| 1 | Deploy LiquidityRouter | `0x04ce5d057664eddf3b7002fd75bc53c716178f244fb5ea32aa3f8d76e1b6f602` | [View](https://sepolia.basescan.org/tx/0x04ce5d057664eddf3b7002fd75bc53c716178f244fb5ea32aa3f8d76e1b6f602) |
| 2 | Initialize Pool with Hook | `0x3fa7685f1e7e34e04bb7a08abed6da51376b07d2d19f9a21abb7e536ef06e4a3` | [View](https://sepolia.basescan.org/tx/0x3fa7685f1e7e34e04bb7a08abed6da51376b07d2d19f9a21abb7e536ef06e4a3) |
| 3 | Wrap ETH to WETH | `0xe0110436efb422c359bd072d281f75890064743cca896b5319e57b6b4c990946` | [View](https://sepolia.basescan.org/tx/0xe0110436efb422c359bd072d281f75890064743cca896b5319e57b6b4c990946) |
| 4 | Approve WETH | `0xaf2b1f2150a1f53b0e4d8edf32f9c4754ad69458e0b5f6ae690c56aea6361b02` | [View](https://sepolia.basescan.org/tx/0xaf2b1f2150a1f53b0e4d8edf32f9c4754ad69458e0b5f6ae690c56aea6361b02) |
| 5 | Approve USDC | `0x4ff804ddca74585ac23070781023b8775f40332a4602705efc56d6ca0c610e19` | [View](https://sepolia.basescan.org/tx/0x4ff804ddca74585ac23070781023b8775f40332a4602705efc56d6ca0c610e19) |
| 6 | Deploy SwapRouter | `0xb5bf283e89a6e58f107bd31ca920305031650b95129ef1cc73ccc807f1e35908` | [View](https://sepolia.basescan.org/tx/0xb5bf283e89a6e58f107bd31ca920305031650b95129ef1cc73ccc807f1e35908) |
| 7 | Add Liquidity | `0xdf0e7d14e7834ce31f35c97450876a8c1ae68439c5f69acdd1d4393a7c26a78a` | [View](https://sepolia.basescan.org/tx/0xdf0e7d14e7834ce31f35c97450876a8c1ae68439c5f69acdd1d4393a7c26a78a) |
| 8 | Test Swap | `0x981572dc04222d11074492404ea759313df3bac450abec7b591f43fc4e4b0e01` | [View](https://sepolia.basescan.org/tx/0x981572dc04222d11074492404ea759313df3bac450abec7b591f43fc4e4b0e01) |
| 9 | Final Approval | `0x83bbf1c1873ce57ac0dee7bc0c634e9a22a6845c0dcf9e75cb39d8385c9c31bf` | [View](https://sepolia.basescan.org/tx/0x83bbf1c1873ce57ac0dee7bc0c634e9a22a6845c0dcf9e75cb39d8385c9c31bf) |

### ✅ Results:
- ✅ Pool created with SpendSave Hook
- ✅ Liquidity added: 29,554 USDC + 29,554 WETH units
- ✅ Test swap successful: 0.01 USDC → WETH

---

## 🏆 Test 2: COMPLETE PROTOCOL WITH SAVINGS EXTRACTION

**Block:** 32,802,845  
**Total Gas:** 2,948,804  
**Total Cost:** 0.000002949 ETH

| # | Action | TX Hash | BaseScan |
|---|--------|---------|----------|
| 1 | Deploy LiquidityRouter | `0xc07feeca1021b1c4bbe9cff7b2581e56c8194250d018ed804a01b603eac27310` | [View](https://sepolia.basescan.org/tx/0xc07feeca1021b1c4bbe9cff7b2581e56c8194250d018ed804a01b603eac27310) |
| 2 | Approve Token 1 | `0xe6cac56796c3f695360c40142daca4c2f6534c7b2d384ef6fda72da8be08e489` | [View](https://sepolia.basescan.org/tx/0xe6cac56796c3f695360c40142daca4c2f6534c7b2d384ef6fda72da8be08e489) |
| 3 | Approve Token 2 | `0x743dedbd5d5489a9953e91066efbc22d34d7c404c83ed2ab5277bbca4f5c0e36` | [View](https://sepolia.basescan.org/tx/0x743dedbd5d5489a9953e91066efbc22d34d7c404c83ed2ab5277bbca4f5c0e36) |
| 4 | Wrap ETH to WETH | `0x1f710408ead0b7276b0a0ac7992e9050acd3cd246a3b30c3c4863b4f5554546e` | [View](https://sepolia.basescan.org/tx/0x1f710408ead0b7276b0a0ac7992e9050acd3cd246a3b30c3c4863b4f5554546e) |
| 5 | Deploy SwapRouter | `0x027aebeb4ce737c8522e06748ca0df0555a8515a01a4e317f1032938164097b0` | [View](https://sepolia.basescan.org/tx/0x027aebeb4ce737c8522e06748ca0df0555a8515a01a4e317f1032938164097b0) |
| 6 | Approve USDC to Router | `0x860e87cec25515b83ab57a3361409d08678a7e96741487169b8faab1cdc601d0` | [View](https://sepolia.basescan.org/tx/0x860e87cec25515b83ab57a3361409d08678a7e96741487169b8faab1cdc601d0) |
| 7 | Approve WETH to Router | `0xba3b415ce1ca2a0f0fb19d3a6e8ff9d5d8ead2cabf7e398ed686ce49fd1d5c88` | [View](https://sepolia.basescan.org/tx/0xba3b415ce1ca2a0f0fb19d3a6e8ff9d5d8ead2cabf7e398ed686ce49fd1d5c88) |
| 8 | Add Liquidity | `0x5a1e2b2f6af3c223b1de85bfe58e87815c51572f74f3de1bf86024cb73c9c9e1` | [View](https://sepolia.basescan.org/tx/0x5a1e2b2f6af3c223b1de85bfe58e87815c51572f74f3de1bf86024cb73c9c9e1) |
| **9** | **🎯 SWAP WITH SAVINGS** | **`0x4f19214ca298d8c0af1bb3da729300ec2ca62c48324fa33fb7ddcb64b1a14c8d`** | **[View](https://sepolia.basescan.org/tx/0x4f19214ca298d8c0af1bb3da729300ec2ca62c48324fa33fb7ddcb64b1a14c8d)** |

---

## 🎊 THE ULTIMATE PROOF

### Transaction #9: Swap with Savings Extraction

**TX Hash:** `0x4f19214ca298d8c0af1bb3da729300ec2ca62c48324fa33fb7ddcb64b1a14c8d`  
**Block:** 32,802,845  
**Gas Used:** 283,213

### What Happened:

```
Configuration:  10% savings on INPUT tokens
Input Amount:   10,000 USDC units (0.01 USDC)

SAVINGS BEFORE:  0 units
SWAP EXECUTED:   10,000 USDC → WETH through SpendSave Hook
SAVINGS AFTER:   1,000 units

EXTRACTED:       1,000 units
EXPECTED:        1,000 units (10% of 10,000)
ACCURACY:        100% PERFECT MATCH ✅✅✅
```

### Verification:

```bash
# Check savings balance on-chain
cast call 0xC95A40D1b2914a72319735Db73c14183bC641fA2 \
  "savings(address,address)(uint256)" \
  0x9aC2d5a0A0E88D459Ecfb68Bcbb94DFD7cdF1f09 \
  0x036CbD53842c5426634e7929541eC2318f3dCF7e \
  --rpc-url https://sepolia.base.org

# Returns: 1000 ✅
```

---

## 📊 Summary

### Total Transactions: 18
- **Test 1 (Pool Init):** 9 transactions
- **Test 2 (Savings Proof):** 9 transactions

### Key Achievements:
✅ Pool created with SpendSave Hook  
✅ Liquidity added successfully  
✅ Strategy configured: 10% INPUT savings  
✅ **Savings extracted: 1,000 units (10% of 10,000)** 🏆  
✅ **Accuracy: 100% perfect match**  
✅ All transactions confirmed on Base Sepolia

---

## 🔗 Quick Links

**Most Important Transaction (Savings Extraction):**  
https://sepolia.basescan.org/tx/0x4f19214ca298d8c0af1bb3da729300ec2ca62c48324fa33fb7ddcb64b1a14c8d

**Pool Initialization:**  
https://sepolia.basescan.org/tx/0x3fa7685f1e7e34e04bb7a08abed6da51376b07d2d19f9a21abb7e536ef06e4a3

**Hook Contract:**  
https://sepolia.basescan.org/address/0xc4ABf9A7bf8300086BBad164b4c47B1Afbbf00Cc

**Storage Contract:**  
https://sepolia.basescan.org/address/0xC95A40D1b2914a72319735Db73c14183bC641fA2

---

## 💡 For Judges

**To verify savings extraction:**

1. Visit the savings extraction transaction:  
   https://sepolia.basescan.org/tx/0x4f19214ca298d8c0af1bb3da729300ec2ca62c48324fa33fb7ddcb64b1a14c8d

2. Check the savings balance on-chain using the command above

3. See that 1,000 units were saved from a 10,000 unit swap (10% exact!)

**This is proof that SpendSave Protocol actually works!** ✅

---

*Generated: October 25, 2025*  
*Network: Base Sepolia (84532)*  
*Status: ✅ Fully Functional*
