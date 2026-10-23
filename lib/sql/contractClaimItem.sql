UPDATE contracts
SET items_claim_round = ?
WHERE contract_id = ?
    AND items_fetched = 0
    AND items_claim_round <> ?;
