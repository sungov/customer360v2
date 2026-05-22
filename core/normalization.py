from __future__ import annotations
import re
from typing import Any

def null_if_blank(v: Any) -> str | None:
    if v is None:
        return None
    s = str(v).strip()
    if not s or s.lower() in {'nan','none','null'}:
        return None
    return s

def normalize_email(email: Any) -> str | None:
    s = null_if_blank(email)
    if not s:
        return None
    return s.lower().strip()

def normalize_phone(phone: Any) -> str | None:
    s = null_if_blank(phone)
    if not s:
        return None
    digits = re.sub(r'\D+', '', s)
    if not digits:
        return None
    if len(digits) == 10:
        return '+1' + digits
    if len(digits) == 11 and digits.startswith('1'):
        return '+' + digits
    if s.startswith('+'):
        return '+' + digits
    return '+' + digits

def normalize_name(name: Any) -> str | None:
    s = null_if_blank(name)
    if not s:
        return None
    s = re.sub(r'[^a-zA-Z\s]', '', s).lower()
    return re.sub(r'\s+', ' ', s).strip() or None

def source_key(source_system: str, source_customer_id: str) -> str:
    return f"{str(source_system).upper()}:{str(source_customer_id).strip()}"
