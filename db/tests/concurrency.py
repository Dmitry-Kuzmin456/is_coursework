"""Проверка конкурентного добавления цикла. Подключение: PGHOST/PGPORT/PGDATABASE/PGUSER.
Использовать отдельную тестовую базу: тест временно добавляет реальные записи.
"""
import os
import subprocess
import time
import uuid


def query(sql, *, check=True):
    result = subprocess.run(
        ['psql', '-X', '-qAt', '-v', 'ON_ERROR_STOP=1', '-c', sql],
        text=True, capture_output=True, check=False,
    )
    if check and result.returncode:
        raise RuntimeError(result.stderr)
    return result


suffix = uuid.uuid4().hex
# RETURNING связывает созданные записи; пользовательские входные данные не подставляются.
seed = query(f"""
WITH u AS (
 INSERT INTO remkomstroy.app_users(full_name,email)
 VALUES ('Concurrency test','{suffix}@test.invalid') RETURNING id
), f AS (
 INSERT INTO remkomstroy.facilities(name,kind,address) VALUES ('Test','Test','Test') RETURNING id
), e AS (
 INSERT INTO remkomstroy.facility_elements(name,element_type,facility_id)
 SELECT 'Test','Test',id FROM f RETURNING id
), p AS (
 INSERT INTO remkomstroy.repair_projects(name,defect_description,element_id,author_id)
 SELECT 'Test','Test',e.id,u.id FROM e,u RETURNING id
), t AS (
 INSERT INTO remkomstroy.work_types(name) VALUES ('Test {suffix}') RETURNING id
), w AS (
 INSERT INTO remkomstroy.repair_works(name,work_code,volume,project_id,work_type_id,element_id)
 SELECT 'Test',code,1,p.id,t.id,e.id FROM p CROSS JOIN t CROSS JOIN e CROSS JOIN LATERAL (VALUES ('A'),('B')) AS codes(code)
 RETURNING id,project_id,work_type_id,element_id
)
SELECT string_agg(id::text,',' ORDER BY id), min(project_id),min(work_type_id),min(element_id), (SELECT id FROM f), (SELECT id FROM u) FROM w;
""").stdout.strip()
works, project, kind, element, facility, user = seed.split('|')
w1, w2 = works.split(',')
first = None
try:
    first = subprocess.Popen(
        ['psql', '-X', '-qAt', '-v', 'ON_ERROR_STOP=1', '-c', f"""
         BEGIN;
         INSERT INTO remkomstroy.work_dependencies VALUES ({w1},{w2});
         SELECT pg_sleep(2);
         COMMIT;
        """], text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
        env={**os.environ, 'PGAPPNAME': 'remkomstroy_cycle_test_' + suffix},
    )
    deadline = time.monotonic() + 10
    while query(f"SELECT EXISTS(SELECT 1 FROM pg_stat_activity WHERE application_name='remkomstroy_cycle_test_{suffix}' AND wait_event='PgSleep')").stdout.strip() != 't':
        if first.poll() is not None or time.monotonic() > deadline:
            raise RuntimeError('First connection did not reach the synchronization point')
        time.sleep(.05)
    second = query(f'INSERT INTO remkomstroy.work_dependencies VALUES ({w2},{w1});', check=False)
    _, first_error = first.communicate(timeout=15)
    assert first.returncode == 0, first_error
    assert second.returncode != 0 and 'Граф работ содержит цикл' in second.stderr, second.stderr
    assert query(f'SELECT count(*) FROM remkomstroy.work_dependencies WHERE predecessor_id IN ({w1},{w2})').stdout.strip() == '1'
    print('PASS: concurrent cycle rejected; committed dependency preserved')
finally:
    if first is not None and first.poll() is None:
        first.communicate(timeout=15)
    query(f"""
    BEGIN;
    DELETE FROM remkomstroy.work_dependencies WHERE predecessor_id IN ({w1},{w2});
    DELETE FROM remkomstroy.repair_works WHERE project_id={project};
    DELETE FROM remkomstroy.repair_projects WHERE id={project};
    DELETE FROM remkomstroy.work_types WHERE id={kind};
    DELETE FROM remkomstroy.facility_elements WHERE id={element};
    DELETE FROM remkomstroy.facilities WHERE id={facility};
    DELETE FROM remkomstroy.app_users WHERE id={user};
    COMMIT;
    """)
