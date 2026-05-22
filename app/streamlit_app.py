from __future__ import annotations
import uuid
from pathlib import Path
import pandas as pd
import streamlit as st
from app.services.snowflake_client import query_df, execute
from cache.redis_index import RedisIdentityIndex

st.set_page_config(page_title='Customer360 Identity v2', layout='wide')
st.markdown('''
<style>
.stApp { background:#f7f9fc; color:#111827; }
[data-testid="stSidebar"] { background:#111827; }
[data-testid="stSidebar"] * { color:#f9fafb !important; }
.block-container { padding-top:1.5rem; }
.card { background:white; padding:1rem; border-radius:16px; box-shadow:0 2px 8px rgba(0,0,0,.06); border:1px solid #e5e7eb; }
</style>
''', unsafe_allow_html=True)

st.sidebar.title('Customer360 v2')
page = st.sidebar.radio('Navigate', ['Dashboard','Upload / Microbatch','Lookup','Golden 360','Stewardship','Rules & Rerun','Admin'])

def safe_df(sql, params=None):
    try:
        return query_df(sql, params)
    except Exception as e:
        st.error(str(e)); return pd.DataFrame()

def metric_row():
    c1,c2,c3,c4 = st.columns(4)
    metrics = [
        ('Golden customers', "SELECT COUNT(*) C FROM GOLD.GOLDEN_CUSTOMER"),
        ('Source records', "SELECT COUNT(*) C FROM IDENTITY.SOURCE_CUSTOMER"),
        ('Open stewardship', "SELECT COUNT(*) C FROM IDENTITY.STEWARDSHIP_QUEUE WHERE status='OPEN'"),
        ('Batches', "SELECT COUNT(*) C FROM PROCESSING.BATCH_CONTROL"),
    ]
    for col,(label,sql) in zip([c1,c2,c3,c4],metrics):
        df=safe_df(sql); val=int(df.iloc[0,0]) if not df.empty else 0
        col.metric(label, f'{val:,}')

if page == 'Dashboard':
    st.title('Customer360 Identity Platform v2')
    st.caption('Source-specific raw tables → batch queue → source dedupe → cross-source match → gold facts/profile → Redis lookup')
    metric_row()
    st.subheader('Recent Batches')
    st.dataframe(safe_df('SELECT * FROM PROCESSING.BATCH_CONTROL ORDER BY created_at DESC LIMIT 20'), use_container_width=True)
    st.subheader('Match Candidates')
    st.dataframe(safe_df('SELECT * FROM IDENTITY.MATCH_CANDIDATE ORDER BY created_at DESC LIMIT 20'), use_container_width=True)

elif page == 'Upload / Microbatch':
    st.title('Upload Files to RAW Layer')
    st.info('This UI mimics source-system ingestion. Files land in source-specific RAW tables and create a batch record. Processing picks NEW batches only.')
    file_type = st.selectbox('File type', ['OPERA Customer','B4T Customer','Braze Profile','App User','OPERA Stay','B4T Spa Service','Transaction','Braze Engagement','Recommendation'])
    load_type = st.radio('Load type', ['FULL','INCREMENTAL'], horizontal=True)
    file = st.file_uploader('Upload CSV', type=['csv'])
    table_map = {
        'OPERA Customer':'RAW.OPERA_CUSTOMERS','B4T Customer':'RAW.B4T_CUSTOMERS','Braze Profile':'RAW.BRAZE_PROFILES','App User':'RAW.APP_USERS',
        'OPERA Stay':'RAW.OPERA_STAYS','B4T Spa Service':'RAW.B4T_SPA_SERVICES','Transaction':'RAW.TRANSACTIONS','Braze Engagement':'RAW.BRAZE_ENGAGEMENT_EVENTS','Recommendation':'RAW.RECOMMENDATIONS'
    }
    entity_map = {k:('CUSTOMER' if 'Customer' in k or 'Profile' in k or 'User' in k else 'FACT') for k in table_map}
    source_map = {'OPERA Customer':'OPERA','B4T Customer':'B4T','Braze Profile':'BRAZE','App User':'APP','OPERA Stay':'OPERA','B4T Spa Service':'B4T','Transaction':'MIXED','Braze Engagement':'BRAZE','Recommendation':'MIXED'}
    if file and st.button('Load to RAW table'):
        df = pd.read_csv(file)
        batch_id='BATCH_'+uuid.uuid4().hex[:12].upper()
        df['BATCH_ID']=batch_id; df['SOURCE_FILE_NAME']=file.name; df['PROCESS_STATUS']='NEW'
        table = table_map[file_type]
        try:
            from app.services.snowflake_client import get_connection
            from snowflake.connector.pandas_tools import write_pandas
            with get_connection() as conn:
                ok,_,rows,out = write_pandas(conn, df, table.split('.')[1], schema=table.split('.')[0], quote_identifiers=False)
            execute('''INSERT INTO PROCESSING.BATCH_CONTROL(batch_id, source_system, entity_type, file_name, load_type, status, record_count)
                       VALUES(%s,%s,%s,%s,%s,'LOADED',%s)''', (batch_id, source_map[file_type], entity_map[file_type], file.name, load_type, len(df)))
            st.success(f'Loaded {rows} rows to {table}. Batch: {batch_id}')
        except Exception as e:
            st.error(e)
    c1,c2,c3 = st.columns(3)
    if c1.button('Process all pending batches'):
        try:
            from scripts.process_batches import process_all_pending
            st.json(process_all_pending())
        except Exception as e: st.error(e)
    if c2.button('Run matching/rematch all'):
        try:
            from scripts.matching_engine_local import run_matching
            st.json(run_matching(rematch_all=True))
        except Exception as e: st.error(e)
    if c3.button('Refresh golden profile'):
        try: st.write(execute('CALL GOLD.REFRESH_GOLDEN_CUSTOMER_PROFILE()'))
        except Exception as e: st.error(e)
    st.subheader('Batch monitor')
    st.dataframe(safe_df('SELECT * FROM PROCESSING.BATCH_CONTROL ORDER BY created_at DESC LIMIT 50'), use_container_width=True)

elif page == 'Lookup':
    st.title('Fast Customer Lookup')
    c1,c2,c3 = st.columns(3)
    email=c1.text_input('Email'); phone=c2.text_input('Phone'); loyalty=c3.text_input('Loyalty ID')
    s1,s2 = st.columns(2)
    source=s1.text_input('Source system'); source_id=s2.text_input('Source customer ID')
    if st.button('Lookup in Redis'):
        try:
            r=RedisIdentityIndex(); st.json(r.lookup(email=email, phone=phone, loyalty_id=loyalty, source_system=source, source_customer_id=source_id).__dict__)
        except Exception as e: st.error(e)

elif page == 'Golden 360':
    st.title('Golden Customer 360')
    gid=st.text_input('Golden customer ID')
    if gid:
        prof=safe_df('SELECT * FROM GOLD.GOLDEN_CUSTOMER_PROFILE WHERE golden_customer_id=%s', (gid,))
        st.dataframe(prof, use_container_width=True)
        st.subheader('Contributing source records')
        st.dataframe(safe_df('SELECT * FROM IDENTITY.IDENTITY_CROSSWALK WHERE golden_customer_id=%s AND active_flag', (gid,)), use_container_width=True)
        for title,sql in [('Stays',"SELECT s.* FROM GOLD.FACT_STAY s JOIN IDENTITY.IDENTITY_CROSSWALK x ON s.source_system=x.source_system AND s.source_customer_id=x.source_customer_id WHERE x.golden_customer_id=%s"),('Spa Services',"SELECT s.* FROM GOLD.FACT_SPA_SERVICE s JOIN IDENTITY.IDENTITY_CROSSWALK x ON s.source_system=x.source_system AND s.source_customer_id=x.source_customer_id WHERE x.golden_customer_id=%s"),('Transactions',"SELECT t.* FROM GOLD.FACT_TRANSACTION t JOIN IDENTITY.IDENTITY_CROSSWALK x ON t.source_system=x.source_system AND t.source_customer_id=x.source_customer_id WHERE x.golden_customer_id=%s"),('Engagement',"SELECT e.* FROM GOLD.FACT_ENGAGEMENT_EVENT e JOIN IDENTITY.IDENTITY_CROSSWALK x ON e.source_system=x.source_system AND e.source_customer_id=x.source_customer_id WHERE x.golden_customer_id=%s")]:
            st.subheader(title); st.dataframe(safe_df(sql,(gid,)), use_container_width=True)
    else:
        st.dataframe(safe_df('SELECT * FROM GOLD.GOLDEN_CUSTOMER_PROFILE ORDER BY refreshed_at DESC LIMIT 50'), use_container_width=True)

elif page == 'Stewardship':
    st.title('Stewardship Queue')
    q=safe_df("SELECT * FROM IDENTITY.STEWARDSHIP_QUEUE WHERE status='OPEN' ORDER BY created_at DESC LIMIT 100")
    st.dataframe(q, use_container_width=True)
    queue_id=st.text_input('Queue ID to resolve')
    action=st.selectbox('Resolution', ['APPROVE','REJECT'])
    if st.button('Resolve') and queue_id:
        execute("UPDATE IDENTITY.STEWARDSHIP_QUEUE SET status='RESOLVED', resolution=%s, resolved_at=CURRENT_TIMESTAMP(), resolved_by=CURRENT_USER() WHERE queue_id=%s", (action, queue_id))
        st.success('Resolved')

elif page == 'Rules & Rerun':
    st.title('Rules, Thresholds, and Rerun')
    st.caption('POC rules are table-driven; the local matching script currently uses default thresholds. Next step is to read these live from CONFIG tables.')
    st.subheader('Rule Sets')
    st.dataframe(safe_df('SELECT * FROM CONFIG.RULE_SET ORDER BY created_at DESC'), use_container_width=True)
    st.subheader('Rule Conditions')
    st.dataframe(safe_df('SELECT * FROM CONFIG.RULE_CONDITION ORDER BY rule_version_id, condition_order'), use_container_width=True)
    if st.button('Rerun full matching for all active source customers'):
        try:
            from scripts.matching_engine_local import run_matching
            st.json(run_matching(rematch_all=True))
        except Exception as e: st.error(e)

elif page == 'Admin':
    st.title('Admin')
    if st.button('Ping Redis'):
        try: st.success(f'Redis connected: {RedisIdentityIndex().ping()}')
        except Exception as e: st.error(e)
    if st.button('Rebuild Redis from Snowflake'):
        try:
            from scripts.rebuild_redis import rebuild
            st.json(rebuild())
        except Exception as e: st.error(e)
    st.subheader('Raw row status counts')
    st.dataframe(safe_df("""
      SELECT 'OPERA_CUSTOMERS' table_name, process_status, count(*) rows FROM RAW.OPERA_CUSTOMERS GROUP BY 1,2
      UNION ALL SELECT 'B4T_CUSTOMERS', process_status, count(*) FROM RAW.B4T_CUSTOMERS GROUP BY 1,2
      UNION ALL SELECT 'BRAZE_PROFILES', process_status, count(*) FROM RAW.BRAZE_PROFILES GROUP BY 1,2
      UNION ALL SELECT 'APP_USERS', process_status, count(*) FROM RAW.APP_USERS GROUP BY 1,2
    """), use_container_width=True)
