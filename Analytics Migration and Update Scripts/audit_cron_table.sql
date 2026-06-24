select * from  
(
   (select id, contract_id, created, audit_type, created_by_id,json_extract_scalar(data, '$.pending_with_counter_party') as pending_with_counterparty, 
json_extract_scalar(data, '$.on_hold') as on_hold,
null as required_id, created_by_workspace
   from `{{project_id}}.{{prod_dataset_name}}.{{public}}contracts_v3_contractv3audit`
where audit_type in ('contract-voided','pending-with-manual-override', 'on-hold-status-update')
)
union all
(select cast(concat(id, safe_cast(json_extract_scalar(approvals, '$.id') as int64)) as int64) as id, contract_id, created, audit_type, created_by_id,json_extract_scalar(data, '$.pending_with_counter_party') as pending_with_counterparty, 
json_extract_scalar(data, '$.on_hold') as on_hold, 
    safe_cast(json_extract_scalar(approvals, '$.id') as int64) as required_approval_id,
created_by_workspace
   from `{{project_id}}.{{prod_dataset_name}}.{{public}}contracts_v3_contractv3audit`as a, unnest(json_extract_array(a.data, '$.approvals')) as approvals
where audit_type in ('contract-approval-sent', 'contract-approval-resent')
)

union all
(select cast(concat(id, safe_cast(json_extract_scalar(approvals, '$.id') as int64)) as int64) as id, contract_id, created, audit_type, created_by_id,json_extract_scalar(data, '$.pending_with_counter_party') as pending_with_counterparty, 
json_extract_scalar(data, '$.on_hold') as on_hold, 
    safe_cast(json_extract_scalar(approvals, '$.id') as int64) as required_approval_id,
created_by_workspace
   from `{{project_id}}.{{prod_dataset_name}}.{{public}}contracts_v3_contractv3audit`as a, unnest(json_extract_array(a.data, '$.sent_to')) as approvals
where audit_type in ('recipient-approver-email-sent')
)

union all 
(select * from 
   (select cast(concat(id, coalesce(safe_cast(json_extract_scalar(json_element, '$.id') as int64), 123456)) as int64 )as a, contract_id, created, audit_type, created_by_id,json_extract_scalar(data, '$.pending_with_counter_party') as pending_with_counterparty, 
   json_extract_scalar(data, '$.on_hold') as on_hold, 
   safe_cast(json_extract_scalar(json_element, '$.id') as int64) as org_id,
   created_by_workspace 
   from `{{project_id}}.{{prod_dataset_name}}.{{public}}contracts_v3_contractv3audit`, UNNEST((json_extract_array(data, '$.sent_to'))) AS json_element
   where audit_type in ('sent-for-signature-in-order', 'sent-for-signature')
   )
)
union all
(
   select id, contract_id, created, audit_type, created_by_id,json_extract_scalar(data, '$.pending_with_counter_party') as pending_with_counterparty, 
   concat( json_extract_scalar(data, '$.old_status'),'-', json_extract_scalar(data, '$.new_status') ) as on_hold,
   null as required_id, created_by_workspace
   from `{{project_id}}.{{prod_dataset_name}}.{{public}}contracts_v3_contractv3audit`
   where audit_type = 'update-status'
   and (json_extract_scalar(data, '$.new_status') = 'DELETED' or json_extract_scalar(data, '$.old_status') = 'DELETED')
   and (json_extract_scalar(data, '$.new_status') != 'COMPLETED' and json_extract_scalar(data, '$.old_status') != 'COMPLETED')
   and (json_extract_scalar(data, '$.new_status') != 'HARD_DELETED')
   and (json_extract_scalar(data, '$.new_status') != json_extract_scalar(data, '$.old_status'))

)

)
union all
 (select id, contract_id, created, audit_type, created_by_id,json_extract_scalar(data, '$.pending_with_counter_party') as pending_with_counterparty, 
json_extract_scalar(data, '$.on_hold') as on_hold,
null as required_id, created_by_workspace
   from `{{project_id}}.{{prod_dataset_name}}.{{public}}contracts_v3_contractv3audit`
where audit_type in ('send-to-counterparty-v2', 'send-to-counterparty', 'contract-moved-to-redlining', 'questionnaire-submitted',
'web-dav-edit-session-started', 'oo-native-edit-session-started', 'user-joined-wopi-session', 'web-dav-edit-session-ended', 'oo-native-edit-session-ended', 'wopi-edit-session-ended', 'stale-edit-session-ended'
)
)

union all
(
   select id, contract_id, created, audit_type, created_by_id,json_extract_scalar(data, '$.pending_with_counter_party') as pending_with_counterparty, 
   concat( json_extract_scalar(data, '$.old_workflow_status'),'~', json_extract_scalar(data, '$.new_workflow_status') ) as on_hold,
   null as required_id, created_by_workspace
   from `{{project_id}}.{{prod_dataset_name}}.{{public}}contracts_v3_contractv3audit`
   where audit_type in ('workflow-status-update')
   and contract_id is not null

)

union all
(
   select id, contract_id, created, audit_type, created_by_id,
   case when 
      
      REGEXP_CONTAINS(JSON_EXTRACT_SCALAR(a.data, '$.received_from_workspace.id'), r'^[0-9]+$')
            then cast(CAST(JSON_EXTRACT_SCALAR(a.data, '$.received_from_workspace.id') AS INT64) <> created_by_workspace as string)
          
   when
            REGEXP_CONTAINS(JSON_EXTRACT_SCALAR(a.data, '$.received_from_workspace_id'), r'^[0-9]+$')
            then cast( CAST(JSON_EXTRACT_SCALAR(a.data, '$.received_from_workspace_id') AS INT64) <> created_by_workspace as string)
          
   end as pending_with_counterparty, 
   concat( json_extract_scalar(data, '$.old_workflow_status'),'~', json_extract_scalar(data, '$.new_workflow_status') ) as on_hold,
   null as required_id, created_by_workspace
   from `{{project_id}}.{{prod_dataset_name}}.{{public}}contracts_v3_contractv3audit` as a
   where audit_type in ('ie-upload-contract-version')
   and contract_id is not null

)

