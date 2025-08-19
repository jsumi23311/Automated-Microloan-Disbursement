# Automated Microloan Disbursement (Loandisburse)

A Stacks blockchain smart contract that automates microloan distribution and repayment in developing economies, providing transparent and efficient lending through smart contracts.

## Features

- **Lending Pool Management**: Contributors can add funds to the lending pool
- **Loan Applications**: Borrowers apply for loans with purpose descriptions
- **Automated Approval**: Contract owner approves qualified loan applications
- **Interest Calculation**: Automatic 10% interest rate calculation
- **Repayment Tracking**: Track partial and full loan repayments
- **Reputation System**: Borrower credit scoring based on payment history
- **Overdue Management**: Automatic marking of overdue loans
- **Emergency Controls**: Pause/resume loans when needed

## Contract Constants

- **Interest Rate**: 10%
- **Loan Duration**: 2160 blocks (~15 days)
- **Minimum Loan**: 1 STX
- **Maximum Loan**: 50 STX
- **Minimum Reputation**: 300 (out of 1000)

## Usage

### For Lenders

```clarity
;; Contribute STX to the lending pool
(contract-call? .Loandisburse contribute-to-pool u5000000) ;; 5 STX
```

### For Borrowers

```clarity
;; Apply for a loan
(contract-call? .Loandisburse apply-for-loan u2000000 "Small business inventory")

;; Make loan payment
(contract-call? .Loandisburse make-payment u1 u500000) ;; Pay 0.5 STX toward loan #1
```

### For Contract Owner

```clarity
;; Approve a loan application
(contract-call? .Loandisburse approve-loan 'ST1BORROWER...)

;; Disburse approved loan
(contract-call? .Loandisburse disburse-loan u1)

;; Mark overdue loans
(contract-call? .Loandisburse mark-loan-overdue u1)
```

### Read-Only Functions

```clarity
;; Check pool balance
(contract-call? .Loandisburse get-pool-balance)

;; Get loan details
(contract-call? .Loandisburse get-loan-info u1)

;; Check borrower reputation
(contract-call? .Loandisburse get-borrower-stats 'ST1BORROWER...)

;; Check loan eligibility
(contract-call? .Loandisburse get-loan-eligibility 'ST1BORROWER... u2000000)

;; Get payment schedule
(contract-call? .Loandisburse get-payment-schedule u1)
```

## Loan Process Flow

1. **Lenders** contribute STX to the pool
2. **Borrowers** apply for loans with amount and purpose
3. **Contract Owner** approves qualified applications
4. **Contract Owner** disburses approved loans to borrowers
5. **Borrowers** make payments over time
6. **System** automatically tracks repayments and updates reputation scores
7. **Repaid funds** return to the pool for new loans

## Security Features

- Owner-only functions for loan approval and disbursement
- Reputation-based lending eligibility
- Reserve fund management (20% pool reserve)
- Overdue loan tracking and penalties
- Emergency pause/resume functionality

## Deployment

Deploy using Clarinet:

```bash
clarinet check
clarinet test
clarinet deploy --testnet
```

## Error Codes

- `100`: Unauthorized access
- `101`: Insufficient funds
- `102`: Loan not found
- `103`: Loan already active
- `104`: Invalid amount
- `105`: Loan overdue
- `106`: Payment too small
- `107`: Already approved
- `108`: Not approved
