from __future__ import annotations
import uuid
import networkx as nx
from app.services.snowflake_client import query_df, execute
from core.scoring import score_pair

AUTO_THRESHOLD = 0.90
REVIEW_THRESHOLD = 0.75
RULE_VERSION = 'RULE_V1'

def fetch_customers(where_clause='1=1'):
    return query_df(f'''
      SELECT c.source_record_uid, c.source_system, c.source_customer_id, c.first_name, c.last_name, c.email, c.phone, c.dob, c.loyalty_id,
             k.normalized_email, k.normalized_phone, k.normalized_full_name, k.blocking_phone_last4, k.blocking_name_dob
      FROM IDENTITY.SOURCE_CUSTOMER c
      JOIN IDENTITY.SOURCE_CUSTOMER_KEYS k ON c.source_record_uid=k.source_record_uid
      WHERE c.active_flag AND {where_clause}
    ''')

def candidate_pairs(df, same_source: bool):
    pairs = set()
    for col in ['NORMALIZED_EMAIL','NORMALIZED_PHONE','LOYALTY_ID','BLOCKING_NAME_DOB','BLOCKING_PHONE_LAST4']:
        if col not in df.columns:
            continue
        grp = df.dropna(subset=[col]).groupby(col)
        for _, g in grp:
            recs = g.to_dict('records')[:200]
            for i in range(len(recs)):
                for j in range(i+1, len(recs)):
                    a,b = recs[i], recs[j]
                    if same_source and a['SOURCE_SYSTEM'] != b['SOURCE_SYSTEM']:
                        continue
                    if not same_source and a['SOURCE_SYSTEM'] == b['SOURCE_SYSTEM']:
                        continue
                    pairs.add((a['SOURCE_RECORD_UID'], b['SOURCE_RECORD_UID']))
    by_id = {r['SOURCE_RECORD_UID']: r for r in df.to_dict('records')}
    return [(by_id[a], by_id[b]) for a,b in pairs]

def ensure_golden_for_cluster(records, match_run_id):
    # survivorship: prefer OPERA > B4T > APP > BRAZE, first non-null
    priority = {'OPERA':0,'B4T':1,'APP':2,'BRAZE':3}
    records = sorted(records, key=lambda r: priority.get(r['SOURCE_SYSTEM'],99))
    g_id = 'GOLDEN_' + uuid.uuid4().hex[:12].upper()
    master = {}
    for field in ['FIRST_NAME','LAST_NAME','EMAIL','PHONE','DOB','LOYALTY_ID']:
        master[field] = next((r.get(field) for r in records if r.get(field)), None)
    execute('''INSERT INTO GOLD.GOLDEN_CUSTOMER(golden_customer_id, rule_version_id, first_name,last_name,email,phone,dob,loyalty_id)
               VALUES (%s,%s,%s,%s,%s,%s,%s,%s)''', (g_id, RULE_VERSION, master['FIRST_NAME'], master['LAST_NAME'], master['EMAIL'], master['PHONE'], master['DOB'], master['LOYALTY_ID']))
    for r in records:
        execute('''MERGE INTO IDENTITY.IDENTITY_CROSSWALK t USING (SELECT %s source_system, %s source_customer_id) s
                   ON t.source_system=s.source_system AND t.source_customer_id=s.source_customer_id AND t.active_flag
                   WHEN NOT MATCHED THEN INSERT(source_system, source_customer_id, source_record_uid, golden_customer_id, link_type, confidence, rule_version_id)
                   VALUES(%s,%s,%s,%s,'AUTO',1.0,%s)''', (r['SOURCE_SYSTEM'], r['SOURCE_CUSTOMER_ID'], r['SOURCE_SYSTEM'], r['SOURCE_CUSTOMER_ID'], r['SOURCE_RECORD_UID'], g_id, RULE_VERSION))
    return g_id

def run_matching(rematch_all=False):
    match_run_id = 'RUN_' + uuid.uuid4().hex[:12].upper()
    df = fetch_customers()
    if df.empty:
        return {'match_run_id': match_run_id, 'message':'No customers found'}

    # same-source dedupe then cross-source; both contribute to graph clustering
    graph = nx.Graph()
    for r in df.to_dict('records'):
        graph.add_node(r['SOURCE_RECORD_UID'], record=r)

    review_count = 0
    auto_edges = 0
    for same_source in [True, False]:
        for left, right in candidate_pairs(df, same_source=same_source):
            score, reasons = score_pair(left, right, same_source=same_source)
            ctype = 'WITHIN_SOURCE_DEDUPE' if same_source else 'CROSS_SOURCE_MATCH'
            decision = 'AUTO_MATCH' if score >= AUTO_THRESHOLD else 'REVIEW' if score >= REVIEW_THRESHOLD else 'NO_MATCH'
            execute('''INSERT INTO IDENTITY.MATCH_CANDIDATE(match_run_id,left_source_system,left_source_customer_id,right_source_system,right_source_customer_id,candidate_type,score,reason,decision)
                       VALUES(%s,%s,%s,%s,%s,%s,%s,%s,%s)''', (match_run_id,left['SOURCE_SYSTEM'],left['SOURCE_CUSTOMER_ID'],right['SOURCE_SYSTEM'],right['SOURCE_CUSTOMER_ID'],ctype,score,'; '.join(reasons),decision))
            if decision == 'AUTO_MATCH':
                graph.add_edge(left['SOURCE_RECORD_UID'], right['SOURCE_RECORD_UID'])
                auto_edges += 1
            elif decision == 'REVIEW':
                execute('''INSERT INTO IDENTITY.STEWARDSHIP_QUEUE(match_run_id,left_source_system,left_source_customer_id,right_source_system,right_source_customer_id,score,reason)
                           VALUES(%s,%s,%s,%s,%s,%s,%s)''', (match_run_id,left['SOURCE_SYSTEM'],left['SOURCE_CUSTOMER_ID'],right['SOURCE_SYSTEM'],right['SOURCE_CUSTOMER_ID'],score,'; '.join(reasons)))
                review_count += 1

    golden_count = 0
    for comp in nx.connected_components(graph):
        records = [graph.nodes[n]['record'] for n in comp]
        # create one golden row even for singletons if not already crosswalked
        ensure_golden_for_cluster(records, match_run_id)
        golden_count += 1

    execute('CALL GOLD.REFRESH_GOLDEN_CUSTOMER_PROFILE()')
    return {'match_run_id': match_run_id, 'golden_clusters': golden_count, 'auto_edges': auto_edges, 'review_count': review_count}

if __name__ == '__main__':
    print(run_matching())
