# Customer360 Identity Platform v2

This is a clean POC rebuild with production-style boundaries:

- Source-specific RAW tables
- Batch/micro-batch control
- Process only NEW rows
- Within-source dedupe first
- Cross-source matching second
- One active golden customer row per real customer
- Normalized identity crosswalk for all contributing source PKs
- Source-native gold fact tables
- Golden 360 profile resolves facts through crosswalk
- Redis exact lookup index
- Streamlit upload/stewardship/config/search UI
- FastAPI lookup API

## Setup

```bat
py -3.12 -m venv .venv
.venv\Scripts\activate
python -m pip install --upgrade pip
python -m pip install -r requirements.txt
copy .env.example .env
```

Fill `.env` with Snowflake and Redis Cloud values. For your Redis Cloud free tier, use password-only auth and `REDIS_SSL=false` if your test script required it.

## Create Snowflake objects

```bat
python scripts\setup_snowflake.py
```

This runs:

```text
snowflake/schema/*.sql
snowflake/procedures/*.sql
```

## Generate sample data

```bat
python scripts\generate_customer360_seed_data.py --records 100000
```

Outputs go to `data/generated/`:

```text
opera_customers.csv
b4t_customers.csv
braze_profiles.csv
app_users.csv
fact_stays.csv
fact_spa_services.csv
fact_transactions.csv
fact_engagement_events.csv
fact_recommendations.csv
expected_crosswalk.csv
```

## Load raw files

```bat
python scripts\load_raw_files.py --folder data\generated --load-type FULL
```

This loads each CSV into the right source-specific RAW table and inserts a row into `PROCESSING.BATCH_CONTROL`.

## Process micro-batches

```bat
python scripts\process_batches.py
```

This does:

1. Load NEW raw customer rows into `IDENTITY.SOURCE_CUSTOMER`
2. Build normalized keys
3. Load NEW fact rows into separate `GOLD.FACT_*` tables
4. Run matching
5. Create/update `GOLD.GOLDEN_CUSTOMER`
6. Create/update `IDENTITY.IDENTITY_CROSSWALK`
7. Refresh `GOLD.GOLDEN_CUSTOMER_PROFILE`

## Rebuild Redis

```bat
python scripts\rebuild_redis.py
```

Redis stores exact lookup keys:

```text
c360:source:OPERA:OPERA_123 -> GOLDEN_...
c360:email:user@example.com -> GOLDEN_...
c360:phone:+15551234567 -> GOLDEN_...
c360:loyalty:CR123 -> GOLDEN_...
```

## Start Streamlit UI

```bat
python -m streamlit run app\streamlit_app.py
```

## Start API

```bat
python -m uvicorn api.identity_api:app --reload
```

## Architecture decision notes

Facts do **not** store `golden_customer_id` initially. Gold facts remain source-native:

```text
source_system + source_customer_id
```

The Golden 360 profile joins facts through:

```text
IDENTITY.IDENTITY_CROSSWALK
```

This avoids rewriting millions of fact rows after a rematch/rule change. `GOLD.GOLDEN_CUSTOMER_PROFILE` contains aggregated arrays like `linked_source_keys` for UI convenience, but the crosswalk is the source of truth.

## Current POC limitations

- Matching script is local Python using Snowflake connector, not yet deployed as a Snowpark stored procedure.
- Rule config tables exist, but the local matcher uses default constants. Next iteration should read thresholds/weights from `CONFIG.*`.
- Stewardship approval currently marks queue items resolved; full merge/reject procedures should be added next.
- Cortex edge-case matching is not included yet; it should be added only for near-threshold candidates to control cost.
