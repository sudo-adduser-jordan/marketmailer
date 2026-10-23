UPDATE contracts
SET items_attempts = items_attempts + 1, items_next_attempt_at = ?, items_claim_round = 0
WHERE contract_id = ?;
