# Review Fraud Detection & Rating Manipulation Analytics

Detecting suspicious restaurants and fake review patterns using SQL and Power BI, built on 72,000+ real Yelp reviews.

## Problem

Restaurants can artificially boost their ratings using fake reviews — bulk 5-star reviews from brand-new accounts, sudden unexplained rating spikes, or a small ring of accounts reviewing repeatedly. This project scores every restaurant on a **Fraud Risk Score (0–100)** using four behavioral/statistical signals, so suspicious restaurants can be flagged for manual review.

## Data

Real Yelp review data (Cleveland, OH), sourced from a public GitHub mirror of the Yelp Open Dataset. Cleaned and mapped into a 3-table schema:

| Table | Rows | Columns |
|---|---|---|
| `restaurants.csv` | 1,703 | `restaurant_id`, `restaurant_name`, `city`, `cuisine` |
| `users.csv` | 27,516 | `user_id`, `account_age_days`, `total_reviews` |
| `reviews.csv` | 72,981 | `review_id`, `restaurant_id`, `user_id`, `rating`, `review_date` |

> Only businesses tagged `Restaurants` or `Food` were kept from the raw Yelp business file. `account_age_days` was derived from each user's `yelping_since` date.

## Approach

Four signals feed into the Fraud Risk Score, each normalized to a 0–100 scale (min-max) before weighting:

| Signal | Weight | What it measures |
|---|---|---|
| New Account Reviews | 40% | 5-star reviews from accounts < 15 days old |
| Rating Spike | 30% | Largest month-over-month jump in average rating |
| Review Velocity | 20% | Reviews per 30 days |
| Reviewer Diversity | 10% | 1 − (unique reviewers / total reviews) — low diversity flags collusion rings |

All queries live in [`queries.sql`](queries.sql), including:
- **Q1** — Monthly rating trend + a spike detector using `LAG()` to catch month-over-month jumps > 1.0 star
- **Q2** — Frequent reviewers, plus a rolling 7-day burst detector (catches bot-like posting velocity a simple `COUNT > 30` would miss)
- **Q3** — Restaurants with unusually many 5-star reviews from accounts < 15 days old
- **Q4** — Reviewer diversity ratio per restaurant (collusion-ring detector)
- **Fraud Risk Score** — full CTE pipeline combining all four normalized signals into the final weighted score

Output: [`fraud_risk_scores.csv`](fraud_risk_scores%20%281%29.csv) — one row per restaurant with the component breakdown and final score.

## Dashboard

3-page interactive Power BI dashboard:
- **Overview** — total reviews, average rating, suspicious review count, rating trend, cuisine breakdown
- **Fraud Risk Score** — sorted risk table, top suspicious restaurants, score component breakdown
- **Reviewer Behavior** — review velocity vs. account age scatter plot, rating distribution, account-age patterns

## Honest limitations

- Scoring weights (40/30/20/10) are a business assumption, not statistically fit — new-account fraud is weighted highest because it's the cheapest/most common way to fake reviews.
- Reviewer-diversity signal turned out to be uninformative on this real dataset (ratio ≈ 1.0 almost everywhere — Yelp users rarely review the same restaurant twice), a genuine finding worth noting rather than hiding.
- No ground-truth fraud labels exist for real data, so precision/recall of the score itself isn't validated — it's a heuristic risk ranking, not a trained classifier.
- Data is limited to one city (Cleveland); patterns may differ elsewhere.

## Tech stack

MySQL 8.0 · Python (data cleaning) · Power BI Desktop

## How to reproduce

1. Load `restaurants.csv`, `users.csv`, `reviews.csv` into MySQL.
2. Run `sql/queries.sql` to reproduce Q1–Q4 and the Fraud Risk Score.
3. Load all 4 CSVs (including `fraud_risk_scores.csv`) into Power BI, relate on `restaurant_id` / `user_id`, and build the 3 dashboard pages.
