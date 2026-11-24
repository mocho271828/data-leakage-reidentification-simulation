-- 成功率は、対象者全員が正しく照合された反復数を分子とする。
WITH totals AS (
    SELECT past_percent, past_count, new_size, mask, service,
           count(*) AS trials, sum(all_correct)::BIGINT AS successes,
           avg(all_correct) AS rate, avg(correct) AS mean_correct,
           avg(incorrect) AS mean_incorrect, avg(unresolved) AS mean_unresolved,
           avg(health_revealed) AS mean_health, avg(seen_in_past) AS mean_seen,
           avg(all_seen) AS all_seen_rate
    FROM read_csv(getvariable('trials_csv'))
    GROUP BY ALL
), wilson AS (
    SELECT *, 1.959963984540054 AS z, 1 + z*z/trials AS denom,
           (rate + z*z/(2*trials))/denom AS center,
           z/denom * sqrt(rate*(1-rate)/trials + z*z/(4*trials*trials)) AS radius
    FROM totals
), limits AS (
    SELECT *, IF(successes=0, 0, center-radius) AS lower95,
           IF(successes=trials, 1, center+radius) AS upper95
    FROM wilson
)
SELECT past_percent, past_count, new_size, mask, service, trials, successes, rate,
       lower95, upper95, CASE WHEN lower95>=0.8 THEN 'reached'
                              WHEN upper95<0.8 THEN 'below' ELSE 'uncertain' END AS decision,
       mean_correct, mean_incorrect, mean_unresolved, mean_health, mean_seen, all_seen_rate
FROM limits ORDER BY past_percent, new_size, past_count, mask, service;
