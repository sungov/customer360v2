from __future__ import annotations

import argparse
import random
import uuid
import hashlib
from datetime import date, datetime, timedelta
from pathlib import Path

import pandas as pd
from faker import Faker


fake = Faker("en_US")
random.seed(42)
Faker.seed(42)

SOURCES = ["OPERA", "B4T", "BRAZE", "APP"]

SERVICE_TYPES = [
    "Massage",
    "Facial",
    "Fitness Consultation",
    "Nutrition Consultation",
    "Yoga",
    "Meditation",
    "Skin Care",
    "Wellness Package",
]

ROOM_TYPES = ["Deluxe", "Suite", "Villa", "Standard", "Premium"]
PROPERTY_CODES = ["CR_TUCSON", "CR_LENOX", "CR_WOOD"]
CHANNELS = ["email", "sms", "push", "web"]
CAMPAIGNS = ["Welcome", "Spa Offer", "Reactivation", "Wellness Retreat", "Birthday"]


def new_batch_id(prefix: str) -> str:
    return f"{prefix}_{uuid.uuid4().hex[:12].upper()}"


def rand_date(days_back: int = 730) -> date:
    return date.today() - timedelta(days=random.randint(0, days_back))


def rand_timestamp(days_back: int = 365) -> datetime:
    d = datetime.now() - timedelta(
        days=random.randint(0, days_back),
        hours=random.randint(0, 23),
        minutes=random.randint(0, 59),
    )
    return d.replace(microsecond=0)


def maybe(value, null_rate: float = 0.05):
    return None if random.random() < null_rate else value


def typo_name(name: str) -> str:
    if not name or len(name) < 4:
        return name
    i = random.randint(1, len(name) - 2)
    return name[:i] + name[i + 1:]


def alter_email(email: str) -> str:
    if not email or "@" not in email:
        return email
    if random.random() < 0.5:
        return email.replace("@", f"+{random.randint(1, 99)}@")
    return email.replace(".", "", 1)


def alter_phone(phone: str) -> str:
    if not phone or len(phone) < 5:
        return phone
    return phone[:-1] + str(random.randint(0, 9))


def hash_record(row: dict) -> str:
    text = "|".join("" if row.get(k) is None else str(row.get(k)) for k in sorted(row.keys()))
    return hashlib.sha256(text.encode("utf-8")).hexdigest()


def make_base_people(num_people: int) -> list[dict]:
    people = []

    for i in range(num_people):
        first = fake.first_name()
        last = fake.last_name()
        email = f"{first}.{last}{random.randint(1, 9999)}@example.com".lower()
        phone = f"+1{random.randint(2000000000, 9999999999)}"

        people.append(
            {
                "person_id": f"P{i + 1:08d}",
                "first_name": first,
                "last_name": last,
                "email": email,
                "phone": phone,
                "dob": fake.date_of_birth(minimum_age=18, maximum_age=85),
                "address_line1": fake.street_address(),
                "city": fake.city(),
                "state": fake.state_abbr(),
                "postal_code": fake.postcode(),
                "country": "US",
                "loyalty_id": f"CR{random.randint(10000000, 99999999)}",
            }
        )

    return people


def create_source_record(person: dict, source: str, batch_id: str, file_name: str, duplicate_variant: bool) -> dict:
    first = person["first_name"]
    last = person["last_name"]
    email = person["email"]
    phone = person["phone"]

    if duplicate_variant:
        if random.random() < 0.20:
            first = typo_name(first)
        if random.random() < 0.15:
            last = typo_name(last)
        if random.random() < 0.25:
            email = alter_email(email)
        if random.random() < 0.20:
            phone = alter_phone(phone)

    row = {
        "batch_id": batch_id,
        "source_file_name": file_name,
        "source_system": source,
        "source_customer_id": f"{source}_{uuid.uuid4().hex[:12].upper()}",
        "expected_person_id": person["person_id"],
        "first_name": maybe(first, 0.02),
        "last_name": maybe(last, 0.02),
        "email": maybe(email, 0.08 if source in ["B4T", "OPERA"] else 0.03),
        "phone": maybe(phone, 0.06),
        "dob": maybe(person["dob"], 0.12),
        "address_line1": maybe(person["address_line1"], 0.20),
        "city": maybe(person["city"], 0.12),
        "state": maybe(person["state"], 0.12),
        "postal_code": maybe(person["postal_code"], 0.15),
        "country": person["country"],
        "loyalty_id": maybe(person["loyalty_id"], 0.35),
        "created_at": rand_timestamp(1200),
        "updated_at": rand_timestamp(90),
        "process_status": "NEW",
    }

    row["record_hash"] = hash_record(row)
    return row


def distribute_source_records(base_people: list[dict], total_records: int, batch_ids: dict, file_names: dict) -> pd.DataFrame:
    records = []

    source_weights = {
        "OPERA": 0.42,
        "B4T": 0.24,
        "BRAZE": 0.26,
        "APP": 0.08,
    }

    for person in base_people:
        primary_source = random.choices(
            list(source_weights.keys()),
            weights=list(source_weights.values()),
        )[0]

        records.append(
            create_source_record(
                person,
                primary_source,
                batch_ids[primary_source],
                file_names[primary_source],
                False,
            )
        )

        overlap_chance = random.random()

        if overlap_chance < 0.22:
            second_source = random.choice([s for s in SOURCES if s != primary_source])
            records.append(
                create_source_record(
                    person,
                    second_source,
                    batch_ids[second_source],
                    file_names[second_source],
                    True,
                )
            )

        if overlap_chance < 0.06:
            third_source = random.choice([s for s in SOURCES if s != primary_source])
            records.append(
                create_source_record(
                    person,
                    third_source,
                    batch_ids[third_source],
                    file_names[third_source],
                    True,
                )
            )

        if random.random() < 0.04:
            records.append(
                create_source_record(
                    person,
                    primary_source,
                    batch_ids[primary_source],
                    file_names[primary_source],
                    True,
                )
            )

        if len(records) >= total_records:
            break

    while len(records) < total_records:
        person = random.choice(base_people)
        source = random.choice(SOURCES)
        records.append(
            create_source_record(
                person,
                source,
                batch_ids[source],
                file_names[source],
                True,
            )
        )

    return pd.DataFrame(records[:total_records])


def customer_table_columns() -> list[str]:
    return [
        "batch_id",
        "source_file_name",
        "source_customer_id",
        "expected_person_id",
        "first_name",
        "last_name",
        "email",
        "phone",
        "dob",
        "address_line1",
        "city",
        "state",
        "postal_code",
        "country",
        "loyalty_id",
        "created_at",
        "updated_at",
        "record_hash",
        "process_status",
    ]


def write_customer_files(customers: pd.DataFrame, output_dir: Path):
    mapping = {
        "OPERA": "opera_customers.csv",
        "B4T": "b4t_customers.csv",
        "BRAZE": "braze_profiles.csv",
        "APP": "app_users.csv",
    }

    cols = customer_table_columns()

    for source, filename in mapping.items():
        df = customers[customers["source_system"] == source].copy()
        df = df[cols]
        df.to_csv(output_dir / filename, index=False)


def make_stays(customers: pd.DataFrame, batch_id: str, max_rows: int) -> pd.DataFrame:
    opera = customers[customers["source_system"] == "OPERA"]
    rows = []

    if opera.empty:
        return pd.DataFrame()

    sample = opera.sample(min(len(opera), max_rows), random_state=42)

    for _, row in sample.iterrows():
        checkin = rand_date(900)
        nights = random.randint(1, 14)

        rows.append(
            {
                "batch_id": batch_id,
                "source_file_name": "fact_stays.csv",
                "stay_id": f"STAY_{uuid.uuid4().hex[:14].upper()}",
                "source_system": "OPERA",
                "source_customer_id": row["source_customer_id"],
                "expected_person_id": row["expected_person_id"],
                "property_code": random.choice(PROPERTY_CODES),
                "checkin_date": checkin,
                "checkout_date": checkin + timedelta(days=nights),
                "room_type": random.choice(ROOM_TYPES),
                "nights": nights,
                "revenue_amount": round(random.uniform(250, 8000), 2),
                "currency": "USD",
                "process_status": "NEW",
            }
        )

    return pd.DataFrame(rows)


def make_spa_services(customers: pd.DataFrame, batch_id: str, max_rows: int) -> pd.DataFrame:
    eligible = customers[customers["source_system"].isin(["B4T", "OPERA"])]
    rows = []

    if eligible.empty:
        return pd.DataFrame()

    sample = eligible.sample(min(len(eligible), max_rows), random_state=43)

    for _, row in sample.iterrows():
        rows.append(
            {
                "batch_id": batch_id,
                "source_file_name": "fact_spa_services.csv",
                "service_id": f"SVC_{uuid.uuid4().hex[:14].upper()}",
                "source_system": row["source_system"],
                "source_customer_id": row["source_customer_id"],
                "expected_person_id": row["expected_person_id"],
                "service_date": rand_date(730),
                "service_type": random.choice(SERVICE_TYPES),
                "provider_id": f"PROV_{random.randint(1000, 9999)}",
                "amount": round(random.uniform(80, 1200), 2),
                "currency": "USD",
                "process_status": "NEW",
            }
        )

    return pd.DataFrame(rows)


def make_transactions(customers: pd.DataFrame, batch_id: str, max_rows: int) -> pd.DataFrame:
    rows = []
    sample = customers.sample(min(len(customers), max_rows), random_state=44)

    for _, row in sample.iterrows():
        rows.append(
            {
                "batch_id": batch_id,
                "source_file_name": "fact_transactions.csv",
                "transaction_id": f"TXN_{uuid.uuid4().hex[:14].upper()}",
                "source_system": row["source_system"],
                "source_customer_id": row["source_customer_id"],
                "expected_person_id": row["expected_person_id"],
                "transaction_date": rand_date(730),
                "category": random.choice(["Retail", "Food & Beverage", "Spa", "Stay", "Wellness"]),
                "amount": round(random.uniform(20, 2500), 2),
                "currency": "USD",
                "process_status": "NEW",
            }
        )

    return pd.DataFrame(rows)


def make_engagement_events(customers: pd.DataFrame, batch_id: str, max_rows: int) -> pd.DataFrame:
    eligible = customers[customers["source_system"].isin(["BRAZE", "APP"])]
    rows = []

    if eligible.empty:
        return pd.DataFrame()

    sample = eligible.sample(min(len(eligible), max_rows), random_state=45)

    for _, row in sample.iterrows():
        rows.append(
            {
                "batch_id": batch_id,
                "source_file_name": "fact_engagement_events.csv",
                "event_id": f"EVT_{uuid.uuid4().hex[:14].upper()}",
                "source_system": row["source_system"],
                "source_customer_id": row["source_customer_id"],
                "expected_person_id": row["expected_person_id"],
                "event_timestamp": rand_timestamp(365),
                "channel": random.choice(CHANNELS),
                "campaign_name": random.choice(CAMPAIGNS),
                "event_type": random.choice(["sent", "opened", "clicked", "booked", "unsubscribed"]),
                "process_status": "NEW",
            }
        )

    return pd.DataFrame(rows)


def make_recommendations(customers: pd.DataFrame, batch_id: str, stays: pd.DataFrame, spa: pd.DataFrame, transactions: pd.DataFrame) -> pd.DataFrame:
    people = customers[["expected_person_id"]].drop_duplicates()
    rows = []

    stayed_people = set(stays["expected_person_id"].unique()) if not stays.empty else set()
    spa_people = set(spa["expected_person_id"].unique()) if not spa.empty else set()
    txn_people = set(transactions["expected_person_id"].unique()) if not transactions.empty else set()

    for person_id in people["expected_person_id"]:
        if person_id in spa_people:
            rec = "Offer premium spa package"
            reason = "Customer has prior spa service history"
        elif person_id in stayed_people:
            rec = "Offer wellness retreat package"
            reason = "Customer has prior stay history"
        elif person_id in txn_people:
            rec = "Offer retail wellness bundle"
            reason = "Customer has prior purchase history"
        else:
            rec = "Send welcome campaign"
            reason = "No recent activity found"

        rows.append(
            {
                "batch_id": batch_id,
                "source_file_name": "fact_recommendations.csv",
                "expected_person_id": person_id,
                "recommendation_id": f"REC_{uuid.uuid4().hex[:12].upper()}",
                "recommendation": rec,
                "reason": reason,
                "priority": random.choice(["HIGH", "MEDIUM", "LOW"]),
                "created_at": date.today(),
                "process_status": "NEW",
            }
        )

    return pd.DataFrame(rows)


def write_batch_control(output_dir: Path, customers: pd.DataFrame, fact_frames: dict, batch_ids: dict, file_names: dict, load_type: str):
    rows = []

    for source in SOURCES:
        rows.append(
            {
                "batch_id": batch_ids[source],
                "source_system": source,
                "entity_type": "CUSTOMER",
                "file_name": file_names[source],
                "load_type": load_type,
                "status": "LOADED",
                "record_count": int((customers["source_system"] == source).sum()),
            }
        )

    fact_source_map = {
        "fact_stays.csv": ("OPERA", "STAY"),
        "fact_spa_services.csv": ("B4T", "SPA_SERVICE"),
        "fact_transactions.csv": ("MULTI", "TRANSACTION"),
        "fact_engagement_events.csv": ("BRAZE", "ENGAGEMENT"),
        "fact_recommendations.csv": ("SYSTEM", "RECOMMENDATION"),
    }

    for filename, df in fact_frames.items():
        src, entity = fact_source_map[filename]
        rows.append(
            {
                "batch_id": batch_ids[filename],
                "source_system": src,
                "entity_type": entity,
                "file_name": filename,
                "load_type": load_type,
                "status": "LOADED",
                "record_count": 0 if df is None or df.empty else len(df),
            }
        )

    pd.DataFrame(rows).to_csv(output_dir / "batch_control.csv", index=False)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--records", type=int, default=100_000)
    parser.add_argument("--output-dir", type=str, default="data/generated")
    parser.add_argument("--load-type", type=str, default="FULL", choices=["FULL", "INCREMENTAL"])
    args = parser.parse_args()

    output_dir = Path(args.output_dir)
    output_dir.mkdir(parents=True, exist_ok=True)

    customer_batch_ids = {
        "OPERA": new_batch_id("BATCH_OPERA_CUSTOMERS"),
        "B4T": new_batch_id("BATCH_B4T_CUSTOMERS"),
        "BRAZE": new_batch_id("BATCH_BRAZE_PROFILES"),
        "APP": new_batch_id("BATCH_APP_USERS"),
    }

    customer_file_names = {
        "OPERA": "opera_customers.csv",
        "B4T": "b4t_customers.csv",
        "BRAZE": "braze_profiles.csv",
        "APP": "app_users.csv",
    }

    fact_batch_ids = {
        "fact_stays.csv": new_batch_id("BATCH_OPERA_STAYS"),
        "fact_spa_services.csv": new_batch_id("BATCH_B4T_SPA"),
        "fact_transactions.csv": new_batch_id("BATCH_TXN"),
        "fact_engagement_events.csv": new_batch_id("BATCH_BRAZE_ENG"),
        "fact_recommendations.csv": new_batch_id("BATCH_RECS"),
    }

    all_batch_ids = {**customer_batch_ids, **fact_batch_ids}

    base_people_count = int(args.records * 0.78)

    print(f"Generating {base_people_count:,} base people...")
    base_people = make_base_people(base_people_count)

    print(f"Generating {args.records:,} customer source rows...")
    customers = distribute_source_records(
        base_people,
        args.records,
        customer_batch_ids,
        customer_file_names,
    )

    print("Writing customer source files...")
    customers.to_csv(output_dir / "all_source_customers.csv", index=False)
    write_customer_files(customers, output_dir)

    print("Generating fact files...")
    stays = make_stays(customers, fact_batch_ids["fact_stays.csv"], int(args.records * 0.35))
    spa = make_spa_services(customers, fact_batch_ids["fact_spa_services.csv"], int(args.records * 0.30))
    transactions = make_transactions(customers, fact_batch_ids["fact_transactions.csv"], int(args.records * 0.45))
    engagement = make_engagement_events(customers, fact_batch_ids["fact_engagement_events.csv"], int(args.records * 0.40))
    recommendations = make_recommendations(
        customers,
        fact_batch_ids["fact_recommendations.csv"],
        stays,
        spa,
        transactions,
    )

    stays.to_csv(output_dir / "fact_stays.csv", index=False)
    spa.to_csv(output_dir / "fact_spa_services.csv", index=False)
    transactions.to_csv(output_dir / "fact_transactions.csv", index=False)
    engagement.to_csv(output_dir / "fact_engagement_events.csv", index=False)
    recommendations.to_csv(output_dir / "fact_recommendations.csv", index=False)

    fact_frames = {
        "fact_stays.csv": stays,
        "fact_spa_services.csv": spa,
        "fact_transactions.csv": transactions,
        "fact_engagement_events.csv": engagement,
        "fact_recommendations.csv": recommendations,
    }

    print("Writing batch_control.csv...")
    write_batch_control(
        output_dir,
        customers,
        fact_frames,
        all_batch_ids,
        {**customer_file_names, **{k: k for k in fact_batch_ids}},
        args.load_type,
    )

    expected_crosswalk = customers[
        ["source_system", "source_customer_id", "expected_person_id"]
    ].copy()
    expected_crosswalk.rename(
        columns={"expected_person_id": "expected_golden_customer_id"},
        inplace=True,
    )
    expected_crosswalk.to_csv(output_dir / "expected_crosswalk.csv", index=False)

    print("\nDone.")
    print(f"Output folder: {output_dir.resolve()}")
    print("\nFiles generated:")
    for file in sorted(output_dir.glob("*.csv")):
        try:
            cnt = sum(1 for _ in open(file, encoding="utf-8")) - 1
        except Exception:
            cnt = 0
        print(f" - {file.name}: {cnt:,} rows")


if __name__ == "__main__":
    main()