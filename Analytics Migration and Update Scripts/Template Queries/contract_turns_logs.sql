WITH contract_base AS (
    SELECT
        c.id AS contract_id,
        c.created_by_workspace_id,
        contract_kind
    FROM `{{project_id}}.{{prod_dataset_name}}.{{public}}contracts_v3_contractv3` c
),

signals AS (
    -- 1) AUTO: sent to CP => pending_with counterparty
    SELECT 
        concat('audit_',a.id) AS audit_id,
        a.contract_id,
        a.created AS toggled_at,
        'COUNTER_PARTY' AS target_pending_with,
        'AUTO_SEND_TO_CP' AS reason,
        contract_kind,
        b.created_by_workspace_id as workspace_id
    FROM `{{project_id}}.{{prod_dataset_name}}.cron_audit_table` a
    join contract_base as b on a.contract_id = b.contract_id
    WHERE a.audit_type IN ('send-to-counterparty', 'send-to-counterparty-v2')

    union all

        SELECT
        concat('audit_',a.id) AS audit_id,
        a.contract_id,
        a.created AS toggled_at,
        'CREATOR_PARTY' AS target_pending_with,
        'EDITING_SESSION' AS reason,
        contract_kind,
        b.created_by_workspace_id 
    FROM `{{project_id}}.{{prod_dataset_name}}.cron_audit_table` a
    join contract_base as b on a.contract_id = b.contract_id
    WHERE a.audit_type IN ('web-dav-edit-session-started', 'oo-native-edit-session-started', 'user-joined-wopi-session', 'web-dav-edit-session-ended', 'oo-native-edit-session-ended', 'wopi-edit-session-ended', 'stale-edit-session-ended')
    
    union all 

    SELECT
        concat('manualtask_',a.id) AS audit_id,
        a.contract_id,
        a.created AS toggled_at,
        'CREATOR_PARTY' AS target_pending_with,
        case 
            when type = 'LEGAL_REVIEW' then 'REVIEW_ACTION'
            else 'EDITING_SESSION'
        end AS reason,
        b.contract_kind,
        b.created_by_workspace_id 
    FROM `{{project_id}}.{{prod_dataset_name}}.{{public}}contracts_v3_manualtaskdata` a
    join contract_base as b on a.contract_id = b.contract_id
    WHERE a.type IN ('LEGAL_REVIEW', 'USER_EDIT', 'WOPI_EDIT_SESSION')


    UNION ALL
    
    -- 2) AUTO: CP submitted questionnaire => pending_with creator/client
    SELECT
        concat('audit_',a.id) AS audit_id,
        a.contract_id,
        a.created AS toggled_at,
        'CREATOR_PARTY' AS target_pending_with,
        'AUTO_CP_QUESTIONNAIRE_SUBMITTED' AS reason,
        cb.contract_kind,
        cb.created_by_workspace_id 
    FROM `{{project_id}}.{{prod_dataset_name}}.cron_audit_table` a
    JOIN contract_base cb
      ON cb.contract_id = a.contract_id
    WHERE a.audit_type = 'questionnaire-submitted'
      AND a.created_by_workspace IS NOT NULL
      AND a.created_by_workspace <> cb.created_by_workspace_id
      
    UNION ALL
    
    -- 3) AUTO: CP uploaded version (received_from_workspace != creator ws) => creator/client
    SELECT
        concat('audit_',a.id) AS audit_id,
        a.contract_id,
        a.created AS toggled_at,
        'CREATOR_PARTY' AS target_pending_with,
        'AUTO_CP_UPLOAD_VERSION' AS reason,
        cb.contract_kind,
        cb.created_by_workspace_id 
    FROM `{{project_id}}.{{prod_dataset_name}}.cron_audit_table` a
    JOIN contract_base cb
      ON cb.contract_id = a.contract_id
    WHERE a.audit_type = 'ie-upload-contract-version'
      AND (
          pending_with_counterparty = 'true'
      )
    UNION ALL
    
    -- 4) MANUAL override audit
    SELECT
        concat('audit_',a.id) AS audit_id,
        a.contract_id,
        a.created AS toggled_at,
        CASE
            when pending_with_counterparty = 'true' THEN 'COUNTER_PARTY'
            when pending_with_counterparty = 'false' THEN 'CREATOR_PARTY'
            ELSE NULL
        END AS target_pending_with,
        'MANUAL_OVERRIDE' AS reason,
        b.contract_kind,
        b.created_by_workspace_id 
    FROM `{{project_id}}.{{prod_dataset_name}}.cron_audit_table` a
    join contract_base as b on a.contract_id = b.contract_id
    WHERE a.audit_type = 'pending-with-manual-override'
),


normalized AS (
    SELECT *
    FROM signals
    WHERE target_pending_with IS NOT NULL
),

ordered AS (
    SELECT
        n.*,
        LAG(n.target_pending_with) OVER (
            PARTITION BY n.contract_id
            ORDER BY n.toggled_at, n.audit_id
        ) AS previous_pending_with
    FROM normalized n
)


SELECT
    contract_id,
    toggled_at,
    previous_pending_with,
    target_pending_with AS new_pending_with,
    reason,
    contract_kind,
    workspace_id,
    audit_id
FROM ordered
-- keep only actual toggles (drop duplicate same-state signals)
WHERE previous_pending_with IS DISTINCT FROM target_pending_with
ORDER BY contract_id, toggled_at, audit_id