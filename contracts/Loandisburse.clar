;; title: Loandisburse

(define-constant ERR_UNAUTHORIZED (err u100))
(define-constant ERR_INSUFFICIENT_FUNDS (err u101))
(define-constant ERR_LOAN_NOT_FOUND (err u102))
(define-constant ERR_LOAN_ALREADY_ACTIVE (err u103))
(define-constant ERR_INVALID_AMOUNT (err u104))
(define-constant ERR_LOAN_OVERDUE (err u105))
(define-constant ERR_PAYMENT_TOO_SMALL (err u106))
(define-constant ERR_ALREADY_APPROVED (err u107))
(define-constant ERR_NOT_APPROVED (err u108))
(define-constant ERR_INSUFFICIENT_COLLATERAL (err u109))
(define-constant ERR_LIQUIDATION_NOT_ALLOWED (err u110))
(define-constant ERR_EXCESS_COLLATERAL_WITHDRAWAL (err u111))
(define-constant ERR_LIQUIDATION_THRESHOLD_REACHED (err u112))

(define-constant CONTRACT_OWNER tx-sender)
(define-constant INTEREST_RATE u10)
(define-constant LOAN_DURATION u2160)
(define-constant MIN_LOAN_AMOUNT u1000000)
(define-constant MAX_LOAN_AMOUNT u50000000)
(define-constant MIN_COLLATERAL_RATIO u150)
(define-constant LIQUIDATION_THRESHOLD u120)
(define-constant LIQUIDATION_PENALTY u10)

(define-data-var total-pool uint u0)
(define-data-var next-loan-id uint u1)
(define-data-var total-loans-disbursed uint u0)
(define-data-var total-repaid uint u0)
(define-data-var total-collateral-locked uint u0)
(define-data-var total-liquidations uint u0)
(define-data-var base-rate uint u10)
(define-data-var market-scalar uint u100)
(define-data-var total-outstanding-debt uint u0)

(define-map loans
  { loan-id: uint }
  {
    borrower: principal,
    amount: uint,
    interest: uint,
    total-due: uint,
    amount-repaid: uint,
    disbursed-at: uint,
    due-at: uint,
    status: (string-ascii 20),
    approved: bool,
  }
)

(define-map loan-applications
  { applicant: principal }
  {
    amount: uint,
    purpose: (string-ascii 500),
    applied-at: uint,
    approved: bool,
    loan-id: (optional uint),
  }
)

(define-map borrower-stats
  { borrower: principal }
  {
    total-loans: uint,
    total-repaid: uint,
    current-loans: uint,
    reputation-score: uint,
  }
)

(define-map lender-contributions
  { lender: principal }
  {
    total-contributed: uint,
    total-earned: uint,
    active-contribution: uint,
  }
)

(define-map collateral-positions
  { loan-id: uint }
  {
    borrower: principal,
    stx-locked: uint,
    collateral-ratio: uint,
    liquidation-price: uint,
    locked-at: uint,
    is-liquidated: bool,
  }
)

(define-public (contribute-to-pool (amount uint))
  (begin
    (asserts! (> amount u0) ERR_INVALID_AMOUNT)
    (try! (stx-transfer? amount tx-sender (as-contract tx-sender)))
    (var-set total-pool (+ (var-get total-pool) amount))
    (map-set lender-contributions { lender: tx-sender }
      (merge
        (default-to {
          total-contributed: u0,
          total-earned: u0,
          active-contribution: u0,
        }
          (map-get? lender-contributions { lender: tx-sender })
        ) {
        total-contributed: (+ amount
          (get total-contributed
            (default-to {
              total-contributed: u0,
              total-earned: u0,
              active-contribution: u0,
            }
              (map-get? lender-contributions { lender: tx-sender })
            ))
        ),
        active-contribution: (+ amount
          (get active-contribution
            (default-to {
              total-contributed: u0,
              total-earned: u0,
              active-contribution: u0,
            }
              (map-get? lender-contributions { lender: tx-sender })
            ))
        ),
      })
    )
    (ok amount)
  )
)

(define-public (deposit-collateral
    (loan-id uint)
    (collateral-amount uint)
  )
  (let (
      (loan (unwrap! (map-get? loans { loan-id: loan-id }) ERR_LOAN_NOT_FOUND))
      (borrower (get borrower loan))
      (loan-amount (get amount loan))
      (required-collateral (/ (* loan-amount MIN_COLLATERAL_RATIO) u100))
    )
    (asserts! (is-eq tx-sender borrower) ERR_UNAUTHORIZED)
    (asserts! (>= collateral-amount required-collateral)
      ERR_INSUFFICIENT_COLLATERAL
    )
    (asserts! (is-eq (get status loan) "active") ERR_LOAN_NOT_FOUND)
    (asserts! (> collateral-amount u0) ERR_INVALID_AMOUNT)

    (try! (stx-transfer? collateral-amount tx-sender (as-contract tx-sender)))
    (var-set total-collateral-locked
      (+ (var-get total-collateral-locked) collateral-amount)
    )

    (let ((collateral-ratio (/ (* collateral-amount u100) loan-amount)))
      (map-set collateral-positions { loan-id: loan-id } {
        borrower: borrower,
        stx-locked: collateral-amount,
        collateral-ratio: collateral-ratio,
        liquidation-price: (/ (* loan-amount LIQUIDATION_THRESHOLD) u100),
        locked-at: stacks-block-height,
        is-liquidated: false,
      })
    )
    (ok collateral-amount)
  )
)

(define-public (withdraw-collateral
    (loan-id uint)
    (withdrawal-amount uint)
  )
  (let (
      (loan (unwrap! (map-get? loans { loan-id: loan-id }) ERR_LOAN_NOT_FOUND))
      (collateral-pos (unwrap! (map-get? collateral-positions { loan-id: loan-id })
        ERR_LOAN_NOT_FOUND
      ))
      (borrower (get borrower loan))
      (loan-amount (get amount loan))
      (amount-repaid (get amount-repaid loan))
      (outstanding-debt (- (get total-due loan) amount-repaid))
      (current-collateral (get stx-locked collateral-pos))
      (remaining-collateral (- current-collateral withdrawal-amount))
      (new-ratio (if (> outstanding-debt u0)
        (/ (* remaining-collateral u100) outstanding-debt)
        u0
      ))
    )
    (asserts! (is-eq tx-sender borrower) ERR_UNAUTHORIZED)
    (asserts! (> withdrawal-amount u0) ERR_INVALID_AMOUNT)
    (asserts! (<= withdrawal-amount current-collateral) ERR_INSUFFICIENT_FUNDS)
    (asserts! (not (get is-liquidated collateral-pos))
      ERR_LIQUIDATION_NOT_ALLOWED
    )
    (asserts!
      (or (is-eq outstanding-debt u0) (>= new-ratio MIN_COLLATERAL_RATIO))
      ERR_EXCESS_COLLATERAL_WITHDRAWAL
    )

    (try! (as-contract (stx-transfer? withdrawal-amount tx-sender borrower)))
    (var-set total-collateral-locked
      (- (var-get total-collateral-locked) withdrawal-amount)
    )

    (map-set collateral-positions { loan-id: loan-id }
      (merge collateral-pos {
        stx-locked: remaining-collateral,
        collateral-ratio: new-ratio,
      })
    )
    (ok withdrawal-amount)
  )
)

(define-public (apply-for-loan
    (amount uint)
    (purpose (string-ascii 500))
  )
  (begin
    (asserts! (and (>= amount MIN_LOAN_AMOUNT) (<= amount MAX_LOAN_AMOUNT))
      ERR_INVALID_AMOUNT
    )
    (asserts! (is-none (map-get? loan-applications { applicant: tx-sender }))
      ERR_LOAN_ALREADY_ACTIVE
    )
    (map-set loan-applications { applicant: tx-sender } {
      amount: amount,
      purpose: purpose,
      applied-at: stacks-block-height,
      approved: false,
      loan-id: none,
    })
    (ok stacks-block-height)
  )
)

(define-public (approve-loan (applicant principal))
  (let (
      (application (unwrap! (map-get? loan-applications { applicant: applicant })
        ERR_LOAN_NOT_FOUND
      ))
      (loan-amount (get amount application))
      (rate (unwrap-panic (get-dynamic-rate applicant)))
      (interest-amount (/ (* loan-amount rate) u100))
      (total-due (+ loan-amount interest-amount))
      (loan-id (var-get next-loan-id))
    )
    (asserts! (is-eq tx-sender CONTRACT_OWNER) ERR_UNAUTHORIZED)
    (asserts! (not (get approved application)) ERR_ALREADY_APPROVED)
    (asserts! (>= (var-get total-pool) loan-amount) ERR_INSUFFICIENT_FUNDS)

    (map-set loan-applications { applicant: applicant }
      (merge application {
        approved: true,
        loan-id: (some loan-id),
      })
    )

    (map-set loans { loan-id: loan-id } {
      borrower: applicant,
      amount: loan-amount,
      interest: interest-amount,
      total-due: total-due,
      amount-repaid: u0,
      disbursed-at: stacks-block-height,
      due-at: (+ stacks-block-height LOAN_DURATION),
      status: "active",
      approved: true,
    })

    (var-set next-loan-id (+ loan-id u1))
    (ok loan-id)
  )
)

(define-public (disburse-loan (loan-id uint))
  (let (
      (loan (unwrap! (map-get? loans { loan-id: loan-id }) ERR_LOAN_NOT_FOUND))
      (borrower (get borrower loan))
      (amount (get amount loan))
    )
    (asserts! (is-eq tx-sender CONTRACT_OWNER) ERR_UNAUTHORIZED)
    (asserts! (get approved loan) ERR_NOT_APPROVED)
    (asserts! (is-eq (get status loan) "active") ERR_LOAN_ALREADY_ACTIVE)
    (asserts! (>= (var-get total-pool) amount) ERR_INSUFFICIENT_FUNDS)

    (try! (as-contract (stx-transfer? amount tx-sender borrower)))
    (var-set total-pool (- (var-get total-pool) amount))
    (var-set total-loans-disbursed (+ (var-get total-loans-disbursed) u1))
    (var-set total-outstanding-debt
      (+ (var-get total-outstanding-debt) (get total-due loan))
    )

    (map-set loans { loan-id: loan-id } (merge loan { status: "disbursed" }))

    (map-set borrower-stats { borrower: borrower }
      (merge
        (default-to {
          total-loans: u0,
          total-repaid: u0,
          current-loans: u0,
          reputation-score: u100,
        }
          (map-get? borrower-stats { borrower: borrower })
        ) {
        total-loans: (+ u1
          (get total-loans
            (default-to {
              total-loans: u0,
              total-repaid: u0,
              current-loans: u0,
              reputation-score: u100,
            }
              (map-get? borrower-stats { borrower: borrower })
            ))
        ),
        current-loans: (+ u1
          (get current-loans
            (default-to {
              total-loans: u0,
              total-repaid: u0,
              current-loans: u0,
              reputation-score: u100,
            }
              (map-get? borrower-stats { borrower: borrower })
            ))
        ),
      })
    )

    (ok amount)
  )
)

(define-public (make-payment
    (loan-id uint)
    (amount uint)
  )
  (let (
      (loan (unwrap! (map-get? loans { loan-id: loan-id }) ERR_LOAN_NOT_FOUND))
      (borrower (get borrower loan))
      (current-repaid (get amount-repaid loan))
      (total-due (get total-due loan))
      (new-repaid (+ current-repaid amount))
    )
    (asserts! (is-eq tx-sender borrower) ERR_UNAUTHORIZED)
    (asserts! (> amount u0) ERR_INVALID_AMOUNT)
    (asserts! (<= new-repaid total-due) ERR_PAYMENT_TOO_SMALL)
    (asserts! (is-eq (get status loan) "disbursed") ERR_LOAN_NOT_FOUND)

    (try! (stx-transfer? amount tx-sender (as-contract tx-sender)))
    (var-set total-pool (+ (var-get total-pool) amount))
    (var-set total-repaid (+ (var-get total-repaid) amount))
    (var-set total-outstanding-debt
      (if (> (var-get total-outstanding-debt) amount)
        (- (var-get total-outstanding-debt) amount)
        u0
      ))

    (let ((final-status (if (is-eq new-repaid total-due)
        "repaid"
        "disbursed"
      )))
      (map-set loans { loan-id: loan-id }
        (merge loan {
          amount-repaid: new-repaid,
          status: final-status,
        })
      )

      (if (is-eq final-status "repaid")
        (begin
          (match (map-get? collateral-positions { loan-id: loan-id })
            collateral-pos (begin
              (let ((locked-collateral (get stx-locked collateral-pos)))
                (if (> locked-collateral u0)
                  (begin
                    (try! (as-contract (stx-transfer? locked-collateral tx-sender borrower)))
                    (var-set total-collateral-locked
                      (- (var-get total-collateral-locked) locked-collateral)
                    )
                    (map-set collateral-positions { loan-id: loan-id }
                      (merge collateral-pos { stx-locked: u0 })
                    )
                  )
                  true
                )
              )
            )
            true
          )
          (map-set borrower-stats { borrower: borrower }
            (merge
              (default-to {
                total-loans: u0,
                total-repaid: u0,
                current-loans: u0,
                reputation-score: u100,
              }
                (map-get? borrower-stats { borrower: borrower })
              ) {
              total-repaid: (+ total-due
                (get total-repaid
                  (default-to {
                    total-loans: u0,
                    total-repaid: u0,
                    current-loans: u0,
                    reputation-score: u100,
                  }
                    (map-get? borrower-stats { borrower: borrower })
                  ))
              ),
              current-loans: (-
                (get current-loans
                  (default-to {
                    total-loans: u0,
                    total-repaid: u0,
                    current-loans: u0,
                    reputation-score: u100,
                  }
                    (map-get? borrower-stats { borrower: borrower })
                  ))
                u1
              ),
              reputation-score: (if (<
                  (+
                    (get reputation-score
                      (default-to {
                        total-loans: u0,
                        total-repaid: u0,
                        current-loans: u0,
                        reputation-score: u100,
                      }
                        (map-get? borrower-stats { borrower: borrower })
                      ))
                    u50
                  )
                  u1000
                )
                (+
                  (get reputation-score
                    (default-to {
                      total-loans: u0,
                      total-repaid: u0,
                      current-loans: u0,
                      reputation-score: u100,
                    }
                      (map-get? borrower-stats { borrower: borrower })
                    ))
                  u50
                )
                u1000
              ),
            })
          )
          (ok new-repaid)
        )
        (ok new-repaid)
      )
    )
  )
)

(define-public (liquidate-position (loan-id uint))
  (let (
      (loan (unwrap! (map-get? loans { loan-id: loan-id }) ERR_LOAN_NOT_FOUND))
      (collateral-pos (unwrap! (map-get? collateral-positions { loan-id: loan-id })
        ERR_LOAN_NOT_FOUND
      ))
      (borrower (get borrower loan))
      (outstanding-debt (- (get total-due loan) (get amount-repaid loan)))
      (collateral-amount (get stx-locked collateral-pos))
      (current-ratio (if (> outstanding-debt u0)
        (/ (* collateral-amount u100) outstanding-debt)
        u0
      ))
      (penalty-amount (/ (* collateral-amount LIQUIDATION_PENALTY) u100))
      (liquidator-reward (/ penalty-amount u2))
      (protocol-share (- penalty-amount liquidator-reward))
      (remaining-collateral (- collateral-amount penalty-amount))
    )
    (asserts! (< current-ratio LIQUIDATION_THRESHOLD) ERR_LIQUIDATION_NOT_ALLOWED)
    (asserts! (not (get is-liquidated collateral-pos))
      ERR_LIQUIDATION_NOT_ALLOWED
    )
    (asserts! (not (is-eq (get status loan) "repaid")) ERR_LOAN_NOT_FOUND)

    (try! (as-contract (stx-transfer? liquidator-reward tx-sender tx-sender)))
    (try! (as-contract (stx-transfer? remaining-collateral tx-sender (as-contract tx-sender))))

    (var-set total-pool (+ (var-get total-pool) remaining-collateral))
    (var-set total-collateral-locked
      (- (var-get total-collateral-locked) collateral-amount)
    )
    (var-set total-liquidations (+ (var-get total-liquidations) u1))
    (var-set total-outstanding-debt
      (if (> (var-get total-outstanding-debt) outstanding-debt)
        (- (var-get total-outstanding-debt) outstanding-debt)
        u0
      ))

    (map-set loans { loan-id: loan-id } (merge loan { status: "liquidated" }))

    (map-set collateral-positions { loan-id: loan-id }
      (merge collateral-pos {
        is-liquidated: true,
        stx-locked: u0,
      })
    )

    (map-set borrower-stats { borrower: borrower }
      (merge
        (default-to {
          total-loans: u0,
          total-repaid: u0,
          current-loans: u0,
          reputation-score: u100,
        }
          (map-get? borrower-stats { borrower: borrower })
        ) {
        reputation-score: (if (>
            (get reputation-score
              (default-to {
                total-loans: u0,
                total-repaid: u0,
                current-loans: u0,
                reputation-score: u100,
              }
                (map-get? borrower-stats { borrower: borrower })
              ))
            u50
          )
          (-
            (get reputation-score
              (default-to {
                total-loans: u0,
                total-repaid: u0,
                current-loans: u0,
                reputation-score: u100,
              }
                (map-get? borrower-stats { borrower: borrower })
              ))
            u50
          )
          u0
        ),
        current-loans: (-
          (get current-loans
            (default-to {
              total-loans: u0,
              total-repaid: u0,
              current-loans: u0,
              reputation-score: u100,
            }
              (map-get? borrower-stats { borrower: borrower })
            ))
          u1
        ),
      })
    )
    (ok loan-id)
  )
)

(define-public (mark-loan-overdue (loan-id uint))
  (let (
      (loan (unwrap! (map-get? loans { loan-id: loan-id }) ERR_LOAN_NOT_FOUND))
      (borrower (get borrower loan))
    )
    (asserts! (is-eq tx-sender CONTRACT_OWNER) ERR_UNAUTHORIZED)
    (asserts! (> stacks-block-height (get due-at loan)) ERR_LOAN_NOT_FOUND)
    (asserts! (not (is-eq (get status loan) "repaid")) ERR_LOAN_NOT_FOUND)

    (map-set loans { loan-id: loan-id } (merge loan { status: "overdue" }))

    (map-set borrower-stats { borrower: borrower }
      (merge
        (default-to {
          total-loans: u0,
          total-repaid: u0,
          current-loans: u0,
          reputation-score: u100,
        }
          (map-get? borrower-stats { borrower: borrower })
        ) { reputation-score: (if (>
          (get reputation-score
            (default-to {
              total-loans: u0,
              total-repaid: u0,
              current-loans: u0,
              reputation-score: u100,
            }
              (map-get? borrower-stats { borrower: borrower })
            ))
          u30
        )
        (-
          (get reputation-score
            (default-to {
              total-loans: u0,
              total-repaid: u0,
              current-loans: u0,
              reputation-score: u100,
            }
              (map-get? borrower-stats { borrower: borrower })
            ))
          u30
        )
        u0
      ) }
      ))
    (ok loan-id)
  )
)

(define-public (withdraw-from-pool (amount uint))
  (begin
    (asserts! (is-eq tx-sender CONTRACT_OWNER) ERR_UNAUTHORIZED)
    (asserts! (> amount u0) ERR_INVALID_AMOUNT)
    (asserts! (>= (var-get total-pool) amount) ERR_INSUFFICIENT_FUNDS)

    (try! (as-contract (stx-transfer? amount tx-sender CONTRACT_OWNER)))
    (var-set total-pool (- (var-get total-pool) amount))
    (ok amount)
  )
)

(define-public (update-reputation
    (borrower principal)
    (score uint)
  )
  (begin
    (asserts! (is-eq tx-sender CONTRACT_OWNER) ERR_UNAUTHORIZED)
    (asserts! (<= score u1000) ERR_INVALID_AMOUNT)

    (map-set borrower-stats { borrower: borrower }
      (merge
        (default-to {
          total-loans: u0,
          total-repaid: u0,
          current-loans: u0,
          reputation-score: u100,
        }
          (map-get? borrower-stats { borrower: borrower })
        ) { reputation-score: score }
      ))
    (ok score)
  )
)

(define-public (emergency-pause-loan (loan-id uint))
  (let ((loan (unwrap! (map-get? loans { loan-id: loan-id }) ERR_LOAN_NOT_FOUND)))
    (asserts! (is-eq tx-sender CONTRACT_OWNER) ERR_UNAUTHORIZED)
    (asserts! (not (is-eq (get status loan) "repaid")) ERR_LOAN_NOT_FOUND)

    (map-set loans { loan-id: loan-id } (merge loan { status: "paused" }))
    (ok loan-id)
  )
)

(define-public (resume-loan (loan-id uint))
  (let ((loan (unwrap! (map-get? loans { loan-id: loan-id }) ERR_LOAN_NOT_FOUND)))
    (asserts! (is-eq tx-sender CONTRACT_OWNER) ERR_UNAUTHORIZED)
    (asserts! (is-eq (get status loan) "paused") ERR_LOAN_NOT_FOUND)

    (map-set loans { loan-id: loan-id }
      (merge loan {
        status: "disbursed",
        due-at: (+ stacks-block-height LOAN_DURATION),
      })
    )
    (ok loan-id)
  )
)

(define-read-only (get-pool-balance)
  (ok (var-get total-pool))
)

(define-read-only (get-loan-info (loan-id uint))
  (ok (map-get? loans { loan-id: loan-id }))
)

(define-read-only (get-application-info (applicant principal))
  (ok (map-get? loan-applications { applicant: applicant }))
)

(define-read-only (get-borrower-stats (borrower principal))
  (ok (map-get? borrower-stats { borrower: borrower }))
)

(define-read-only (get-lender-stats (lender principal))
  (ok (map-get? lender-contributions { lender: lender }))
)

(define-read-only (get-contract-stats)
  (ok {
    total-pool: (var-get total-pool),
    total-loans-disbursed: (var-get total-loans-disbursed),
    total-repaid: (var-get total-repaid),
    next-loan-id: (var-get next-loan-id),
    total-collateral-locked: (var-get total-collateral-locked),
    total-liquidations: (var-get total-liquidations),
  })
)

(define-read-only (calculate-interest (amount uint))
  (ok (/ (* amount INTEREST_RATE) u100))
)

(define-read-only (is-loan-overdue (loan-id uint))
  (match (map-get? loans { loan-id: loan-id })
    loan-data (ok (and
      (> stacks-block-height (get due-at loan-data))
      (not (is-eq (get status loan-data) "repaid"))
    ))
    (ok false)
  )
)

(define-read-only (get-available-funds)
  (let (
      (pool-balance (var-get total-pool))
      (reserve-ratio u20)
      (reserve-amount (/ (* pool-balance reserve-ratio) u100))
    )
    (ok (if (> pool-balance reserve-amount)
      (- pool-balance reserve-amount)
      u0
    ))
  )
)

(define-read-only (can-borrow
    (applicant principal)
    (amount uint)
  )
  (let (
      (stats (default-to {
        total-loans: u0,
        total-repaid: u0,
        current-loans: u0,
        reputation-score: u100,
      }
        (map-get? borrower-stats { borrower: applicant })
      ))
      (reputation (get reputation-score stats))
      (current-loans (get current-loans stats))
      (max-concurrent-loans (/ reputation u100))
    )
    (ok (and
      (>= reputation u300)
      (< current-loans max-concurrent-loans)
      (<= amount (unwrap-panic (get-available-funds)))
    ))
  )
)

(define-read-only (get-payment-schedule (loan-id uint))
  (match (map-get? loans { loan-id: loan-id })
    loan-data (let (
        (total-due (get total-due loan-data))
        (amount-repaid (get amount-repaid loan-data))
        (remaining (- total-due amount-repaid))
        (blocks-remaining (if (> (get due-at loan-data) stacks-block-height)
          (- (get due-at loan-data) stacks-block-height)
          u0
        ))
      )
      (ok {
        remaining-balance: remaining,
        blocks-until-due: blocks-remaining,
        minimum-payment: (if (> remaining u0)
          (if (> (/ remaining u10) u10000)
            (/ remaining u10)
            u10000
          )
          u0
        ),
        is-overdue: (> stacks-block-height (get due-at loan-data)),
      })
    )
    (err ERR_LOAN_NOT_FOUND)
  )
)

(define-public (distribute-interest-to-lender
    (lender principal)
    (amount uint)
  )
  (begin
    (asserts! (is-eq tx-sender CONTRACT_OWNER) ERR_UNAUTHORIZED)
    (asserts! (> amount u0) ERR_INVALID_AMOUNT)
    (asserts! (>= (var-get total-pool) amount) ERR_INSUFFICIENT_FUNDS)

    (try! (as-contract (stx-transfer? amount tx-sender lender)))
    (var-set total-pool (- (var-get total-pool) amount))

    (map-set lender-contributions { lender: lender }
      (merge
        (default-to {
          total-contributed: u0,
          total-earned: u0,
          active-contribution: u0,
        }
          (map-get? lender-contributions { lender: lender })
        ) { total-earned: (+ amount
        (get total-earned
          (default-to {
            total-contributed: u0,
            total-earned: u0,
            active-contribution: u0,
          }
            (map-get? lender-contributions { lender: lender })
          ))
      ) }
      ))
    (ok amount)
  )
)

(define-public (auto-approve-qualified-loans)
  (begin
    (asserts! (is-eq tx-sender CONTRACT_OWNER) ERR_UNAUTHORIZED)
    (ok u0)
  )
)

(define-read-only (get-collateral-position (loan-id uint))
  (ok (map-get? collateral-positions { loan-id: loan-id }))
)

(define-read-only (check-liquidation-risk (loan-id uint))
  (match (map-get? loans { loan-id: loan-id })
    loan-data (match (map-get? collateral-positions { loan-id: loan-id })
      collateral-pos (let (
          (outstanding-debt (- (get total-due loan-data) (get amount-repaid loan-data)))
          (collateral-amount (get stx-locked collateral-pos))
          (current-ratio (if (> outstanding-debt u0)
            (/ (* collateral-amount u100) outstanding-debt)
            u0
          ))
        )
        (ok {
          current-ratio: current-ratio,
          liquidation-threshold: LIQUIDATION_THRESHOLD,
          at-risk: (< current-ratio LIQUIDATION_THRESHOLD),
          collateral-locked: collateral-amount,
          outstanding-debt: outstanding-debt,
        })
      )
      (ok {
        current-ratio: u0,
        liquidation-threshold: LIQUIDATION_THRESHOLD,
        at-risk: false,
        collateral-locked: u0,
        outstanding-debt: u0,
      })
    )
    (err ERR_LOAN_NOT_FOUND)
  )
)

(define-read-only (calculate-required-collateral (loan-amount uint))
  (ok (/ (* loan-amount MIN_COLLATERAL_RATIO) u100))
)

(define-read-only (get-liquidation-info (loan-id uint))
  (match (map-get? loans { loan-id: loan-id })
    loan-data (match (map-get? collateral-positions { loan-id: loan-id })
      collateral-pos (let (
          (outstanding-debt (- (get total-due loan-data) (get amount-repaid loan-data)))
          (collateral-amount (get stx-locked collateral-pos))
          (penalty-amount (/ (* collateral-amount LIQUIDATION_PENALTY) u100))
          (liquidator-reward (/ penalty-amount u2))
        )
        (ok {
          can-liquidate: (and
            (<
              (if (> outstanding-debt u0)
                (/ (* collateral-amount u100) outstanding-debt)
                u0
              )
              LIQUIDATION_THRESHOLD
            )
            (not (get is-liquidated collateral-pos))
            (not (is-eq (get status loan-data) "repaid"))
          ),
          liquidator-reward: liquidator-reward,
          penalty-amount: penalty-amount,
          collateral-at-risk: collateral-amount,
        })
      )
      (ok {
        can-liquidate: false,
        liquidator-reward: u0,
        penalty-amount: u0,
        collateral-at-risk: u0,
      })
    )
    (err ERR_LOAN_NOT_FOUND)
  )
)

(define-read-only (get-loan-eligibility
    (applicant principal)
    (amount uint)
  )
  (let (
      (stats (default-to {
        total-loans: u0,
        total-repaid: u0,
        current-loans: u0,
        reputation-score: u100,
      }
        (map-get? borrower-stats { borrower: applicant })
      ))
      (reputation (get reputation-score stats))
      (current-loans (get current-loans stats))
      (available-funds (unwrap-panic (get-available-funds)))
      (required-collateral (/ (* amount MIN_COLLATERAL_RATIO) u100))
    )
    (ok {
      eligible: (and
        (>= reputation u300)
        (is-eq current-loans u0)
        (<= amount available-funds)
        (>= amount MIN_LOAN_AMOUNT)
        (<= amount MAX_LOAN_AMOUNT)
      ),
      min-reputation-required: u300,
      current-reputation: reputation,
      max-loan-amount: (if (< available-funds MAX_LOAN_AMOUNT)
        available-funds
        MAX_LOAN_AMOUNT
      ),
      current-loans: current-loans,
      required-collateral: required-collateral,
    })
  )
)

(define-read-only (get-interest-config)
  (ok {
    base-rate: (var-get base-rate),
    market-scalar: (var-get market-scalar),
  })
)

(define-read-only (get-utilization)
  (let (
      (pool (var-get total-pool))
      (out (var-get total-outstanding-debt))
      (cap (+ pool out))
    )
    (ok (if (> cap u0)
      (/ (* out u100) cap)
      u0
    ))
  )
)

(define-read-only (get-borrower-reputation (p principal))
  (let ((stats (default-to {
      total-loans: u0,
      total-repaid: u0,
      current-loans: u0,
      reputation-score: u100,
    }
      (map-get? borrower-stats { borrower: p })
    )))
    (ok (get reputation-score stats))
  )
)

(define-read-only (get-dynamic-rate (borrower principal))
  (let (
      (base (var-get base-rate))
      (scalar (var-get market-scalar))
      (util (unwrap-panic (get-utilization)))
      (rep (unwrap-panic (get-borrower-reputation borrower)))
      (scaled (/ (* base scalar) u100))
      (util-adj (if (>= util u80)
        u5
        (if (>= util u60)
          u3
          (if (>= util u40)
            u1
            u0
          )
        )
      ))
      (rep-disc (if (>= rep u700)
        u3
        (if (>= rep u500)
          u2
          (if (>= rep u300)
            u1
            u0
          )
        )
      ))
      (raw (+ scaled util-adj))
      (adj (if (> raw rep-disc)
        (- raw rep-disc)
        u0
      ))
      (min u2)
      (max u25)
      (clamped (if (< adj min)
        min
        (if (> adj max)
          max
          adj
        )
      ))
    )
    (ok clamped)
  )
)

(define-read-only (quote-interest
    (borrower principal)
    (amount uint)
  )
  (let ((rate (unwrap-panic (get-dynamic-rate borrower))))
    (ok {
      rate: rate,
      interest: (/ (* amount rate) u100),
    })
  )
)

(define-read-only (simulate-rate
    (reputation uint)
    (utilization uint)
    (base uint)
    (scalar uint)
  )
  (let (
      (scaled (/ (* base scalar) u100))
      (util-adj (if (>= utilization u80)
        u5
        (if (>= utilization u60)
          u3
          (if (>= utilization u40)
            u1
            u0
          )
        )
      ))
      (rep-disc (if (>= reputation u700)
        u3
        (if (>= reputation u500)
          u2
          (if (>= reputation u300)
            u1
            u0
          )
        )
      ))
      (raw (+ scaled util-adj))
      (adj (if (> raw rep-disc)
        (- raw rep-disc)
        u0
      ))
      (min u2)
      (max u25)
      (clamped (if (< adj min)
        min
        (if (> adj max)
          max
          adj
        )
      ))
    )
    (ok clamped)
  )
)

(define-public (set-interest-config
    (base uint)
    (scalar uint)
  )
  (begin
    (asserts! (is-eq tx-sender CONTRACT_OWNER) ERR_UNAUTHORIZED)
    (asserts! (and (> base u0) (> scalar u0)) ERR_INVALID_AMOUNT)
    (var-set base-rate base)
    (var-set market-scalar scalar)
    (ok true)
  )
)

(define-data-var rf-next-id uint u1)
(define-data-var rf-cooldown uint u144)
(define-data-var rf-base-apr-bps uint u1500)
(define-map rf-active
  principal
  {
    id: uint,
    apr: uint,
    outstanding: uint,
    start: uint,
    term: uint,
  }
)
(define-map rf-history
  {
    borrower: principal,
    seq: uint,
  }
  {
    apr: uint,
    principal: uint,
    start: uint,
    end: uint,
  }
)
(define-map rf-stats
  principal
  {
    rep: uint,
    refi-count: uint,
    best-apr: uint,
    last-refi: uint,
    total: uint,
  }
)

(define-read-only (rf-offer (user principal))
  (let (
      (b (var-get rf-base-apr-bps))
      (st (default-to {
        rep: u0,
        refi-count: u0,
        best-apr: u100000,
        last-refi: u0,
        total: u0,
      }
        (map-get? rf-stats user)
      ))
      (rep (get rep st))
      (raw (* rep u5))
      (d (if (> raw u500)
        u500
        raw
      ))
    )
    (if (> b d)
      (- b d)
      u0
    )
  )
)

(define-read-only (rf-eligible (user principal))
  (let (
      (a (map-get? rf-active user))
      (o (rf-offer user))
      (cd (var-get rf-cooldown))
    )
    (if (is-some a)
      (let ((aa (unwrap-panic a)))
        (and
          (> (get outstanding aa) u0)
          (< o (get apr aa))
          (>= stacks-block-height (+ (get start aa) cd))
        )
      )
      false
    )
  )
)

(define-read-only (rf-view (user principal))
  (let (
      (a (map-get? rf-active user))
      (o (rf-offer user))
      (cd (var-get rf-cooldown))
    )
    (if (is-some a)
      (let ((aa (unwrap-panic a)))
        {
          has: true,
          eligible: (and
            (> (get outstanding aa) u0)
            (< o (get apr aa))
            (>= stacks-block-height (+ (get start aa) cd))
          ),
          current: (get apr aa),
          offer: o,
          outstanding: (get outstanding aa),
          cooldown: (+ (get start aa) cd),
        }
      )
      {
        has: false,
        eligible: false,
        current: u0,
        offer: o,
        outstanding: u0,
        cooldown: u0,
      }
    )
  )
)

(define-public (rf-track
    (principal-amount uint)
    (outstanding uint)
    (apr uint)
    (term uint)
  )
  (if (is-some (map-get? rf-active tx-sender))
    (err u409)
    (if (and (> apr u0) (> term u0))
      (let ((id (var-get rf-next-id)))
        (var-set rf-next-id (+ id u1))
        (map-set rf-active tx-sender {
          id: id,
          apr: apr,
          outstanding: outstanding,
          start: stacks-block-height,
          term: term,
        })
        (ok id)
      )
      (err u422)
    )
  )
)

(define-public (rf-set-outstanding (amount uint))
  (let ((a (map-get? rf-active tx-sender)))
    (if (is-some a)
      (let ((aa (unwrap-panic a)))
        (if (<= amount (get outstanding aa))
          (begin
            (map-set rf-active tx-sender {
              id: (get id aa),
              apr: (get apr aa),
              outstanding: (- (get outstanding aa) amount),
              start: (get start aa),
              term: (get term aa),
            })
            (ok true)
          )
          (err u413)
        )
      )
      (err u404)
    )
  )
)

(define-public (rf-report
    (amount uint)
    (on-time bool)
  )
  (let (
      (st (default-to {
        rep: u0,
        refi-count: u0,
        best-apr: u100000,
        last-refi: u0,
        total: u0,
      }
        (map-get? rf-stats tx-sender)
      ))
      (inc (if on-time
        (let ((x (/ amount u1000000)))
          (if (> x u100)
            u100
            x
          )
        )
        u0
      ))
      (new-rep (let ((sum (+ (get rep st) inc)))
        (if (> sum u1000)
          u1000
          sum
        )
      ))
    )
    (map-set rf-stats tx-sender {
      rep: new-rep,
      refi-count: (get refi-count st),
      best-apr: (get best-apr st),
      last-refi: (get last-refi st),
      total: (+ (get total st) amount),
    })
    (ok new-rep)
  )
)

(define-public (rf-refinance (term uint))
  (let (
      (a (map-get? rf-active tx-sender))
      (o (rf-offer tx-sender))
      (cd (var-get rf-cooldown))
    )
    (if (is-some a)
      (let ((aa (unwrap-panic a)))
        (if (and
            (> (get outstanding aa) u0)
            (< o (get apr aa))
            (>= stacks-block-height (+ (get start aa) cd))
            (> term u0)
          )
          (let (
              (old-id (get id aa))
              (new-id (var-get rf-next-id))
              (st (default-to {
                rep: u0,
                refi-count: u0,
                best-apr: u100000,
                last-refi: u0,
                total: u0,
              }
                (map-get? rf-stats tx-sender)
              ))
            )
            (map-set rf-history {
              borrower: tx-sender,
              seq: old-id,
            } {
              apr: (get apr aa),
              principal: (get outstanding aa),
              start: (get start aa),
              end: stacks-block-height,
            })
            (var-set rf-next-id (+ new-id u1))
            (map-set rf-active tx-sender {
              id: new-id,
              apr: o,
              outstanding: (get outstanding aa),
              start: stacks-block-height,
              term: term,
            })
            (map-set rf-stats tx-sender {
              rep: (get rep st),
              refi-count: (+ (get refi-count st) u1),
              best-apr: (if (< o (get best-apr st))
                o
                (get best-apr st)
              ),
              last-refi: stacks-block-height,
              total: (get total st),
            })
            (ok new-id)
          )
          (err u400)
        )
      )
      (err u404)
    )
  )
)
