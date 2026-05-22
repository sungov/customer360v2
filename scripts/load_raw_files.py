from __future__ import annotations
import argparse
import uuid
from pathlib import Path
import pandas as pd
from app.services.snowflake_client import get_connection, execute

CUSTOMER_FILE_MAP = {
    'opera_customers.csv': ('RAW.OPERA_CUSTOMERS', 'OPERA', 'CUSTOMER'),
    'b4t_customers.csv': ('RAW.B4T_CUSTOMERS', 'B4T', 'CUSTOMER'),
    'braze_profiles.csv': ('RAW.BRAZE_PROFILES', 'BRAZE', 'CUSTOMER'),
    'braze_customers.csv': ('RAW.BRAZE_PROFILES', 'BRAZE', 'CUSTOMER'),
    'app_users.csv': ('RAW.APP_USERS', 'APP', 'CUSTOMER'),
    'app_customers.csv': ('RAW.APP_USERS', 'APP', 'CUSTOMER'),
}
FACT_FILE_MAP = {
    'fact_stays.csv': ('RAW.OPERA_STAYS', 'OPERA', 'STAY'),
    'fact_spa_services.csv': ('RAW.B4T_SPA_SERVICES', 'B4T', 'SPA_SERVICE'),
    'fact_transactions.csv': ('RAW.TRANSACTIONS', 'MIXED', 'TRANSACTION'),
    'fact_engagement_events.csv': ('RAW.BRAZE_ENGAGEMENT_EVENTS', 'BRAZE', 'ENGAGEMENT'),
    'fact_recommendations.csv': ('RAW.RECOMMENDATIONS', 'MIXED', 'RECOMMENDATION'),
}
ALL_FILE_MAP = {**CUSTOMER_FILE_MAP, **FACT_FILE_MAP}

def load_csv(file_path: Path, load_type='FULL') -> str:
    name = file_path.name
    if name not in ALL_FILE_MAP:
        raise ValueError(f'Unknown file type: {name}. Known files: {sorted(ALL_FILE_MAP)}')
    table, source_system, entity_type = ALL_FILE_MAP[name]
    batch_id = 'BATCH_' + uuid.uuid4().hex[:12].upper()
    df = pd.read_csv(file_path)
    df['BATCH_ID'] = batch_id
    df['SOURCE_FILE_NAME'] = name
    df['PROCESS_STATUS'] = 'NEW'
    with get_connection() as conn:
        ok, nchunks, nrows, _ = conn.cursor().execute('SELECT 1').fetchone() if False else (True,0,0,None)
        from snowflake.connector.pandas_tools import write_pandas
        success, nchunks, nrows, output = write_pandas(conn, df, table.split('.')[1], schema=table.split('.')[0], quote_identifiers=False)
        if not success:
            raise RuntimeError(output)
    execute('''INSERT INTO PROCESSING.BATCH_CONTROL(batch_id, source_system, entity_type, file_name, load_type, status, record_count)
               VALUES(%s,%s,%s,%s,%s,'LOADED',%s)''', (batch_id, source_system, 'CUSTOMER' if entity_type=='CUSTOMER' else 'FACT', name, load_type, len(df)))
    return batch_id

def load_folder(folder: Path, load_type='FULL'):
    out = []
    for f in folder.glob('*.csv'):
        if f.name in ALL_FILE_MAP:
            out.append((f.name, load_csv(f, load_type)))
    return out

if __name__ == '__main__':
    p = argparse.ArgumentParser()
    p.add_argument('--folder', default='data/generated')
    p.add_argument('--file')
    p.add_argument('--load-type', default='FULL', choices=['FULL','INCREMENTAL'])
    args = p.parse_args()
    if args.file:
        print(load_csv(Path(args.file), args.load_type))
    else:
        print(load_folder(Path(args.folder), args.load_type))
