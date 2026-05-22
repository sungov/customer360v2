from __future__ import annotations
import json
from dataclasses import dataclass
from typing import Optional
import redis
from app.services.settings import settings
from core.normalization import normalize_email, normalize_phone, null_if_blank, source_key

@dataclass
class LookupResult:
    status: str
    golden_customer_id: Optional[str] = None
    match_key: Optional[str] = None
    confidence: Optional[float] = None
    source: str = 'redis'
    message: Optional[str] = None

class RedisIdentityIndex:
    def __init__(self):
        self.prefix = settings.redis_key_prefix
        self.client = redis.Redis(
            host=settings.redis_host,
            port=settings.redis_port,
            db=settings.redis_db,
            password=settings.redis_password,
            ssl=settings.redis_ssl,
            decode_responses=True,
            socket_connect_timeout=settings.redis_connect_timeout,
            socket_timeout=settings.redis_socket_timeout,
        )

    def key(self, key_type: str, key_value: str) -> str:
        return f"{self.prefix}:{key_type}:{key_value}"

    def ping(self) -> bool:
        return bool(self.client.ping())

    def set_mapping(self, key_type: str, key_value: str, golden_customer_id: str, confidence: float = 1.0):
        if not key_value or not golden_customer_id:
            return
        self.client.set(self.key(key_type, key_value), json.dumps({
            'golden_customer_id': golden_customer_id,
            'confidence': confidence,
        }))

    def get_mapping(self, key_type: str, key_value: str) -> LookupResult:
        if not key_value:
            return LookupResult(status='NOT_FOUND')
        k = self.key(key_type, key_value)
        raw = self.client.get(k)
        if not raw:
            return LookupResult(status='NOT_FOUND', match_key=k)
        try:
            payload = json.loads(raw)
        except Exception:
            payload = {'golden_customer_id': raw, 'confidence': 1.0}
        return LookupResult(status='FOUND', golden_customer_id=payload.get('golden_customer_id'), match_key=k, confidence=float(payload.get('confidence', 1.0)))

    def lookup(self, email=None, phone=None, loyalty_id=None, source_system=None, source_customer_id=None) -> LookupResult:
        candidates = []
        if source_system and source_customer_id:
            candidates.append(('source', source_key(source_system, source_customer_id)))
        loyalty = null_if_blank(loyalty_id)
        if loyalty:
            candidates.append(('loyalty', loyalty))
        em = normalize_email(email)
        if em:
            candidates.append(('email', em))
        ph = normalize_phone(phone)
        if ph:
            candidates.append(('phone', ph))
        for t, v in candidates:
            res = self.get_mapping(t, v)
            if res.status == 'FOUND':
                return res
        return LookupResult(status='NOT_FOUND', message='No exact key found in Redis')
