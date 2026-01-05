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
(define-constant err-operation-not-found (err u410))
(define-constant err-operation-expired (err u411))
(define-constant err-operation-executed (err u412))
(define-constant err-already-approved (err u413))
(define-constant err-insufficient-approvals (err u414))

;; Maximum supply cap (10 billion tokens with 6 decimals)
(define-constant max-supply u10000000000000000)

;; Role definitions
(define-constant ROLE-ADMIN u1)
(define-constant ROLE-COMPLIANCE-OFFICER u2)
(define-constant ROLE-ASSET-MANAGER u3)
(define-constant ROLE-EMERGENCY-RESPONDER u4)

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
;; Role-Based Access Control
;; ================

;; Role mappings
(define-map user-roles principal uint)
(define-map role-permissions uint (list 20 (string-ascii 32)))

;; Multi-signature requirements for critical operations
(define-map pending-operations 
  uint 
  {
    operation-type: (string-ascii 32),
    target: principal,
    amount: uint,
    approvals: (list 5 principal),
    required-approvals: uint,
    expiry: uint,
    executed: bool
  }
)
(define-data-var operation-counter uint u0)

;; Initialize contract with owner as admin
(begin
  (map-set user-roles tx-sender ROLE-ADMIN)
  (map-set role-permissions ROLE-ADMIN (list "mint" "burn" "transfer-ownership" "set-roles" "emergency-pause" "update-metadata" "set-reserve-ratio"))
  (map-set role-permissions ROLE-COMPLIANCE-OFFICER (list "set-kyc" "freeze-account" "unfreeze-account" "batch-set-kyc"))
  (map-set role-permissions ROLE-ASSET-MANAGER (list "update-metadata" "set-reserve-ratio"))
  (map-set role-permissions ROLE-EMERGENCY-RESPONDER (list "emergency-freeze-multiple" "pause" "unpause"))
)

;; ================
;; Enhanced Access Control Functions
;; ================

(define-private (has-role (user principal) (role uint))
  (begin
    (asserts! (is-eq (default-to u0 (map-get? user-roles user)) role) err-unauthorized)
    (ok true)
  )
)

(define-private (has-permission (user principal) (permission (string-ascii 32)))
  (let ((user-role (default-to u0 (map-get? user-roles user)))
        (permissions (default-to (list) (map-get? role-permissions user-role))))
    (asserts! (is-some (index-of permissions permission)) err-unauthorized)
    (ok true)
  )
)

(define-private (is-owner-or-has-permission (user principal) (permission (string-ascii 32)))
  (if (is-eq user (var-get contract-owner))
    (ok true)
    (has-permission user permission)
  )
)

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

(define-private (emit-role-assigned (user principal) (role uint))
  (print {
    event: "role-assigned",
    user: user,
    role: role,
    block-height: stacks-block-height
  })
)

(define-private (emit-operation-created (op-id uint) (operation-type (string-ascii 32)))
  (print {
    event: "operation-created",
    operation-id: op-id,
    operation-type: operation-type,
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
;; Helper Functions for Batch Operations
;; ================

(define-private (assign-role-to-user (user principal) (role uint))
  (begin
    (map-set user-roles user role)
    (emit-role-assigned user role)
    true
  )
)

(define-private (set-kyc-for-user (user principal))
  (begin
    (map-set kyc-approved user true)
    (map-set kyc-expiry user (+ stacks-block-height u52560)) ;; 1 year from now
    (emit-kyc-update user true)
    true
  )
)

(define-private (freeze-user-account (user principal))
  (begin
    (map-set frozen-accounts user true)
    true
  )
)

;; ================
;; Role Management Functions
;; ================

(define-public (assign-role (user principal) (role uint))
  (begin
    (try! (only-owner))
    (asserts! (<= role ROLE-EMERGENCY-RESPONDER) err-invalid-amount)
    (asserts! (>= role ROLE-ADMIN) err-invalid-amount)
    (map-set user-roles user role)
    (emit-role-assigned user role)
    (ok true)
  )
)

(define-public (revoke-role (user principal))
  (begin
    (try! (only-owner))
    (map-delete user-roles user)
    (emit-role-assigned user u0)
    (ok true)
  )
)

(define-public (batch-assign-roles (users (list 10 principal)) (role uint))
  (begin
    (try! (only-owner))
    (asserts! (<= role ROLE-EMERGENCY-RESPONDER) err-invalid-amount)
    (asserts! (>= role ROLE-ADMIN) err-invalid-amount)
    (let ((results (fold assign-role-helper users {role: role, success: true})))
      (ok (get success results))
    )
  )
)

(define-private (assign-role-helper (user principal) (acc {role: uint, success: bool}))
  (begin
    (map-set user-roles user (get role acc))
    (emit-role-assigned user (get role acc))
    acc
  )
)

;; ================
;; Multi-Signature Operations
;; ================

(define-public (create-critical-operation 
  (operation-type (string-ascii 32)) 
  (target principal) 
  (amount uint) 
  (required-approvals uint))
  (begin
    (try! (is-owner-or-has-permission tx-sender operation-type))
    (asserts! (and (>= required-approvals u2) (<= required-approvals u5)) err-invalid-amount)
    (let ((op-id (var-get operation-counter)))
      (map-set pending-operations op-id {
        operation-type: operation-type,
        target: target,
        amount: amount,
        approvals: (list tx-sender),
        required-approvals: required-approvals,
        expiry: (+ stacks-block-height u1440), ;; 24 hours
        executed: false
      })
      (var-set operation-counter (+ op-id u1))
      (emit-operation-created op-id operation-type)
      (ok op-id)
    )
  )
)

(define-public (approve-operation (op-id uint))
  (match (map-get? pending-operations op-id)
    operation
      (let ((current-approvals (get approvals operation)))
        (try! (is-owner-or-has-permission tx-sender (get operation-type operation)))
        (asserts! (not (get executed operation)) err-operation-executed)
        (asserts! (< stacks-block-height (get expiry operation)) err-operation-expired)
        (asserts! (is-none (index-of current-approvals tx-sender)) err-already-approved)
        
        (let ((new-approvals (unwrap! (as-max-len? (append current-approvals tx-sender) u5) err-invalid-amount)))
          (map-set pending-operations op-id (merge operation {approvals: new-approvals}))
          (ok true)
        )
      )
    err-operation-not-found
  )
)

(define-public (execute-approved-operation (op-id uint))
  (match (map-get? pending-operations op-id)
    operation
      (begin
        (try! (is-owner-or-has-permission tx-sender (get operation-type operation)))
        (asserts! (not (get executed operation)) err-operation-executed)
        (asserts! (< stacks-block-height (get expiry operation)) err-operation-expired)
        (asserts! (>= (len (get approvals operation)) (get required-approvals operation)) err-insufficient-approvals)
        
        ;; Mark as executed
        (map-set pending-operations op-id (merge operation {executed: true}))
        
        ;; Execute based on operation type
        (if (is-eq (get operation-type operation) "emergency-pause")
          (begin
            (var-set paused true)
            (ok true)
          )
          (if (is-eq (get operation-type operation) "transfer-ownership")
            (begin
              (var-set contract-owner (get target operation))
              (ok true)
            )
            (ok true) ;; Default case for other operations
          )
        )
      )
    err-operation-not-found
  )
)

;; ================
;; Enhanced Admin Functions
;; ================

(define-public (set-kyc (user principal) (approved bool) (expiry-height uint))
  (begin
    (try! (is-owner-or-has-permission tx-sender "set-kyc"))
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
    (try! (is-owner-or-has-permission tx-sender "batch-set-kyc"))
    (let ((results (fold kyc-helper users {approved: approved, expiry: expiry-height, success: true})))
      (ok (get success results))
    )
  )
)

(define-private (kyc-helper (user principal) (acc {approved: bool, expiry: uint, success: bool}))
  (begin
    (map-set kyc-approved user (get approved acc))
    (if (get approved acc)
      (map-set kyc-expiry user (get expiry acc))
      (map-delete kyc-expiry user)
    )
    (emit-kyc-update user (get approved acc))
    acc
  )
)

(define-public (emergency-freeze-multiple (users (list 20 principal)))
  (begin
    (try! (is-owner-or-has-permission tx-sender "emergency-freeze-multiple"))
    (let ((results (fold freeze-helper users {success: true})))
      (ok (get success results))
    )
  )
)

(define-private (freeze-helper (user principal) (acc {success: bool}))
  (begin
    (map-set frozen-accounts user true)
    acc
  )
)

(define-public (set-reserve-ratio (new-ratio uint))
  (begin
    (try! (is-owner-or-has-permission tx-sender "set-reserve-ratio"))
    (asserts! (<= new-ratio u100) err-invalid-amount)
    (var-set reserve-ratio new-ratio)
    (ok new-ratio)
  )
)

(define-public (freeze-account (user principal))
  (begin
    (try! (is-owner-or-has-permission tx-sender "freeze-account"))
    (map-set frozen-accounts user true)
    (ok true)
  )
)

(define-public (unfreeze-account (user principal))
  (begin
    (try! (is-owner-or-has-permission tx-sender "unfreeze-account"))
    (map-set frozen-accounts user false)
    (ok true)
  )
)

(define-public (pause)
  (begin
    (try! (is-owner-or-has-permission tx-sender "pause"))
    (var-set paused true)
    (ok true)
  )
)

(define-public (unpause)
  (begin
    (try! (is-owner-or-has-permission tx-sender "unpause"))
    (var-set paused false)
    (ok true)
  )
)

(define-public (transfer-ownership (new-owner principal))
  (begin
    (try! (only-owner))
    (var-set contract-owner new-owner)
    ;; Assign admin role to new owner
    (map-set user-roles new-owner ROLE-ADMIN)
    (ok new-owner)
  )
)

;; ================
;; Enhanced Token Functions
;; ================

(define-public (mint (recipient principal) (amount uint) (metadata {description: (string-ascii 256), asset-type: (string-ascii 64), valuation: uint}))
  (begin
    (try! (is-owner-or-has-permission tx-sender "mint"))
    (try! (not-paused))
    (try! (valid-amount amount))
    (try! (not-frozen recipient))
    (try! (only-kyc-valid recipient))
    
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
        
        (try! (ft-mint? rwa-token amount recipient))
        (emit-mint recipient amount current-id)
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
    (try! (is-owner-or-has-permission tx-sender "update-metadata"))
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

;; ================
;; Role-Based Query Functions
;; ================

(define-read-only (get-user-role (user principal))
  (ok (default-to u0 (map-get? user-roles user)))
)

(define-read-only (get-role-permissions (role uint))
  (ok (default-to (list) (map-get? role-permissions role)))
)

(define-read-only (has-user-permission (user principal) (permission (string-ascii 32)))
  (let ((user-role (default-to u0 (map-get? user-roles user)))
        (permissions (default-to (list) (map-get? role-permissions user-role))))
    (ok (is-some (index-of permissions permission)))
  )
)

(define-read-only (get-pending-operation (op-id uint))
  (match (map-get? pending-operations op-id)
    operation (ok operation)
    err-operation-not-found
  )
)

(define-read-only (get-operation-status (op-id uint))
  (match (map-get? pending-operations op-id)
    operation 
      (ok {
        approvals-count: (len (get approvals operation)),
        required-approvals: (get required-approvals operation),
        executed: (get executed operation),
        expired: (> stacks-block-height (get expiry operation))
      })
    err-operation-not-found
  )
)

(define-read-only (can-execute-operation (op-id uint))
  (match (map-get? pending-operations op-id)
    operation
      (ok (and 
        (not (get executed operation))
        (< stacks-block-height (get expiry operation))
        (>= (len (get approvals operation)) (get required-approvals operation))
      ))
    (ok false)
  )
)
