-- РемКомСтрой: текущая компактная ER-модель, PostgreSQL 14+.
-- Не удаляет существующую схему. Повторная установка требует явного удаления.
BEGIN;
CREATE SCHEMA remkomstroy;
SET search_path TO remkomstroy, public;

CREATE TABLE app_users (
    id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    full_name text NOT NULL CHECK (btrim(full_name) <> ''),
    email text NOT NULL CHECK (email ~ '^[^@[:space:]]+@[^@[:space:]]+$')
);
CREATE UNIQUE INDEX app_users_email_unique ON app_users (lower(email));

CREATE TABLE roles (
    id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    name text NOT NULL UNIQUE CHECK (btrim(name) <> '')
);
CREATE TABLE user_roles (
    user_id bigint NOT NULL REFERENCES app_users ON DELETE CASCADE,
    role_id bigint NOT NULL REFERENCES roles ON DELETE RESTRICT,
    PRIMARY KEY (user_id, role_id)
);

CREATE TABLE contractors (
    id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    company_name text NOT NULL CHECK (btrim(company_name) <> ''),
    status text NOT NULL DEFAULT 'ACTIVE' CHECK (status IN ('ACTIVE', 'BLOCKED'))
);
CREATE TABLE company_representatives (
    -- PK сохраняет согласованное ограничение: не более одной компании у человека.
    user_id bigint PRIMARY KEY REFERENCES app_users ON DELETE CASCADE,
    contractor_id bigint NOT NULL REFERENCES contractors ON DELETE CASCADE,
    is_primary boolean NOT NULL DEFAULT false
);
-- Главный представитель не обязателен; число главных пока не ограничивается.
CREATE INDEX company_representatives_contractor_idx ON company_representatives (contractor_id);

CREATE TABLE facilities (
    id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    name text NOT NULL CHECK (btrim(name) <> ''),
    kind text NOT NULL CHECK (btrim(kind) <> ''),
    address text NOT NULL CHECK (btrim(address) <> '')
);
CREATE TABLE facility_elements (
    id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    name text NOT NULL CHECK (btrim(name) <> ''),
    element_type text NOT NULL CHECK (btrim(element_type) <> ''),
    location text,
    facility_id bigint NOT NULL REFERENCES facilities ON DELETE RESTRICT,
    parent_id bigint,
    UNIQUE (id, facility_id),
    CHECK (parent_id IS NULL OR parent_id <> id),
    FOREIGN KEY (parent_id, facility_id)
        REFERENCES facility_elements (id, facility_id) ON DELETE RESTRICT
        DEFERRABLE INITIALLY IMMEDIATE
);
CREATE INDEX facility_elements_parent_idx ON facility_elements (parent_id, facility_id);

CREATE TABLE work_types (
    id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    name text NOT NULL UNIQUE CHECK (btrim(name) <> '')
);
CREATE TABLE contractor_work_types (
    contractor_id bigint NOT NULL REFERENCES contractors ON DELETE CASCADE,
    work_type_id bigint NOT NULL REFERENCES work_types ON DELETE RESTRICT,
    PRIMARY KEY (contractor_id, work_type_id)
);
CREATE TABLE repair_projects (
    id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    name text NOT NULL CHECK (btrim(name) <> ''),
    defect_description text NOT NULL CHECK (btrim(defect_description) <> ''),
    priority text NOT NULL DEFAULT 'NORMAL' CHECK (priority IN ('LOW', 'NORMAL', 'HIGH', 'URGENT')),
    status text NOT NULL DEFAULT 'DRAFT'
        CHECK (status IN ('DRAFT', 'PLANNING', 'TENDERING', 'IN_PROGRESS', 'COMPLETED', 'CANCELLED')),
    current_version integer NOT NULL DEFAULT 1 CHECK (current_version > 0),
    element_id bigint NOT NULL REFERENCES facility_elements ON DELETE RESTRICT,
    author_id bigint NOT NULL REFERENCES app_users ON DELETE RESTRICT
);
CREATE TABLE repair_works (
    id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    name text NOT NULL CHECK (btrim(name) <> ''),
    version_no integer NOT NULL DEFAULT 1 CHECK (version_no > 0),
    work_code text NOT NULL CHECK (btrim(work_code) <> ''),
    volume numeric(14, 3) NOT NULL CHECK (volume > 0 AND volume <> 'NaN'::numeric),
    status text NOT NULL DEFAULT 'PLANNED'
        CHECK (status IN ('PLANNED', 'BLOCKED', 'READY', 'IN_PROGRESS', 'PAUSED',
                          'ON_ACCEPTANCE', 'REWORK', 'ACCEPTED', 'CANCELLED')),
    project_id bigint NOT NULL REFERENCES repair_projects ON DELETE RESTRICT,
    work_type_id bigint NOT NULL REFERENCES work_types ON DELETE RESTRICT,
    element_id bigint NOT NULL REFERENCES facility_elements ON DELETE RESTRICT,
    contractor_id bigint REFERENCES contractors ON DELETE RESTRICT,
    UNIQUE (project_id, version_no, work_code)
);
CREATE INDEX repair_works_project_idx ON repair_works (project_id, version_no);
CREATE INDEX repair_works_contractor_idx ON repair_works (contractor_id);
CREATE TABLE work_dependencies (
    predecessor_id bigint NOT NULL REFERENCES repair_works ON DELETE RESTRICT,
    successor_id bigint NOT NULL REFERENCES repair_works ON DELETE RESTRICT,
    PRIMARY KEY (predecessor_id, successor_id),
    CHECK (predecessor_id <> successor_id)
);
CREATE INDEX work_dependencies_successor_idx ON work_dependencies (successor_id);

CREATE TABLE tenders (
    id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    name text NOT NULL CHECK (btrim(name) <> ''),
    plan_version integer NOT NULL CHECK (plan_version > 0),
    response_deadline timestamptz NOT NULL,
    status text NOT NULL DEFAULT 'DRAFT'
        CHECK (status IN ('DRAFT', 'OPEN', 'CLOSED', 'AWARDED', 'CANCELLED')),
    project_id bigint NOT NULL REFERENCES repair_projects ON DELETE RESTRICT
);
CREATE TABLE tender_works (
    tender_id bigint NOT NULL REFERENCES tenders ON DELETE CASCADE,
    work_id bigint NOT NULL REFERENCES repair_works ON DELETE RESTRICT,
    PRIMARY KEY (tender_id, work_id)
);
CREATE TABLE bids (
    id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    price numeric(14, 2) NOT NULL CHECK (price > 0 AND price <> 'NaN'::numeric),
    duration_days integer NOT NULL CHECK (duration_days > 0),
    start_date date NOT NULL,
    warranty_months integer NOT NULL CHECK (warranty_months >= 0),
    rank_place integer CHECK (rank_place > 0),
    is_winner boolean NOT NULL DEFAULT false,
    justification text,
    tender_id bigint NOT NULL REFERENCES tenders ON DELETE RESTRICT,
    contractor_id bigint NOT NULL REFERENCES contractors ON DELETE RESTRICT,
    UNIQUE (tender_id, contractor_id),
    CHECK (NOT is_winner OR rank_place IS NOT NULL),
    CHECK (NOT is_winner OR rank_place = 1 OR
           (justification IS NOT NULL AND btrim(justification) <> ''))
);
CREATE UNIQUE INDEX bids_one_winner ON bids (tender_id) WHERE is_winner;

CREATE TABLE change_requests (
    id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    description text NOT NULL CHECK (btrim(description) <> ''),
    status text NOT NULL DEFAULT 'SUBMITTED'
        CHECK (status IN ('SUBMITTED', 'NEEDS_INFO', 'APPROVED', 'REJECTED')),
    expert_decision text,
    source_work_id bigint NOT NULL REFERENCES repair_works ON DELETE RESTRICT,
    element_id bigint NOT NULL REFERENCES facility_elements ON DELETE RESTRICT,
    author_id bigint NOT NULL REFERENCES app_users ON DELETE RESTRICT,
    expert_id bigint REFERENCES app_users ON DELETE RESTRICT,
    CHECK (status NOT IN ('APPROVED', 'REJECTED', 'NEEDS_INFO') OR
           (expert_id IS NOT NULL AND expert_decision IS NOT NULL AND btrim(expert_decision) <> ''))
);
CREATE TABLE acceptances (
    id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    acceptance_date date NOT NULL DEFAULT CURRENT_DATE,
    result text NOT NULL CHECK (result IN ('ACCEPTED', 'REWORK')),
    remarks text,
    correction_deadline date,
    work_id bigint NOT NULL REFERENCES repair_works ON DELETE RESTRICT,
    expert_id bigint NOT NULL REFERENCES app_users ON DELETE RESTRICT,
    CHECK (correction_deadline IS NULL OR correction_deadline >= acceptance_date),
    CHECK (result <> 'REWORK' OR
           (remarks IS NOT NULL AND btrim(remarks) <> '' AND correction_deadline IS NOT NULL))
);
CREATE INDEX acceptances_work_idx ON acceptances (work_id, id DESC);

INSERT INTO roles (name) VALUES ('ADMIN'), ('CONTRACTOR'), ('EXPERT');
COMMENT ON TABLE company_representatives IS 'Представитель компании; user_id — PK и FK. Главный представитель необязателен.';
COMMENT ON TABLE work_dependencies IS 'Направленная M:N: предшественник должен быть принят до выполнения последователя.';
COMMENT ON TABLE tender_works IS 'M:N: одна работа может участвовать в повторных тендерах.';
COMMENT ON COLUMN repair_works.version_no IS 'Номер редакции; полноценные снимки плана в этой модели не реализованы.';
COMMIT;
