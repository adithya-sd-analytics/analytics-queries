
SELECT * FROM  
(
   (SELECT 
      id, coalesce(contract_id, entity_id) as contract_id, created, audit_type, created_by_id,
      json_extract_scalar(data, '$.pending_with_counter_party') as pending_with_counterparty, 
      json_extract_scalar(data, '$.on_hold') as on_hold,
      null as required_id, created_by_workspace,
      entity_id, entity_type
   FROM `{{project_id}}.{{prod_dataset_name}}.{{public}}contracts_v3_contractv3audit`
   WHERE audit_type in ('contract-voided','pending-with-manual-override', 'on-hold-status-update')
   AND (contract_id is not null or entity_type = 'CONTRACT')
   )
   
   UNION ALL
   
   (SELECT 
      cast(concat(id, safe_cast(json_extract_scalar(approvals, '$.id') as int64)) as int64) as id, 
      coalesce(contract_id, entity_id) as contract_id, created, audit_type, created_by_id,
      json_extract_scalar(data, '$.pending_with_counter_party') as pending_with_counterparty, 
      json_extract_scalar(data, '$.on_hold') as on_hold, 
      safe_cast(json_extract_scalar(approvals, '$.id') as int64) as required_approval_id,
      created_by_workspace,
      entity_id, entity_type
   FROM `{{project_id}}.{{prod_dataset_name}}.{{public}}contracts_v3_contractv3audit` as a, 
   UNNEST(json_extract_array(a.data, '$.approvals')) as approvals
   WHERE audit_type in ('contract-approval-sent', 'contract-approval-resent')
   AND (contract_id is not null or entity_type = 'CONTRACT')
   )

   UNION ALL

   (SELECT 
      cast(concat(id, safe_cast(json_extract_scalar(approvals, '$.id') as int64)) as int64) as id, 
      coalesce(contract_id, entity_id) as contract_id, created, audit_type, created_by_id,
      json_extract_scalar(data, '$.pending_with_counter_party') as pending_with_counterparty, 
      json_extract_scalar(data, '$.on_hold') as on_hold, 
      safe_cast(json_extract_scalar(approvals, '$.id') as int64) as required_approval_id,
      created_by_workspace,
      entity_id, entity_type
   FROM `{{project_id}}.{{prod_dataset_name}}.{{public}}contracts_v3_contractv3audit` as a, 
   UNNEST(json_extract_array(a.data, '$.sent_to')) as approvals
   WHERE audit_type in ('recipient-approver-email-sent')
   AND (contract_id is not null or entity_type = 'CONTRACT')
   )

   UNION ALL 

   (SELECT * FROM 
      (SELECT 
         cast(concat(id, coalesce(safe_cast(json_extract_scalar(json_element, '$.id') as int64), 123456)) as int64 ) as a, 
         coalesce(contract_id, entity_id) as contract_id, created, audit_type, created_by_id,
         json_extract_scalar(data, '$.pending_with_counter_party') as pending_with_counterparty, 
         json_extract_scalar(data, '$.on_hold') as on_hold, 
         safe_cast(json_extract_scalar(json_element, '$.id') as int64) as org_id,
         created_by_workspace,
         entity_id, entity_type
      FROM `{{project_id}}.{{prod_dataset_name}}.{{public}}contracts_v3_contractv3audit`, 
      UNNEST((json_extract_array(data, '$.sent_to'))) AS json_element
      WHERE audit_type in ('sent-for-signature-in-order', 'sent-for-signature')
      AND (contract_id is not null or entity_type = 'CONTRACT')
      )
   )
   
   UNION ALL
   
   (SELECT 
      id, coalesce(contract_id, entity_id) as contract_id, created, audit_type, created_by_id,
      json_extract_scalar(data, '$.pending_with_counter_party') as pending_with_counterparty, 
      concat( json_extract_scalar(data, '$.old_status'),'-', json_extract_scalar(data, '$.new_status') ) as on_hold,
      null as required_id, created_by_workspace,
      entity_id, entity_type
   FROM `{{project_id}}.{{prod_dataset_name}}.{{public}}contracts_v3_contractv3audit`
   WHERE audit_type = 'update-status'
     AND (json_extract_scalar(data, '$.new_status') = 'DELETED' or json_extract_scalar(data, '$.old_status') = 'DELETED')
     AND (json_extract_scalar(data, '$.new_status') != 'COMPLETED' and json_extract_scalar(data, '$.old_status') != 'COMPLETED')
     AND (json_extract_scalar(data, '$.new_status') != 'HARD_DELETED')
     AND (json_extract_scalar(data, '$.new_status') != json_extract_scalar(data, '$.old_status'))
     AND (contract_id is not null or entity_type = 'CONTRACT')
   )
   



UNION ALL

(SELECT 
   id, coalesce(contract_id, entity_id) as contract_id, created, audit_type, created_by_id,
   json_extract_scalar(data, '$.pending_with_counter_party') as pending_with_counterparty, 
   json_extract_scalar(data, '$.on_hold') as on_hold,
   null as required_id, created_by_workspace,
   entity_id, entity_type
FROM `{{project_id}}.{{prod_dataset_name}}.{{public}}contracts_v3_contractv3audit`
WHERE audit_type in (
   'send-to-counterparty-v2', 'send-to-counterparty', 'contract-moved-to-redlining', 'questionnaire-submitted',
   'web-dav-edit-session-started', 'oo-native-edit-session-started', 'user-joined-wopi-session', 
   'web-dav-edit-session-ended', 'oo-native-edit-session-ended', 'wopi-edit-session-ended', 'stale-edit-session-ended'
   )
   AND (contract_id is not null or entity_type = 'CONTRACT')
)

UNION ALL

(SELECT 
   id, coalesce(contract_id, entity_id) as contract_id, created, audit_type, created_by_id,
   json_extract_scalar(data, '$.pending_with_counter_party') as pending_with_counterparty, 
   concat( json_extract_scalar(data, '$.old_workflow_status'),'~', json_extract_scalar(data, '$.new_workflow_status') ) as on_hold,
   null as required_id, created_by_workspace,
   entity_id, entity_type
FROM `{{project_id}}.{{prod_dataset_name}}.{{public}}contracts_v3_contractv3audit`
WHERE audit_type in ('workflow-status-update')
  AND (contract_id is not null or entity_type = 'CONTRACT')
)

UNION ALL

(SELECT 
   id, coalesce(contract_id, entity_id) as contract_id, created, audit_type, created_by_id,
   CASE 
      WHEN REGEXP_CONTAINS(JSON_EXTRACT_SCALAR(a.data, '$.received_from_workspace.id'), r'^[0-9]+$')
      THEN cast(CAST(JSON_EXTRACT_SCALAR(a.data, '$.received_from_workspace.id') AS INT64) <> created_by_workspace as string)
      WHEN REGEXP_CONTAINS(JSON_EXTRACT_SCALAR(a.data, '$.received_from_workspace_id'), r'^[0-9]+$')
      THEN cast( CAST(JSON_EXTRACT_SCALAR(a.data, '$.received_from_workspace_id') AS INT64) <> created_by_workspace as string)
   END as pending_with_counterparty, 
   concat( json_extract_scalar(data, '$.old_workflow_status'),'~', json_extract_scalar(data, '$.new_workflow_status') ) as on_hold,
   null as required_id, created_by_workspace,
   entity_id, entity_type
FROM `{{project_id}}.{{prod_dataset_name}}.{{public}}contracts_v3_contractv3audit` as a
WHERE audit_type in ('ie-upload-contract-version')
  AND (contract_id is not null or entity_type = 'CONTRACT')
)

union all

(SELECT 
      id, coalesce(contract_id, entity_id) as contract_id, created, audit_type, created_by_id,
      json_extract_scalar(data, '$.pending_with_counter_party') as pending_with_counterparty, 
      concat(json_value(data, '$.reassigned_data[0].from_actor_type') ,'~',  json_value(data, '$.reassigned_data[0].to_actor_type')) as on_hold,
      cast(json_value(data, '$.approval.id') as int64) as required_id, created_by_workspace,

      
      entity_id, entity_type
   FROM `{{project_id}}.{{prod_dataset_name}}.{{public}}contracts_v3_contractv3audit`
   WHERE audit_type in ('approval-v5-reassigned')
   AND (contract_id is not null or entity_type = 'CONTRACT')
   )


union all 

(SELECT 
   id, null as contract_id, created, audit_type, created_by_id,
   json_extract_scalar(data, '$.pending_with_counter_party') as pending_with_counterparty, 
   concat( JSON_VALUE(data, '$.updated_fields.status.new_value') , '~',JSON_VALUE(data, '$.updated_fields.status.old_value')  ) as on_hold,
   null as required_id, created_by_workspace,
   entity_id, entity_type
FROM `{{project_id}}.{{prod_dataset_name}}.{{public}}contracts_v3_contractv3audit`
WHERE audit_type in ('legal-intake-updated')
  AND (entity_type = 'INTAKE')
  and JSON_VALUE(data, '$.updated_fields.status.new_value') is not null
)
)