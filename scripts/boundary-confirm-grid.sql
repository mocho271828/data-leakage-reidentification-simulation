-- 探索・理論境界の前2件～後3件、代表点、探索上端を固定してから確認用シードを使う。
WITH pilot AS (
    SELECT past_percent, new_size, min(past_count) AS k
    FROM read_csv('explore-summary.csv')
    WHERE service='A' AND mask IN (2,31) AND rate>=0.8
    GROUP BY past_percent, new_size, mask
), theory AS (
    SELECT past_percent, new_size, first_k AS k
    FROM read_csv('boundary-theory.csv')
    WHERE service='A' AND first_k IS NOT NULL
), centers AS (
    SELECT * FROM pilot UNION SELECT * FROM theory
), points AS (
    SELECT past_percent, k + d AS past_count, new_size
    FROM centers, range(-2,4) delta(d) WHERE k+d BETWEEN 1 AND 56
    UNION
    SELECT p, k, n FROM unnest([12,24]) a(p), unnest([5,6,7,15,24,56]) b(k),
                        unnest([1,10,100]) c(n)
)
SELECT past_percent, past_count, new_size, mask FROM points, unnest([2,3,31]) m(mask)
ORDER BY past_percent, past_count, new_size, mask;
