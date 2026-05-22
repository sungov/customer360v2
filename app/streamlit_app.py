from __future__ import annotations

import json
import uuid
from datetime import datetime

import pandas as pd
import streamlit as st

from app.services.snowflake_client import query_df, execute, call_proc
from cache.redis_index import RedisIdentityIndex

st.set_page_config(page_title="Customer360 Identity v2", layout="wide")

st.markdown(
    """
<style>
.stApp { background:#f7f9fc; color:#111827; }
[data-testid="stSidebar"] { background:#111827; }
[data-testid="stSidebar"] * { color:#f9fafb !important; }
.block-container { padding-top:1.5rem; max-width:1400px; }
.card { background:white; padding:1rem; border-radius:16px; box-shadow:0 2px 8px rgba(0,0,0,.06); border:1px solid #e5e7eb; }
.small-muted { color:#6b7280; font-size:0.85rem; }
.good { color:#047857; font-weight:700; }
.warn { color:#b45309; font-weight:700; }
.bad { color:#b91c1c; font-weight:700; }
.code-chip { font-family:monospace; background:#eef2ff; border:1px solid #c7d2fe; padding:3px 7px; border-radius:8px; }
</style>
""",
    unsafe_allow_html=True,
)


def safe_df(sql: str, params=None) -> pd.DataFrame:
    try:
        return query_df(sql, params)
    except Exception as e:
        st.error(str(e))
        return pd.DataFrame()


def safe_exec(sql: str, params=None):
    try:
        return execute(sql, params)
    except Exception as e:
        st.error(str(e))
        return None


def fmt(v):
    if v is None:
        return "—"
    if isinstance(v, float) and pd.isna(v):
        return "—"
    return str(v)


def get_scalar(sql: str, default=0):
    df = safe_df(sql)
    if df.empty:
        return default
    return df.iloc[0, 0]


def status_filter():
    return "status IN ('OPEN','PENDING')"


def render_kpis():
    metrics = safe_df("SELECT * FROM GOLD.V_DASHBOARD_METRICS")
    if metrics.empty:
        c1, c2, c3, c4 = st.columns(4)
        for c, label in zip(c1, ["Golden customers"]):
            pass
        return
    row = metrics.iloc[0]
    c1, c2, c3, c4 = st.columns(4)
    c1.metric("Source records", f"{int(row.get('SOURCE_RECORDS', 0)):,}")
    c2.metric("Golden customers", f"{int(row.get('GOLDEN_CUSTOMERS', 0)):,}")
    c3.metric("Active links", f"{int(row.get('ACTIVE_LINKS', 0)):,}")
    c4.metric("Open stewardship", f"{int(row.get('OPEN_STEWARDSHIP', 0)):,}")


def load_source_record(source_system: str, source_customer_id: str) -> pd.DataFrame:
    return safe_df(
        """
        SELECT source_system, source_customer_id, first_name, last_name, email, phone, dob,
               address_line1, city, state, postal_code, country, loyalty_id, updated_at
        FROM IDENTITY.SOURCE_CUSTOMER
        WHERE source_system = %s AND source_customer_id = %s
        LIMIT 1
        """,
        (source_system, source_customer_id),
    )


def render_record_card(title: str, source_system: str, source_customer_id: str):
    df = load_source_record(source_system, source_customer_id)
    if df.empty:
        st.warning(f"No source record found for {source_system}:{source_customer_id}")
        return
    r = df.iloc[0]
    st.markdown(f"**{title}**  ")
    st.markdown(
        f"<span class='code-chip'>{fmt(r['SOURCE_SYSTEM'])}:{fmt(r['SOURCE_CUSTOMER_ID'])}</span>",
        unsafe_allow_html=True,
    )
    st.write(f"**Name:** {fmt(r.get('FIRST_NAME'))} {fmt(r.get('LAST_NAME'))}")
    st.write(f"**Email:** {fmt(r.get('EMAIL'))}")
    st.write(f"**Phone:** {fmt(r.get('PHONE'))}")
    st.write(f"**DOB:** {fmt(r.get('DOB'))}")
    st.write(f"**Address:** {fmt(r.get('ADDRESS_LINE1'))}, {fmt(r.get('CITY'))}, {fmt(r.get('STATE'))} {fmt(r.get('POSTAL_CODE'))}")
    st.write(f"**Loyalty:** {fmt(r.get('LOYALTY_ID'))}")


st.sidebar.title("Customer360 v2")
page = st.sidebar.radio(
    "Navigate",
    [
        "Dashboard",
        "Upload / Microbatch",
        "Lookup",
        "Golden 360",
        "Stewardship",
        "Rules & Rerun",
        "Admin",
    ],
)

if page == "Dashboard":
    st.title("Customer360 Identity Dashboard")
    st.caption("Operational view of batches, matching, stewardship and golden customer quality.")

    render_kpis()
    st.divider()

    c1, c2 = st.columns(2)
    with c1:
        st.subheader("Batch status")
        st.dataframe(
            safe_df(
                """
                SELECT status, COUNT(*) AS batch_count
                FROM PROCESSING.BATCH_CONTROL
                GROUP BY status
                ORDER BY batch_count DESC
                """
            ),
            use_container_width=True,
        )

        st.subheader("Cluster size distribution")
        st.dataframe(
            safe_df("SELECT * FROM GOLD.V_CLUSTER_SIZE_DISTRIBUTION ORDER BY linked_count"),
            use_container_width=True,
        )

    with c2:
        st.subheader("Match confidence")
        st.dataframe(
            safe_df("SELECT * FROM IDENTITY.V_MATCH_CONFIDENCE ORDER BY match_type, score_bucket DESC"),
            use_container_width=True,
        )

        st.subheader("Source overlap")
        st.dataframe(
            safe_df(
                """
                SELECT source_system_count, COUNT(*) AS golden_customer_count
                FROM GOLD.V_SOURCE_OVERLAP
                GROUP BY source_system_count
                ORDER BY source_system_count
                """
            ),
            use_container_width=True,
        )

    st.divider()
    st.subheader("Recent identity events")
    st.dataframe(
        safe_df("SELECT * FROM IDENTITY.V_DECISION_HISTORY ORDER BY created_at DESC LIMIT 50"),
        use_container_width=True,
    )

elif page == "Upload / Microbatch":
    st.title("Upload Files to RAW Layer")
    st.info("This UI mimics source-system ingestion. Files land in source-specific RAW tables and create a batch record. Processing picks NEW/LOADED batches only.")

    file_type = st.selectbox(
        "File type",
        [
            "OPERA Customer",
            "B4T Customer",
            "Braze Profile",
            "App User",
            "OPERA Stay",
            "B4T Spa Service",
            "Transaction",
            "Braze Engagement",
            "Recommendation",
        ],
    )
    load_type = st.radio("Load type", ["FULL", "INCREMENTAL"], horizontal=True)
    file = st.file_uploader("Upload CSV", type=["csv"])

    table_map = {
        "OPERA Customer": "RAW.OPERA_CUSTOMERS",
        "B4T Customer": "RAW.B4T_CUSTOMERS",
        "Braze Profile": "RAW.BRAZE_PROFILES",
        "App User": "RAW.APP_USERS",
        "OPERA Stay": "RAW.OPERA_STAYS",
        "B4T Spa Service": "RAW.B4T_SPA_SERVICES",
        "Transaction": "RAW.TRANSACTIONS",
        "Braze Engagement": "RAW.BRAZE_ENGAGEMENT_EVENTS",
        "Recommendation": "RAW.RECOMMENDATIONS",
    }
    entity_map = {k: ("CUSTOMER" if "Customer" in k or "Profile" in k or "User" in k else "FACT") for k in table_map}
    source_map = {
        "OPERA Customer": "OPERA",
        "B4T Customer": "B4T",
        "Braze Profile": "BRAZE",
        "App User": "APP",
        "OPERA Stay": "OPERA",
        "B4T Spa Service": "B4T",
        "Transaction": "MIXED",
        "Braze Engagement": "BRAZE",
        "Recommendation": "MIXED",
    }

    if file and st.button("Load to RAW table", type="primary"):
        df = pd.read_csv(file)
        batch_id = "BATCH_" + uuid.uuid4().hex[:12].upper()
        df["BATCH_ID"] = batch_id
        df["SOURCE_FILE_NAME"] = file.name
        df["PROCESS_STATUS"] = "NEW"
        table = table_map[file_type]
        try:
            from app.services.snowflake_client import get_connection
            from snowflake.connector.pandas_tools import write_pandas

            with get_connection() as conn:
                ok, _, rows, _ = write_pandas(
                    conn,
                    df,
                    table.split(".")[1],
                    schema=table.split(".")[0],
                    quote_identifiers=False,
                )
            execute(
                """
                INSERT INTO PROCESSING.BATCH_CONTROL(batch_id, source_system, entity_type, file_name, load_type, status, record_count)
                VALUES(%s,%s,%s,%s,%s,'LOADED',%s)
                """,
                (batch_id, source_map[file_type], entity_map[file_type], file.name, load_type, len(df)),
            )
            st.success(f"Loaded {rows} rows to {table}. Batch: {batch_id}")
        except Exception as e:
            st.error(e)

    c1, c2, c3 = st.columns(3)
    if c1.button("Process pending batches using Snowpark proc"):
        st.write(execute("CALL PROCESSING.PROCESS_PENDING_BATCHES_V2(10)"))
    if c2.button("Refresh golden profile"):
        st.write(execute("CALL GOLD.REFRESH_GOLDEN_CUSTOMER_PROFILE()"))
    if c3.button("Rebuild Redis"):
        try:
            from scripts.rebuild_redis import rebuild
            st.json(rebuild())
        except Exception as e:
            st.error(e)

    st.subheader("Batch monitor")
    st.dataframe(safe_df("SELECT * FROM PROCESSING.BATCH_CONTROL ORDER BY created_at DESC LIMIT 50"), use_container_width=True)

elif page == "Lookup":
    st.title("Fast Customer Lookup")
    c1, c2, c3 = st.columns(3)
    email = c1.text_input("Email")
    phone = c2.text_input("Phone")
    loyalty = c3.text_input("Loyalty ID")
    s1, s2 = st.columns(2)
    source = s1.text_input("Source system")
    source_id = s2.text_input("Source customer ID")
    if st.button("Lookup in Redis"):
        try:
            r = RedisIdentityIndex()
            st.json(r.lookup(email=email, phone=phone, loyalty_id=loyalty, source_system=source, source_customer_id=source_id).__dict__)
        except Exception as e:
            st.error(e)

elif page == "Golden 360":
    st.title("Golden Customer 360")
    gid = st.text_input("Golden customer ID")

    if gid:
        prof = safe_df("SELECT * FROM GOLD.GOLDEN_CUSTOMER_PROFILE WHERE golden_customer_id=%s", (gid,))
        if prof.empty:
            st.warning("Golden customer not found.")
        else:
            st.subheader("Profile")
            st.dataframe(prof, use_container_width=True)

        st.subheader("Contributing source records")
        links = safe_df(
            """
            SELECT *
            FROM IDENTITY.IDENTITY_CROSSWALK
            WHERE golden_customer_id=%s AND active_flag = TRUE
            ORDER BY source_system, source_customer_id
            """,
            (gid,),
        )
        st.dataframe(links, use_container_width=True)

        if not links.empty:
            with st.expander("Unmerge / eject one source record"):
                labels = [f"{r['SOURCE_SYSTEM']}:{r['SOURCE_CUSTOMER_ID']}" for _, r in links.iterrows()]
                selected = st.selectbox("Source record to eject", labels)
                reason = st.text_area("Reason for unmerge", key="unmerge_reason")
                if st.button("Unmerge selected source record", disabled=not reason):
                    src, sid = selected.split(":", 1)
                    st.write(execute("CALL IDENTITY.UNMERGE_SOURCE_RECORD(%s,%s,%s,%s)", (gid, src, sid, reason)))
                    st.success("Unmerge submitted. Refresh the page.")

            with st.expander("Dissolve entire cluster"):
                dissolve_reason = st.text_area("Reason for dissolving this cluster", key="dissolve_reason")
                confirm = st.checkbox("I understand this will split every contributing source record into its own golden customer")
                if st.button("Dissolve cluster", disabled=not (dissolve_reason and confirm)):
                    st.write(execute("CALL IDENTITY.DISSOLVE_GOLDEN_CLUSTER(%s,%s)", (gid, dissolve_reason)))
                    st.success("Cluster dissolve submitted. Refresh the page.")

        st.subheader("Facts")
        fact_queries = [
            ("Stays", "SELECT s.* FROM GOLD.FACT_STAY s JOIN IDENTITY.IDENTITY_CROSSWALK x ON s.source_system=x.source_system AND s.source_customer_id=x.source_customer_id WHERE x.active_flag = TRUE AND x.golden_customer_id=%s"),
            ("Spa Services", "SELECT s.* FROM GOLD.FACT_SPA_SERVICE s JOIN IDENTITY.IDENTITY_CROSSWALK x ON s.source_system=x.source_system AND s.source_customer_id=x.source_customer_id WHERE x.active_flag = TRUE AND x.golden_customer_id=%s"),
            ("Transactions", "SELECT t.* FROM GOLD.FACT_TRANSACTION t JOIN IDENTITY.IDENTITY_CROSSWALK x ON t.source_system=x.source_system AND t.source_customer_id=x.source_customer_id WHERE x.active_flag = TRUE AND x.golden_customer_id=%s"),
            ("Engagement", "SELECT e.* FROM GOLD.FACT_ENGAGEMENT_EVENT e JOIN IDENTITY.IDENTITY_CROSSWALK x ON e.source_system=x.source_system AND e.source_customer_id=x.source_customer_id WHERE x.active_flag = TRUE AND x.golden_customer_id=%s"),
        ]
        for title, sql in fact_queries:
            st.markdown(f"#### {title}")
            st.dataframe(safe_df(sql, (gid,)), use_container_width=True)

        st.subheader("Decision history")
        st.dataframe(
            safe_df("SELECT * FROM IDENTITY.V_DECISION_HISTORY WHERE golden_customer_id=%s ORDER BY created_at DESC", (gid,)),
            use_container_width=True,
        )
    else:
        st.dataframe(safe_df("SELECT * FROM GOLD.GOLDEN_CUSTOMER_PROFILE ORDER BY refreshed_at DESC LIMIT 50"), use_container_width=True)

elif page == "Stewardship":
    st.title("Stewardship Queue")
    st.caption("Review fuzzy/borderline matches. Approve creates/updates crosswalk; reject writes to rejection registry.")

    q = safe_df(
        """
        SELECT queue_id, match_run_id, left_source_system, left_source_customer_id,
               right_source_system, right_source_customer_id, score, reason, status, created_at
        FROM IDENTITY.STEWARDSHIP_QUEUE
        WHERE status IN ('OPEN','PENDING')
        ORDER BY score DESC, created_at DESC
        LIMIT 100
        """
    )

    if q.empty:
        st.success("Queue is clear.")
    else:
        st.metric("Open review items", f"{len(q):,}")
        for idx, row in q.iterrows():
            title = f"{row['LEFT_SOURCE_SYSTEM']}:{row['LEFT_SOURCE_CUSTOMER_ID']} ↔ {row['RIGHT_SOURCE_SYSTEM']}:{row['RIGHT_SOURCE_CUSTOMER_ID']} · score {float(row['SCORE'] or 0):.2f} · {row['REASON']}"
            with st.expander(title, expanded=(idx == q.index[0])):
                st.progress(float(row["SCORE"] or 0), text=f"Confidence {float(row['SCORE'] or 0):.0%}")
                ca, cb = st.columns(2)
                with ca:
                    render_record_card("Record A", row["LEFT_SOURCE_SYSTEM"], row["LEFT_SOURCE_CUSTOMER_ID"])
                with cb:
                    render_record_card("Record B", row["RIGHT_SOURCE_SYSTEM"], row["RIGHT_SOURCE_CUSTOMER_ID"])

                note = st.text_input("Decision note", key=f"note_{row['QUEUE_ID']}")
                a, b = st.columns(2)
                with a:
                    if st.button("Approve match", key=f"approve_{row['QUEUE_ID']}", type="primary"):
                        st.write(execute("CALL IDENTITY.APPROVE_MATCH(%s,%s)", (row["QUEUE_ID"], note)))
                        st.success("Approved")
                        st.rerun()
                with b:
                    if st.button("Reject match", key=f"reject_{row['QUEUE_ID']}"):
                        st.write(execute("CALL IDENTITY.REJECT_MATCH(%s,%s)", (row["QUEUE_ID"], note or "Rejected by steward")))
                        st.warning("Rejected")
                        st.rerun()

elif page == "Rules & Rerun":
    st.title("Rules, Thresholds, and Rerun")
    st.caption("Current stored procedure still needs to be wired fully to dynamic weights. This page manages the CONFIG tables and supports publishing versions.")

    st.subheader("Rule sets")
    st.dataframe(safe_df("SELECT * FROM CONFIG.RULE_SET ORDER BY created_at DESC"), use_container_width=True)

    with st.expander("Create new rule set"):
        name = st.text_input("Rule set name", value="Customer match rules")
        scope = st.selectbox("Scope", ["CROSS_SOURCE_MATCH", "WITHIN_SOURCE_DEDUPE"])
        left = st.text_input("Left/source A", value="ANY")
        right = st.text_input("Right/source B", value="ANY")
        auto = st.number_input("Auto-match threshold", min_value=0.0, max_value=1.0, value=0.92, step=0.01)
        review = st.number_input("Review threshold", min_value=0.0, max_value=1.0, value=0.78, step=0.01)
        if st.button("Create rule version"):
            rv = "RULE_" + uuid.uuid4().hex[:10].upper()
            execute(
                """
                INSERT INTO CONFIG.RULE_SET(rule_version_id, rule_set_name, rule_scope, source_system_left, source_system_right, auto_match_threshold, review_threshold, status)
                VALUES(%s,%s,%s,%s,%s,%s,%s,'DRAFT')
                """,
                (rv, name, scope, left, right, auto, review),
            )
            st.success(f"Created {rv}")

    st.subheader("Rule conditions")
    st.dataframe(safe_df("SELECT * FROM CONFIG.RULE_CONDITION ORDER BY rule_version_id, condition_order"), use_container_width=True)

    with st.expander("Add rule condition"):
        rv = st.text_input("Rule version ID")
        field = st.selectbox("Field", ["loyalty_id", "email", "phone", "dob", "postal_code", "full_name", "city"])
        mtype = st.selectbox("Match type", ["EXACT", "JAROWINKLER", "EDITDISTANCE"])
        weight = st.number_input("Weight", min_value=0.0, max_value=1.0, value=0.1, step=0.01)
        order = st.number_input("Condition order", min_value=1, value=1)
        if st.button("Add condition", disabled=not rv):
            execute(
                """
                INSERT INTO CONFIG.RULE_CONDITION(rule_version_id, rule_name, condition_order, field_name, match_type, weight, enabled)
                VALUES(%s,%s,%s,%s,%s,%s,TRUE)
                """,
                (rv, f"{field}_{mtype}", order, field, mtype, weight),
            )
            st.success("Condition added")

    st.divider()
    if st.button("Rerun pending batches with current procedure"):
        st.write(execute("CALL PROCESSING.PROCESS_PENDING_BATCHES_V2(10)"))

elif page == "Admin":
    st.title("Admin")
    if st.button("Ping Redis"):
        try:
            st.success(f"Redis connected: {RedisIdentityIndex().ping()}")
        except Exception as e:
            st.error(e)

    if st.button("Rebuild Redis from Snowflake"):
        try:
            from scripts.rebuild_redis import rebuild
            st.json(rebuild())
        except Exception as e:
            st.error(e)

    st.subheader("Raw row status counts")
    st.dataframe(
        safe_df(
            """
            SELECT 'OPERA_CUSTOMERS' AS table_name, process_status, COUNT(*) AS row_count FROM RAW.OPERA_CUSTOMERS GROUP BY 1,2
            UNION ALL SELECT 'B4T_CUSTOMERS' AS table_name, process_status, COUNT(*) AS row_count FROM RAW.B4T_CUSTOMERS GROUP BY 1,2
            UNION ALL SELECT 'BRAZE_PROFILES' AS table_name, process_status, COUNT(*) AS row_count FROM RAW.BRAZE_PROFILES GROUP BY 1,2
            UNION ALL SELECT 'APP_USERS' AS table_name, process_status, COUNT(*) AS row_count FROM RAW.APP_USERS GROUP BY 1,2
            """
        ),
        use_container_width=True,
    )

    st.subheader("Recent errors")
    st.dataframe(
        safe_df(
            """
            SELECT *
            FROM PROCESSING.BATCH_CONTROL
            WHERE status = 'ERROR'
            ORDER BY completed_at DESC
            LIMIT 50
            """
        ),
        use_container_width=True,
    )
