from pydantic_settings import BaseSettings, SettingsConfigDict

class Settings(BaseSettings):
    model_config = SettingsConfigDict(env_file='.env', env_file_encoding='utf-8', extra='ignore')

    snowflake_account: str = ''
    snowflake_user: str = ''
    snowflake_password: str = ''
    snowflake_role: str = 'ACCOUNTADMIN'
    snowflake_warehouse: str = 'COMPUTE_WH'
    snowflake_database: str = 'CUSTOMER360_V2'
    snowflake_schema: str = 'PUBLIC'
    snowflake_authenticator: str = "snowflake"
    snowflake_token: str | None = None
    
    redis_host: str = 'localhost'
    redis_port: int = 6379
    redis_password: str | None = None
    redis_ssl: bool = False
    redis_db: int = 0
    redis_key_prefix: str = 'c360'
    redis_connect_timeout: float = 5
    redis_socket_timeout: float = 5

settings = Settings()
