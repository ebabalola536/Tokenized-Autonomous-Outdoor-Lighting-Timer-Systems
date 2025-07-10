;; Malfunction Detection Contract
;; Identifies timer failures and repair needs

;; Constants
(define-constant CONTRACT-OWNER tx-sender)
(define-constant ERR-NOT-AUTHORIZED (err u400))
(define-constant ERR-INVALID-FIXTURE (err u401))
(define-constant ERR-INVALID-REPORT (err u402))
(define-constant ERR-REPORT-NOT-FOUND (err u403))

;; Data Variables
(define-data-var next-report-id uint u1)
(define-data-var maintenance-threshold uint u3)

;; Data Maps
(define-map fixture-health
  { fixture-id: uint }
  {
    status: uint, ;; 0=healthy, 1=warning, 2=critical, 3=offline
    last-heartbeat: uint,
    failure-count: uint,
    uptime-percentage: uint,
    owner: principal,
    registered-at: uint
  }
)

(define-map malfunction-reports
  { report-id: uint }
  {
    fixture-id: uint,
    issue-type: (string-ascii 50),
    severity: uint, ;; 1=low, 2=medium, 3=high, 4=critical
    description: (string-ascii 200),
    reported-by: principal,
    reported-at: uint,
    resolved: bool,
    resolution-notes: (string-ascii 200)
  }
)

(define-map maintenance-schedule
  { fixture-id: uint }
  {
    last-maintenance: uint,
    next-maintenance: uint,
    maintenance-type: (string-ascii 30),
    technician-assigned: (optional principal),
    estimated-cost: uint
  }
)

(define-map system-alerts
  { fixture-id: uint }
  {
    alert-level: uint,
    alert-message: (string-ascii 100),
    alert-timestamp: uint,
    acknowledged: bool,
    auto-generated: bool
  }
)

;; Private Functions
(define-private (is-fixture-owner (fixture-id uint) (user principal))
  (match (map-get? fixture-health { fixture-id: fixture-id })
    health-data (is-eq (get owner health-data) user)
    false
  )
)

(define-private (calculate-uptime-percentage (last-heartbeat uint) (registered-at uint))
  (let
    (
      (current-block block-height)
      (total-time (- current-block registered-at))
      (downtime (- current-block last-heartbeat))
    )
    (if (is-eq total-time u0)
      u100
      (- u100 (/ (* downtime u100) total-time))
    )
  )
)

(define-private (determine-health-status (failure-count uint) (uptime-percentage uint))
  (if (< uptime-percentage u50)
    u3 ;; Offline
    (if (< uptime-percentage u80)
      u2 ;; Critical
      (if (or (> failure-count u5) (< uptime-percentage u95))
        u1 ;; Warning
        u0 ;; Healthy
      )
    )
  )
)

;; Public Functions
(define-public (register-fixture-health (fixture-id uint))
  (let
    (
      (current-time block-height)
    )
    (asserts! (is-none (map-get? fixture-health { fixture-id: fixture-id })) ERR-NOT-AUTHORIZED)

    (map-set fixture-health
      { fixture-id: fixture-id }
      {
        status: u0,
        last-heartbeat: current-time,
        failure-count: u0,
        uptime-percentage: u100,
        owner: tx-sender,
        registered-at: current-time
      }
    )

    (map-set maintenance-schedule
      { fixture-id: fixture-id }
      {
        last-maintenance: current-time,
        next-maintenance: (+ current-time u2592000), ;; 30 days
        maintenance-type: "routine",
        technician-assigned: none,
        estimated-cost: u0
      }
    )

    (ok fixture-id)
  )
)

(define-public (send-heartbeat (fixture-id uint))
  (match (map-get? fixture-health { fixture-id: fixture-id })
    health-data
    (let
      (
        (current-time block-height)
        (uptime-percentage (calculate-uptime-percentage current-time (get registered-at health-data)))
        (new-status (determine-health-status (get failure-count health-data) uptime-percentage))
      )
      (asserts! (is-fixture-owner fixture-id tx-sender) ERR-NOT-AUTHORIZED)

      (map-set fixture-health
        { fixture-id: fixture-id }
        (merge health-data {
          last-heartbeat: current-time,
          uptime-percentage: uptime-percentage,
          status: new-status
        })
      )

      (ok current-time)
    )
    ERR-INVALID-FIXTURE
  )
)

(define-public (report-malfunction
  (fixture-id uint)
  (issue-type (string-ascii 50))
  (severity uint)
  (description (string-ascii 200)))
  (let
    (
      (report-id (var-get next-report-id))
      (current-time block-height)
    )
    (asserts! (and (>= severity u1) (<= severity u4)) ERR-INVALID-REPORT)
    (asserts! (> (len issue-type) u0) ERR-INVALID-REPORT)

    (map-set malfunction-reports
      { report-id: report-id }
      {
        fixture-id: fixture-id,
        issue-type: issue-type,
        severity: severity,
        description: description,
        reported-by: tx-sender,
        reported-at: current-time,
        resolved: false,
        resolution-notes: ""
      }
    )

    ;; Update fixture health
    (match (map-get? fixture-health { fixture-id: fixture-id })
      health-data
      (let
        (
          (new-failure-count (+ (get failure-count health-data) u1))
          (uptime-percentage (get uptime-percentage health-data))
          (new-status (determine-health-status new-failure-count uptime-percentage))
        )
        (map-set fixture-health
          { fixture-id: fixture-id }
          (merge health-data {
            failure-count: new-failure-count,
            status: new-status
          })
        )

        ;; Generate system alert for high severity issues
        (if (>= severity u3)
          (map-set system-alerts
            { fixture-id: fixture-id }
            {
              alert-level: severity,
              alert-message: "Critical malfunction detected",
              alert-timestamp: current-time,
              acknowledged: false,
              auto-generated: true
            }
          )
          true
        )
      )
      true
    )

    (var-set next-report-id (+ report-id u1))
    (ok report-id)
  )
)

(define-public (resolve-malfunction (report-id uint) (resolution-notes (string-ascii 200)))
  (match (map-get? malfunction-reports { report-id: report-id })
    report-data
    (begin
      (asserts! (or
        (is-fixture-owner (get fixture-id report-data) tx-sender)
        (is-eq tx-sender CONTRACT-OWNER)
      ) ERR-NOT-AUTHORIZED)
      (asserts! (not (get resolved report-data)) ERR-INVALID-REPORT)

      (map-set malfunction-reports
        { report-id: report-id }
        (merge report-data {
          resolved: true,
          resolution-notes: resolution-notes
        })
      )

      (ok report-id)
    )
    ERR-REPORT-NOT-FOUND
  )
)

(define-public (schedule-maintenance (fixture-id uint) (maintenance-type (string-ascii 30)) (estimated-cost uint))
  (match (map-get? maintenance-schedule { fixture-id: fixture-id })
    schedule-data
    (let
      (
        (current-time block-height)
        (next-maintenance-time (+ current-time u604800)) ;; 7 days from now
      )
      (asserts! (is-fixture-owner fixture-id tx-sender) ERR-NOT-AUTHORIZED)

      (map-set maintenance-schedule
        { fixture-id: fixture-id }
        (merge schedule-data {
          next-maintenance: next-maintenance-time,
          maintenance-type: maintenance-type,
          estimated-cost: estimated-cost
        })
      )

      (ok next-maintenance-time)
    )
    ERR-INVALID-FIXTURE
  )
)

(define-public (acknowledge-alert (fixture-id uint))
  (match (map-get? system-alerts { fixture-id: fixture-id })
    alert-data
    (begin
      (asserts! (is-fixture-owner fixture-id tx-sender) ERR-NOT-AUTHORIZED)

      (map-set system-alerts
        { fixture-id: fixture-id }
        (merge alert-data { acknowledged: true })
      )

      (ok true)
    )
    ERR-INVALID-FIXTURE
  )
)

;; Read-only Functions
(define-read-only (get-fixture-health (fixture-id uint))
  (map-get? fixture-health { fixture-id: fixture-id })
)

(define-read-only (get-malfunction-report (report-id uint))
  (map-get? malfunction-reports { report-id: report-id })
)

(define-read-only (get-maintenance-schedule (fixture-id uint))
  (map-get? maintenance-schedule { fixture-id: fixture-id })
)

(define-read-only (get-system-alert (fixture-id uint))
  (map-get? system-alerts { fixture-id: fixture-id })
)

(define-read-only (is-fixture-healthy (fixture-id uint))
  (match (map-get? fixture-health { fixture-id: fixture-id })
    health-data (is-eq (get status health-data) u0)
    false
  )
)

(define-read-only (get-uptime-percentage (fixture-id uint))
  (match (map-get? fixture-health { fixture-id: fixture-id })
    health-data (some (get uptime-percentage health-data))
    none
  )
)

(define-read-only (needs-maintenance (fixture-id uint))
  (match (map-get? maintenance-schedule { fixture-id: fixture-id })
    schedule-data
    (let
      (
        (current-time block-height)
        (next-maintenance (get next-maintenance schedule-data))
      )
      (>= current-time next-maintenance)
    )
    false
  )
)

(define-read-only (get-failure-count (fixture-id uint))
  (match (map-get? fixture-health { fixture-id: fixture-id })
    health-data (some (get failure-count health-data))
    none
  )
)
