-- ============================================================
-- REVIEW FRAUD DETECTION & RATING MANIPULATION ANALYTICS
-- MySQL 8.0 | Tested against real Yelp (Cleveland) data
-- ============================================================

-- Q1. Rating spikes by month per restaurant
SELECT restaurant_id,
       DATE_FORMAT(review_date, '%Y-%m-01') AS month,
       ROUND(AVG(rating),2) AS avg_rating,
       COUNT(*) AS review_count
FROM reviews
GROUP BY restaurant_id, month
ORDER BY restaurant_id, month;

-- Q1b. UNIQUE ADDITION: actual spike detector (month-over-month jump > 1.0 star)
WITH monthly AS (
    SELECT restaurant_id,
           DATE_FORMAT(review_date, '%Y-%m-01') AS month,
           AVG(rating) AS avg_rating,
           COUNT(*) AS review_count
    FROM reviews
    GROUP BY restaurant_id, month
),
with_prev AS (
    SELECT *,
           LAG(avg_rating) OVER (PARTITION BY restaurant_id ORDER BY month) AS prev_avg,
           LAG(review_count) OVER (PARTITION BY restaurant_id ORDER BY month) AS prev_count
    FROM monthly
)
SELECT restaurant_id, month, ROUND(prev_avg,2) AS prev_month_avg,
       ROUND(avg_rating,2) AS this_month_avg,
       ROUND(avg_rating - prev_avg,2) AS jump,
       review_count
FROM with_prev
WHERE prev_avg IS NOT NULL
  AND (avg_rating - prev_avg) > 1.0
  AND review_count >= 5   -- ignore noise from tiny sample months
ORDER BY jump DESC;

-- Q2. Users who review too frequently (velocity fraud)
SELECT user_id, COUNT(*) AS review_count
FROM reviews
GROUP BY user_id
HAVING COUNT(*) > 30
ORDER BY review_count DESC;

-- Q2b. UNIQUE ADDITION: velocity within a short time window (bot-like burst)
-- For each review, count how many reviews the SAME user posted in the
-- following 7 days, then take the MAX per user = their worst burst.
WITH burst AS (
    SELECT r1.user_id,
           r1.review_id,
           (SELECT COUNT(*) FROM reviews r2
            WHERE r2.user_id = r1.user_id
              AND r2.review_date BETWEEN r1.review_date AND DATE_ADD(r1.review_date, INTERVAL 7 DAY)
           ) AS window_count
    FROM reviews r1
)
SELECT user_id, MAX(window_count) AS max_reviews_in_7days
FROM burst
GROUP BY user_id
HAVING MAX(window_count) >= 5
ORDER BY max_reviews_in_7days DESC;

-- Q3. Restaurants getting many 5-star reviews from brand-new accounts
SELECT r.restaurant_id,
       COUNT(*) AS suspicious_reviews
FROM reviews r
JOIN users u ON r.user_id = u.user_id
WHERE r.rating = 5
  AND u.account_age_days < 15
GROUP BY r.restaurant_id
HAVING COUNT(*) > 0
ORDER BY suspicious_reviews DESC;

-- Q4. UNIQUE ADDITION: Reviewer diversity per restaurant (collusion ring detector)
-- Low ratio = same small group of users reviewing repeatedly = suspicious
SELECT restaurant_id,
       COUNT(*) AS total_reviews,
       COUNT(DISTINCT user_id) AS unique_reviewers,
       ROUND(COUNT(DISTINCT user_id) / COUNT(*), 3) AS diversity_ratio
FROM reviews
GROUP BY restaurant_id
HAVING COUNT(*) >= 10
ORDER BY diversity_ratio ASC;

-- ============================================================
-- FRAUD RISK SCORE (0-100)
-- 40% New Account Reviews | 30% Rating Spike | 20% Review Velocity | 10% Reviewer Diversity
-- Each component normalized 0-100 using MIN-MAX scaling before weighting.
-- ============================================================
WITH
new_acct AS (
    SELECT r.restaurant_id,
           SUM(CASE WHEN r.rating = 5 AND u.account_age_days < 15 THEN 1 ELSE 0 END) AS new_acct_5star,
           COUNT(*) AS total_reviews
    FROM reviews r JOIN users u ON r.user_id = u.user_id
    GROUP BY r.restaurant_id
),
monthly AS (
    SELECT restaurant_id, DATE_FORMAT(review_date,'%Y-%m-01') AS month, AVG(rating) AS avg_rating
    FROM reviews GROUP BY restaurant_id, month
),
spike AS (
    SELECT restaurant_id, MAX(jump) AS max_jump FROM (
        SELECT restaurant_id, month, avg_rating,
               avg_rating - LAG(avg_rating) OVER (PARTITION BY restaurant_id ORDER BY month) AS jump
        FROM monthly
    ) t
    GROUP BY restaurant_id
),
velocity AS (
    SELECT restaurant_id, COUNT(*) AS total_reviews,
           COUNT(*) / GREATEST(DATEDIFF(MAX(review_date), MIN(review_date)),1) * 30 AS reviews_per_30d
    FROM reviews GROUP BY restaurant_id
),
diversity AS (
    SELECT restaurant_id,
           COUNT(DISTINCT user_id) / COUNT(*) AS diversity_ratio
    FROM reviews GROUP BY restaurant_id HAVING COUNT(*) >= 5
),
combined AS (
    SELECT
        n.restaurant_id,
        n.total_reviews,
        COALESCE(n.new_acct_5star / NULLIF(n.total_reviews,0), 0) AS new_acct_rate,
        COALESCE(s.max_jump, 0) AS rating_spike,
        COALESCE(v.reviews_per_30d, 0) AS velocity,
        COALESCE(1 - d.diversity_ratio, 0) AS low_diversity   -- invert: low diversity = high risk
    FROM new_acct n
    LEFT JOIN spike s ON n.restaurant_id = s.restaurant_id
    LEFT JOIN velocity v ON n.restaurant_id = v.restaurant_id
    LEFT JOIN diversity d ON n.restaurant_id = d.restaurant_id
    WHERE n.total_reviews >= 5   -- exclude near-empty restaurants (not enough signal)
),
scaled AS (
    SELECT *,
        100.0 * (new_acct_rate - MIN(new_acct_rate) OVER()) / NULLIF(MAX(new_acct_rate) OVER() - MIN(new_acct_rate) OVER(),0) AS new_acct_scaled,
        100.0 * (rating_spike - MIN(rating_spike) OVER()) / NULLIF(MAX(rating_spike) OVER() - MIN(rating_spike) OVER(),0) AS spike_scaled,
        100.0 * (velocity - MIN(velocity) OVER()) / NULLIF(MAX(velocity) OVER() - MIN(velocity) OVER(),0) AS velocity_scaled,
        100.0 * (low_diversity - MIN(low_diversity) OVER()) / NULLIF(MAX(low_diversity) OVER() - MIN(low_diversity) OVER(),0) AS diversity_scaled
    FROM combined
)
SELECT
    restaurant_id,
    total_reviews,
    ROUND(COALESCE(new_acct_scaled,0),1) AS new_acct_component,
    ROUND(COALESCE(spike_scaled,0),1) AS spike_component,
    ROUND(COALESCE(velocity_scaled,0),1) AS velocity_component,
    ROUND(COALESCE(diversity_scaled,0),1) AS diversity_component,
    ROUND(
        0.40 * COALESCE(new_acct_scaled,0) +
        0.30 * COALESCE(spike_scaled,0) +
        0.20 * COALESCE(velocity_scaled,0) +
        0.10 * COALESCE(diversity_scaled,0)
    , 1) AS fraud_risk_score
FROM scaled
ORDER BY fraud_risk_score DESC
LIMIT 25;
