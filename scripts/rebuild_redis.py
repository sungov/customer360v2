from __future__ import annotations
from cache.redis_index import RedisIdentityIndex
from app.services.snowflake_client import query_df
from core.normalization import normalize_email, normalize_phone, null_if_blank, source_key

def rebuild():
    r = RedisIdentityIndex()
    df = query_df('''
      SELECT x.golden_customer_id, x.source_system, x.source_customer_id, g.email, g.phone, g.loyalty_id
      FROM IDENTITY.IDENTITY_CROSSWALK x
      JOIN GOLD.GOLDEN_CUSTOMER g ON x.golden_customer_id=g.golden_customer_id
      WHERE x.active_flag
    ''')
    count = 0
    for _, row in df.iterrows():
        gid = row['GOLDEN_CUSTOMER_ID']
        r.set_mapping('source', source_key(row['SOURCE_SYSTEM'], row['SOURCE_CUSTOMER_ID']), gid, 1.0); count += 1
        em = normalize_email(row.get('EMAIL'))
        ph = normalize_phone(row.get('PHONE'))
        loy = null_if_blank(row.get('LOYALTY_ID'))
        if em: r.set_mapping('email', em, gid, 1.0); count += 1
        if ph: r.set_mapping('phone', ph, gid, 1.0); count += 1
        if loy: r.set_mapping('loyalty', loy, gid, 1.0); count += 1
    return {'keys_written': count}

if __name__ == '__main__':
    print(rebuild())
