from pathlib import Path
from app.services.snowflake_client import execute

def run_folder(folder):
    for f in sorted(Path(folder).glob('*.sql')):
        sql = f.read_text(encoding='utf-8')
        print('Running', f)
        for stmt in [s.strip() for s in sql.split(';') if s.strip()]:
            execute(stmt)

if __name__ == '__main__':
    run_folder('snowflake/schema')
    run_folder('snowflake/procedures')
    print('Snowflake setup complete')
