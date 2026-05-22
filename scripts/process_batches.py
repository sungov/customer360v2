from __future__ import annotations
from app.services.snowflake_client import query_df, execute
from scripts.matching_engine_local import run_matching

def process_all_pending():
    batches = query_df("SELECT batch_id, entity_type FROM PROCESSING.BATCH_CONTROL WHERE status IN ('LOADED','NEW') ORDER BY created_at")
    results = []
    for _, b in batches.iterrows():
        batch_id = b['BATCH_ID']
        entity = b['ENTITY_TYPE']
        execute("UPDATE PROCESSING.BATCH_CONTROL SET status='PROCESSING', started_at=CURRENT_TIMESTAMP() WHERE batch_id=%s", (batch_id,))
        try:
            if entity == 'CUSTOMER':
                execute('CALL PROCESSING.LOAD_RAW_CUSTOMERS_TO_IDENTITY(%s)', (batch_id,))
                execute('CALL IDENTITY.BUILD_SOURCE_CUSTOMER_KEYS(%s)', (batch_id,))
            else:
                execute('CALL PROCESSING.LOAD_RAW_FACTS_TO_GOLD(%s)', (batch_id,))
            execute("UPDATE PROCESSING.BATCH_CONTROL SET status='COMPLETE', completed_at=CURRENT_TIMESTAMP() WHERE batch_id=%s", (batch_id,))
            results.append((batch_id, 'COMPLETE'))
        except Exception as e:
            execute("UPDATE PROCESSING.BATCH_CONTROL SET status='ERROR', error_message=%s, completed_at=CURRENT_TIMESTAMP() WHERE batch_id=%s", (str(e), batch_id))
            results.append((batch_id, 'ERROR', str(e)))
    match_result = run_matching()
    return {'batches': results, 'matching': match_result}

if __name__ == '__main__':
    print(process_all_pending())
