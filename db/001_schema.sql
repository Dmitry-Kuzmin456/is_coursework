-- РемКомСтрой. ER-модель, этап 2.
-- PostgreSQL. На helios выполнять в уже существующей базе studs:
--
--   psql -h pg -d studs -f db/001_schema.sql
--
-- Решения по модели:
--   * один пользователь с ролью CONTRACTOR — одна компания-подрядчик;
--   * проект содержит версии плана, в каждой версии свой снимок работ и зависимостей;
--   * одна и та же логическая работа связана между версиями полем stable_key;
--   * тендер относится к подтверждённой версии плана и делится на лоты;
--   * файл хранится в Nextcloud, в базе только ссылка.
--
-- Сущности (31):
--   app_users, contractors, specializations, contractor_specializations,
--   facility_types, facilities, facility_elements, work_types, dependency_rules,
--   repair_requests, repair_projects, plan_versions, repair_works, work_dependencies,
--   tenders, tender_lots, lot_works, evaluation_criteria, tender_criterion_weights,
--   tender_invitations, bids, bid_versions, bid_scores, lot_awards,
--   work_log_entries, change_requests, acceptances, acceptance_remarks,
--   file_links, warranty_periods, audit_events.
--
-- Многие-ко-многим:
--   contractors *—* specializations
--   repair_works *—* repair_works        (work_dependencies, граф «до / после»)
--   tenders *—* evaluation_criteria      (tender_criterion_weights, с весом)

BEGIN;

CREATE SCHEMA remkomstroy;
SET search_path TO remkomstroy, public;

-- ---------------------------------------------------------------------------
-- Перечисления. Это состояния процессов, а не расширяемые справочники.
-- Новые виды объектов, работ и критерии добавляются строками в таблицы.
-- ---------------------------------------------------------------------------

CREATE TYPE user_role AS ENUM ('ADMIN', 'CONTRACTOR', 'EXPERT');
CREATE TYPE contractor_status AS ENUM ('ACTIVE', 'BLOCKED');
CREATE TYPE asset_condition AS ENUM ('GOOD', 'SATISFACTORY', 'NEEDS_REPAIR', 'EMERGENCY');
CREATE TYPE request_priority AS ENUM ('LOW', 'NORMAL', 'HIGH', 'URGENT');
CREATE TYPE request_status AS ENUM ('DRAFT', 'SUBMITTED', 'SCOPE_CONFIRMED', 'IN_PROGRESS', 'CLOSED', 'REJECTED');
CREATE TYPE project_status AS ENUM ('DRAFT', 'PLANNING', 'TENDERING', 'IN_PROGRESS', 'COMPLETED', 'CANCELLED');
CREATE TYPE plan_status AS ENUM ('DRAFT', 'SCOPE_CONFIRMED', 'CONFIRMED', 'SUPERSEDED');
CREATE TYPE work_status AS ENUM (
    'PLANNED', 'BLOCKED', 'READY', 'IN_PROGRESS', 'PAUSED',
    'ON_ACCEPTANCE', 'REWORK', 'ACCEPTED', 'CANCELLED'
);
CREATE TYPE tender_status AS ENUM ('DRAFT', 'OPEN', 'CLOSED', 'AWARDED', 'CANCELLED');
CREATE TYPE invitation_status AS ENUM ('SENT', 'ACCEPTED', 'DECLINED');
CREATE TYPE bid_status AS ENUM ('DRAFT', 'SUBMITTED', 'WITHDRAWN', 'AWARDED', 'LOST');
CREATE TYPE change_status AS ENUM ('SUBMITTED', 'NEEDS_INFO', 'APPROVED', 'REJECTED');
CREATE TYPE acceptance_decision AS ENUM ('ACCEPTED', 'REWORK');

-- ---------------------------------------------------------------------------
-- Пользователи и подрядчики
-- ---------------------------------------------------------------------------

CREATE TABLE app_users (
    id              bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    full_name       text NOT NULL CHECK (btrim(full_name) <> ''),
    email           text NOT NULL CHECK (email ~* '^[^@[:space:]]+@[^@[:space:]]+$'),
    password_hash   text NOT NULL CHECK (btrim(password_hash) <> ''),
    role            user_role NOT NULL,
    is_active       boolean NOT NULL DEFAULT true,
    created_at      timestamptz NOT NULL DEFAULT now()
);

CREATE UNIQUE INDEX app_users_email_lower_idx ON app_users (lower(email));

CREATE TABLE contractors (
    id              bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    user_id         bigint NOT NULL UNIQUE REFERENCES app_users (id) ON DELETE RESTRICT,
    company_name    text NOT NULL CHECK (btrim(company_name) <> ''),
    status          contractor_status NOT NULL DEFAULT 'ACTIVE',
    created_at      timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE specializations (
    id              bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    code            text NOT NULL UNIQUE CHECK (btrim(code) <> ''),
    name            text NOT NULL UNIQUE CHECK (btrim(name) <> '')
);

-- Подрядчик *—* специализация.
CREATE TABLE contractor_specializations (
    contractor_id       bigint NOT NULL REFERENCES contractors (id) ON DELETE CASCADE,
    specialization_id   bigint NOT NULL REFERENCES specializations (id) ON DELETE RESTRICT,
    PRIMARY KEY (contractor_id, specialization_id)
);

-- ---------------------------------------------------------------------------
-- Объекты ремонта и правила работ
-- ---------------------------------------------------------------------------

CREATE TABLE facility_types (
    id              bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    code            text NOT NULL UNIQUE CHECK (btrim(code) <> ''),
    name            text NOT NULL UNIQUE CHECK (btrim(name) <> '')
);

CREATE TABLE facilities (
    id                  bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    facility_type_id    bigint NOT NULL REFERENCES facility_types (id) ON DELETE RESTRICT,
    name                text NOT NULL CHECK (btrim(name) <> ''),
    address             text NOT NULL CHECK (btrim(address) <> ''),
    condition           asset_condition NOT NULL DEFAULT 'NEEDS_REPAIR',
    admin_id            bigint NOT NULL REFERENCES app_users (id) ON DELETE RESTRICT,
    created_at          timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE facility_elements (
    id                  bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    facility_id         bigint NOT NULL REFERENCES facilities (id) ON DELETE CASCADE,
    parent_element_id   bigint REFERENCES facility_elements (id) ON DELETE CASCADE,
    name                text NOT NULL CHECK (btrim(name) <> ''),
    element_type        text NOT NULL CHECK (btrim(element_type) <> ''),
    position_label      text,
    tech_spec           text,
    condition           asset_condition NOT NULL DEFAULT 'NEEDS_REPAIR',
    CHECK (parent_element_id IS DISTINCT FROM id)
);

CREATE TABLE work_types (
    id                  bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    specialization_id   bigint NOT NULL REFERENCES specializations (id) ON DELETE RESTRICT,
    code                text NOT NULL UNIQUE CHECK (btrim(code) <> ''),
    name                text NOT NULL CHECK (btrim(name) <> '')
);

-- Шаблон: связанный вид работ выполняется раньше исходного.
CREATE TABLE dependency_rules (
    id                      bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    source_work_type_id     bigint NOT NULL REFERENCES work_types (id) ON DELETE CASCADE,
    required_work_type_id   bigint NOT NULL REFERENCES work_types (id) ON DELETE RESTRICT,
    UNIQUE (source_work_type_id, required_work_type_id),
    CHECK (source_work_type_id <> required_work_type_id)
);

-- ---------------------------------------------------------------------------
-- Заявка, проект и версии плана
-- ---------------------------------------------------------------------------

CREATE TABLE repair_requests (
    id                  bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    facility_id         bigint NOT NULL REFERENCES facilities (id) ON DELETE RESTRICT,
    element_id          bigint NOT NULL REFERENCES facility_elements (id) ON DELETE RESTRICT,
    created_by          bigint NOT NULL REFERENCES app_users (id) ON DELETE RESTRICT,
    defect_description  text NOT NULL CHECK (btrim(defect_description) <> ''),
    priority            request_priority NOT NULL DEFAULT 'NORMAL',
    desired_due_date    date,
    status              request_status NOT NULL DEFAULT 'DRAFT',
    created_at          timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE repair_projects (
    id              bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    request_id      bigint NOT NULL UNIQUE REFERENCES repair_requests (id) ON DELETE RESTRICT,
    facility_id     bigint NOT NULL REFERENCES facilities (id) ON DELETE RESTRICT,
    title           text NOT NULL CHECK (btrim(title) <> ''),
    status          project_status NOT NULL DEFAULT 'DRAFT',
    created_at      timestamptz NOT NULL DEFAULT now(),
    closed_at       timestamptz,
    closed_by       bigint REFERENCES app_users (id) ON DELETE RESTRICT,
    CHECK (closed_at IS NULL OR status = 'COMPLETED')
);

CREATE TABLE plan_versions (
    id                      bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    project_id              bigint NOT NULL REFERENCES repair_projects (id) ON DELETE CASCADE,
    version_no              integer NOT NULL CHECK (version_no >= 1),
    status                  plan_status NOT NULL DEFAULT 'DRAFT',
    based_on_version_id     bigint REFERENCES plan_versions (id) ON DELETE RESTRICT,
    change_request_id       bigint,
    scope_confirmed_by      bigint REFERENCES app_users (id) ON DELETE RESTRICT,
    scope_confirmed_at      timestamptz,
    approved_by             bigint REFERENCES app_users (id) ON DELETE RESTRICT,
    approved_at             timestamptz,
    critical_end_date       date,
    published_at            timestamptz,
    created_at              timestamptz NOT NULL DEFAULT now(),
    UNIQUE (project_id, version_no),
    CHECK (based_on_version_id IS DISTINCT FROM id),
    CHECK (status <> 'SCOPE_CONFIRMED' OR scope_confirmed_by IS NOT NULL),
    CHECK (status <> 'CONFIRMED' OR (scope_confirmed_by IS NOT NULL AND approved_by IS NOT NULL))
);

-- Одна подтверждённая версия на проект. Старую нужно перевести в SUPERSEDED
-- в той же транзакции, в которой публикуется новая.
CREATE UNIQUE INDEX plan_versions_one_confirmed_idx
    ON plan_versions (project_id)
    WHERE status = 'CONFIRMED';

CREATE TABLE repair_works (
    id                      bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    plan_version_id         bigint NOT NULL REFERENCES plan_versions (id) ON DELETE CASCADE,
    stable_key              uuid NOT NULL,
    work_type_id            bigint NOT NULL REFERENCES work_types (id) ON DELETE RESTRICT,
    element_id              bigint NOT NULL REFERENCES facility_elements (id) ON DELETE RESTRICT,
    title                   text NOT NULL CHECK (btrim(title) <> ''),
    volume_qty              numeric(12, 3) CHECK (volume_qty IS NULL OR volume_qty > 0),
    volume_unit             text,
    requirements            text,
    is_mandatory            boolean NOT NULL DEFAULT true,
    status                  work_status NOT NULL DEFAULT 'PLANNED',
    assigned_contractor_id  bigint REFERENCES contractors (id) ON DELETE RESTRICT,
    planned_start           date,
    planned_finish          date,
    actual_start            date,
    actual_finish           date,
    UNIQUE (plan_version_id, stable_key),
    CHECK (planned_finish IS NULL OR planned_start IS NULL OR planned_finish >= planned_start),
    CHECK (actual_finish IS NULL OR actual_start IS NULL OR actual_finish >= actual_start)
);

-- Работа *—* работа внутри одной версии плана.
CREATE TABLE work_dependencies (
    predecessor_work_id bigint NOT NULL REFERENCES repair_works (id) ON DELETE CASCADE,
    successor_work_id   bigint NOT NULL REFERENCES repair_works (id) ON DELETE CASCADE,
    PRIMARY KEY (predecessor_work_id, successor_work_id),
    CHECK (predecessor_work_id <> successor_work_id)
);

-- ---------------------------------------------------------------------------
-- Тендер, лоты, предложения и рейтинг
-- ---------------------------------------------------------------------------

CREATE TABLE tenders (
    id                  bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    project_id          bigint NOT NULL REFERENCES repair_projects (id) ON DELETE CASCADE,
    plan_version_id     bigint NOT NULL REFERENCES plan_versions (id) ON DELETE RESTRICT,
    title               text NOT NULL CHECK (btrim(title) <> ''),
    response_deadline   timestamptz NOT NULL,
    status              tender_status NOT NULL DEFAULT 'DRAFT',
    created_by          bigint NOT NULL REFERENCES app_users (id) ON DELETE RESTRICT,
    created_at          timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE tender_lots (
    id                  bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    tender_id           bigint NOT NULL REFERENCES tenders (id) ON DELETE CASCADE,
    specialization_id   bigint NOT NULL REFERENCES specializations (id) ON DELETE RESTRICT,
    title               text NOT NULL CHECK (btrim(title) <> ''),
    sequence_no         integer NOT NULL CHECK (sequence_no >= 1),
    UNIQUE (tender_id, sequence_no)
);

-- Лот группирует работы одной специализации. Работа входит не более чем в один лот.
CREATE TABLE lot_works (
    lot_id          bigint NOT NULL REFERENCES tender_lots (id) ON DELETE CASCADE,
    repair_work_id  bigint NOT NULL UNIQUE REFERENCES repair_works (id) ON DELETE CASCADE,
    PRIMARY KEY (lot_id, repair_work_id)
);

CREATE TABLE evaluation_criteria (
    id                  bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    code                text NOT NULL UNIQUE CHECK (btrim(code) <> ''),
    name                text NOT NULL CHECK (btrim(name) <> ''),
    higher_is_better    boolean NOT NULL,
    description         text
);

-- Тендер *—* критерий, атрибут связи — вес.
CREATE TABLE tender_criterion_weights (
    tender_id       bigint NOT NULL REFERENCES tenders (id) ON DELETE CASCADE,
    criterion_id    bigint NOT NULL REFERENCES evaluation_criteria (id) ON DELETE RESTRICT,
    weight          numeric(6, 4) NOT NULL CHECK (weight > 0 AND weight <= 1),
    PRIMARY KEY (tender_id, criterion_id)
);

CREATE TABLE tender_invitations (
    id              bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    lot_id          bigint NOT NULL REFERENCES tender_lots (id) ON DELETE CASCADE,
    contractor_id   bigint NOT NULL REFERENCES contractors (id) ON DELETE RESTRICT,
    status          invitation_status NOT NULL DEFAULT 'SENT',
    decline_reason  text,
    sent_at         timestamptz NOT NULL DEFAULT now(),
    responded_at    timestamptz,
    UNIQUE (lot_id, contractor_id),
    CHECK (
        status <> 'DECLINED'
        OR (decline_reason IS NOT NULL AND btrim(decline_reason) <> '')
    )
);

CREATE TABLE bids (
    id              bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    invitation_id   bigint NOT NULL UNIQUE REFERENCES tender_invitations (id) ON DELETE CASCADE,
    status          bid_status NOT NULL DEFAULT 'DRAFT',
    created_at      timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE bid_versions (
    id                  bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    bid_id              bigint NOT NULL REFERENCES bids (id) ON DELETE CASCADE,
    version_no          integer NOT NULL CHECK (version_no >= 1),
    price               numeric(14, 2) NOT NULL CHECK (price > 0),
    duration_days       integer NOT NULL CHECK (duration_days > 0),
    available_start     date NOT NULL,
    warranty_months     integer NOT NULL CHECK (warranty_months >= 0),
    is_current          boolean NOT NULL DEFAULT true,
    total_score         numeric(12, 4),
    rank_place          integer CHECK (rank_place IS NULL OR rank_place >= 1),
    ranked_at           timestamptz,
    submitted_at        timestamptz NOT NULL DEFAULT now(),
    UNIQUE (bid_id, version_no),
    CHECK (
        (total_score IS NULL AND rank_place IS NULL AND ranked_at IS NULL)
        OR (total_score IS NOT NULL AND rank_place IS NOT NULL AND ranked_at IS NOT NULL)
    )
);

CREATE UNIQUE INDEX bid_versions_one_current_idx
    ON bid_versions (bid_id)
    WHERE is_current;

-- Снимок входа в рейтинг: исходное значение и вес на момент расчёта.
CREATE TABLE bid_scores (
    id                  bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    bid_version_id      bigint NOT NULL REFERENCES bid_versions (id) ON DELETE CASCADE,
    criterion_id        bigint NOT NULL REFERENCES evaluation_criteria (id) ON DELETE RESTRICT,
    raw_value           numeric(14, 4) NOT NULL,
    weight_used         numeric(6, 4) NOT NULL CHECK (weight_used > 0 AND weight_used <= 1),
    weighted_score      numeric(12, 4) NOT NULL,
    UNIQUE (bid_version_id, criterion_id)
);

CREATE TABLE lot_awards (
    id                      bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    lot_id                  bigint NOT NULL UNIQUE REFERENCES tender_lots (id) ON DELETE CASCADE,
    bid_version_id          bigint NOT NULL UNIQUE REFERENCES bid_versions (id) ON DELETE RESTRICT,
    awarded_by              bigint NOT NULL REFERENCES app_users (id) ON DELETE RESTRICT,
    rank_place_at_choice    integer NOT NULL CHECK (rank_place_at_choice >= 1),
    justification           text,
    awarded_at              timestamptz NOT NULL DEFAULT now()
);

-- ---------------------------------------------------------------------------
-- Выполнение, скрытый дефект, приёмка
-- ---------------------------------------------------------------------------

CREATE TABLE work_log_entries (
    id              bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    repair_work_id  bigint NOT NULL REFERENCES repair_works (id) ON DELETE CASCADE,
    author_id       bigint NOT NULL REFERENCES app_users (id) ON DELETE RESTRICT,
    recorded_at     timestamptz NOT NULL DEFAULT now(),
    volume_done     numeric(12, 3) CHECK (volume_done IS NULL OR volume_done >= 0),
    materials_note  text,
    note            text
);

CREATE TABLE change_requests (
    id                      bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    discovered_on_work_id   bigint NOT NULL REFERENCES repair_works (id) ON DELETE RESTRICT,
    element_id              bigint NOT NULL REFERENCES facility_elements (id) ON DELETE RESTRICT,
    author_id               bigint NOT NULL REFERENCES app_users (id) ON DELETE RESTRICT,
    description             text NOT NULL CHECK (btrim(description) <> ''),
    can_continue_current    boolean NOT NULL,
    volume_estimate         numeric(12, 3) CHECK (volume_estimate IS NULL OR volume_estimate > 0),
    caused_by_contractor    boolean NOT NULL DEFAULT false,
    status                  change_status NOT NULL DEFAULT 'SUBMITTED',
    expert_id               bigint REFERENCES app_users (id) ON DELETE RESTRICT,
    decision_reason         text,
    decided_at              timestamptz,
    new_work_stable_key     uuid,
    created_at              timestamptz NOT NULL DEFAULT now(),
    CHECK (
        status IN ('SUBMITTED', 'NEEDS_INFO')
        OR (expert_id IS NOT NULL AND decision_reason IS NOT NULL AND btrim(decision_reason) <> '' AND decided_at IS NOT NULL)
    )
);

ALTER TABLE plan_versions
    ADD CONSTRAINT plan_versions_change_request_fkey
    FOREIGN KEY (change_request_id) REFERENCES change_requests (id) ON DELETE RESTRICT;

CREATE UNIQUE INDEX plan_versions_one_per_change_idx
    ON plan_versions (change_request_id)
    WHERE change_request_id IS NOT NULL;

CREATE TABLE acceptances (
    id              bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    repair_work_id  bigint NOT NULL REFERENCES repair_works (id) ON DELETE CASCADE,
    expert_id       bigint NOT NULL REFERENCES app_users (id) ON DELETE RESTRICT,
    attempt_no      integer NOT NULL CHECK (attempt_no >= 1),
    decision        acceptance_decision NOT NULL,
    decided_at      timestamptz NOT NULL DEFAULT now(),
    UNIQUE (repair_work_id, attempt_no)
);

CREATE TABLE acceptance_remarks (
    id              bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    acceptance_id   bigint NOT NULL REFERENCES acceptances (id) ON DELETE CASCADE,
    description     text NOT NULL CHECK (btrim(description) <> ''),
    fix_due_date    date NOT NULL,
    resolved_at     timestamptz
);

-- Ссылка на файл в Nextcloud. Ровно один владелец.
CREATE TABLE file_links (
    id                  bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    nextcloud_url       text NOT NULL CHECK (btrim(nextcloud_url) <> ''),
    file_name           text NOT NULL CHECK (btrim(file_name) <> ''),
    uploaded_by         bigint NOT NULL REFERENCES app_users (id) ON DELETE RESTRICT,
    uploaded_at         timestamptz NOT NULL DEFAULT now(),
    repair_request_id   bigint REFERENCES repair_requests (id) ON DELETE CASCADE,
    work_log_entry_id   bigint REFERENCES work_log_entries (id) ON DELETE CASCADE,
    change_request_id   bigint REFERENCES change_requests (id) ON DELETE CASCADE,
    acceptance_id       bigint REFERENCES acceptances (id) ON DELETE CASCADE,
    CHECK (
        num_nonnulls(repair_request_id, work_log_entry_id, change_request_id, acceptance_id) = 1
    )
);

CREATE TABLE warranty_periods (
    id              bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    repair_work_id  bigint NOT NULL UNIQUE REFERENCES repair_works (id) ON DELETE RESTRICT,
    contractor_id   bigint NOT NULL REFERENCES contractors (id) ON DELETE RESTRICT,
    starts_on       date NOT NULL,
    ends_on         date NOT NULL,
    incident_count  integer NOT NULL DEFAULT 0 CHECK (incident_count >= 0),
    CHECK (ends_on > starts_on)
);

CREATE TABLE audit_events (
    id              bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    actor_id        bigint REFERENCES app_users (id) ON DELETE RESTRICT,
    happened_at     timestamptz NOT NULL DEFAULT now(),
    entity_name     text NOT NULL CHECK (btrim(entity_name) <> ''),
    entity_id       bigint NOT NULL,
    action          text NOT NULL CHECK (btrim(action) <> ''),
    details         jsonb NOT NULL DEFAULT '{}'::jsonb
);

-- ---------------------------------------------------------------------------
-- Индексы внешних ключей, по которым идут соединения прецедентов
-- ---------------------------------------------------------------------------

CREATE INDEX facilities_admin_idx ON facilities (admin_id);
CREATE INDEX facilities_type_idx ON facilities (facility_type_id);
CREATE INDEX facility_elements_facility_idx ON facility_elements (facility_id);
CREATE INDEX facility_elements_parent_idx ON facility_elements (parent_element_id);
CREATE INDEX work_types_specialization_idx ON work_types (specialization_id);
CREATE INDEX dependency_rules_required_idx ON dependency_rules (required_work_type_id);
CREATE INDEX repair_requests_facility_idx ON repair_requests (facility_id, status);
CREATE INDEX repair_requests_element_idx ON repair_requests (element_id);
CREATE INDEX repair_projects_facility_idx ON repair_projects (facility_id, status);
CREATE INDEX plan_versions_project_idx ON plan_versions (project_id, version_no);
CREATE INDEX repair_works_version_status_idx ON repair_works (plan_version_id, status);
CREATE INDEX repair_works_stable_key_idx ON repair_works (stable_key);
CREATE INDEX repair_works_contractor_idx ON repair_works (assigned_contractor_id);
CREATE INDEX work_dependencies_successor_idx ON work_dependencies (successor_work_id);
CREATE INDEX tenders_project_idx ON tenders (project_id, status);
CREATE INDEX tenders_plan_idx ON tenders (plan_version_id);
CREATE INDEX tender_lots_tender_idx ON tender_lots (tender_id);
CREATE INDEX tender_invitations_contractor_idx ON tender_invitations (contractor_id, status);
CREATE INDEX bid_versions_bid_idx ON bid_versions (bid_id, version_no);
CREATE INDEX bid_scores_version_idx ON bid_scores (bid_version_id);
CREATE INDEX work_log_entries_work_idx ON work_log_entries (repair_work_id, recorded_at);
CREATE INDEX change_requests_work_idx ON change_requests (discovered_on_work_id, status);
CREATE INDEX acceptances_work_idx ON acceptances (repair_work_id, attempt_no);
CREATE INDEX audit_events_entity_idx ON audit_events (entity_name, entity_id, happened_at);

-- ---------------------------------------------------------------------------
-- Ограничения, которые нельзя выразить одним внешним ключом
-- ---------------------------------------------------------------------------

CREATE FUNCTION assert_user_role(p_user_id bigint, p_role user_role, p_message text)
RETURNS void
LANGUAGE plpgsql
SET search_path = remkomstroy, public
AS $$
BEGIN
    IF p_user_id IS NULL THEN
        RETURN;
    END IF;

    IF NOT EXISTS (
        SELECT 1
        FROM app_users
        WHERE id = p_user_id
          AND role = p_role
          AND is_active
    ) THEN
        RAISE EXCEPTION USING MESSAGE = p_message;
    END IF;
END;
$$;

CREATE FUNCTION enforce_contractor_profile()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = remkomstroy, public
AS $$
BEGIN
    PERFORM assert_user_role(
        NEW.user_id,
        'CONTRACTOR',
        'Карточка подрядчика привязывается к действующему пользователю с ролью подрядчика'
    );
    RETURN NEW;
END;
$$;

CREATE TRIGGER contractors_profile_trg
    BEFORE INSERT OR UPDATE OF user_id ON contractors
    FOR EACH ROW
    EXECUTE FUNCTION enforce_contractor_profile();

CREATE FUNCTION enforce_user_role_change()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = remkomstroy, public
AS $$
BEGIN
    IF NEW.role IS DISTINCT FROM OLD.role
       AND OLD.role = 'CONTRACTOR'
       AND EXISTS (SELECT 1 FROM contractors WHERE user_id = NEW.id) THEN
        RAISE EXCEPTION USING MESSAGE =
            'Нельзя сменить роль пользователя, у которого есть карточка подрядчика';
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER app_users_role_trg
    BEFORE UPDATE OF role ON app_users
    FOR EACH ROW
    EXECUTE FUNCTION enforce_user_role_change();

CREATE FUNCTION enforce_facility()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = remkomstroy, public
AS $$
BEGIN
    PERFORM assert_user_role(
        NEW.admin_id,
        'ADMIN',
        'Ответственным за объект может быть только действующий администратор'
    );
    RETURN NEW;
END;
$$;

CREATE TRIGGER facilities_admin_trg
    BEFORE INSERT OR UPDATE OF admin_id ON facilities
    FOR EACH ROW
    EXECUTE FUNCTION enforce_facility();

CREATE FUNCTION enforce_facility_element()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = remkomstroy, public
AS $$
DECLARE
    parent_facility bigint;
BEGIN
    IF TG_OP = 'UPDATE'
       AND NEW.facility_id IS DISTINCT FROM OLD.facility_id
       AND EXISTS (SELECT 1 FROM facility_elements WHERE parent_element_id = NEW.id) THEN
        RAISE EXCEPTION USING MESSAGE =
            'Нельзя перенести элемент в другой объект, пока у него есть дочерние элементы';
    END IF;

    IF NEW.parent_element_id IS NULL THEN
        RETURN NEW;
    END IF;

    IF NEW.parent_element_id = NEW.id THEN
        RAISE EXCEPTION USING MESSAGE = 'Элемент не может быть родителем самого себя';
    END IF;

    SELECT facility_id
      INTO parent_facility
    FROM facility_elements
    WHERE id = NEW.parent_element_id;

    IF parent_facility IS NULL THEN
        RAISE EXCEPTION USING MESSAGE = 'Родительский элемент не найден';
    END IF;

    IF parent_facility <> NEW.facility_id THEN
        RAISE EXCEPTION USING MESSAGE =
            'Родительский элемент должен принадлежать тому же объекту';
    END IF;

    -- Новый идентификатор ещё не входит в дерево, цикл возможен при смене родителя.
    IF NEW.id IS NOT NULL AND EXISTS (
        WITH RECURSIVE ancestors AS (
            SELECT NEW.parent_element_id AS id, ARRAY[NEW.parent_element_id] AS path
            UNION ALL
            SELECT e.parent_element_id, ancestors.path || e.parent_element_id
            FROM facility_elements e
            JOIN ancestors ON e.id = ancestors.id
            WHERE e.parent_element_id IS NOT NULL
              AND NOT e.parent_element_id = ANY (ancestors.path)
        )
        SELECT 1 FROM ancestors WHERE id = NEW.id
    ) THEN
        RAISE EXCEPTION USING MESSAGE = 'В иерархии элементов получился цикл';
    END IF;

    RETURN NEW;
END;
$$;

CREATE TRIGGER facility_elements_tree_trg
    BEFORE INSERT OR UPDATE OF parent_element_id, facility_id ON facility_elements
    FOR EACH ROW
    EXECUTE FUNCTION enforce_facility_element();

CREATE FUNCTION enforce_dependency_rule()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = remkomstroy, public
AS $$
DECLARE
    excluded_id bigint;
BEGIN
    IF NEW.source_work_type_id = NEW.required_work_type_id THEN
        RAISE EXCEPTION USING MESSAGE = 'Вид работ не может зависеть от самого себя';
    END IF;

    IF TG_OP = 'UPDATE' THEN
        excluded_id := OLD.id;
    END IF;

    -- Ребро: обязательная работа -> исходная. Цикл, если от исходной уже есть путь назад.
    IF EXISTS (
        WITH RECURSIVE reach AS (
            SELECT source_work_type_id AS id,
                   ARRAY[NEW.source_work_type_id, source_work_type_id] AS path
            FROM dependency_rules
            WHERE required_work_type_id = NEW.source_work_type_id
              AND (excluded_id IS NULL OR id <> excluded_id)
            UNION ALL
            SELECT r.source_work_type_id, reach.path || r.source_work_type_id
            FROM dependency_rules r
            JOIN reach ON r.required_work_type_id = reach.id
            WHERE NOT r.source_work_type_id = ANY (reach.path)
              AND (excluded_id IS NULL OR r.id <> excluded_id)
        )
        SELECT 1 FROM reach WHERE id = NEW.required_work_type_id
    ) THEN
        RAISE EXCEPTION USING MESSAGE = 'Правила зависимости видов работ образуют цикл';
    END IF;

    RETURN NEW;
END;
$$;

CREATE TRIGGER dependency_rules_cycle_trg
    BEFORE INSERT OR UPDATE ON dependency_rules
    FOR EACH ROW
    EXECUTE FUNCTION enforce_dependency_rule();

CREATE FUNCTION enforce_repair_request()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = remkomstroy, public
AS $$
BEGIN
    PERFORM assert_user_role(
        NEW.created_by,
        'ADMIN',
        'Заявку на ремонт создаёт администратор'
    );

    IF NOT EXISTS (
        SELECT 1
        FROM facility_elements
        WHERE id = NEW.element_id
          AND facility_id = NEW.facility_id
    ) THEN
        RAISE EXCEPTION USING MESSAGE = 'Элемент заявки не принадлежит указанному объекту';
    END IF;

    RETURN NEW;
END;
$$;

CREATE TRIGGER repair_requests_trg
    BEFORE INSERT OR UPDATE OF facility_id, element_id, created_by ON repair_requests
    FOR EACH ROW
    EXECUTE FUNCTION enforce_repair_request();

CREATE FUNCTION enforce_repair_project()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = remkomstroy, public
AS $$
BEGIN
    IF NOT EXISTS (
        SELECT 1
        FROM repair_requests
        WHERE id = NEW.request_id
          AND facility_id = NEW.facility_id
    ) THEN
        RAISE EXCEPTION USING MESSAGE = 'Проект должен относиться к тому же объекту, что и заявка';
    END IF;

    IF NEW.closed_by IS NOT NULL THEN
        PERFORM assert_user_role(
            NEW.closed_by,
            'ADMIN',
            'Проект закрывает администратор'
        );
    END IF;

    RETURN NEW;
END;
$$;

CREATE TRIGGER repair_projects_trg
    BEFORE INSERT OR UPDATE OF request_id, facility_id, closed_by ON repair_projects
    FOR EACH ROW
    EXECUTE FUNCTION enforce_repair_project();

CREATE FUNCTION enforce_plan_version()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = remkomstroy, public
AS $$
BEGIN
    IF NEW.based_on_version_id IS NOT NULL THEN
        IF NOT EXISTS (
            SELECT 1
            FROM plan_versions
            WHERE id = NEW.based_on_version_id
              AND project_id = NEW.project_id
        ) THEN
            RAISE EXCEPTION USING MESSAGE = 'Предыдущая версия плана относится к другому проекту';
        END IF;

        IF NEW.id IS NOT NULL AND EXISTS (
            WITH RECURSIVE chain AS (
                SELECT NEW.based_on_version_id AS id, ARRAY[NEW.based_on_version_id] AS path
                UNION ALL
                SELECT v.based_on_version_id, chain.path || v.based_on_version_id
                FROM plan_versions v
                JOIN chain ON v.id = chain.id
                WHERE v.based_on_version_id IS NOT NULL
                  AND NOT v.based_on_version_id = ANY (chain.path)
            )
            SELECT 1 FROM chain WHERE id = NEW.id
        ) THEN
            RAISE EXCEPTION USING MESSAGE = 'Цепочка версий плана зациклена';
        END IF;
    END IF;

    IF NEW.change_request_id IS NOT NULL AND NOT EXISTS (
        SELECT 1
        FROM change_requests cr
        JOIN repair_works w ON w.id = cr.discovered_on_work_id
        JOIN plan_versions v ON v.id = w.plan_version_id
        WHERE cr.id = NEW.change_request_id
          AND v.project_id = NEW.project_id
    ) THEN
        RAISE EXCEPTION USING MESSAGE = 'Запрос на изменение относится к другому проекту';
    END IF;

    PERFORM assert_user_role(
        NEW.scope_confirmed_by,
        'EXPERT',
        'Состав работ подтверждает технический эксперт'
    );
    PERFORM assert_user_role(
        NEW.approved_by,
        'ADMIN',
        'План ремонта утверждает администратор'
    );

    RETURN NEW;
END;
$$;

CREATE TRIGGER plan_versions_trg
    BEFORE INSERT OR UPDATE ON plan_versions
    FOR EACH ROW
    EXECUTE FUNCTION enforce_plan_version();

CREATE FUNCTION predecessors_pending(p_work_id bigint)
RETURNS boolean
LANGUAGE sql
STABLE
SET search_path = remkomstroy, public
AS $$
    SELECT EXISTS (
        SELECT 1
        FROM work_dependencies d
        JOIN repair_works pred ON pred.id = d.predecessor_work_id
        WHERE d.successor_work_id = p_work_id
          AND pred.status <> 'ACCEPTED'
    );
$$;

CREATE FUNCTION enforce_repair_work()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = remkomstroy, public
AS $$
DECLARE
    contractor_changed boolean := false;
    starts_now boolean := false;
    goes_to_acceptance boolean := false;
    becomes_accepted boolean := false;
BEGIN
    IF NOT EXISTS (
        SELECT 1
        FROM plan_versions v
        JOIN repair_projects p ON p.id = v.project_id
        JOIN facility_elements e
          ON e.id = NEW.element_id
         AND e.facility_id = p.facility_id
        WHERE v.id = NEW.plan_version_id
    ) THEN
        RAISE EXCEPTION USING MESSAGE =
            'Работа должна относиться к элементу объекта этого проекта';
    END IF;

    IF TG_OP = 'INSERT' THEN
        contractor_changed := NEW.assigned_contractor_id IS NOT NULL;
        starts_now := NEW.status = 'IN_PROGRESS';
        goes_to_acceptance := NEW.status = 'ON_ACCEPTANCE';
        becomes_accepted := NEW.status = 'ACCEPTED';
    ELSE
        contractor_changed := NEW.assigned_contractor_id IS NOT NULL
            AND NEW.assigned_contractor_id IS DISTINCT FROM OLD.assigned_contractor_id;
        starts_now := NEW.status = 'IN_PROGRESS' AND OLD.status IS DISTINCT FROM 'IN_PROGRESS';
        goes_to_acceptance := NEW.status = 'ON_ACCEPTANCE' AND OLD.status IS DISTINCT FROM 'ON_ACCEPTANCE';
        becomes_accepted := NEW.status = 'ACCEPTED' AND OLD.status IS DISTINCT FROM 'ACCEPTED';
    END IF;

    IF contractor_changed AND NOT EXISTS (
        SELECT 1
        FROM contractors c
        JOIN app_users u ON u.id = c.user_id
        WHERE c.id = NEW.assigned_contractor_id
          AND c.status = 'ACTIVE'
          AND u.is_active
          AND u.role = 'CONTRACTOR'
    ) THEN
        RAISE EXCEPTION USING MESSAGE = 'Назначить можно только действующего подрядчика';
    END IF;

    IF starts_now AND predecessors_pending(NEW.id) THEN
        RAISE EXCEPTION USING MESSAGE =
            'Этап нельзя начать, пока не приняты предшествующие работы';
    END IF;

    IF goes_to_acceptance AND NOT EXISTS (
        SELECT 1
        FROM work_log_entries entry
        JOIN file_links link ON link.work_log_entry_id = entry.id
        WHERE entry.repair_work_id = NEW.id
    ) THEN
        RAISE EXCEPTION USING MESSAGE =
            'Нельзя передать этап на приёмку: в журнале нет ссылки на материалы';
    END IF;

    IF becomes_accepted AND NOT EXISTS (
        SELECT 1
        FROM acceptances
        WHERE repair_work_id = NEW.id
          AND decision = 'ACCEPTED'
    ) THEN
        RAISE EXCEPTION USING MESSAGE = 'Статус «принят» ставится по решению технического эксперта';
    END IF;

    RETURN NEW;
END;
$$;

CREATE TRIGGER repair_works_trg
    BEFORE INSERT OR UPDATE ON repair_works
    FOR EACH ROW
    EXECUTE FUNCTION enforce_repair_work();

CREATE FUNCTION enforce_work_dependency()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = remkomstroy, public
AS $$
DECLARE
    predecessor_version bigint;
    successor_version bigint;
    skip_predecessor bigint;
    skip_successor bigint;
BEGIN
    IF NEW.predecessor_work_id = NEW.successor_work_id THEN
        RAISE EXCEPTION USING MESSAGE = 'Работа не может зависеть от самой себя';
    END IF;

    SELECT plan_version_id INTO predecessor_version
    FROM repair_works
    WHERE id = NEW.predecessor_work_id;

    SELECT plan_version_id INTO successor_version
    FROM repair_works
    WHERE id = NEW.successor_work_id;

    IF predecessor_version IS NULL OR successor_version IS NULL THEN
        RAISE EXCEPTION USING MESSAGE = 'Обе работы зависимости должны существовать';
    END IF;

    IF predecessor_version <> successor_version THEN
        RAISE EXCEPTION USING MESSAGE = 'Зависимость связывается только внутри одной версии плана';
    END IF;

    IF TG_OP = 'UPDATE' THEN
        skip_predecessor := OLD.predecessor_work_id;
        skip_successor := OLD.successor_work_id;
    END IF;

    IF EXISTS (
        WITH RECURSIVE reach AS (
            SELECT successor_work_id AS id,
                   ARRAY[NEW.successor_work_id, successor_work_id] AS path
            FROM work_dependencies
            WHERE predecessor_work_id = NEW.successor_work_id
              AND (
                    skip_predecessor IS NULL
                    OR (predecessor_work_id, successor_work_id)
                       IS DISTINCT FROM (skip_predecessor, skip_successor)
              )
            UNION ALL
            SELECT d.successor_work_id, reach.path || d.successor_work_id
            FROM work_dependencies d
            JOIN reach ON d.predecessor_work_id = reach.id
            WHERE NOT d.successor_work_id = ANY (reach.path)
              AND (
                    skip_predecessor IS NULL
                    OR (d.predecessor_work_id, d.successor_work_id)
                       IS DISTINCT FROM (skip_predecessor, skip_successor)
              )
        )
        SELECT 1 FROM reach WHERE id = NEW.predecessor_work_id
    ) THEN
        RAISE EXCEPTION USING MESSAGE = 'Граф работ этой версии плана содержит цикл';
    END IF;

    RETURN NEW;
END;
$$;

CREATE TRIGGER work_dependencies_trg
    BEFORE INSERT OR UPDATE ON work_dependencies
    FOR EACH ROW
    EXECUTE FUNCTION enforce_work_dependency();

CREATE FUNCTION enforce_tender()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = remkomstroy, public
AS $$
DECLARE
    version_ok boolean;
BEGIN
    PERFORM assert_user_role(NEW.created_by, 'ADMIN', 'Тендер создаёт администратор');

    IF TG_OP = 'UPDATE'
       AND NEW.project_id = OLD.project_id
       AND NEW.plan_version_id = OLD.plan_version_id THEN
        RETURN NEW;
    END IF;

    SELECT status = 'CONFIRMED'
      INTO version_ok
    FROM plan_versions
    WHERE id = NEW.plan_version_id
      AND project_id = NEW.project_id;

    IF version_ok IS NULL THEN
        RAISE EXCEPTION USING MESSAGE = 'Версия плана не принадлежит проекту тендера';
    END IF;

    IF NOT version_ok THEN
        RAISE EXCEPTION USING MESSAGE = 'Тендер объявляется по подтверждённой версии плана';
    END IF;

    RETURN NEW;
END;
$$;

CREATE TRIGGER tenders_trg
    BEFORE INSERT OR UPDATE ON tenders
    FOR EACH ROW
    EXECUTE FUNCTION enforce_tender();

CREATE FUNCTION enforce_lot_work()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = remkomstroy, public
AS $$
DECLARE
    tender_plan bigint;
    lot_spec bigint;
    work_plan bigint;
    work_spec bigint;
BEGIN
    SELECT t.plan_version_id, lot.specialization_id
      INTO tender_plan, lot_spec
    FROM tender_lots lot
    JOIN tenders t ON t.id = lot.tender_id
    WHERE lot.id = NEW.lot_id;

    SELECT w.plan_version_id, wt.specialization_id
      INTO work_plan, work_spec
    FROM repair_works w
    JOIN work_types wt ON wt.id = w.work_type_id
    WHERE w.id = NEW.repair_work_id;

    IF tender_plan IS NULL OR work_plan IS NULL THEN
        RAISE EXCEPTION USING MESSAGE = 'Лот или работа для связи не найдены';
    END IF;

    IF tender_plan <> work_plan THEN
        RAISE EXCEPTION USING MESSAGE =
            'В лот входят только работы той версии плана, по которой объявлен тендер';
    END IF;

    IF lot_spec <> work_spec THEN
        RAISE EXCEPTION USING MESSAGE = 'Специализация работы не совпадает со специализацией лота';
    END IF;

    RETURN NEW;
END;
$$;

CREATE TRIGGER lot_works_trg
    BEFORE INSERT OR UPDATE ON lot_works
    FOR EACH ROW
    EXECUTE FUNCTION enforce_lot_work();

CREATE FUNCTION enforce_invitation()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = remkomstroy, public
AS $$
DECLARE
    lot_spec bigint;
BEGIN
    IF TG_OP = 'UPDATE'
       AND NEW.lot_id = OLD.lot_id
       AND NEW.contractor_id = OLD.contractor_id THEN
        RETURN NEW;
    END IF;

    SELECT specialization_id INTO lot_spec
    FROM tender_lots
    WHERE id = NEW.lot_id;

    IF NOT EXISTS (
        SELECT 1
        FROM contractors c
        JOIN app_users u ON u.id = c.user_id
        JOIN contractor_specializations cs
          ON cs.contractor_id = c.id
         AND cs.specialization_id = lot_spec
        WHERE c.id = NEW.contractor_id
          AND c.status = 'ACTIVE'
          AND u.is_active
          AND u.role = 'CONTRACTOR'
    ) THEN
        RAISE EXCEPTION USING MESSAGE =
            'Приглашать можно только действующего подрядчика со специализацией лота';
    END IF;

    RETURN NEW;
END;
$$;

CREATE TRIGGER tender_invitations_trg
    BEFORE INSERT OR UPDATE OF lot_id, contractor_id ON tender_invitations
    FOR EACH ROW
    EXECUTE FUNCTION enforce_invitation();

CREATE FUNCTION enforce_lot_award()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = remkomstroy, public
AS $$
DECLARE
    bid_lot bigint;
    bid_rank integer;
    bid_current boolean;
BEGIN
    PERFORM assert_user_role(NEW.awarded_by, 'ADMIN', 'Победителя лота выбирает администратор');

    SELECT invitation.lot_id, version.rank_place, version.is_current
      INTO bid_lot, bid_rank, bid_current
    FROM bid_versions version
    JOIN bids bid ON bid.id = version.bid_id
    JOIN tender_invitations invitation ON invitation.id = bid.invitation_id
    WHERE version.id = NEW.bid_version_id;

    IF bid_lot IS NULL THEN
        RAISE EXCEPTION USING MESSAGE = 'Версия предложения не найдена';
    END IF;

    IF bid_lot <> NEW.lot_id THEN
        RAISE EXCEPTION USING MESSAGE = 'Предложение относится к другому лоту';
    END IF;

    IF NOT bid_current THEN
        RAISE EXCEPTION USING MESSAGE = 'Назначить можно только актуальную версию предложения';
    END IF;

    IF bid_rank IS NULL THEN
        RAISE EXCEPTION USING MESSAGE = 'Сначала нужно ранжировать предложения лота';
    END IF;

    IF NEW.rank_place_at_choice IS DISTINCT FROM bid_rank THEN
        RAISE EXCEPTION USING MESSAGE = 'Место в решении должно совпадать с сохранённым рейтингом';
    END IF;

    IF bid_rank > 1 AND (NEW.justification IS NULL OR btrim(NEW.justification) = '') THEN
        RAISE EXCEPTION USING MESSAGE =
            'Если выбрано не первое место рейтинга, нужно указать обоснование';
    END IF;

    RETURN NEW;
END;
$$;

CREATE TRIGGER lot_awards_trg
    BEFORE INSERT OR UPDATE ON lot_awards
    FOR EACH ROW
    EXECUTE FUNCTION enforce_lot_award();

CREATE FUNCTION enforce_work_log()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = remkomstroy, public
AS $$
BEGIN
    IF NOT EXISTS (
        SELECT 1
        FROM repair_works w
        JOIN contractors c ON c.id = w.assigned_contractor_id
        WHERE w.id = NEW.repair_work_id
          AND c.user_id = NEW.author_id
          AND c.status = 'ACTIVE'
    ) THEN
        RAISE EXCEPTION USING MESSAGE = 'Журнал этапа ведёт назначенный на него подрядчик';
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER work_log_entries_trg
    BEFORE INSERT OR UPDATE OF repair_work_id, author_id ON work_log_entries
    FOR EACH ROW
    EXECUTE FUNCTION enforce_work_log();

CREATE FUNCTION enforce_change_request()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = remkomstroy, public
AS $$
BEGIN
    IF NOT EXISTS (
        SELECT 1
        FROM repair_works w
        JOIN plan_versions v ON v.id = w.plan_version_id
        JOIN repair_projects p ON p.id = v.project_id
        JOIN facility_elements e ON e.id = NEW.element_id AND e.facility_id = p.facility_id
        WHERE w.id = NEW.discovered_on_work_id
    ) THEN
        RAISE EXCEPTION USING MESSAGE =
            'Дефект должен относиться к элементу того же объекта, на котором идёт работа';
    END IF;

    IF NOT EXISTS (
        SELECT 1
        FROM repair_works w
        JOIN contractors c ON c.id = w.assigned_contractor_id
        WHERE w.id = NEW.discovered_on_work_id
          AND c.user_id = NEW.author_id
    ) THEN
        RAISE EXCEPTION USING MESSAGE =
            'О скрытом дефекте сообщает подрядчик, который выполняет этап';
    END IF;

    PERFORM assert_user_role(
        NEW.expert_id,
        'EXPERT',
        'Дополнительную работу проверяет технический эксперт'
    );

    RETURN NEW;
END;
$$;

CREATE TRIGGER change_requests_trg
    BEFORE INSERT OR UPDATE ON change_requests
    FOR EACH ROW
    EXECUTE FUNCTION enforce_change_request();

CREATE FUNCTION enforce_acceptance()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = remkomstroy, public
AS $$
BEGIN
    PERFORM assert_user_role(
        NEW.expert_id,
        'EXPERT',
        'Этап принимает технический эксперт'
    );

    IF TG_OP = 'INSERT' AND NOT EXISTS (
        SELECT 1
        FROM repair_works
        WHERE id = NEW.repair_work_id
          AND status = 'ON_ACCEPTANCE'
    ) THEN
        RAISE EXCEPTION USING MESSAGE =
            'Принимать можно только этап, который подрядчик передал на приёмку';
    END IF;

    IF predecessors_pending(NEW.repair_work_id) THEN
        RAISE EXCEPTION USING MESSAGE =
            'Нельзя принять этап, пока не приняты предшествующие работы';
    END IF;

    RETURN NEW;
END;
$$;

CREATE TRIGGER acceptances_actor_trg
    BEFORE INSERT OR UPDATE OF expert_id ON acceptances
    FOR EACH ROW
    EXECUTE FUNCTION enforce_acceptance();

CREATE FUNCTION apply_acceptance_decision()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = remkomstroy, public
AS $$
BEGIN
    UPDATE repair_works
    SET status = CASE
            WHEN NEW.decision = 'ACCEPTED' THEN 'ACCEPTED'::work_status
            ELSE 'REWORK'::work_status
        END
    WHERE id = NEW.repair_work_id;
    RETURN NEW;
END;
$$;

CREATE TRIGGER acceptances_apply_trg
    AFTER INSERT OR UPDATE OF decision ON acceptances
    FOR EACH ROW
    EXECUTE FUNCTION apply_acceptance_decision();

-- ---------------------------------------------------------------------------
-- Справочники, которые предметная область уже называет явно.
-- Специализации и виды работ добавляются данными, без смены схемы.
-- ---------------------------------------------------------------------------

INSERT INTO facility_types (code, name) VALUES
    ('BUILDING', 'Здание'),
    ('ROAD', 'Автомобильная дорога'),
    ('YARD', 'Дворовая территория'),
    ('COMPLEX', 'Комплекс сооружений');

INSERT INTO evaluation_criteria (code, name, higher_is_better, description) VALUES
    ('PRICE', 'Стоимость', false, 'Окончательная цена предложения'),
    ('DURATION', 'Срок выполнения', false, 'Продолжительность работ в днях'),
    ('OVERDUE_SHARE', 'Доля просрочек', false, 'Доля ранее просроченных работ подрядчика'),
    ('REWORK_COUNT', 'Возвраты на доработку', false, 'Число возвратов этапов на доработку'),
    ('WARRANTY_CASES', 'Гарантийные случаи', false, 'Число гарантийных случаев подрядчика');

COMMENT ON SCHEMA remkomstroy IS
    'РемКомСтрой: объекты ремонта, план работ, тендеры, выполнение и приёмка';

COMMENT ON TABLE contractor_specializations IS
    'Связь многие-ко-многим: подрядчик и его специализации';
COMMENT ON TABLE work_dependencies IS
    'Связь многие-ко-многим внутри версии плана: предшественник и последователь';
COMMENT ON TABLE tender_criterion_weights IS
    'Связь многие-ко-многим: критерии рейтинга тендера и их веса';
COMMENT ON TABLE file_links IS
    'Ссылка на файл в Nextcloud. Содержимое файла в базе не хранится';
COMMENT ON COLUMN repair_works.stable_key IS
    'Один и тот же ключ у копий работы во всех версиях плана';
COMMENT ON COLUMN bid_scores.weight_used IS
    'Вес критерия на момент расчёта, чтобы рейтинг можно было воспроизвести';

COMMIT;
