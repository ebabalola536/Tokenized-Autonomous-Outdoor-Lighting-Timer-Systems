;; Energy Efficiency Contract
;; Optimizes power consumption and bulb longevity

;; Constants
(define-constant CONTRACT-OWNER tx-sender)
(define-constant ERR-NOT-AUTHORIZED (err u200))
(define-constant ERR-INVALID-FIXTURE (err u201))
(define-constant ERR-INVALID-READING (err u202))
(define-constant ERR-INSUFFICIENT-DATA (err u203))

;; Data Variables
(define-data-var efficiency-threshold uint u80)
(define-data-var max-daily-hours uint u12)

;; Data Maps
(define-map fixture-energy-data
  { fixture-id: uint }
  {
    total-consumption: uint,
    daily-consumption: uint,
    operating-hours: uint,
    efficiency-rating: uint,
    bulb-health: uint,
    last-updated: uint,
    owner: principal
  }
)

(define-map daily-usage-history
  { fixture-id: uint, day: uint }
  {
    consumption: uint,
    hours-active: uint,
    peak-usage: uint,
    efficiency-score: uint
  }
)

(define-map efficiency-rewards
  { fixture-id: uint }
  {
    total-rewards: uint,
    last-reward-block: uint,
    efficiency-streak: uint
  }
)

;; Private Functions
(define-private (calculate-efficiency-rating (consumption uint) (hours uint))
  (if (is-eq hours u0)
    u0
    (let
      (
        (efficiency-ratio (/ (* consumption u100) hours))
        (base-rating u100)
      )
      (if (<= efficiency-ratio u50)
        u100
        (if (<= efficiency-ratio u75)
          u80
          (if (<= efficiency-ratio u100)
            u60
            u40
          )
        )
      )
    )
  )
)

(define-private (calculate-bulb-health (operating-hours uint) (efficiency-rating uint))
  (let
    (
      (health-factor (if (> operating-hours u8760) ;; More than a year of operation
        (- u100 (/ operating-hours u876)) ;; Decrease health over time
        u100
      ))
      (efficiency-bonus (/ efficiency-rating u10))
    )
    (+ health-factor efficiency-bonus)
  )
)

(define-private (is-fixture-owner (fixture-id uint) (user principal))
  (match (map-get? fixture-energy-data { fixture-id: fixture-id })
    fixture-data (is-eq (get owner fixture-data) user)
    false
  )
)

;; Public Functions
(define-public (register-fixture-energy (fixture-id uint))
  (let
    (
      (current-time stacks-block-height)
    )
    (asserts! (is-none (map-get? fixture-energy-data { fixture-id: fixture-id })) ERR-NOT-AUTHORIZED)

    (map-set fixture-energy-data
      { fixture-id: fixture-id }
      {
        total-consumption: u0,
        daily-consumption: u0,
        operating-hours: u0,
        efficiency-rating: u100,
        bulb-health: u100,
        last-updated: current-time,
        owner: tx-sender
      }
    )

    (map-set efficiency-rewards
      { fixture-id: fixture-id }
      {
        total-rewards: u0,
        last-reward-block: stacks-block-height,
        efficiency-streak: u0
      }
    )

    (ok fixture-id)
  )
)

(define-public (update-energy-consumption (fixture-id uint) (consumption uint) (hours-active uint))
  (match (map-get? fixture-energy-data { fixture-id: fixture-id })
    fixture-data
    (let
      (
        (current-time stacks-block-height)
        (new-total-consumption (+ (get total-consumption fixture-data) consumption))
        (new-operating-hours (+ (get operating-hours fixture-data) hours-active))
        (efficiency-rating (calculate-efficiency-rating consumption hours-active))
        (bulb-health (calculate-bulb-health new-operating-hours efficiency-rating))
      )
      (asserts! (is-fixture-owner fixture-id tx-sender) ERR-NOT-AUTHORIZED)
      (asserts! (> consumption u0) ERR-INVALID-READING)
      (asserts! (<= hours-active (var-get max-daily-hours)) ERR-INVALID-READING)

      (map-set fixture-energy-data
        { fixture-id: fixture-id }
        (merge fixture-data {
          total-consumption: new-total-consumption,
          daily-consumption: consumption,
          operating-hours: new-operating-hours,
          efficiency-rating: efficiency-rating,
          bulb-health: bulb-health,
          last-updated: current-time
        })
      )

      ;; Record daily usage
      (map-set daily-usage-history
        { fixture-id: fixture-id, day: (/ current-time u86400) }
        {
          consumption: consumption,
          hours-active: hours-active,
          peak-usage: consumption,
          efficiency-score: efficiency-rating
        }
      )

      (ok efficiency-rating)
    )
    ERR-INVALID-FIXTURE
  )
)

(define-public (optimize-power-settings (fixture-id uint) (target-efficiency uint))
  (match (map-get? fixture-energy-data { fixture-id: fixture-id })
    fixture-data
    (begin
      (asserts! (is-fixture-owner fixture-id tx-sender) ERR-NOT-AUTHORIZED)
      (asserts! (and (>= target-efficiency u50) (<= target-efficiency u100)) ERR-INVALID-READING)

      (let
        (
          (current-efficiency (get efficiency-rating fixture-data))
          (optimization-factor (if (> target-efficiency current-efficiency)
            (+ u100 (- target-efficiency current-efficiency))
            (- u100 (- current-efficiency target-efficiency))
          ))
        )
        (ok optimization-factor)
      )
    )
    ERR-INVALID-FIXTURE
  )
)

(define-public (claim-efficiency-reward (fixture-id uint))
  (match (map-get? fixture-energy-data { fixture-id: fixture-id })
    fixture-data
    (match (map-get? efficiency-rewards { fixture-id: fixture-id })
      reward-data
      (let
        (
          (efficiency-rating (get efficiency-rating fixture-data))
          (threshold-value (var-get efficiency-threshold))
          (blocks-since-last-reward (- stacks-block-height (get last-reward-block reward-data)))
          (reward-amount (if (>= efficiency-rating threshold-value)
            (* efficiency-rating blocks-since-last-reward)
            u0
          ))
        )
        (asserts! (is-fixture-owner fixture-id tx-sender) ERR-NOT-AUTHORIZED)
        (asserts! (>= efficiency-rating threshold-value) ERR-INSUFFICIENT-DATA)
        (asserts! (> blocks-since-last-reward u144) ERR-INSUFFICIENT-DATA) ;; At least 1 day

        (map-set efficiency-rewards
          { fixture-id: fixture-id }
          (merge reward-data {
            total-rewards: (+ (get total-rewards reward-data) reward-amount),
            last-reward-block: stacks-block-height,
            efficiency-streak: (+ (get efficiency-streak reward-data) u1)
          })
        )

        (ok reward-amount)
      )
      ERR-INVALID-FIXTURE
    )
    ERR-INVALID-FIXTURE
  )
)

;; Read-only Functions
(define-read-only (get-fixture-energy-data (fixture-id uint))
  (map-get? fixture-energy-data { fixture-id: fixture-id })
)

(define-read-only (get-efficiency-rating (fixture-id uint))
  (match (map-get? fixture-energy-data { fixture-id: fixture-id })
    fixture-data (some (get efficiency-rating fixture-data))
    none
  )
)

(define-read-only (get-bulb-health (fixture-id uint))
  (match (map-get? fixture-energy-data { fixture-id: fixture-id })
    fixture-data (some (get bulb-health fixture-data))
    none
  )
)

(define-read-only (get-daily-usage (fixture-id uint) (day uint))
  (map-get? daily-usage-history { fixture-id: fixture-id, day: day })
)

(define-read-only (get-efficiency-rewards (fixture-id uint))
  (map-get? efficiency-rewards { fixture-id: fixture-id })
)

(define-read-only (calculate-projected-savings (fixture-id uint) (target-efficiency uint))
  (match (map-get? fixture-energy-data { fixture-id: fixture-id })
    fixture-data
    (let
      (
        (current-consumption (get daily-consumption fixture-data))
        (current-efficiency (get efficiency-rating fixture-data))
        (improvement-factor (if (> target-efficiency current-efficiency)
          (/ target-efficiency current-efficiency)
          u1
        ))
        (projected-consumption (/ current-consumption improvement-factor))
        (savings (- current-consumption projected-consumption))
      )
      (some savings)
    )
    none
  )
)
