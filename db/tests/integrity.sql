\set ON_ERROR_STOP on
BEGIN;
SET search_path = remkomstroy, public;
CREATE FUNCTION pg_temp.expect_error(statement text, expected_state text) RETURNS void
LANGUAGE plpgsql AS $$
DECLARE actual_state text;
BEGIN
    BEGIN
        EXECUTE statement;
    EXCEPTION WHEN OTHERS THEN
        GET STACKED DIAGNOSTICS actual_state = RETURNED_SQLSTATE;
        IF actual_state <> expected_state THEN
            RAISE EXCEPTION 'Expected SQLSTATE %, got % for %', expected_state, actual_state, statement;
        END IF;
        RETURN;
    END;
    RAISE EXCEPTION 'Expected SQLSTATE %, but operation succeeded: %', expected_state, statement;
END $$;
CREATE FUNCTION pg_temp.assert_true(value boolean, message text) RETURNS void
LANGUAGE plpgsql AS $$ BEGIN
    IF value IS DISTINCT FROM true THEN RAISE EXCEPTION '%', message; END IF;
END $$;
DO $$
DECLARE
    u bigint; u2 bigint; company bigint; company2 bigint; facility bigint; facility2 bigint;
    elem bigint; child bigint; other_elem bigint; p bigint; p2 bigint;
    kind bigint; unavailable_kind bigint; w1 bigint; w2 bigint; w3 bigint; foreign_work bigint;
    t bigint; t2 bigint; request_id bigint; first_bid bigint; second_bid bigint;
BEGIN
    IF to_regclass('remkomstroy.roles') IS NULL THEN
        RAISE EXCEPTION 'В новой модели необходима таблица roles';
    END IF;
    IF to_regclass('remkomstroy.company_representatives') IS NULL THEN
        RAISE EXCEPTION 'В новой модели необходима таблица company_representatives';
    END IF;
    PERFORM pg_temp.assert_true((SELECT count(*)=17 FROM information_schema.tables
        WHERE table_schema='remkomstroy' AND table_type='BASE TABLE'), 'Expected 17 model tables');
    INSERT INTO app_users(full_name,email) VALUES ('Автор','author@example.test') RETURNING id INTO u;
    INSERT INTO app_users(full_name,email) VALUES ('Эксперт','expert@example.test') RETURNING id INTO u2;
    INSERT INTO user_roles SELECT u,id FROM roles WHERE name IN ('ADMIN','CONTRACTOR');
    PERFORM pg_temp.assert_true((SELECT count(*)=2 FROM user_roles WHERE user_id=u), 'Multiple roles');
    PERFORM pg_temp.expect_error($q$INSERT INTO app_users(full_name,email) VALUES ('Дубль','AUTHOR@example.test')$q$, '23505');
    PERFORM pg_temp.expect_error($q$INSERT INTO app_users(full_name,email) VALUES ('','bad')$q$, '23514');
    INSERT INTO contractors(company_name) VALUES ('Компания без представителя') RETURNING id INTO company;
    INSERT INTO contractors(company_name) VALUES ('Другая компания') RETURNING id INTO company2;
    INSERT INTO company_representatives VALUES (u, company, false), (u2, company, true);
    PERFORM pg_temp.assert_true((SELECT count(*)=2 FROM company_representatives WHERE contractor_id=company), 'Several representatives');
    PERFORM pg_temp.expect_error(format('INSERT INTO company_representatives VALUES (%s,%s,false)',u,company2),'23505');
    -- Наличие главного и его единственность намеренно не обязательны.
    UPDATE company_representatives SET is_primary=true WHERE user_id=u;
    UPDATE company_representatives SET is_primary=false;

    INSERT INTO facilities(name,kind,address) VALUES ('Дом','Здание','Улица 1') RETURNING id INTO facility;
    INSERT INTO facilities(name,kind,address) VALUES ('Другой дом','Здание','Улица 2') RETURNING id INTO facility2;
    INSERT INTO facility_elements(name,element_type,facility_id) VALUES ('Проём','Проём',facility) RETURNING id INTO elem;
    INSERT INTO facility_elements(name,element_type,facility_id,parent_id) VALUES ('Окно','Окно',facility,elem) RETURNING id INTO child;
    INSERT INTO facility_elements(name,element_type,facility_id) VALUES ('Чужой элемент','Стена',facility2) RETURNING id INTO other_elem;
    PERFORM pg_temp.expect_error(format('UPDATE facility_elements SET parent_id=%s WHERE id=%s',child,elem),'23514');
    PERFORM pg_temp.expect_error(format('UPDATE facility_elements SET parent_id=%s WHERE id=%s',other_elem,child),'23503');
    PERFORM pg_temp.expect_error(format('UPDATE facility_elements SET parent_id=id WHERE id=%s',child),'23514');
    INSERT INTO work_types(name) VALUES ('Ремонт') RETURNING id INTO kind;
    INSERT INTO work_types(name) VALUES ('Недоступный вид') RETURNING id INTO unavailable_kind;
    INSERT INTO contractor_work_types VALUES (company,kind), (company2,kind);
    INSERT INTO repair_projects(name,defect_description,element_id,author_id)
        VALUES ('Проект','Трещина',elem,u) RETURNING id INTO p;
    INSERT INTO repair_projects(name,defect_description,element_id,author_id)
        VALUES ('Чужой проект','Трещина',other_elem,u) RETURNING id INTO p2;
    INSERT INTO repair_works(name,work_code,volume,project_id,work_type_id,element_id,contractor_id)
        VALUES ('Первая','A',1,p,kind,elem,company) RETURNING id INTO w1;
    INSERT INTO repair_works(name,work_code,volume,project_id,work_type_id,element_id,contractor_id)
        VALUES ('Вторая','B',1,p,kind,child,company) RETURNING id INTO w2;
    INSERT INTO repair_works(name,work_code,volume,project_id,work_type_id,element_id)
        VALUES ('Третья','C',1,p,kind,elem) RETURNING id INTO w3;
    INSERT INTO repair_works(name,work_code,volume,project_id,work_type_id,element_id)
        VALUES ('Чужая','D',1,p2,kind,other_elem) RETURNING id INTO foreign_work;
    PERFORM pg_temp.expect_error(format('UPDATE repair_works SET element_id=%s WHERE id=%s',other_elem,w1),'23514');
    PERFORM pg_temp.expect_error(format('UPDATE repair_projects SET element_id=%s WHERE id=%s',other_elem,p),'23514');
    PERFORM pg_temp.expect_error(format('UPDATE repair_works SET volume=0 WHERE id=%s',w1),'23514');
    PERFORM pg_temp.expect_error(format('UPDATE repair_works SET work_type_id=%s WHERE id=%s',unavailable_kind,w1),'23514');
    PERFORM pg_temp.expect_error(format('DELETE FROM contractor_work_types WHERE contractor_id=%s',company),'23514');
    PERFORM pg_temp.expect_error(format('UPDATE repair_works SET status=''ACCEPTED'' WHERE id=%s',w1),'23514');
    PERFORM pg_temp.expect_error(format('UPDATE repair_works SET status=''IN_PROGRESS'' WHERE id=%s',w3),'23514');
    INSERT INTO work_dependencies VALUES (w1,w2),(w2,w3);
    PERFORM pg_temp.expect_error(format('INSERT INTO work_dependencies VALUES (%s,%s)',w3,w1),'23514');
    PERFORM pg_temp.expect_error(format('UPDATE work_dependencies SET successor_id=%s WHERE predecessor_id=%s',w1,w2),'23514');
    PERFORM pg_temp.expect_error(format('INSERT INTO work_dependencies VALUES (%s,%s)',w1,w1),'23514');
    PERFORM pg_temp.expect_error(format('INSERT INTO work_dependencies VALUES (%s,%s)',w1,foreign_work),'23514');
    PERFORM pg_temp.expect_error(format('UPDATE repair_works SET version_no=2 WHERE id=%s',w2),'23514');
    PERFORM pg_temp.expect_error(format('UPDATE repair_works SET status=''IN_PROGRESS'' WHERE id=%s',w2),'23514');

    INSERT INTO tenders(name,plan_version,response_deadline,project_id)
        VALUES ('Конкурс',1,now()+interval '7 days',p) RETURNING id INTO t;
    INSERT INTO tenders(name,plan_version,response_deadline,project_id)
        VALUES ('Повторный конкурс',1,now()+interval '7 days',p) RETURNING id INTO t2;
    INSERT INTO tender_works VALUES (t,w1),(t,w2),(t2,w1);
    PERFORM pg_temp.expect_error(format('INSERT INTO tender_works VALUES (%s,%s)',t,foreign_work),'23514');
    PERFORM pg_temp.expect_error(format('UPDATE tenders SET plan_version=2 WHERE id=%s',t),'23514');
    INSERT INTO bids(price,duration_days,start_date,warranty_months,rank_place,tender_id,contractor_id)
        VALUES (100,5,current_date,12,1,t,company) RETURNING id INTO first_bid;
    INSERT INTO bids(price,duration_days,start_date,warranty_months,rank_place,tender_id,contractor_id)
        VALUES (120,6,current_date,12,2,t,company2) RETURNING id INTO second_bid;
    PERFORM pg_temp.expect_error(format('UPDATE bids SET is_winner=true WHERE id=%s',second_bid),'23514');
    UPDATE bids SET is_winner=true WHERE id=first_bid;
    PERFORM pg_temp.expect_error(format('UPDATE bids SET is_winner=true, justification=''Причина'' WHERE id=%s',second_bid),'23505');
    PERFORM pg_temp.expect_error(format('UPDATE bids SET price=-1 WHERE id=%s',first_bid),'23514');

    -- Запрос касается другого элемента того же объекта, а не только элемента работы.
    INSERT INTO change_requests(description,source_work_id,element_id,author_id)
        VALUES ('Новый дефект',w1,child,u) RETURNING id INTO request_id;
    PERFORM pg_temp.expect_error(format('UPDATE change_requests SET element_id=%s WHERE id=%s',other_elem,request_id),'23514');
    PERFORM pg_temp.expect_error(format('UPDATE change_requests SET status=''APPROVED'' WHERE id=%s',request_id),'23514');
    UPDATE change_requests SET status='APPROVED',expert_id=u2,expert_decision='Необходим ремонт' WHERE id=request_id;
    PERFORM pg_temp.expect_error(format('INSERT INTO acceptances(result,work_id,expert_id) VALUES (''ACCEPTED'',%s,%s)',w1,u2),'23514');
    UPDATE repair_works SET status='ON_ACCEPTANCE' WHERE id=w1;
    INSERT INTO acceptances(result,remarks,correction_deadline,work_id,expert_id)
        VALUES ('REWORK','Исправить',current_date+1,w1,u2);
    PERFORM pg_temp.assert_true((SELECT status='REWORK' FROM repair_works WHERE id=w1),'Return to rework');
    UPDATE repair_works SET status='ON_ACCEPTANCE' WHERE id=w1;
    INSERT INTO acceptances(result,work_id,expert_id) VALUES ('ACCEPTED',w1,u2);
    PERFORM pg_temp.assert_true((SELECT status='ACCEPTED' FROM repair_works WHERE id=w1),'Accept work');
    PERFORM pg_temp.assert_true((SELECT count(*)=2 FROM acceptances WHERE work_id=w1),'Preserve repeated acceptances');
    PERFORM pg_temp.expect_error(format('DELETE FROM acceptances WHERE work_id=%s',w1),'23514');
    PERFORM pg_temp.expect_error(format('UPDATE acceptances SET result=''REWORK'' WHERE work_id=%s',w1),'23514');
    UPDATE repair_works SET status='ON_ACCEPTANCE' WHERE id=w2;
    PERFORM pg_temp.expect_error(format('UPDATE repair_works SET status=''REWORK'' WHERE id=%s',w1),'23514');
    PERFORM pg_temp.expect_error(format('UPDATE repair_projects SET status=''COMPLETED'' WHERE id=%s',p),'23514');
    INSERT INTO acceptances(result,work_id,expert_id) VALUES ('ACCEPTED',w2,u2);
    -- Последняя неудачная приёмка отменяет возможность сослаться на старую успешную.
    UPDATE repair_works SET contractor_id=company,status='ON_ACCEPTANCE' WHERE id=w3;
    INSERT INTO acceptances(result,work_id,expert_id) VALUES ('ACCEPTED',w3,u2);
    UPDATE repair_works SET status='ON_ACCEPTANCE' WHERE id=w3;
    INSERT INTO acceptances(result,remarks,correction_deadline,work_id,expert_id)
        VALUES ('REWORK','Повторные замечания',current_date+1,w3,u2);
    PERFORM pg_temp.expect_error(format('UPDATE repair_works SET status=''ACCEPTED'' WHERE id=%s',w3),'23514');
    UPDATE repair_works SET status='CANCELLED' WHERE id=w3;
    UPDATE repair_projects SET status='COMPLETED' WHERE id=p;
    PERFORM pg_temp.assert_true((SELECT status='COMPLETED' FROM repair_projects WHERE id=p),'Complete project');
    PERFORM pg_temp.expect_error(format('DELETE FROM facilities WHERE id=%s',facility),'23503');
    RAISE NOTICE 'All integrity scenarios passed';
END $$;
ROLLBACK;
