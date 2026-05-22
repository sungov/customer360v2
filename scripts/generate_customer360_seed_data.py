from __future__ import annotations
import argparse, random, uuid
from datetime import date, timedelta
from pathlib import Path
import pandas as pd
from faker import Faker
fake = Faker('en_US'); random.seed(42); Faker.seed(42)
SOURCES=['OPERA','B4T','BRAZE','APP']
SERVICE_TYPES=['Massage','Facial','Fitness Consultation','Nutrition Consultation','Yoga','Meditation','Skin Care','Wellness Package']
ROOM_TYPES=['Deluxe','Suite','Villa','Standard','Premium']; CHANNELS=['email','sms','push','web']; CAMPAIGNS=['Welcome','Spa Offer','Reactivation','Wellness Retreat','Birthday']
def rand_date(days_back=730): return date.today()-timedelta(days=random.randint(0,days_back))
def maybe(v, null_rate=0.05): return None if random.random()<null_rate else v
def typo_name(n):
    if len(n)<4: return n
    i=random.randint(1,len(n)-2); return n[:i]+n[i+1:]
def alter_email(e): return e.replace('@',f'+{random.randint(1,99)}@') if random.random()<0.5 else e.replace('.','',1)
def alter_phone(p): return p[:-1]+str(random.randint(0,9)) if len(p)>=10 else p
def make_base_people(n):
    people=[]
    for i in range(n):
        first=fake.first_name(); last=fake.last_name(); email=f'{first}.{last}{random.randint(1,9999)}@example.com'.lower(); phone=f'+1{random.randint(2000000000,9999999999)}'
        people.append({'person_id':f'P{i+1:08d}','first_name':first,'last_name':last,'email':email,'phone':phone,'dob':fake.date_of_birth(minimum_age=18,maximum_age=85),'address_line1':fake.street_address(),'city':fake.city(),'state':fake.state_abbr(),'postal_code':fake.postcode(),'country':'US','loyalty_id':f'CR{random.randint(10000000,99999999)}'})
    return people
def create_source_record(p, source, variant):
    first,last,email,phone=p['first_name'],p['last_name'],p['email'],p['phone']
    if variant:
        if random.random()<0.20: first=typo_name(first)
        if random.random()<0.15: last=typo_name(last)
        if random.random()<0.25: email=alter_email(email)
        if random.random()<0.20: phone=alter_phone(phone)
    return {'source_system':source,'source_customer_id':f'{source}_{uuid.uuid4().hex[:12].upper()}','expected_person_id':p['person_id'],'first_name':maybe(first,0.02),'last_name':maybe(last,0.02),'email':maybe(email,0.08 if source in ['B4T','OPERA'] else 0.03),'phone':maybe(phone,0.06),'dob':maybe(p['dob'],0.12),'address_line1':maybe(p['address_line1'],0.20),'city':maybe(p['city'],0.12),'state':maybe(p['state'],0.12),'postal_code':maybe(p['postal_code'],0.15),'country':p['country'],'loyalty_id':maybe(p['loyalty_id'],0.35),'created_at':rand_date(1200),'updated_at':rand_date(90)}
def distribute(base,total):
    records=[]; weights={'OPERA':.42,'B4T':.24,'BRAZE':.26,'APP':.08}
    for p in base:
        primary=random.choices(list(weights),weights=list(weights.values()))[0]; records.append(create_source_record(p,primary,False)); ov=random.random()
        if ov<.22: records.append(create_source_record(p,random.choice([s for s in SOURCES if s!=primary]),True))
        if ov<.06: records.append(create_source_record(p,random.choice([s for s in SOURCES if s!=primary]),True))
        if random.random()<.04: records.append(create_source_record(p,primary,True))
        if len(records)>=total: break
    while len(records)<total: records.append(create_source_record(random.choice(base),random.choice(SOURCES),True))
    return pd.DataFrame(records[:total])
def make_stays(c,max_rows):
    rows=[]; opera=c[c.source_system=='OPERA']
    for _,r in opera.sample(min(len(opera),max_rows),random_state=42).iterrows():
        ci=rand_date(900); nights=random.randint(1,14); rows.append({'stay_id':f'STAY_{uuid.uuid4().hex[:14].upper()}','source_system':'OPERA','source_customer_id':r.source_customer_id,'expected_person_id':r.expected_person_id,'property_code':random.choice(['CR_TUCSON','CR_LENOX','CR_WOOD']),'checkin_date':ci,'checkout_date':ci+timedelta(days=nights),'room_type':random.choice(ROOM_TYPES),'nights':nights,'revenue_amount':round(random.uniform(250,8000),2),'currency':'USD'})
    return pd.DataFrame(rows)
def make_spa(c,max_rows):
    rows=[]; elig=c[c.source_system.isin(['B4T','OPERA'])]
    for _,r in elig.sample(min(len(elig),max_rows),random_state=43).iterrows(): rows.append({'service_id':f'SVC_{uuid.uuid4().hex[:14].upper()}','source_system':r.source_system,'source_customer_id':r.source_customer_id,'expected_person_id':r.expected_person_id,'service_date':rand_date(730),'service_type':random.choice(SERVICE_TYPES),'provider_id':f'PROV_{random.randint(1000,9999)}','amount':round(random.uniform(80,1200),2),'currency':'USD'})
    return pd.DataFrame(rows)
def make_txn(c,max_rows):
    rows=[]
    for _,r in c.sample(min(len(c),max_rows),random_state=44).iterrows(): rows.append({'transaction_id':f'TXN_{uuid.uuid4().hex[:14].upper()}','source_system':r.source_system,'source_customer_id':r.source_customer_id,'expected_person_id':r.expected_person_id,'transaction_date':rand_date(730),'category':random.choice(['Retail','Food & Beverage','Spa','Stay','Wellness']),'amount':round(random.uniform(20,2500),2),'currency':'USD'})
    return pd.DataFrame(rows)
def make_engagement(c,max_rows):
    rows=[]; elig=c[c.source_system.isin(['BRAZE','APP'])]
    for _,r in elig.sample(min(len(elig),max_rows),random_state=45).iterrows(): rows.append({'event_id':f'EVT_{uuid.uuid4().hex[:14].upper()}','source_system':r.source_system,'source_customer_id':r.source_customer_id,'expected_person_id':r.expected_person_id,'event_timestamp':rand_date(365),'channel':random.choice(CHANNELS),'campaign_name':random.choice(CAMPAIGNS),'event_type':random.choice(['sent','opened','clicked','booked','unsubscribed'])})
    return pd.DataFrame(rows)
def add_recs(c,stays,spa,txns):
    rows=[]; stayed=set(stays.expected_person_id.unique()) if not stays.empty else set(); spa_people=set(spa.expected_person_id.unique()) if not spa.empty else set(); txn_people=set(txns.expected_person_id.unique()) if not txns.empty else set()
    for pid in c.expected_person_id.drop_duplicates():
        if pid in spa_people: rec,reason='Offer premium spa package','Customer has prior spa service history'
        elif pid in stayed: rec,reason='Offer wellness retreat package','Customer has prior stay history'
        elif pid in txn_people: rec,reason='Offer retail wellness bundle','Customer has prior purchase history'
        else: rec,reason='Send welcome campaign','No recent activity found'
        rows.append({'expected_person_id':pid,'recommendation_id':f'REC_{uuid.uuid4().hex[:12].upper()}','recommendation':rec,'reason':reason,'priority':random.choice(['HIGH','MEDIUM','LOW']),'created_at':date.today()})
    return pd.DataFrame(rows)
def write_by_source(c,out):
    mapping={'OPERA':'opera_customers.csv','B4T':'b4t_customers.csv','BRAZE':'braze_profiles.csv','APP':'app_users.csv'}
    for s,fn in mapping.items(): c[c.source_system==s].to_csv(out/fn,index=False)
def main():
    ap=argparse.ArgumentParser(); ap.add_argument('--records',type=int,default=100_000); ap.add_argument('--output-dir',default='data/generated'); args=ap.parse_args(); out=Path(args.output_dir); out.mkdir(parents=True,exist_ok=True)
    base=make_base_people(int(args.records*.78)); c=distribute(base,args.records); stays=make_stays(c,int(args.records*.35)); spa=make_spa(c,int(args.records*.30)); txns=make_txn(c,int(args.records*.45)); eng=make_engagement(c,int(args.records*.40)); recs=add_recs(c,stays,spa,txns)
    c.to_csv(out/'all_source_customers.csv',index=False); write_by_source(c,out); stays.to_csv(out/'fact_stays.csv',index=False); spa.to_csv(out/'fact_spa_services.csv',index=False); txns.to_csv(out/'fact_transactions.csv',index=False); eng.to_csv(out/'fact_engagement_events.csv',index=False); recs.to_csv(out/'fact_recommendations.csv',index=False); c[['source_system','source_customer_id','expected_person_id']].rename(columns={'expected_person_id':'expected_golden_customer_id'}).to_csv(out/'expected_crosswalk.csv',index=False)
    for f in sorted(out.glob('*.csv')): print(f'{f.name}: {sum(1 for _ in open(f, encoding="utf-8"))-1:,}')
if __name__=='__main__': main()
