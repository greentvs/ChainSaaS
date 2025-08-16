;; ChainSaaS Subscription Token Contract
;; Clarity v2 (Stacks 2.1+)
;; Implements SIP-10 fungible token with subscription extensions:
;; - Minting tokens tied to subscription tiers and durations
;; - Burning for cancellations
;; - Transfers with optional restrictions
;; - Allowances for approved spending
;; - Subscription tracking: tiers, expirations, auto-renew flags
;; - Renewal logic based on block-height
;; - Admin controls, pausing, and events via print

(define-fungible-token subscription-token u6) ;; Micro-units, 6 decimals

(define-constant ERR-NOT-AUTHORIZED u100)
(define-constant ERR-INSUFFICIENT-BALANCE u101)
(define-constant ERR-INSUFFICIENT-ALLOWANCE u102)
(define-constant ERR-EXPIRED-SUBSCRIPTION u103)
(define-constant ERR-PAUSED u104)
(define-constant ERR-ZERO-ADDRESS u105)
(define-constant ERR-INVALID-TIER u106)
(define-constant ERR-INVALID-AMOUNT u107)
(define-constant ERR-ALREADY-SUBSCRIBED u108)
(define-constant ERR-NOT-RENEWABLE u109)

;; Token metadata (SIP-10 compliant)
(define-constant TOKEN-NAME "ChainSaaS Subscription Token")
(define-constant TOKEN-SYMBOL "CSST")
(define-constant TOKEN-DECIMALS u6)
(define-constant TOKEN-URI none) ;; Optional URI for metadata

;; Tiers definition (example: 3 tiers with different durations in blocks ~10min/block)
(define-constant TIER-BASIC u1) ;; ~1 month: 4320 blocks
(define-constant TIER-PRO u2) ;; ~3 months: 12960 blocks
(define-constant TIER-ENTERPRISE u3) ;; ~1 year: 52560 blocks

(define-map tier-durations uint uint)
(begin
  (map-set tier-durations TIER-BASIC u4320)
  (map-set tier-durations TIER-PRO u12960)
  (map-set tier-durations TIER-ENTERPRISE u52560)
)

;; Admin and state
(define-data-var admin principal tx-sender)
(define-data-var paused bool false)
(define-data-var minter principal tx-sender) ;; Separate minter role, e.g., payment router

;; Balances and allowances (SIP-10)
(define-map allowances {owner: principal, spender: principal} uint)

;; Subscription data
(define-map subscriptions principal {tier: uint, start-block: uint, duration: uint, auto-renew: bool, active: bool})

;; Events (using print for indexing)
(define-private (emit-event (event-type (string-ascii 32)) (data { key: (string-ascii 32), value: any }))
  (print {type: event-type, data: data})
)

;; Helper: is-admin
(define-private (is-admin)
  (is-eq tx-sender (var-get admin))
)

;; Helper: is-minter
(define-private (is-minter)
  (is-eq tx-sender (var-get minter))
)

;; Helper: ensure-not-paused
(define-private (ensure-not-paused)
  (asserts! (not (var-get paused)) (err ERR-PAUSED))
)

;; Helper: get-expiration (start + duration)
(define-private (get-expiration (sub {tier: uint, start-block: uint, duration: uint, auto-renew: bool, active: bool}))
  (+ (get start-block sub) (get duration sub))
)

;; Helper: is-sub-active (check against block-height)
(define-private (is-sub-active (user principal))
  (match (map-get? subscriptions user)
    some-sub (and (get active some-sub) (<= block-height (get-expiration some-sub)))
    false
  )
)

;; Admin: transfer admin
(define-public (transfer-admin (new-admin principal))
  (begin
    (asserts! (is-admin) (err ERR-NOT-AUTHORIZED))
    (asserts! (not (is-eq new-admin 'SP000000000000000000002Q6VF78)) (err ERR-ZERO-ADDRESS))
    (var-set admin new-admin)
    (emit-event "admin-transferred" {key: "new-admin", value: new-admin})
    (ok true)
  )
)

;; Admin: set minter (e.g., to payment router contract)
(define-public (set-minter (new-minter principal))
  (begin
    (asserts! (is-admin) (err ERR-NOT-AUTHORIZED))
    (asserts! (not (is-eq new-minter 'SP000000000000000000002Q6VF78)) (err ERR-ZERO-ADDRESS))
    (var-set minter new-minter)
    (emit-event "minter-set" {key: "new-minter", value: new-minter})
    (ok true)
  )
)

;; Admin: pause/unpause
(define-public (set-paused (pause bool))
  (begin
    (asserts! (is-admin) (err ERR-NOT-AUTHORIZED))
    (var-set paused pause)
    (emit-event "paused" {key: "status", value: pause})
    (ok pause)
  )
)

;; SIP-10: get-name
(define-read-only (get-name)
  (ok TOKEN-NAME)
)

;; SIP-10: get-symbol
(define-read-only (get-symbol)
  (ok TOKEN-SYMBOL)
)

;; SIP-10: get-decimals
(define-read-only (get-decimals)
  (ok TOKEN-DECIMALS)
)

;; SIP-10: get-token-uri
(define-read-only (get-token-uri)
  (ok TOKEN-URI)
)

;; SIP-10: get-total-supply
(define-read-only (get-total-supply)
  (ok (ft-get-supply subscription-token))
)

;; SIP-10: get-balance
(define-read-only (get-balance (account principal))
  (ok (ft-get-balance subscription-token account))
)

;; Subscription: get-subscription
(define-read-only (get-subscription (user principal))
  (ok (map-get? subscriptions user))
)

;; Subscription: is-active
(define-read-only (is-active (user principal))
  (ok (is-sub-active user))
)

;; SIP-10: transfer
(define-public (transfer (amount uint) (sender principal) (recipient principal) (memo (optional (buff 34))))
  (begin
    (ensure-not-paused)
    (asserts! (> amount u0) (err ERR-INVALID-AMOUNT))
    (asserts! (or (is-eq tx-sender sender) (>= (default-to u0 (map-get? allowances {owner: sender, spender: tx-sender})) amount)) (err ERR-NOT-AUTHORIZED))
    (asserts! (not (is-eq recipient 'SP000000000000000000002Q6VF78)) (err ERR-ZERO-ADDRESS))
    (try! (ft-transfer? subscription-token amount sender recipient))
    (if (is-some memo) (print {memo: (unwrap-panic memo)}) true)
    (emit-event "transfer" {key: "details", value: {amount: amount, from: sender, to: recipient}})
    (ok true)
  )
)

;; Allowance: approve
(define-public (approve (spender principal) (amount uint))
  (begin
    (ensure-not-paused)
    (asserts! (> amount u0) (err ERR-INVALID-AMOUNT))
    (asserts! (not (is-eq spender 'SP000000000000000000002Q6VF78)) (err ERR-ZERO-ADDRESS))
    (map-set allowances {owner: tx-sender, spender: spender} amount)
    (emit-event "approval" {key: "details", value: {amount: amount, owner: tx-sender, spender: spender}})
    (ok true)
  )
)

;; Allowance: increase-allowance
(define-public (increase-allowance (spender principal) (added uint))
  (begin
    (ensure-not-paused)
    (asserts! (> added u0) (err ERR-INVALID-AMOUNT))
    (asserts! (not (is-eq spender 'SP000000000000000000002Q6VF78)) (err ERR-ZERO-ADDRESS))
    (let ((current (default-to u0 (map-get? allowances {owner: tx-sender, spender: spender}))))
      (try! (approve spender (+ current added)))
      (ok true)
    )
  )
)

;; Allowance: decrease-allowance
(define-public (decrease-allowance (spender principal) (subtracted uint))
  (begin
    (ensure-not-paused)
    (asserts! (> subtracted u0) (err ERR-INVALID-AMOUNT))
    (asserts! (not (is-eq spender 'SP000000000000000000002Q6VF78)) (err ERR-ZERO-ADDRESS))
    (let ((current (default-to u0 (map-get? allowances {owner: tx-sender, spender: spender}))))
      (asserts! (>= current subtracted) (err ERR-INSUFFICIENT-ALLOWANCE))
      (try! (approve spender (- current subtracted)))
      (ok true)
    )
  )
)

;; Allowance: get-allowance
(define-read-only (get-allowance (owner principal) (spender principal))
  (ok (default-to u0 (map-get? allowances {owner: owner, spender: spender})))
)

;; Mint: subscribe-mint (called by minter, e.g., after payment)
(define-public (subscribe-mint (recipient principal) (tier uint) (amount uint) (auto-renew bool))
  (begin
    (asserts! (is-minter) (err ERR-NOT-AUTHORIZED))
    (asserts! (not (is-eq recipient 'SP000000000000000000002Q6VF78)) (err ERR-ZERO-ADDRESS))
    (asserts! (> amount u0) (err ERR-INVALID-AMOUNT))
    (asserts! (is-some (map-get? tier-durations tier)) (err ERR-INVALID-TIER))
    (asserts! (is-none (map-get? subscriptions recipient)) (err ERR-ALREADY-SUBSCRIBED))
    (let ((duration (unwrap-panic (map-get? tier-durations tier))))
      (try! (ft-mint? subscription-token amount recipient))
      (map-set subscriptions recipient {tier: tier, start-block: block-height, duration: duration, auto-renew: auto-renew, active: true})
      (emit-event "subscribed" {key: "details", value: {user: recipient, tier: tier, amount: amount}})
      (ok true)
    )
  )
)

;; Burn: cancel-burn
(define-public (cancel-burn)
  (begin
    (ensure-not-paused)
    (match (map-get? subscriptions tx-sender)
      some-sub (begin
        (asserts! (get active some-sub) (err ERR-EXPIRED-SUBSCRIPTION))
        (let ((balance (ft-get-balance subscription-token tx-sender))
              (expiration (get-expiration some-sub))
              (used-blocks (- block-height (get start-block some-sub)))
              (total-duration (get duration some-sub))
              (refund-amount (/ (* balance (- total-duration used-blocks)) total-duration))) ;; Prorated refund
          (asserts! (> balance u0) (err ERR-INSUFFICIENT-BALANCE))
          (try! (ft-burn? subscription-token balance tx-sender))
          (map-set subscriptions tx-sender (merge some-sub {active: false}))
          (emit-event "cancelled" {key: "details", value: {user: tx-sender, refund: refund-amount}})
          (ok refund-amount)
        )
      )
      (err ERR-EXPIRED-SUBSCRIPTION)
    )
  )
)

;; Renew: auto or manual renew
(define-public (renew (user principal))
  (begin
    (ensure-not-paused)
    (asserts! (not (is-eq user 'SP000000000000000000002Q6VF78)) (err ERR-ZERO-ADDRESS))
    (match (map-get? subscriptions user)
      some-sub (begin
        (asserts! (or (is-eq tx-sender user) (get auto-renew some-sub)) (err ERR-NOT-RENEWABLE))
        (asserts! (not (get active some-sub)) (err ERR-NOT-RENEWABLE))
        (let ((new-start block-height)
              (balance (ft-get-balance subscription-token user)))
          (asserts! (> balance u0) (err ERR-INSUFFICIENT-BALANCE))
          (map-set subscriptions user (merge some-sub {start-block: new-start, active: true}))
          (emit-event "renewed" {key: "details", value: {user: user, tier: (get tier some-sub)}})
          (ok true)
        )
      )
      (err ERR-EXPIRED-SUBSCRIPTION)
    )
  )
)

;; Utility: toggle-auto-renew
(define-public (toggle-auto-renew (enable bool))
  (begin
    (ensure-not-paused)
    (match (map-get? subscriptions tx-sender)
      some-sub (begin
        (map-set subscriptions tx-sender (merge some-sub {auto-renew: enable}))
        (emit-event "auto-renew-toggled" {key: "details", value: {user: tx-sender, enable: enable}})
        (ok true)
      )
      (err ERR-EXPIRED-SUBSCRIPTION)
    )
  )
)

;; Admin: emergency-burn (for disputes)
(define-public (emergency-burn (user principal) (amount uint))
  (begin
    (asserts! (is-admin) (err ERR-NOT-AUTHORIZED))
    (asserts! (not (is-eq user 'SP000000000000000000002Q6VF78)) (err ERR-ZERO-ADDRESS))
    (asserts! (> amount u0) (err ERR-INVALID-AMOUNT))
    (asserts! (>= (ft-get-balance subscription-token user) amount) (err ERR-INSUFFICIENT-BALANCE))
    (try! (as-contract (ft-burn? subscription-token amount user)))
    (emit-event "emergency-burn" {key: "details", value: {user: user, amount: amount}})
    (ok true)
  )
)

;; Read-only: get-admin
(define-read-only (get-admin)
  (ok (var-get admin))
)

;; Read-only: get-minter
(define-read-only (get-minter)
  (ok (var-get minter))
)

;; Read-only: is-paused
(define-read-only (is-paused)
  (ok (var-get paused))
)

;; Read-only: get-tier-duration
(define-read-only (get-tier-duration (tier uint))
  (ok (map-get? tier-durations tier))
)