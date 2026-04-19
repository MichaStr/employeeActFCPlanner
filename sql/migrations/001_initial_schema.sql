-- +goose Up

-- ============================================================
-- 1. LOOKUP / REFERENCE TABLES
-- ============================================================

-- costcenters: self-referential hierarchy (division → department → costcenter)
-- The FK back to self is added after the table exists.
CREATE TABLE costcenters (
    id         UUID         NOT NULL DEFAULT gen_random_uuid() PRIMARY KEY,
    code       VARCHAR(50)  NOT NULL,
    name       VARCHAR(255) NOT NULL,
    level      SMALLINT     NOT NULL,
    parent_id  UUID,                            -- FK added below
    is_active  BOOLEAN      NOT NULL DEFAULT true,
    created_at TIMESTAMPTZ  NOT NULL DEFAULT now(),
    updated_at TIMESTAMPTZ  NOT NULL DEFAULT now(),

    CONSTRAINT uq_costcenters_code  UNIQUE (code),
    CONSTRAINT chk_costcenters_level CHECK (level BETWEEN 1 AND 10)
);

ALTER TABLE costcenters
    ADD CONSTRAINT fk_costcenters_parent
        FOREIGN KEY (parent_id) REFERENCES costcenters (id);

CREATE INDEX idx_costcenters_parent_id ON costcenters (parent_id) WHERE parent_id IS NOT NULL;
CREATE INDEX idx_costcenters_level     ON costcenters (level);
CREATE INDEX idx_costcenters_is_active ON costcenters (is_active);

COMMENT ON TABLE  costcenters           IS 'Self-referential cost-center hierarchy. Walk with WITH RECURSIVE to aggregate FTE up the tree.';
COMMENT ON COLUMN costcenters.level     IS '1 = division, 2 = department, 3 = costcenter (leaf). Informational — tree depth is not DB-enforced.';
COMMENT ON COLUMN costcenters.parent_id IS 'NULL for root nodes.';

-- ------------------------------------------------------------

CREATE TABLE employee_groups (
    id         UUID         NOT NULL DEFAULT gen_random_uuid() PRIMARY KEY,
    code       VARCHAR(50)  NOT NULL,
    label      VARCHAR(255) NOT NULL,
    sort_order SMALLINT     NOT NULL DEFAULT 0,
    is_active  BOOLEAN      NOT NULL DEFAULT true,

    CONSTRAINT uq_employee_groups_code UNIQUE (code)
);

COMMENT ON TABLE employee_groups IS 'Lookup for the empl_group field. Seed: Executive, Manager, Engineer, Support, Operator.';

-- ------------------------------------------------------------

CREATE TABLE classification_types (
    id         UUID         NOT NULL DEFAULT gen_random_uuid() PRIMARY KEY,
    code       VARCHAR(50)  NOT NULL,
    label      VARCHAR(255) NOT NULL,
    sort_order SMALLINT     NOT NULL DEFAULT 0,
    is_active  BOOLEAN      NOT NULL DEFAULT true,

    CONSTRAINT uq_classification_types_code UNIQUE (code)
);

COMMENT ON TABLE classification_types IS 'Extensible lookup for the direct/indirect axis. Extend with INSERT — no ALTER TYPE needed.';

-- ============================================================
-- 2. USERS & SYSTEM CONFIGURATION
-- ============================================================

CREATE TABLE users (
    id           UUID         NOT NULL DEFAULT gen_random_uuid() PRIMARY KEY,
    email        VARCHAR(255) NOT NULL,
    display_name VARCHAR(255) NOT NULL,
    is_active    BOOLEAN      NOT NULL DEFAULT true,
    created_at   TIMESTAMPTZ  NOT NULL DEFAULT now(),
    updated_at   TIMESTAMPTZ  NOT NULL DEFAULT now(),

    CONSTRAINT uq_users_email UNIQUE (email)
);

COMMENT ON TABLE users IS 'Application users — department heads, planners, admins, readers. Referenced by all audit FK columns.';

-- ------------------------------------------------------------

CREATE TABLE system_config (
    key         VARCHAR(100) NOT NULL PRIMARY KEY,
    value       TEXT         NOT NULL,
    description TEXT,
    updated_at  TIMESTAMPTZ  NOT NULL DEFAULT now(),
    updated_by  UUID         REFERENCES users (id)
);

COMMENT ON TABLE  system_config     IS 'Runtime key/value settings. Cast value to the required type in the application layer.';
COMMENT ON COLUMN system_config.key IS 'Known keys: fc_horizon_months (int), fc_lock_day (int 1-28), import_source_label (string).';

-- ============================================================
-- 3. SAP EMPLOYEE IDENTITY
-- ============================================================

CREATE TABLE employees (
    id          UUID        NOT NULL DEFAULT gen_random_uuid() PRIMARY KEY,
    employee_id VARCHAR(50) NOT NULL,
    created_at  TIMESTAMPTZ NOT NULL DEFAULT now(),

    CONSTRAINT uq_employees_employee_id UNIQUE (employee_id)
);

COMMENT ON TABLE  employees             IS 'Thin identity anchor — one row per real SAP employee, ever. All mutable attributes live in employee_actuals or forecast_entries.';
COMMENT ON COLUMN employees.employee_id IS 'SAP personnel number (Personalnummer). Stable cross-system key — must never be updated.';

-- ============================================================
-- 4. PLANNING CONTAINERS (virtual HC buckets)
-- ============================================================

CREATE TABLE planning_containers (
    id            UUID         NOT NULL DEFAULT gen_random_uuid() PRIMARY KEY,
    empl_plan_no  VARCHAR(50)  NOT NULL,
    costcenter_id UUID         NOT NULL REFERENCES costcenters (id),
    label         VARCHAR(255) NOT NULL,
    notes         TEXT,
    is_active     BOOLEAN      NOT NULL DEFAULT true,
    created_by    UUID         NOT NULL REFERENCES users (id),
    created_at    TIMESTAMPTZ  NOT NULL DEFAULT now(),
    updated_at    TIMESTAMPTZ  NOT NULL DEFAULT now(),

    CONSTRAINT uq_planning_containers_empl_plan_no UNIQUE (empl_plan_no)
);

CREATE INDEX idx_planning_containers_cc     ON planning_containers (costcenter_id);
CREATE INDEX idx_planning_containers_active ON planning_containers (is_active);

COMMENT ON TABLE  planning_containers              IS 'Virtual HC buckets with no SAP origin. FTE may be negative (reduction) or >1 (multi-head bucket).';
COMMENT ON COLUMN planning_containers.empl_plan_no IS 'Human-readable virtual ID, e.g. "PLAN-CC100-001". Analogous to SAP employee_id.';

-- ============================================================
-- 5. SAP IMPORT & ACTUALS (immutable monthly snapshots)
-- ============================================================

CREATE TABLE import_runs (
    id           UUID         NOT NULL DEFAULT gen_random_uuid() PRIMARY KEY,
    period_year  SMALLINT     NOT NULL,
    period_month SMALLINT     NOT NULL,
    status       VARCHAR(50)  NOT NULL DEFAULT 'completed',
    row_count    INTEGER,
    source_file  VARCHAR(500),
    imported_by  UUID         NOT NULL REFERENCES users (id),
    imported_at  TIMESTAMPTZ  NOT NULL DEFAULT now(),

    CONSTRAINT uq_import_runs_period  UNIQUE (period_year, period_month),
    CONSTRAINT chk_import_runs_month  CHECK (period_month BETWEEN 1 AND 12),
    CONSTRAINT chk_import_runs_year   CHECK (period_year  BETWEEN 2000 AND 2100),
    CONSTRAINT chk_import_runs_status CHECK (status IN ('completed', 'failed', 'partial'))
);

CREATE INDEX idx_import_runs_status ON import_runs (status);

COMMENT ON TABLE  import_runs              IS 'One row per monthly SAP import. Unique on (period_year, period_month). A re-import requires admin deletion of the prior run first.';
COMMENT ON COLUMN import_runs.period_month IS '1–12.';

-- ------------------------------------------------------------

CREATE TABLE employee_actuals (
    id                UUID         NOT NULL DEFAULT gen_random_uuid() PRIMARY KEY,
    import_run_id     UUID         NOT NULL REFERENCES import_runs (id),
    employee_id       UUID         NOT NULL REFERENCES employees (id),
    first_name        VARCHAR(255) NOT NULL,
    last_name         VARCHAR(255) NOT NULL,
    costcenter_id     UUID         NOT NULL REFERENCES costcenters (id),
    classification_id UUID         REFERENCES classification_types (id),
    employee_group_id UUID         REFERENCES employee_groups (id),
    job_description   VARCHAR(500),
    fte               NUMERIC(6,4) NOT NULL,
    created_at        TIMESTAMPTZ  NOT NULL DEFAULT now(),

    CONSTRAINT uq_employee_actuals_run_empl UNIQUE (import_run_id, employee_id),
    CONSTRAINT chk_employee_actuals_fte     CHECK (fte > 0 AND fte <= 10)
);

CREATE INDEX idx_employee_actuals_run    ON employee_actuals (import_run_id);
CREATE INDEX idx_employee_actuals_empl   ON employee_actuals (employee_id);
CREATE INDEX idx_employee_actuals_cc     ON employee_actuals (costcenter_id);
CREATE INDEX idx_employee_actuals_run_cc ON employee_actuals (import_run_id, costcenter_id);

COMMENT ON TABLE  employee_actuals           IS 'IMMUTABLE after insert. One row = one employee state for one monthly import run. Never UPDATE or DELETE.';
COMMENT ON COLUMN employee_actuals.fte       IS 'Full-time equivalent, e.g. 1.0000 or 0.5000. Always positive for real employees.';
COMMENT ON COLUMN employee_actuals.classification_id IS 'NULL only if SAP did not supply a value.';
COMMENT ON COLUMN employee_actuals.employee_group_id IS 'NULL only if SAP did not supply a value.';

-- ============================================================
-- 6. FORECAST VERSIONS & ENTRIES (versioned, SCD Type 2)
-- ============================================================

CREATE TABLE forecast_versions (
    id                UUID         NOT NULL DEFAULT gen_random_uuid() PRIMARY KEY,
    label             VARCHAR(255) NOT NULL,
    status            VARCHAR(20)  NOT NULL DEFAULT 'working',
    period_year       SMALLINT     NOT NULL,
    period_month      SMALLINT     NOT NULL,
    fc_horizon_months SMALLINT     NOT NULL,
    source_version_id UUID         REFERENCES forecast_versions (id),
    archived_at       TIMESTAMPTZ,
    archived_by       UUID         REFERENCES users (id),
    created_by        UUID         NOT NULL REFERENCES users (id),
    created_at        TIMESTAMPTZ  NOT NULL DEFAULT now(),

    CONSTRAINT chk_fv_status  CHECK (status IN ('working', 'archived')),
    CONSTRAINT chk_fv_month   CHECK (period_month      BETWEEN 1  AND 12),
    CONSTRAINT chk_fv_year    CHECK (period_year       BETWEEN 2000 AND 2100),
    CONSTRAINT chk_fv_horizon CHECK (fc_horizon_months BETWEEN 1  AND 60),

    -- archived_at / archived_by must be set together and only for archived rows
    CONSTRAINT chk_fv_archived_consistency CHECK (
        (status = 'archived' AND archived_at IS NOT NULL AND archived_by IS NOT NULL)
        OR
        (status = 'working'  AND archived_at IS NULL     AND archived_by IS NULL)
    )
);

CREATE INDEX idx_fc_versions_period ON forecast_versions (period_year, period_month);
CREATE INDEX idx_fc_versions_status ON forecast_versions (status);
CREATE INDEX idx_fc_versions_source ON forecast_versions (source_version_id);

-- Enforce at most one working version at any point in time.
-- A regular UNIQUE constraint on status would block multiple archived rows,
-- so a partial index is used instead.
CREATE UNIQUE INDEX uq_fc_versions_one_working
    ON forecast_versions (status)
    WHERE status = 'working';

COMMENT ON TABLE  forecast_versions                   IS 'Version registry. One working version enforced by partial unique index. Archived snapshots are read-only.';
COMMENT ON COLUMN forecast_versions.source_version_id IS 'Self-FK. NULL for the very first version. Forms a singly-linked list for version diffing: working → snapshot_N → snapshot_N-1 → …';
COMMENT ON COLUMN forecast_versions.fc_horizon_months IS 'Snapshot of system_config fc_horizon_months at version creation time. Defines how far this version extends.';

-- ------------------------------------------------------------

CREATE TABLE forecast_entries (
    id                UUID         NOT NULL DEFAULT gen_random_uuid() PRIMARY KEY,
    version_id        UUID         NOT NULL REFERENCES forecast_versions (id),

    -- Exactly one of these two FKs must be non-null (chk_fe_subject_exclusive below).
    employee_id       UUID         REFERENCES employees (id),
    container_id      UUID         REFERENCES planning_containers (id),

    -- Full attribute snapshot at this point in the SCD Type 2 chain
    first_name        VARCHAR(255) NOT NULL,
    last_name         VARCHAR(255) NOT NULL,
    costcenter_id     UUID         NOT NULL REFERENCES costcenters (id),
    classification_id UUID         REFERENCES classification_types (id),
    employee_group_id UUID         REFERENCES employee_groups (id),
    job_description   VARCHAR(500),
    fte               NUMERIC(6,4) NOT NULL,

    -- Temporal bounds — always first-day-of-month values
    valid_from        DATE         NOT NULL,
    valid_to          DATE,

    -- Soft delete
    is_deleted        BOOLEAN      NOT NULL DEFAULT false,
    deleted_at        TIMESTAMPTZ,
    deleted_by        UUID         REFERENCES users (id),

    -- Audit
    created_by        UUID         NOT NULL REFERENCES users (id),
    created_at        TIMESTAMPTZ  NOT NULL DEFAULT now(),

    -- Exactly one subject per row
    CONSTRAINT chk_fe_subject_exclusive CHECK (
        (employee_id  IS NOT NULL AND container_id IS NULL)
        OR
        (employee_id  IS NULL     AND container_id IS NOT NULL)
    ),
    -- valid_to must be strictly after valid_from
    CONSTRAINT chk_fe_temporal CHECK (
        valid_to IS NULL OR valid_to > valid_from
    ),
    -- valid_from must be the first day of a calendar month
    CONSTRAINT chk_fe_valid_from_month_start CHECK (
        EXTRACT(DAY FROM valid_from) = 1
    ),
    -- All three soft-delete columns must be set together or all absent
    CONSTRAINT chk_fe_soft_delete CHECK (
        (is_deleted = false AND deleted_by IS NULL  AND deleted_at IS NULL)
        OR
        (is_deleted = true  AND deleted_by IS NOT NULL AND deleted_at IS NOT NULL)
    )
);

-- Monthly CC headcount rollup — most critical index for the WebUI table.
-- Partial on is_deleted = false because the active dataset is almost always queried.
CREATE INDEX idx_fe_version_cc_from
    ON forecast_entries (version_id, costcenter_id, valid_from)
    WHERE is_deleted = false;

-- Active-row lookup per real employee (INCLUDE avoids a heap fetch for valid_to checks)
CREATE INDEX idx_fe_version_empl_from
    ON forecast_entries (version_id, employee_id, valid_from)
    INCLUDE (valid_to)
    WHERE is_deleted = false AND employee_id IS NOT NULL;

-- Active-row lookup per planning container
CREATE INDEX idx_fe_version_cont_from
    ON forecast_entries (version_id, container_id, valid_from)
    INCLUDE (valid_to)
    WHERE is_deleted = false AND container_id IS NOT NULL;

-- Full temporal scan within a version (used for seeding the next version)
CREATE INDEX idx_fe_version_valid_from
    ON forecast_entries (version_id, valid_from);

-- Soft-delete filter scan
CREATE INDEX idx_fe_is_deleted
    ON forecast_entries (is_deleted);

COMMENT ON TABLE  forecast_entries            IS 'SCD Type 2. Each attribute change closes the current row (valid_to = change_month) and inserts a new open-ended row (valid_to = NULL).';
COMMENT ON COLUMN forecast_entries.valid_from IS 'Inclusive start — always first day of month, e.g. 2025-04-01.';
COMMENT ON COLUMN forecast_entries.valid_to   IS 'Exclusive end — first day of superseding month. NULL = currently active row.';
COMMENT ON COLUMN forecast_entries.fte        IS 'Negative = planned reduction (containers only). Greater than 1 = multi-head bucket.';

-- ============================================================
-- 7. AUDIT LOG (append-only)
-- ============================================================

CREATE TABLE forecast_entry_audit (
    id                UUID        NOT NULL DEFAULT gen_random_uuid() PRIMARY KEY,
    forecast_entry_id UUID        NOT NULL REFERENCES forecast_entries (id),
    version_id        UUID        NOT NULL REFERENCES forecast_versions (id),
    action            VARCHAR(20) NOT NULL,
    changed_fields    JSONB,
    changed_by        UUID        NOT NULL REFERENCES users (id),
    changed_at        TIMESTAMPTZ NOT NULL DEFAULT now(),
    client_ip         VARCHAR(45),
    user_agent        TEXT,

    CONSTRAINT chk_fea_action CHECK (action IN ('INSERT', 'UPDATE', 'DELETE', 'RESTORE'))
);

CREATE INDEX idx_fea_entry_id    ON forecast_entry_audit (forecast_entry_id);
CREATE INDEX idx_fea_version_id  ON forecast_entry_audit (version_id);
CREATE INDEX idx_fea_changed_by  ON forecast_entry_audit (changed_by);
CREATE INDEX idx_fea_changed_at  ON forecast_entry_audit (changed_at);
CREATE INDEX idx_fea_version_time ON forecast_entry_audit (version_id, changed_at DESC);
CREATE INDEX idx_fea_entry_time  ON forecast_entry_audit (forecast_entry_id, changed_at DESC);

COMMENT ON TABLE  forecast_entry_audit               IS 'APPEND-ONLY. No UPDATE or DELETE ever. Populated by the audit trigger on forecast_entries (see migration 003).';
COMMENT ON COLUMN forecast_entry_audit.changed_fields IS '{"field": {"old": <v>, "new": <v>}}. NULL on INSERT. Full snapshot under "deleted_snapshot" key on DELETE.';
COMMENT ON COLUMN forecast_entry_audit.version_id    IS 'Denormalised from forecast_entries for fast per-version audit queries.';


-- +goose Down

DROP TABLE IF EXISTS forecast_entry_audit  CASCADE;
DROP TABLE IF EXISTS forecast_entries      CASCADE;
DROP TABLE IF EXISTS forecast_versions     CASCADE;
DROP TABLE IF EXISTS employee_actuals      CASCADE;
DROP TABLE IF EXISTS import_runs           CASCADE;
DROP TABLE IF EXISTS planning_containers   CASCADE;
DROP TABLE IF EXISTS employees             CASCADE;
DROP TABLE IF EXISTS system_config         CASCADE;
DROP TABLE IF EXISTS users                 CASCADE;
DROP TABLE IF EXISTS classification_types  CASCADE;
DROP TABLE IF EXISTS employee_groups       CASCADE;
DROP TABLE IF EXISTS costcenters           CASCADE;
