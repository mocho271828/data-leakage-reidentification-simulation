-- 実行ディレクトリは各 known-*/trial-1。各人の既知トークンが過去に一度でも存在し、
-- A登録メールが新規メールと同一なら今回の条件では本人を一意に回答できる。
CREATE TEMP TABLE targets AS
WITH truth AS (
    SELECT parse_filename(filename)[5] AS service, row_id, person_id, health_truth
    FROM read_parquet('incidents/scoring/new-*.parquet', filename = true)
), new_mail AS (
    SELECT parse_filename(filename)[5] AS service, row_id, mail_code
    FROM read_parquet('incidents/matching/new-*.parquet', filename = true)
)
SELECT t.*, d.identity_token, coalesce(r.mail_code = n.mail_code, false) AS same_mail
FROM truth t JOIN new_mail n USING (service, row_id)
JOIN 'incidents/scoring/identity-roster.parquet' d USING (person_id)
LEFT JOIN 'incidents/scoring/roster-A.parquet' r USING (person_id);

CREATE TEMP TABLE known_targets AS
SELECT DISTINCT p.identity_token FROM read_parquet('incidents/identity/past-A-*.parquet') p
SEMI JOIN targets USING (identity_token);

WITH expected AS (
    SELECT t.*, k.identity_token IS NOT NULL AND t.same_mail AS expected_match
    FROM targets t LEFT JOIN known_targets k USING (identity_token)
), predictions AS (
    SELECT * FROM 'score-02/predictions.parquet'
)
SELECT service, count(*) AS rows_compared, count_if(expected_match) AS expected_correct,
       count_if(p.row_id IS NULL OR e.row_id IS NULL
             OR p.candidate_count IS DISTINCT FROM expected_match::INTEGER
             OR p.predicted_token IS DISTINCT FROM (CASE WHEN expected_match THEN e.identity_token END)
             OR p.health_code IS DISTINCT FROM e.health_truth) AS mismatches
FROM expected e FULL JOIN predictions p USING (service, row_id)
GROUP BY service ORDER BY service;
