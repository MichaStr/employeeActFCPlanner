-- +goose Up

-- ============================================================
-- classification_types — seed for the direct/indirect axis
-- ============================================================
-- sort_order controls the display order in the WebUI table columns.
-- Add more rows here (or at runtime via INSERT) without any schema change.

INSERT INTO classification_types (id, code, label, sort_order) VALUES
    (gen_random_uuid(), 'direct',     'Direct',     1),
    (gen_random_uuid(), 'indirect',   'Indirect',   2),
    (gen_random_uuid(), 'overhead',   'Overhead',   3),
    (gen_random_uuid(), 'contractor', 'Contractor', 4);

-- ============================================================
-- employee_groups — seed for common employee group codes
-- ============================================================

INSERT INTO employee_groups (id, code, label, sort_order) VALUES
    (gen_random_uuid(), 'EG_EXEC',    'Executive',  1),
    (gen_random_uuid(), 'EG_MGR',     'Manager',    2),
    (gen_random_uuid(), 'EG_ENG',     'Engineer',   3),
    (gen_random_uuid(), 'EG_SUPPORT', 'Support',    4),
    (gen_random_uuid(), 'EG_OPS',     'Operator',   5);

-- ============================================================
-- system_config — default runtime settings
-- ============================================================

INSERT INTO system_config (key, value, description) VALUES
    ('fc_horizon_months',
     '18',
     'How many months forward the rolling forecast extends. Integer. Can be changed at runtime via UPDATE.'),

    ('fc_lock_day',
     '1',
     'Day of month (1–28) on which the working forecast is archived and a new one is opened. Integer.'),

    ('import_source_label',
     'SAP HCM Export',
     'Cosmetic label for the SAP import source displayed in the UI. String.');


-- +goose Down

DELETE FROM system_config
    WHERE key IN ('fc_horizon_months', 'fc_lock_day', 'import_source_label');

DELETE FROM employee_groups
    WHERE code IN ('EG_EXEC', 'EG_MGR', 'EG_ENG', 'EG_SUPPORT', 'EG_OPS');

DELETE FROM classification_types
    WHERE code IN ('direct', 'indirect', 'overhead', 'contractor');
