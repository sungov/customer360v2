from __future__ import annotations
from rapidfuzz import fuzz

def safe_eq(a, b) -> bool:
    return a is not None and b is not None and str(a).strip() != '' and str(a) == str(b)

def fuzzy(a, b) -> float:
    if not a or not b:
        return 0.0
    return fuzz.token_sort_ratio(str(a), str(b)) / 100.0

def score_pair(left: dict, right: dict, same_source: bool = False) -> tuple[float, list[str]]:
    weights = []
    reasons = []
    def add(name, matched, weight, detail=''):
        weights.append((weight, 1.0 if matched else 0.0))
        if matched:
            reasons.append(detail or name)
    add('loyalty', safe_eq(left.get('LOYALTY_ID'), right.get('LOYALTY_ID')), 0.35, 'loyalty exact')
    add('email', safe_eq(left.get('NORMALIZED_EMAIL'), right.get('NORMALIZED_EMAIL')), 0.30, 'email exact')
    add('phone', safe_eq(left.get('NORMALIZED_PHONE'), right.get('NORMALIZED_PHONE')), 0.25, 'phone exact')
    name_score = fuzzy(left.get('NORMALIZED_FULL_NAME'), right.get('NORMALIZED_FULL_NAME'))
    dob_match = safe_eq(str(left.get('DOB')), str(right.get('DOB'))) if left.get('DOB') and right.get('DOB') else False
    if name_score >= 0.88 and dob_match:
        weights.append((0.20, 1.0)); reasons.append('name fuzzy + dob exact')
    elif name_score >= 0.88:
        weights.append((0.08, 1.0)); reasons.append('name fuzzy')
    else:
        weights.append((0.20, 0.0))
    denom = sum(w for w, _ in weights) or 1
    score = sum(w*m for w, m in weights) / denom
    if same_source and score >= 0.85:
        score = min(1.0, score + 0.05)
    return round(score, 4), reasons
