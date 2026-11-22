\set ON_ERROR_STOP on

BEGIN;
SET LOCAL search_path TO s466402, pg_temp;

INSERT INTO c_roles (name) VALUES ('ADMIN') RETURNING id AS admin_role \gset
INSERT INTO c_roles (name) VALUES ('CONTRACTOR') RETURNING id AS contractor_role \gset
INSERT INTO c_roles (name) VALUES ('EXPERT') RETURNING id AS expert_role \gset

INSERT INTO c_app_users (full_name, email)
VALUES ('Анна Соколова', 'admin@example.test') RETURNING id AS admin \gset
INSERT INTO c_app_users (full_name, email)
VALUES ('Иван Петров', 'contractor@example.test') RETURNING id AS representative \gset
INSERT INTO c_app_users (full_name, email)
VALUES ('Елена Волкова', 'expert@example.test') RETURNING id AS expert \gset

INSERT INTO c_user_roles (user_id, role_id)
VALUES (:admin, :admin_role), (:representative, :contractor_role), (:expert, :expert_role);

INSERT INTO c_contractors (company_name, status)
VALUES ('Окна и фасады', 'ACTIVE') RETURNING id AS contractor \gset
INSERT INTO c_company_representatives (user_id, is_primary, contractor_id)
VALUES (:representative, true, :contractor);

INSERT INTO c_contractors (company_name, status)
VALUES ('Фасад-Сервис', 'ACTIVE') RETURNING id AS second_contractor \gset

INSERT INTO c_facilities (name, kind, address)
VALUES ('Учебный корпус', 'Здание', 'Тестовая улица, 10') RETURNING id AS facility \gset
INSERT INTO c_facility_elements (name, element_type, facility_id)
VALUES ('Фасад', 'Стена', :facility) RETURNING id AS facade \gset
INSERT INTO c_facility_elements (name, element_type, location, facility_id, parent_id)
VALUES ('Окно № 3', 'Окно', 'Второй этаж', :facility, :facade) RETURNING id AS window \gset

INSERT INTO c_work_types (name) VALUES ('Подготовка проёма') RETURNING id AS preparation_type \gset
INSERT INTO c_work_types (name) VALUES ('Замена окна') RETURNING id AS replacement_type \gset
INSERT INTO c_contractor_work_types (contractor_id, work_type_id)
VALUES (:contractor, :preparation_type), (:contractor, :replacement_type),
       (:second_contractor, :preparation_type), (:second_contractor, :replacement_type);

INSERT INTO c_repair_projects (name, defect_description, priority, status, element_id, author_id)
VALUES ('Ремонт окна', 'Повреждена рама', 'NORMAL', 'IN_PROGRESS', :window, :admin)
RETURNING id AS project \gset

INSERT INTO c_repair_works (name, version_no, work_code, volume, status, project_id, work_type_id, element_id, contractor_id)
VALUES ('Подготовить проём', 1, 'PREP', 1, 'ACCEPTED', :project, :preparation_type, :window, :contractor)
RETURNING id AS preparation \gset
INSERT INTO c_repair_works (name, version_no, work_code, volume, status, project_id, work_type_id, element_id, contractor_id)
VALUES ('Заменить окно', 1, 'WINDOW', 1, 'ASSIGNED', :project, :replacement_type, :window, :contractor)
RETURNING id AS replacement \gset
INSERT INTO c_repair_works (name, version_no, work_code, volume, status, project_id, work_type_id, element_id, contractor_id)
VALUES ('Укрепить проём', 1, 'REINFORCE', 1, 'ON_ACCEPTANCE', :project, :preparation_type, :window, :contractor)
RETURNING id AS reinforcement \gset
INSERT INTO c_work_dependencies (predecessor_id, successor_id)
VALUES (:preparation, :reinforcement), (:reinforcement, :replacement);

INSERT INTO c_tenders (name, plan_version, response_deadline, status, project_id)
VALUES ('Ремонт окна № 3', 1, CURRENT_TIMESTAMP - INTERVAL '14 days', 'CLOSED', :project)
RETURNING id AS tender \gset
INSERT INTO c_tender_works (tender_id, work_id)
VALUES (:tender, :preparation), (:tender, :reinforcement), (:tender, :replacement);

INSERT INTO c_bids (price, duration_days, start_date, warranty_months, rank_place, is_winner, tender_id, contractor_id)
VALUES (42000, 15, CURRENT_DATE - 10, 12, 1, true, :tender, :contractor),
       (46500, 12, CURRENT_DATE - 8, 18, 2, false, :tender, :second_contractor);

INSERT INTO c_change_requests (description, status, source_work_id, element_id, author_id)
VALUES ('Обнаружена трещина на фасаде', 'NEW', :reinforcement, :facade, :representative);

INSERT INTO c_acceptances (acceptance_date, result, work_id, expert_id)
VALUES (CURRENT_DATE - 2, 'ACCEPTED', :preparation, :expert);

COMMIT;
