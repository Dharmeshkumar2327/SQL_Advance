/* =============================================================================
   R03 - MULE CHAIN (LAYERING)
   Pattern : victim pays mule A -> A forwards ~98% to mule B within minutes ->
             B forwards to C -> ... -> cash-out merchant. Each hop hides the trail.
   Logic   : RECURSIVE CTE walks the money graph.
               anchor   : every successful payment >= min_start_amount
               step     : the receiver pays onward within max_hop_minutes,
                          forwarding between min_forward_ratio and 100% of it
             Paths with >= min_chain_txns hops are flagged; every hop in the
             path gets a hit. A cycle guard stops infinite loops.
   SQL     : WITH RECURSIVE, arrays as path accumulators, cycle detection,
             DISTINCT ON to keep each txn's longest chain
   Output  : fraud.rule_hits  +  fraud.mule_chains (one row per chain hop)
   ============================================================================= */
\echo '  R03 mule chain (recursive CTE)'
SELECT clock_timestamp()::timestamp AS t0 \gset

DELETE FROM fraud.rule_hits WHERE rule_code = 'R03';
DROP TABLE IF EXISTS fraud.mule_chains;

CREATE TABLE fraud.mule_chains AS
WITH RECURSIVE chain AS (
    -- anchor: any sizeable payment can be the start of a chain
    SELECT
        t.txn_id                          AS root_txn_id,
        t.txn_id,
        t.payer_account_id,
        t.payee_account_id,
        t.txn_ts,
        t.amount,
        t.amount                          AS root_amount,
        1                                 AS depth,
        ARRAY[t.txn_id]                   AS txn_path,
        ARRAY[t.payer_account_id, t.payee_account_id] AS account_path
    FROM upi.transactions t
    WHERE t.status = 'SUCCESS'
      AND t.amount >= fraud.param('R03', 'min_start_amount')

    UNION ALL

    -- step: receiver forwards most of the money onward, quickly
    SELECT
        c.root_txn_id,
        n.txn_id,
        n.payer_account_id,
        n.payee_account_id,
        n.txn_ts,
        n.amount,
        c.root_amount,
        c.depth + 1,
        c.txn_path || n.txn_id,
        c.account_path || n.payee_account_id
    FROM chain c
    JOIN upi.transactions n
      ON  n.payer_account_id = c.payee_account_id
      AND n.status = 'SUCCESS'
      AND n.txn_ts >  c.txn_ts
      AND n.txn_ts <= c.txn_ts + make_interval(mins => fraud.param('R03', 'max_hop_minutes')::INT)
      AND n.amount BETWEEN c.amount * fraud.param('R03', 'min_forward_ratio') AND c.amount
    WHERE c.depth < fraud.param('R03', 'max_depth')
      AND NOT (n.payee_account_id = ANY (c.account_path))     -- cycle guard
),
complete_chains AS (            -- keep only the longest path per root
    SELECT DISTINCT ON (root_txn_id)
        root_txn_id, depth AS chain_txns, txn_path, account_path,
        root_amount, amount AS final_amount
    FROM chain
    WHERE depth >= fraud.param('R03', 'min_chain_txns')
    ORDER BY root_txn_id, depth DESC
),
not_sub_chain AS (              -- drop chains that are just the tail of a longer one
    SELECT cc.*
    FROM complete_chains cc
    WHERE NOT EXISTS (
        SELECT 1 FROM complete_chains bigger
        WHERE bigger.root_txn_id <> cc.root_txn_id
          AND cc.root_txn_id = ANY (bigger.txn_path)
    )
)
SELECT
    DENSE_RANK() OVER (ORDER BY c.root_txn_id)          AS chain_id,
    c.root_txn_id,
    c.chain_txns,
    c.root_amount,
    c.final_amount,
    ROUND(100.0 * c.final_amount / c.root_amount, 1)    AS pct_amount_retained,
    hop.hop_no,
    hop.txn_id,
    t.payer_account_id,
    t.payee_account_id,
    t.amount,
    t.txn_ts
FROM not_sub_chain c
CROSS JOIN LATERAL unnest(c.txn_path) WITH ORDINALITY AS hop (txn_id, hop_no)
JOIN upi.transactions t ON t.txn_id = hop.txn_id;

CREATE INDEX ON fraud.mule_chains (txn_id);

INSERT INTO fraud.rule_hits (txn_id, account_id, rule_code, evidence)
SELECT DISTINCT ON (m.txn_id)
    m.txn_id,
    m.payee_account_id,                 -- the receiving (mule) account is suspicious
    'R03',
    jsonb_build_object(
        'chain_id',            m.chain_id,
        'hop_no',              m.hop_no,
        'chain_txns',          m.chain_txns,
        'root_amount',         m.root_amount,
        'pct_amount_retained', m.pct_amount_retained
    )
FROM fraud.mule_chains m
WHERE fraud.is_active('R03')
ORDER BY m.txn_id, m.chain_txns DESC;

-- Accounts that sit in the MIDDLE of a chain (received and forwarded) = suspected mules
DROP TABLE IF EXISTS fraud.suspected_mule_accounts;
CREATE TABLE fraud.suspected_mule_accounts AS
SELECT
    a.account_id,
    a.vpa,
    a.created_at,
    a.kyc_level,
    COUNT(DISTINCT m.chain_id)  AS chains_involved,
    SUM(m.amount)               AS amount_forwarded
FROM fraud.mule_chains m
JOIN upi.accounts a ON a.account_id = m.payer_account_id
WHERE m.hop_no > 1                      -- payer of a later hop = received money earlier in chain
GROUP BY a.account_id, a.vpa, a.created_at, a.kyc_level;

SELECT fraud.log_step('R03', (SELECT COUNT(*) FROM fraud.rule_hits WHERE rule_code = 'R03'), :'t0') AS logged \gset
