from __future__ import annotations
from fastapi import FastAPI
from pydantic import BaseModel
from cache.redis_index import RedisIdentityIndex
from app.services.snowflake_client import query_df

app = FastAPI(title='Customer360 Identity API v2')
redis_index = RedisIdentityIndex()

class LookupRequest(BaseModel):
    email: str | None = None
    phone: str | None = None
    loyalty_id: str | None = None
    source_system: str | None = None
    source_customer_id: str | None = None

@app.get('/health')
def health():
    return {'status': 'ok', 'redis': redis_index.ping()}

@app.post('/lookup')
def lookup(req: LookupRequest):
    res = redis_index.lookup(**req.model_dump())
    return res.__dict__

@app.get('/profile/{golden_customer_id}')
def profile(golden_customer_id: str):
    df = query_df('SELECT * FROM GOLD.GOLDEN_CUSTOMER_PROFILE WHERE golden_customer_id=%s', (golden_customer_id,))
    if df.empty:
        return {'status':'NOT_FOUND'}
    return {'status':'FOUND', 'profile': df.iloc[0].to_dict()}
