-- Устанавливается после 001_schema.sql, в одной и той же базе.
BEGIN;
SET search_path TO remkomstroy, public;

-- Проверки нескольких строк выполняются после изменения и видят его результат.
-- Для согласованных пакетных изменений: BEGIN; SET CONSTRAINTS ALL DEFERRED; ... COMMIT;
CREATE FUNCTION validate_structure() RETURNS trigger
LANGUAGE plpgsql SET search_path = remkomstroy, pg_temp AS $$
BEGIN
    IF EXISTS (
        WITH RECURSIVE ancestors(child, ancestor) AS (
            SELECT id, parent_id FROM facility_elements WHERE parent_id IS NOT NULL
            UNION
            SELECT a.child, e.parent_id FROM ancestors a
            JOIN facility_elements e ON e.id = a.ancestor WHERE e.parent_id IS NOT NULL
        ) SELECT 1 FROM ancestors WHERE child = ancestor
    ) THEN
        RAISE EXCEPTION 'Иерархия элементов содержит цикл' USING ERRCODE = '23514';
    END IF;

    IF EXISTS (
        SELECT 1 FROM repair_works w
        JOIN repair_projects p ON p.id = w.project_id
        JOIN facility_elements root ON root.id = p.element_id
        JOIN facility_elements e ON e.id = w.element_id
        WHERE root.facility_id <> e.facility_id
    ) THEN
        RAISE EXCEPTION 'Работа и исходный элемент проекта должны принадлежать одному объекту'
            USING ERRCODE = '23514';
    END IF;

    IF EXISTS (
        SELECT 1 FROM repair_works w WHERE w.contractor_id IS NOT NULL
        AND NOT EXISTS (SELECT 1 FROM contractor_work_types c
                        WHERE c.contractor_id = w.contractor_id AND c.work_type_id = w.work_type_id)
    ) THEN
        RAISE EXCEPTION 'У назначенного подрядчика отсутствует требуемый вид работ' USING ERRCODE = '23514';
    END IF;

    IF EXISTS (
        SELECT 1 FROM work_dependencies d
        JOIN repair_works a ON a.id = d.predecessor_id
        JOIN repair_works b ON b.id = d.successor_id
        WHERE a.project_id <> b.project_id OR a.version_no <> b.version_no
    ) THEN
        RAISE EXCEPTION 'Зависимости допустимы только внутри проекта и редакции' USING ERRCODE = '23514';
    END IF;
    IF EXISTS (
        WITH RECURSIVE reach(source, target) AS (
            SELECT predecessor_id, successor_id FROM work_dependencies
            UNION
            SELECT r.source, d.successor_id FROM reach r
            JOIN work_dependencies d ON d.predecessor_id = r.target
        ) SELECT 1 FROM reach WHERE source = target
    ) THEN
        RAISE EXCEPTION 'Граф работ содержит цикл' USING ERRCODE = '23514';
    END IF;

    IF EXISTS (
        SELECT 1 FROM tender_works tw
        JOIN tenders t ON t.id = tw.tender_id
        JOIN repair_works w ON w.id = tw.work_id
        WHERE t.project_id <> w.project_id OR t.plan_version <> w.version_no
    ) THEN
        RAISE EXCEPTION 'Тендер и его работы должны относиться к одному проекту и редакции'
            USING ERRCODE = '23514';
    END IF;
    IF EXISTS (
        SELECT 1 FROM change_requests c
        JOIN repair_works w ON w.id = c.source_work_id
        JOIN facility_elements source ON source.id = w.element_id
        JOIN facility_elements target ON target.id = c.element_id
        WHERE source.facility_id <> target.facility_id
    ) THEN
        RAISE EXCEPTION 'Запрос должен касаться элемента того же объекта, что и исходная работа'
            USING ERRCODE = '23514';
    END IF;

    IF EXISTS (
        SELECT 1 FROM work_dependencies d
        JOIN repair_works before_work ON before_work.id = d.predecessor_id
        JOIN repair_works after_work ON after_work.id = d.successor_id
        WHERE after_work.status IN ('IN_PROGRESS', 'ON_ACCEPTANCE', 'REWORK', 'ACCEPTED')
          AND before_work.status <> 'ACCEPTED'
    ) THEN
        RAISE EXCEPTION 'Предшествующие работы должны быть приняты до выполнения зависимой работы'
            USING ERRCODE = '23514';
    END IF;
    IF EXISTS (
        SELECT 1 FROM repair_works w
        WHERE w.status IN ('IN_PROGRESS', 'ON_ACCEPTANCE', 'REWORK', 'ACCEPTED')
          AND w.contractor_id IS NULL
    ) THEN
        RAISE EXCEPTION 'Для выполняемой работы нужен подрядчик' USING ERRCODE = '23514';
    END IF;
    IF EXISTS (
        SELECT 1 FROM repair_works w WHERE w.status = 'ACCEPTED'
          AND (SELECT a.result FROM acceptances a WHERE a.work_id = w.id
               ORDER BY a.id DESC LIMIT 1) IS DISTINCT FROM 'ACCEPTED'
    ) THEN
        RAISE EXCEPTION 'Последняя приёмка работы должна быть положительной' USING ERRCODE = '23514';
    END IF;
    IF EXISTS (
        SELECT 1 FROM repair_projects p WHERE p.status = 'COMPLETED'
          AND (NOT EXISTS (SELECT 1 FROM repair_works w WHERE w.project_id = p.id AND w.version_no = p.current_version)
            OR EXISTS (SELECT 1 FROM repair_works w WHERE w.project_id = p.id AND w.version_no = p.current_version
                       AND w.status NOT IN ('ACCEPTED', 'CANCELLED')))
    ) THEN
        RAISE EXCEPTION 'Завершение проекта возможно после приёмки работ актуальной редакции'
            USING ERRCODE = '23514';
    END IF;
    RETURN NULL;
END $$;

-- Сериализуем изменения связанных данных в небольшом учебном проекте.
-- При SERIALIZABLE конфликты снимков дополнительно отклоняет PostgreSQL.
CREATE FUNCTION lock_integrity_changes() RETURNS trigger
LANGUAGE plpgsql SET search_path = remkomstroy, pg_temp AS $$
BEGIN
    PERFORM pg_advisory_xact_lock(168403, 2);
    RETURN NULL;
END $$;

DO $$
DECLARE table_name text;
BEGIN
    FOREACH table_name IN ARRAY ARRAY[
        'facility_elements', 'repair_projects', 'repair_works', 'work_dependencies',
        'tenders', 'tender_works', 'change_requests', 'acceptances', 'contractor_work_types'
    ] LOOP
        EXECUTE format('CREATE TRIGGER integrity_write_lock BEFORE INSERT OR UPDATE OR DELETE ON %I
                        FOR EACH STATEMENT EXECUTE FUNCTION lock_integrity_changes()', table_name);
        EXECUTE format('CREATE CONSTRAINT TRIGGER structure_integrity
                        AFTER INSERT OR UPDATE OR DELETE ON %I
                        DEFERRABLE INITIALLY IMMEDIATE FOR EACH ROW
                        EXECUTE FUNCTION validate_structure()', table_name);
    END LOOP;
END $$;

-- Попытка приёмки — отдельная запись. После вставки решение отражается в работе.
CREATE FUNCTION check_acceptance() RETURNS trigger
LANGUAGE plpgsql SET search_path = remkomstroy, pg_temp AS $$
DECLARE current_status text;
BEGIN
    IF TG_OP <> 'INSERT' THEN
        RAISE EXCEPTION 'Приёмки сохраняются как история: UPDATE и DELETE запрещены'
            USING ERRCODE = '23514';
    END IF;
    SELECT status INTO current_status FROM repair_works WHERE id = NEW.work_id FOR UPDATE;
    IF current_status IS DISTINCT FROM 'ON_ACCEPTANCE' THEN
        RAISE EXCEPTION 'Принимать можно только работу в статусе ON_ACCEPTANCE' USING ERRCODE = '23514';
    END IF;
    RETURN NEW;
END $$;
CREATE TRIGGER acceptance_check BEFORE INSERT OR UPDATE OR DELETE ON acceptances
    FOR EACH ROW EXECUTE FUNCTION check_acceptance();

CREATE FUNCTION apply_acceptance() RETURNS trigger
LANGUAGE plpgsql SET search_path = remkomstroy, pg_temp AS $$
BEGIN
    UPDATE repair_works SET status = NEW.result WHERE id = NEW.work_id;
    RETURN NEW;
END $$;
CREATE TRIGGER acceptance_apply AFTER INSERT ON acceptances
    FOR EACH ROW EXECUTE FUNCTION apply_acceptance();
COMMIT;
