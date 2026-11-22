\set ON_ERROR_STOP on

BEGIN;

DROP FUNCTION IF EXISTS s466402.ready_repair_works(bigint, bigint);
DROP FUNCTION IF EXISTS s466402.tender_bids(bigint);
DROP PROCEDURE IF EXISTS s466402.register_acceptance(bigint, bigint, text, text, date);

DROP TABLE IF EXISTS
    s466402.c_acceptances,
    s466402.c_change_requests,
    s466402.c_bids,
    s466402.c_tender_works,
    s466402.c_tenders,
    s466402.c_work_dependencies,
    s466402.c_repair_works,
    s466402.c_repair_projects,
    s466402.c_contractor_work_types,
    s466402.c_work_types,
    s466402.c_facility_elements,
    s466402.c_facilities,
    s466402.c_company_representatives,
    s466402.c_contractors,
    s466402.c_user_roles,
    s466402.c_roles,
    s466402.c_app_users;

DROP FUNCTION IF EXISTS
    s466402.increment_project_version(),
    s466402.prevent_element_cycle();

DROP TYPE IF EXISTS
    s466402.c_contractor_status,
    s466402.c_project_status,
    s466402.c_repair_work_status,
    s466402.c_tender_status,
    s466402.c_change_request_status,
    s466402.c_acceptance_result,
    s466402.c_project_priority;

COMMIT;
