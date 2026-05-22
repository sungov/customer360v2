from __future__ import annotations
import pandas as pd
import snowflake.connector
from app.services.settings import settings

def get_connection():
    return snowflake.connector.connect(
        account=settings.snowflake_account,
        user=settings.snowflake_user,
        password=settings.snowflake_password,
        role=settings.snowflake_role,
        warehouse=settings.snowflake_warehouse,
        database=settings.snowflake_database,
        schema=settings.snowflake_schema,
    )

def execute(sql: str, params=None):
    with get_connection() as conn:
        with conn.cursor() as cur:
            cur.execute(sql, params or {})
            try:
                return cur.fetchall()
            except Exception:
                return None

def query_df(sql: str, params=None) -> pd.DataFrame:
    with get_connection() as conn:
        return pd.read_sql(sql, conn, params=params)

def call_proc(proc_name: str, *args):
    placeholders = ','.join(['%s'] * len(args))
    return execute(f"CALL {proc_name}({placeholders})", args)
