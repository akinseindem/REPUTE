;; REPUTE: Decentralized Reputation System
;; A smart contract that manages user reputation in a decentralized manner

;; Constants
(define-constant contract-owner tx-sender)
(define-constant min-stake u1000000) ;; minimum stake required to participate
(define-constant max-score u100) ;; maximum reputation score
(define-constant min-score u0) ;; minimum reputation score
(define-constant cooling-period u144) ;; ~24 hours in blocks
(define-constant dispute-window u720) ;; ~5 days in blocks

;; Error codes
(define-constant err-not-authorized (err u100))
(define-constant err-already-initialized (err u101))
(define-constant err-insufficient-stake (err u102))
(define-constant err-invalid-domain (err u103))
(define-constant err-invalid-score (err u104))
(define-constant err-cooling-period (err u105))
(define-constant err-no-reputation (err u106))
(define-constant err-dispute-exists (err u107))
(define-constant err-no-dispute (err u108))
(define-constant err-dispute-window-closed (err u109))

;; Data maps
(define-map user-stakes { user: principal } { amount: uint })
(define-map domains { domain-id: uint } { name: (string-ascii 64), active: bool })
(define-map reputation-scores 
  { user: principal, domain-id: uint } 
  { score: uint, last-updated: uint, update-count: uint })
(define-map endorsements
  { endorser: principal, endorsee: principal, domain-id: uint }
  { weight: uint, timestamp: uint })
(define-map disputes
  { dispute-id: uint }
  { 
    challenger: principal, 
    target: principal, 
    domain-id: uint, 
    original-score: uint, 
    proposed-score: uint, 
    created-at: uint, 
    resolved: bool, 
    resolution: (optional uint)
  })

;; Variables
(define-data-var dispute-counter uint u0)
(define-data-var domain-counter uint u0)

;; Initialize domains
(define-public (initialize-domains)
  (begin
    (asserts! (is-eq tx-sender contract-owner) err-not-authorized)
    (asserts! (is-eq (var-get domain-counter) u0) err-already-initialized)
    
    ;; Initialize with some default domains
    (map-set domains { domain-id: u1 } { name: "Technical Skills", active: true })
    (map-set domains { domain-id: u2 } { name: "Communication", active: true })
    (map-set domains { domain-id: u3 } { name: "Reliability", active: true })
    (map-set domains { domain-id: u4 } { name: "Quality of Work", active: true })
    
    (var-set domain-counter u4)
    (ok true)
  )
)

;; Add a new domain
(define-public (add-domain (name (string-ascii 64)))
  (let ((new-id (+ (var-get domain-counter) u1)))
    (asserts! (is-eq tx-sender contract-owner) err-not-authorized)
    (map-set domains { domain-id: new-id } { name: name, active: true })
    (var-set domain-counter new-id)
    (ok new-id)
  )
)

;; Stake tokens to participate
(define-public (stake (amount uint))
  (let ((current-stake (default-to u0 (get amount (map-get? user-stakes { user: tx-sender })))))
    (try! (stx-transfer? amount tx-sender (as-contract tx-sender)))
    (map-set user-stakes { user: tx-sender } { amount: (+ current-stake amount) })
    (ok (+ current-stake amount))
  )
)

;; Update reputation score
(define-public (update-reputation (target principal) (domain-id uint) (score uint))
  (let (
    (staked-amount (default-to u0 (get amount (map-get? user-stakes { user: tx-sender }))))
    (domain (map-get? domains { domain-id: domain-id }))
    (current-data (map-get? reputation-scores { user: target, domain-id: domain-id }))
    (current-block-height block-height)
    (current-count (if (is-some current-data)
                      (get update-count (unwrap-panic current-data))
                      u0))
  )
    ;; Validate inputs
    (asserts! (>= staked-amount min-stake) err-insufficient-stake)
    (asserts! (is-some domain) err-invalid-domain)
    (asserts! (get active (unwrap-panic domain)) err-invalid-domain)
    (asserts! (and (>= score min-score) (<= score max-score)) err-invalid-score)
    
    ;; Check cooling period if previous update exists
    (if (is-some current-data)
      (asserts! (>= current-block-height (+ (get last-updated (unwrap-panic current-data)) cooling-period)) err-cooling-period)
      true
    )
    
    ;; Update the reputation score
    (map-set reputation-scores 
      { user: target, domain-id: domain-id } 
      { 
        score: score, 
        last-updated: current-block-height,
        update-count: (+ current-count u1)
      }
    )
    
    (ok score)
  )
)

;; Get reputation score
(define-public (get-reputation (user principal) (domain-id uint))
  (let ((reputation (map-get? reputation-scores { user: user, domain-id: domain-id })))
    (if (is-some reputation)
      (ok (get score (unwrap-panic reputation)))
      (err err-no-reputation)
    )
  )
)

;; Add an endorsement
(define-public (endorse (endorsee principal) (domain-id uint) (weight uint))
  (let (
    (staked-amount (default-to u0 (get amount (map-get? user-stakes { user: tx-sender }))))
    (domain (map-get? domains { domain-id: domain-id }))
  )
    ;; Validate inputs
    (asserts! (>= staked-amount min-stake) err-insufficient-stake)
    (asserts! (is-some domain) err-invalid-domain)
    (asserts! (get active (unwrap-panic domain)) err-invalid-domain)
    (asserts! (and (> weight u0) (<= weight u10)) err-invalid-score)
    
    ;; Add the endorsement
    (map-set endorsements
      { endorser: tx-sender, endorsee: endorsee, domain-id: domain-id }
      { weight: weight, timestamp: block-height }
    )
    
    (ok true)
  )
)

;; Dispute resolution mechanism
(define-public (create-dispute (target principal) (domain-id uint) (proposed-score uint))
  (let (
    (staked-amount (default-to u0 (get amount (map-get? user-stakes { user: tx-sender }))))
    (reputation (map-get? reputation-scores { user: target, domain-id: domain-id }))
    (dispute-id (+ (var-get dispute-counter) u1))
  )
    ;; Validate inputs
    (asserts! (>= staked-amount (* min-stake u2)) err-insufficient-stake)
    (asserts! (is-some reputation) err-no-reputation)
    (asserts! (and (>= proposed-score min-score) (<= proposed-score max-score)) err-invalid-score)
    
    ;; Create the dispute
    (map-set disputes
      { dispute-id: dispute-id }
      { 
        challenger: tx-sender,
        target: target,
        domain-id: domain-id,
        original-score: (get score (unwrap-panic reputation)),
        proposed-score: proposed-score,
        created-at: block-height,
        resolved: false,
        resolution: none
      }
    )
    
    ;; Update the dispute counter
    (var-set dispute-counter dispute-id)
    
    (ok dispute-id)
  )
)

;; Comprehensive dispute resolution function
(define-public (resolve-dispute (dispute-id uint) (resolution-type (string-ascii 10)) (resolution-score (optional uint)))
  (begin
    ;; First check if the dispute exists
    (let ((dispute (map-get? disputes { dispute-id: dispute-id })))
      (if (is-some dispute)
        (let (
          (dispute-data (unwrap-panic dispute))
          (current-block-height block-height)
          (is-owner (is-eq tx-sender contract-owner))
          (is-challenger (is-eq tx-sender (get challenger dispute-data)))
          (is-target (is-eq tx-sender (get target dispute-data)))
          (dispute-age (- current-block-height (get created-at dispute-data)))
          (reputation-key { user: (get target dispute-data), domain-id: (get domain-id dispute-data) })
          (current-rep-data (map-get? reputation-scores reputation-key))
          (current-count (if (is-some current-rep-data)
                            (get update-count (unwrap-panic current-rep-data))
                            u0))
        )
          ;; Check if dispute is already resolved
          (if (get resolved dispute-data)
            (err err-no-dispute)
            ;; Check if within dispute window
            (if (> dispute-age dispute-window)
              (err err-dispute-window-closed)
              ;; Process based on resolution type
              (if (is-eq resolution-type "accept")
                (if is-target
                  (begin
                    ;; Update the reputation score with the proposed score
                    (map-set reputation-scores 
                      reputation-key
                      { 
                        score: (get proposed-score dispute-data), 
                        last-updated: current-block-height,
                        update-count: (+ current-count u1)
                      }
                    )
                    
                    ;; Mark dispute as resolved
                    (map-set disputes
                      { dispute-id: dispute-id }
                      (merge dispute-data { 
                        resolved: true, 
                        resolution: (some (get proposed-score dispute-data)) 
                      })
                    )
                    
                    (ok true)
                  )
                  (err err-not-authorized)
                )
                (if (is-eq resolution-type "reject")
                  (if is-target
                    (begin
                      ;; Mark dispute as resolved with original score
                      (map-set disputes
                        { dispute-id: dispute-id }
                        (merge dispute-data { 
                          resolved: true, 
                          resolution: (some (get original-score dispute-data)) 
                        })
                      )
                      
                      (ok true)
                    )
                    (err err-not-authorized)
                  )
                  (if (is-eq resolution-type "arbitrate")
                    (if is-owner
                      (if (is-some resolution-score)
                        (let ((final-score (unwrap-panic resolution-score)))
                          ;; Validate the score
                          (if (and (>= final-score min-score) (<= final-score max-score))
                            (begin
                              ;; Update the reputation score with the arbitrated score
                              (map-set reputation-scores 
                                reputation-key
                                { 
                                  score: final-score, 
                                  last-updated: current-block-height,
                                  update-count: (+ current-count u1)
                                }
                              )
                              
                              ;; Mark dispute as resolved
                              (map-set disputes
                                { dispute-id: dispute-id }
                                (merge dispute-data { 
                                  resolved: true, 
                                  resolution: (some final-score) 
                                })
                              )
                              
                              (ok true)
                            )
                            (err err-invalid-score)
                          )
                        )
                        (err err-invalid-score)
                      )
                      (err err-not-authorized)
                    )
                    (err err-not-authorized)
                  )
                )
              )
            )
          )
        )
        (err err-no-dispute)
      )
    )
  )
)

