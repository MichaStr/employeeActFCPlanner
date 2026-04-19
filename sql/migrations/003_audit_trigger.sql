-- +goose Up
-- +goose StatementBegin

-- ============================================================
-- Audit trigger for forecast_entries
--
-- Fires AFTER INSERT, UPDATE, DELETE on forecast_entries and
-- appends one row to forecast_entry_audit.
--
-- changed_fields format:
--   INSERT  → NULL  (full new state available via forecast_entry_id FK)
--   UPDATE  → {"col": {"old": <v>, "new": <v>}, ...}  (only changed columns)
--   DELETE  → {"deleted_snapshot": {<all columns>}}
--   RESTORE → {"is_deleted": {"old": true, "new": false}}
--
-- changed_by is read from the session variable app.current_user_id.
-- Set it in the application layer before any write:
--   SET LOCAL app.current_user_id = '<user-uuid>';
-- ============================================================

CREATE OR REPLACE FUNCTION fn_forecast_entries_audit()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
DECLARE
    v_action        VARCHAR(20);
    v_changed_fields JSONB := NULL;
    v_changed_by    UUID;
    v_version_id    UUID;
BEGIN
    -- Resolve the acting user from the session variable.
    -- Falls back to NULL if not set (e.g. direct DB access).
    BEGIN
        v_changed_by := current_setting('app.current_user_id', true)::UUID;
    EXCEPTION WHEN others THEN
        v_changed_by := NULL;
    END;

    IF TG_OP = 'INSERT' THEN
        v_action     := 'INSERT';
        v_version_id := NEW.version_id;
        -- No changed_fields on INSERT; the new row is reachable via the FK.
        v_changed_fields := NULL;

    ELSIF TG_OP = 'DELETE' THEN
        v_action     := 'DELETE';
        v_version_id := OLD.version_id;
        -- Store the full outgoing snapshot so deleted data is not lost.
        v_changed_fields := jsonb_build_object(
            'deleted_snapshot', to_jsonb(OLD)
        );

    ELSIF TG_OP = 'UPDATE' THEN
        v_version_id := NEW.version_id;

        -- Distinguish a soft-delete restore from a regular UPDATE.
        IF OLD.is_deleted = true AND NEW.is_deleted = false THEN
            v_action := 'RESTORE';
        ELSIF NEW.is_deleted = true AND OLD.is_deleted = false THEN
            v_action := 'DELETE';
        ELSE
            v_action := 'UPDATE';
        END IF;

        -- Build a diff object containing only the columns that actually changed.
        v_changed_fields := '{}'::JSONB;

        IF OLD.employee_id       IS DISTINCT FROM NEW.employee_id       THEN v_changed_fields := v_changed_fields || jsonb_build_object('employee_id',       jsonb_build_object('old', OLD.employee_id,       'new', NEW.employee_id));       END IF;
        IF OLD.container_id      IS DISTINCT FROM NEW.container_id      THEN v_changed_fields := v_changed_fields || jsonb_build_object('container_id',      jsonb_build_object('old', OLD.container_id,      'new', NEW.container_id));      END IF;
        IF OLD.first_name        IS DISTINCT FROM NEW.first_name        THEN v_changed_fields := v_changed_fields || jsonb_build_object('first_name',        jsonb_build_object('old', OLD.first_name,        'new', NEW.first_name));        END IF;
        IF OLD.last_name         IS DISTINCT FROM NEW.last_name         THEN v_changed_fields := v_changed_fields || jsonb_build_object('last_name',         jsonb_build_object('old', OLD.last_name,         'new', NEW.last_name));         END IF;
        IF OLD.costcenter_id     IS DISTINCT FROM NEW.costcenter_id     THEN v_changed_fields := v_changed_fields || jsonb_build_object('costcenter_id',     jsonb_build_object('old', OLD.costcenter_id,     'new', NEW.costcenter_id));     END IF;
        IF OLD.classification_id IS DISTINCT FROM NEW.classification_id THEN v_changed_fields := v_changed_fields || jsonb_build_object('classification_id', jsonb_build_object('old', OLD.classification_id, 'new', NEW.classification_id)); END IF;
        IF OLD.employee_group_id IS DISTINCT FROM NEW.employee_group_id THEN v_changed_fields := v_changed_fields || jsonb_build_object('employee_group_id', jsonb_build_object('old', OLD.employee_group_id, 'new', NEW.employee_group_id)); END IF;
        IF OLD.job_description   IS DISTINCT FROM NEW.job_description   THEN v_changed_fields := v_changed_fields || jsonb_build_object('job_description',   jsonb_build_object('old', OLD.job_description,   'new', NEW.job_description));   END IF;
        IF OLD.fte               IS DISTINCT FROM NEW.fte               THEN v_changed_fields := v_changed_fields || jsonb_build_object('fte',               jsonb_build_object('old', OLD.fte,               'new', NEW.fte));               END IF;
        IF OLD.valid_from        IS DISTINCT FROM NEW.valid_from        THEN v_changed_fields := v_changed_fields || jsonb_build_object('valid_from',        jsonb_build_object('old', OLD.valid_from,        'new', NEW.valid_from));        END IF;
        IF OLD.valid_to          IS DISTINCT FROM NEW.valid_to          THEN v_changed_fields := v_changed_fields || jsonb_build_object('valid_to',          jsonb_build_object('old', OLD.valid_to,          'new', NEW.valid_to));          END IF;
        IF OLD.is_deleted        IS DISTINCT FROM NEW.is_deleted        THEN v_changed_fields := v_changed_fields || jsonb_build_object('is_deleted',        jsonb_build_object('old', OLD.is_deleted,        'new', NEW.is_deleted));        END IF;

        -- If nothing meaningful changed, skip the audit row.
        IF v_changed_fields = '{}'::JSONB THEN
            RETURN NEW;
        END IF;
    END IF;

    INSERT INTO forecast_entry_audit (
        forecast_entry_id,
        version_id,
        action,
        changed_fields,
        changed_by,
        changed_at
    ) VALUES (
        CASE TG_OP WHEN 'DELETE' THEN OLD.id ELSE NEW.id END,
        v_version_id,
        v_action,
        v_changed_fields,
        v_changed_by,
        now()
    );

    RETURN CASE TG_OP WHEN 'DELETE' THEN OLD ELSE NEW END;
END;
$$;

-- +goose StatementEnd

CREATE TRIGGER trg_forecast_entries_audit
    AFTER INSERT OR UPDATE OR DELETE
    ON forecast_entries
    FOR EACH ROW
    EXECUTE FUNCTION fn_forecast_entries_audit();

COMMENT ON FUNCTION fn_forecast_entries_audit() IS
    'Audit trigger for forecast_entries. Appends one row to forecast_entry_audit per DML operation. Reads the acting user from session variable app.current_user_id.';


-- +goose Down
-- +goose StatementBegin

DROP TRIGGER IF EXISTS trg_forecast_entries_audit ON forecast_entries;
DROP FUNCTION IF EXISTS fn_forecast_entries_audit();

-- +goose StatementEnd
