-- round/ と mask-{2,3,31}/ のあるディレクトリで、DuckDB CLI の -csv で実行する。
-- 対象は通常氏名・過去の本人対応率100%・健診記録率100%の模擬事故。
-- 人物IDは、通常の照合器が出力した予測を事後検算するために使う。
CREATE TEMP TABLE targets AS
SELECT regexp_extract(filename, 'new-([AB])[.]parquet$', 1) AS service,
       row_id, person_id, health_truth
FROM read_parquet('round/scoring/new-*.parquet', filename = true);

CREATE TEMP TABLE seen AS
SELECT DISTINCT p.person_id
FROM read_parquet('round/scoring/past-A-*.parquet') p SEMI JOIN targets USING (person_id);

WITH new_attributes AS (
    SELECT regexp_extract(filename, 'new-([AB])[.]parquet$', 1) AS service,
           row_id, mail_code, license_code
    FROM read_parquet('round/matching/new-*.parquet', filename = true)
), expected AS (
    SELECT t.service, t.row_id, t.health_truth, masks.mask, d.identity_token,
           s.person_id IS NOT NULL AND r.mail_code = a.mail_code
               AND (masks.mask <> 31 OR a.license_code IS NOT NULL) AS expected_match
    FROM targets t
    JOIN new_attributes a USING (service, row_id)
    LEFT JOIN seen s USING (person_id)
    LEFT JOIN read_parquet('round/scoring/roster-A.parquet') r USING (person_id)
    JOIN read_parquet('round/scoring/identity-roster.parquet') d USING (person_id)
    CROSS JOIN (VALUES (2), (3), (31)) AS masks(mask)
), predictions AS (
    SELECT regexp_extract(filename, 'mask-([0-9]+)/predictions[.]parquet$', 1)::INTEGER AS mask,
           service, row_id, candidate_count, predicted_token, health_code
    FROM read_parquet(['mask-2/predictions.parquet', 'mask-3/predictions.parquet',
                       'mask-31/predictions.parquet'], filename = true)
)
SELECT mask, service,
       CASE WHEN count(*) = count(DISTINCT row_id) THEN count(*)
            ELSE error('同じサービス・条件の行番号が重複しています') END AS rows_compared,
       count(*) FILTER (WHERE e.expected_match) AS expected_correct,
       count(*) FILTER (
           WHERE p.row_id IS NULL OR e.row_id IS NULL
              OR p.candidate_count IS DISTINCT FROM e.expected_match::INTEGER
              OR p.predicted_token IS DISTINCT FROM (CASE WHEN e.expected_match THEN e.identity_token END)
              OR p.health_code IS DISTINCT FROM e.health_truth
       ) AS mismatches
FROM expected e FULL JOIN predictions p USING (mask, service, row_id)
GROUP BY mask, service ORDER BY mask, service;
