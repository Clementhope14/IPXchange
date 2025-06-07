;; Intellectual Property Licensing Platform
;; A decentralized platform for managing IP licenses, royalties, and transfers

;; Constants
(define-constant CONTRACT-OWNER tx-sender)
(define-constant ERR-NOT-AUTHORIZED (err u100))
(define-constant ERR-NOT-FOUND (err u101))
(define-constant ERR-ALREADY-EXISTS (err u102))
(define-constant ERR-INVALID-LICENSE (err u103))
(define-constant ERR-INSUFFICIENT-PAYMENT (err u104))
(define-constant ERR-EXPIRED-LICENSE (err u105))
(define-constant ERR-INVALID-ROYALTY (err u106))
(define-constant ERR-TRANSFER-FAILED (err u107))

;; Data Variables
(define-data-var next-ip-id uint u1)
(define-data-var next-license-id uint u1)
(define-data-var platform-fee-rate uint u250) ;; 2.5% = 250/10000

;; IP Asset Structure
(define-map intellectual-properties
    { ip-id: uint }
    {
        owner: principal,
        title: (string-ascii 100),
        description: (string-ascii 500),
        ip-type: (string-ascii 20), ;; patent, trademark, copyright, trade-secret
        creation-date: uint,
        expiry-date: (optional uint),
        royalty-rate: uint, ;; basis points (100 = 1%)
        is-active: bool,
        metadata-uri: (optional (string-ascii 200))
    }
)

;; License Structure
(define-map licenses
    { license-id: uint }
    {
        ip-id: uint,
        licensee: principal,
        licensor: principal,
        license-type: (string-ascii 20), ;; exclusive, non-exclusive, sublicense
        start-date: uint,
        end-date: uint,
        territory: (string-ascii 50),
        field-of-use: (string-ascii 100),
        royalty-rate: uint,
        upfront-fee: uint,
        is-active: bool,
        terms-hash: (buff 32)
    }
)

;; Revenue tracking for IP owners
(define-map ip-revenue
    { ip-id: uint }
    {
        total-earned: uint,
        total-licenses: uint,
        last-payment: uint
    }
)

;; License usage tracking
(define-map license-usage
    { license-id: uint }
    {
        usage-count: uint,
        revenue-generated: uint,
        last-usage: uint,
        royalties-paid: uint
    }
)

;; Royalty payment records
(define-map royalty-payments
    { payment-id: uint }
    {
        license-id: uint,
        payer: principal,
        amount: uint,
        payment-date: uint,
        usage-period-start: uint,
        usage-period-end: uint
    }
)

;; Payment ID counter
(define-data-var next-payment-id uint u1)

;; Platform fee collection
(define-data-var total-platform-fees uint u0)

;; Read-only functions

;; Get IP details
(define-read-only (get-ip-details (ip-id uint))
    (map-get? intellectual-properties { ip-id: ip-id })
)

;; Get license details
(define-read-only (get-license-details (license-id uint))
    (map-get? licenses { license-id: license-id })
)

;; Get IP revenue
(define-read-only (get-ip-revenue (ip-id uint))
    (map-get? ip-revenue { ip-id: ip-id })
)

;; Get license usage
(define-read-only (get-license-usage (license-id uint))
    (map-get? license-usage { license-id: license-id })
)

;; Check if license is valid and active
(define-read-only (is-license-valid (license-id uint))
    (match (map-get? licenses { license-id: license-id })
        license-data
        (and 
            (get is-active license-data)
            (>= stacks-block-height (get start-date license-data))
            (<= stacks-block-height (get end-date license-data))
        )
        false
    )
)

;; Calculate royalty amount
(define-read-only (calculate-royalty (license-id uint) (revenue uint))
    (match (map-get? licenses { license-id: license-id })
        license-data
        (let ((royalty-rate (get royalty-rate license-data)))
            (/ (* revenue royalty-rate) u10000)
        )
        u0
    )
)

;; Get platform fee rate
(define-read-only (get-platform-fee-rate)
    (var-get platform-fee-rate)
)

;; Public functions

;; Register new intellectual property
(define-public (register-ip 
    (title (string-ascii 100))
    (description (string-ascii 500))
    (ip-type (string-ascii 20))
    (expiry-date (optional uint))
    (royalty-rate uint)
    (metadata-uri (optional (string-ascii 200)))
)
    (let ((ip-id (var-get next-ip-id)))
        ;; Validate royalty rate (max 50% = 5000 basis points)
        (asserts! (<= royalty-rate u5000) ERR-INVALID-ROYALTY)
        
        ;; Create IP record
        (map-set intellectual-properties
            { ip-id: ip-id }
            {
                owner: tx-sender,
                title: title,
                description: description,
                ip-type: ip-type,
                creation-date: stacks-block-height,
                expiry-date: expiry-date,
                royalty-rate: royalty-rate,
                is-active: true,
                metadata-uri: metadata-uri
            }
        )
        
        ;; Initialize revenue tracking
        (map-set ip-revenue
            { ip-id: ip-id }
            {
                total-earned: u0,
                total-licenses: u0,
                last-payment: u0
            }
        )
        
        ;; Increment IP counter
        (var-set next-ip-id (+ ip-id u1))
        
        (ok ip-id)
    )
)

;; Create a new license agreement
(define-public (create-license
    (ip-id uint)
    (licensee principal)
    (license-type (string-ascii 20))
    (end-date uint)
    (territory (string-ascii 50))
    (field-of-use (string-ascii 100))
    (custom-royalty-rate (optional uint))
    (upfront-fee uint)
    (terms-hash (buff 32))
)
    (let (
        (license-id (var-get next-license-id))
        (ip-data (unwrap! (map-get? intellectual-properties { ip-id: ip-id }) ERR-NOT-FOUND))
    )
        ;; Only IP owner can create licenses
        (asserts! (is-eq tx-sender (get owner ip-data)) ERR-NOT-AUTHORIZED)
        
        ;; Ensure IP is active
        (asserts! (get is-active ip-data) ERR-INVALID-LICENSE)
        
        ;; Validate end date
        (asserts! (> end-date stacks-block-height) ERR-INVALID-LICENSE)
        
        ;; Determine royalty rate (custom or default)
        (let ((final-royalty-rate 
                (default-to (get royalty-rate ip-data) custom-royalty-rate)))
            
            ;; Create license
            (map-set licenses
                { license-id: license-id }
                {
                    ip-id: ip-id,
                    licensee: licensee,
                    licensor: tx-sender,
                    license-type: license-type,
                    start-date: stacks-block-height,
                    end-date: end-date,
                    territory: territory,
                    field-of-use: field-of-use,
                    royalty-rate: final-royalty-rate,
                    upfront-fee: upfront-fee,
                    is-active: true,
                    terms-hash: terms-hash
                }
            )
            
            ;; Initialize license usage tracking
            (map-set license-usage
                { license-id: license-id }
                {
                    usage-count: u0,
                    revenue-generated: u0,
                    last-usage: u0,
                    royalties-paid: u0
                }
            )
            
            ;; Update IP license count
            (map-set ip-revenue
                { ip-id: ip-id }
                (merge 
                    (unwrap-panic (map-get? ip-revenue { ip-id: ip-id }))
                    { total-licenses: (+ (get total-licenses 
                        (unwrap-panic (map-get? ip-revenue { ip-id: ip-id }))) u1) }
                )
            )
            
            ;; Increment license counter
            (var-set next-license-id (+ license-id u1))
            
            (ok license-id)
        )
    )
)

;; Accept license and pay upfront fee
(define-public (accept-license (license-id uint))
    (let (
        (license-data (unwrap! (map-get? licenses { license-id: license-id }) ERR-NOT-FOUND))
        (upfront-fee (get upfront-fee license-data))
        (licensor (get licensor license-data))
        (platform-fee (/ (* upfront-fee (var-get platform-fee-rate)) u10000))
        (licensor-payment (- upfront-fee platform-fee))
    )
        ;; Only designated licensee can accept
        (asserts! (is-eq tx-sender (get licensee license-data)) ERR-NOT-AUTHORIZED)
        
        ;; Check if license is still valid
        (asserts! (get is-active license-data) ERR-INVALID-LICENSE)
        
        ;; Transfer upfront fee if required
        (if (> upfront-fee u0)
            (begin
                ;; Transfer payment to licensor
                (unwrap! (stx-transfer? licensor-payment tx-sender licensor) ERR-TRANSFER-FAILED)
                ;; Collect platform fee
                (unwrap! (stx-transfer? platform-fee tx-sender CONTRACT-OWNER) ERR-TRANSFER-FAILED)
                ;; Update platform fees
                (var-set total-platform-fees (+ (var-get total-platform-fees) platform-fee))
            )
            true
        )
        
        ;; Update IP revenue
        (let ((ip-id (get ip-id license-data)))
            (map-set ip-revenue
                { ip-id: ip-id }
                (merge 
                    (unwrap-panic (map-get? ip-revenue { ip-id: ip-id }))
                    { 
                        total-earned: (+ (get total-earned 
                            (unwrap-panic (map-get? ip-revenue { ip-id: ip-id }))) licensor-payment),
                        last-payment: stacks-block-height
                    }
                )
            )
        )
        
        (ok true)
    )
)

;; Pay royalties for license usage
(define-public (pay-royalty 
    (license-id uint) 
    (revenue uint)
    (usage-period-start uint)
    (usage-period-end uint)
)
    (let (
        (license-data (unwrap! (map-get? licenses { license-id: license-id }) ERR-NOT-FOUND))
        (royalty-amount (calculate-royalty license-id revenue))
        (platform-fee (/ (* royalty-amount (var-get platform-fee-rate)) u10000))
        (licensor-payment (- royalty-amount platform-fee))
        (payment-id (var-get next-payment-id))
        (licensor (get licensor license-data))
    )
        ;; Only licensee can pay royalties
        (asserts! (is-eq tx-sender (get licensee license-data)) ERR-NOT-AUTHORIZED)
        
        ;; Check if license is valid
        (asserts! (is-license-valid license-id) ERR-EXPIRED-LICENSE)
        
        ;; Transfer royalty payment
        (unwrap! (stx-transfer? licensor-payment tx-sender licensor) ERR-TRANSFER-FAILED)
        ;; Collect platform fee
        (unwrap! (stx-transfer? platform-fee tx-sender CONTRACT-OWNER) ERR-TRANSFER-FAILED)
        
        ;; Record payment
        (map-set royalty-payments
            { payment-id: payment-id }
            {
                license-id: license-id,
                payer: tx-sender,
                amount: royalty-amount,
                payment-date: stacks-block-height,
                usage-period-start: usage-period-start,
                usage-period-end: usage-period-end
            }
        )
        
        ;; Update license usage
        (map-set license-usage
            { license-id: license-id }
            (merge 
                (unwrap-panic (map-get? license-usage { license-id: license-id }))
                {
                    usage-count: (+ (get usage-count 
                        (unwrap-panic (map-get? license-usage { license-id: license-id }))) u1),
                    revenue-generated: (+ (get revenue-generated 
                        (unwrap-panic (map-get? license-usage { license-id: license-id }))) revenue),
                    last-usage: stacks-block-height,
                    royalties-paid: (+ (get royalties-paid 
                        (unwrap-panic (map-get? license-usage { license-id: license-id }))) royalty-amount)
                }
            )
        )
        
        ;; Update IP revenue
        (let ((ip-id (get ip-id license-data)))
            (map-set ip-revenue
                { ip-id: ip-id }
                (merge 
                    (unwrap-panic (map-get? ip-revenue { ip-id: ip-id }))
                    { 
                        total-earned: (+ (get total-earned 
                            (unwrap-panic (map-get? ip-revenue { ip-id: ip-id }))) licensor-payment),
                        last-payment: stacks-block-height
                    }
                )
            )
        )
        
        ;; Update platform fees
        (var-set total-platform-fees (+ (var-get total-platform-fees) platform-fee))
        
        ;; Increment payment counter
        (var-set next-payment-id (+ payment-id u1))
        
        (ok payment-id)
    )
)

;; Transfer IP ownership
(define-public (transfer-ip-ownership (ip-id uint) (new-owner principal))
    (let ((ip-data (unwrap! (map-get? intellectual-properties { ip-id: ip-id }) ERR-NOT-FOUND)))
        ;; Only current owner can transfer
        (asserts! (is-eq tx-sender (get owner ip-data)) ERR-NOT-AUTHORIZED)
        
        ;; Update IP ownership
        (map-set intellectual-properties
            { ip-id: ip-id }
            (merge ip-data { owner: new-owner })
        )
        
        (ok true)
    )
)

;; Deactivate IP (stop new licensing)
(define-public (deactivate-ip (ip-id uint))
    (let ((ip-data (unwrap! (map-get? intellectual-properties { ip-id: ip-id }) ERR-NOT-FOUND)))
        ;; Only owner can deactivate
        (asserts! (is-eq tx-sender (get owner ip-data)) ERR-NOT-AUTHORIZED)
        
        ;; Deactivate IP
        (map-set intellectual-properties
            { ip-id: ip-id }
            (merge ip-data { is-active: false })
        )
        
        (ok true)
    )
)

;; Terminate license
(define-public (terminate-license (license-id uint))
    (let ((license-data (unwrap! (map-get? licenses { license-id: license-id }) ERR-NOT-FOUND)))
        ;; Only licensor can terminate
        (asserts! (is-eq tx-sender (get licensor license-data)) ERR-NOT-AUTHORIZED)
        
        ;; Deactivate license
        (map-set licenses
            { license-id: license-id }
            (merge license-data { is-active: false })
        )
        
        (ok true)
    )
)

;; Admin function to update platform fee rate
(define-public (update-platform-fee-rate (new-rate uint))
    (begin
        ;; Only contract owner can update
        (asserts! (is-eq tx-sender CONTRACT-OWNER) ERR-NOT-AUTHORIZED)
        ;; Max 10% platform fee
        (asserts! (<= new-rate u1000) ERR-INVALID-ROYALTY)
        
        (var-set platform-fee-rate new-rate)
        (ok true)
    )
)

;; Withdraw platform fees (admin only)
(define-public (withdraw-platform-fees (amount uint))
    (begin
        ;; Only contract owner can withdraw
        (asserts! (is-eq tx-sender CONTRACT-OWNER) ERR-NOT-AUTHORIZED)
        ;; Check sufficient balance
        (asserts! (<= amount (var-get total-platform-fees)) ERR-INSUFFICIENT-PAYMENT)
        
        ;; Transfer fees
        (unwrap! (stx-transfer? amount (as-contract tx-sender) CONTRACT-OWNER) ERR-TRANSFER-FAILED)
        
        ;; Update fee counter
        (var-set total-platform-fees (- (var-get total-platform-fees) amount))
        
        (ok true)
    )
)