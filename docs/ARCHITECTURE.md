# v2 Architecture

## Ingestion model

Streamlit uploads mimic real source-system feeds. Every file lands in a source-specific RAW table. A batch row is created in `PROCESSING.BATCH_CONTROL`.

## Micro-batch model

Processors pick `status IN ('LOADED','NEW')` batches and raw rows with `process_status='NEW'`. Successfully processed rows are marked `COMPLETE`; failures become `ERROR`.

## Identity model

1. RAW source customers
2. IDENTITY.SOURCE_CUSTOMER
3. IDENTITY.SOURCE_CUSTOMER_KEYS
4. Within-source dedupe candidates
5. Cross-source match candidates
6. GOLD.GOLDEN_CUSTOMER
7. IDENTITY.IDENTITY_CROSSWALK

Golden customer has one active row per real person. Crosswalk has many source records per golden customer.

## Fact model

Facts land in separate RAW tables and are moved to separate GOLD fact tables. Facts keep source identifiers and join to golden customers through the crosswalk.

## Rerun/rematch

When rules change, rerun matching over all active source customers. Because facts stay source-native, only crosswalk/profile need to change, not all fact rows.
