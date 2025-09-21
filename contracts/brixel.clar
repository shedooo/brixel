(define-fungible-token rwa-token)

;; ================
;; Constants & Errors
;; ================

(define-constant err-unauthorized (err u401))
(define-constant err-not-kyc (err u402))
(define-constant err-frozen (err u403))
(define-constant err-paused (err u404))
(define-constant err-insufficient-balance (err u405))
(define-constant err-invalid-amount (err u406))
(define-constant err-supply-cap-exceeded (err u407))
(define-constant err-metadata-not-found (err u408))
(define-constant err-invalid-metadata (err u409))

;; Maximum supply cap (10 billion tokens with 6 decimals)
(define-constant max-supply u10000000000000000)

;; ================
;; Data Variables
;; ================

(define-data-var contract-owner principal tx-sender)
(define-data-var paused bool false)
(define-data-var total-supply uint u0)

;; Compliance and access control
(define-map kyc-approved principal bool)
(define-map frozen-accounts principal bool)
(define-map kyc-expiry principal uint)

;; Enhanced metadata system
(define-map rwa-metadata uint {
  description: (string-ascii 256),
  asset-type: (string-ascii 64),
  valuation: uint,
  created-at: uint,
  updated-at: uint
})
(define-data-var metadata-counter uint u0)

;; Asset backing and reserves
(define-map asset-backing uint uint)
(define-data-var reserve-ratio uint u100)

;; ================
;; Events (Print statements for off-chain indexing)
;; ================

(define-private (emit-transfer (from principal) (to principal) (amount uint))
  (print {
    event: "transfer",
    from: from,
    to: to,
    amount: amount,
    block-height: stacks-block-height
  })
)

(define-private (emit-mint (to principal) (amount uint) (metadata-id uint))
  (print {
    event: "mint",
    to: to,
    amount: amount,
    metadata-id: metadata-id,
    block-height: stacks-block-height
  })
)

(define-private (emit-kyc-update (user principal) (approved bool))
  (print {
    event: "kyc-update",
    user: user,
    approved: approved,
    block-height: stacks-block-height
  })
)

;; ================
;; Enhanced Modifiers with Consistent Return Types
;; ================

(define-private (only-owner)
  (begin
    (asserts! (is-eq tx-sender (var-get contract-owner)) err-unauthorized)
    (ok true)
  )
)

(define-private (only-kyc-valid (user principal))
  (let ((kyc-status (default-to false (map-get? kyc-approved user)))
        (kyc-expiry-time (default-to u0 (map-get? kyc-expiry user))))
    (asserts! kyc-status err-not-kyc)
    (asserts! (> kyc-expiry-time stacks-block-height) err-not-kyc)
    (ok true)
  )
)

(define-private (not-frozen (user principal))
  (begin
    (asserts! (not (default-to false (map-get? frozen-accounts user))) err-frozen)
    (ok true)
  )
)

(define-private (not-paused)
  (begin
    (asserts! (not (var-get paused)) err-paused)
    (ok true)
  )
)

(define-private (valid-amount (amount uint))
  (begin
    (asserts! (> amount u0) err-invalid-amount)
    (ok true)
  )
)

;; ================
;; Enhanced Admin Functions
;; ================

(define-public (set-kyc (user principal) (approved bool) (expiry-height uint))
  (begin
    (try! (only-owner))
    (map-set kyc-approved user approved)
    (if approved
      (map-set kyc-expiry user expiry-height)
      (map-delete kyc-expiry user)
    )
    (emit-kyc-update user approved)
    (ok approved)
  )
)

(define-public (batch-set-kyc (users (list 50 principal)) (approved bool) (expiry-height uint))
  (begin
    (try! (only-owner))
    (ok (map set-single-kyc users))
  )
)

(define-private (set-single-kyc (user principal))
  (begin
    (map-set kyc-approved user true)
    (map-set kyc-expiry user (+ stacks-block-height u52560)) ;; 1 year from now
    true
  )
)

(define-public (emergency-freeze-multiple (users (list 20 principal)))
  (begin
    (try! (only-owner))
    (ok (map freeze-single-account users))
  )
)

(define-private (freeze-single-account (user principal))
  (begin
    (map-set frozen-accounts user true)
    true
  )
)

(define-public (set-reserve-ratio (new-ratio uint))
  (begin
    (try! (only-owner))
    (asserts! (<= new-ratio u100) err-invalid-amount)
    (var-set reserve-ratio new-ratio)
    (ok new-ratio)
  )
)

(define-public (freeze-account (user principal))
  (begin
    (try! (only-owner))
    (map-set frozen-accounts user true)
    (ok true)
  )
)

(define-public (unfreeze-account (user principal))
  (begin
    (try! (only-owner))
    (map-set frozen-accounts user false)
    (ok true)
  )
)

(define-public (pause)
  (begin
    (try! (only-owner))
    (var-set paused true)
    (ok true)
  )
)

(define-public (unpause)
  (begin
    (try! (only-owner))
    (var-set paused false)
    (ok true)
  )
)

(define-public (transfer-ownership (new-owner principal))
  (begin
    (try! (only-owner))
    (var-set contract-owner new-owner)
    (ok new-owner)
  )
)

;; ================
;; Enhanced Token Functions
;; ================

(define-public (mint (amount uint) (metadata {description: (string-ascii 256), asset-type: (string-ascii 64), valuation: uint}))
  (begin
    (try! (only-owner))
    (try! (not-paused))
    (try! (valid-amount amount))
    
    ;; Check supply cap
    (asserts! (<= (+ (var-get total-supply) amount) max-supply) err-supply-cap-exceeded)

    ;; Save enhanced metadata
    (let ((current-id (var-get metadata-counter))
          (current-time stacks-block-height))
      (begin
        (map-set rwa-metadata current-id {
          description: (get description metadata),
          asset-type: (get asset-type metadata),
          valuation: (get valuation metadata),
          created-at: current-time,
          updated-at: current-time
        })
        (map-set asset-backing current-id (get valuation metadata))
        (var-set metadata-counter (+ current-id u1))
        (var-set total-supply (+ (var-get total-supply) amount))
        
        (try! (ft-mint? rwa-token amount tx-sender))
        (emit-mint tx-sender amount current-id)
        (ok current-id)
      )
    )
  )
)

(define-public (transfer (recipient principal) (amount uint))
  (begin
    (try! (not-paused))
    (try! (valid-amount amount))
    (try! (not-frozen tx-sender))
    (try! (not-frozen recipient))
    (try! (only-kyc-valid tx-sender))
    (try! (only-kyc-valid recipient))

    ;; Check sufficient balance
    (asserts! (>= (ft-get-balance rwa-token tx-sender) amount) err-insufficient-balance)

    (try! (ft-transfer? rwa-token amount tx-sender recipient))
    (emit-transfer tx-sender recipient amount)
    (ok true)
  )
)

(define-public (burn (amount uint))
  (begin
    (try! (not-paused))
    (try! (valid-amount amount))
    (try! (not-frozen tx-sender))
    (try! (only-kyc-valid tx-sender))
    
    (asserts! (>= (ft-get-balance rwa-token tx-sender) amount) err-insufficient-balance)
    
    (try! (ft-burn? rwa-token amount tx-sender))
    (var-set total-supply (- (var-get total-supply) amount))
    (ok true)
  )
)

;; ================
;; Enhanced Metadata & Query Functions
;; ================

(define-public (update-metadata (id uint) (new-metadata {description: (string-ascii 256), asset-type: (string-ascii 64), valuation: uint}))
  (begin
    (try! (only-owner))
    (match (map-get? rwa-metadata id)
      existing-metadata 
        (begin
          (map-set rwa-metadata id {
            description: (get description new-metadata),
            asset-type: (get asset-type new-metadata),
            valuation: (get valuation new-metadata),
            created-at: (get created-at existing-metadata),
            updated-at: stacks-block-height
          })
          (map-set asset-backing id (get valuation new-metadata))
          (ok true)
        )
      err-metadata-not-found
    )
  )
)

(define-read-only (get-enhanced-metadata (id uint))
  (match (map-get? rwa-metadata id)
    metadata (ok metadata)
    err-metadata-not-found
  )
)

(define-read-only (get-asset-backing (id uint))
  (ok (default-to u0 (map-get? asset-backing id)))
)

(define-read-only (get-kyc-expiry (user principal))
  (ok (default-to u0 (map-get? kyc-expiry user)))
)

(define-read-only (get-total-supply)
  (ok (var-get total-supply))
)

(define-read-only (get-reserve-ratio)
  (ok (var-get reserve-ratio))
)

(define-read-only (get-contract-info)
  (ok {
    total-supply: (var-get total-supply),
    max-supply: max-supply,
    paused: (var-get paused),
    owner: (var-get contract-owner),
    reserve-ratio: (var-get reserve-ratio),
    metadata-counter: (var-get metadata-counter)
  })
)

(define-read-only (get-metadata (id uint))
  (match (map-get? rwa-metadata id)
    metadata (ok (get description metadata))
    err-metadata-not-found
  )
)

(define-read-only (get-token-balance (user principal))
  (ok (ft-get-balance rwa-token user))
)

(define-read-only (is-kyc-approved (user principal))
  (ok (default-to false (map-get? kyc-approved user)))
)

(define-read-only (is-frozen (user principal))
  (ok (default-to false (map-get? frozen-accounts user)))
)

(define-read-only (is-paused)
  (ok (var-get paused))
)

(define-read-only (get-owner)
  (ok (var-get contract-owner))
)