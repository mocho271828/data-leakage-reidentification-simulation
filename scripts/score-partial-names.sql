-- 各サービスで無作為順の最初の81人を使い、先頭17人にだけ氏名が残った場合を採点する。
-- mask-2 はメール、mask-3 は氏名とメールを使って通常の照合器が回答した結果。
WITH observations AS (
    SELECT mail.service, mail.row_id,
           mail.predicted_token AS mail_token, named.predicted_token AS name_mail_token
    FROM 'mask-2/predictions.parquet' mail
    JOIN 'mask-3/predictions.parquet' named USING (service, row_id)
    WHERE mail.row_id < 81
), predictions AS (
    SELECT service, row_id, rule, token
    FROM observations, LATERAL (VALUES
        ('mail', mail_token),
        ('available_fields', CASE WHEN row_id < 17 THEN name_mail_token ELSE mail_token END),
        ('name_and_mail_required', CASE WHEN row_id < 17 THEN name_mail_token END)
    ) rules(rule, token)
), truth AS (
    SELECT 'A' AS service, row_id, person_id FROM 'round/scoring/new-A.parquet'
    UNION ALL
    SELECT 'B' AS service, row_id, person_id FROM 'round/scoring/new-B.parquet'
), scored AS (
    SELECT p.*, t.person_id AS true_id, r.person_id AS predicted_id
    FROM predictions p JOIN truth t USING (service, row_id)
    LEFT JOIN 'round/scoring/identity-roster.parquet' r ON p.token = r.identity_token
)
SELECT service, rule,
       CASE WHEN count(*) = 81 AND count(DISTINCT row_id) = 81
                 AND count(token) = count(predicted_id) THEN count(*)
            ELSE error('81人の予測と採点表が対応していません') END AS targets,
       count(*) FILTER (WHERE predicted_id = true_id) AS correct,
       count(*) FILTER (WHERE predicted_id <> true_id) AS incorrect,
       count(*) FILTER (WHERE token IS NULL) AS unresolved,
       count(*) FILTER (WHERE predicted_id = true_id) = 81 AS all_correct
FROM scored GROUP BY service, rule ORDER BY service, rule;
