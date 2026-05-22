USE DATABASE CUSTOMER360_V2;

INSERT INTO CONFIG.RULE_SET(rule_version_id, rule_set_name, rule_scope, source_system_left, source_system_right, auto_match_threshold, review_threshold, status)
SELECT * FROM VALUES
('RULE_V1','Default within-source dedupe','DEDUPE','ANY','ANY',0.90,0.75,'ACTIVE'),
('RULE_V1','Default cross-source match','MATCH','ANY','ANY',0.90,0.75,'ACTIVE');

INSERT INTO CONFIG.RULE_CONDITION(rule_version_id, rule_name, condition_order, field_name, match_type, weight, enabled)
SELECT * FROM VALUES
('RULE_V1','loyalty exact',1,'loyalty_id','EXACT',0.35,TRUE),
('RULE_V1','email exact',2,'normalized_email','EXACT',0.30,TRUE),
('RULE_V1','phone exact',3,'normalized_phone','EXACT',0.25,TRUE),
('RULE_V1','name dob',4,'normalized_full_name+dob','FUZZY_PLUS_EXACT',0.20,TRUE);

INSERT INTO CONFIG.SURVIVORSHIP_RULE(rule_version_id, field_name, source_priority, default_strategy)
SELECT 'RULE_V1', 'email', ARRAY_CONSTRUCT('OPERA','B4T','APP','BRAZE'), 'FIRST_NON_NULL'
UNION ALL SELECT 'RULE_V1', 'phone', ARRAY_CONSTRUCT('OPERA','B4T','APP','BRAZE'), 'FIRST_NON_NULL'
UNION ALL SELECT 'RULE_V1', 'name', ARRAY_CONSTRUCT('OPERA','B4T','APP','BRAZE'), 'FIRST_NON_NULL'
UNION ALL SELECT 'RULE_V1', 'loyalty_id', ARRAY_CONSTRUCT('OPERA','APP','B4T','BRAZE'), 'FIRST_NON_NULL';
