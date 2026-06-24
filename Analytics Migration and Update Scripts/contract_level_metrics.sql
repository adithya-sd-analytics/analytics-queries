with 

on_hold as 
(SELECT contract_id, on_hold FROM `{{project_id}}.{{prod_dataset_name}}.{{public}}contracts_v3_contractprofile` as a 
where on_hold = true),

all_con as (
  select * ,
   case 
      when status in ('VOIDED') then 'Voided'
      when on_hold = true then 'On Hold'
      when workflow_status not in ('COMPLETED', 'DRAFT', 'SIGN' ) then 'Redlining'
      when workflow_status = 'COMPLETED' then 'Executed'
      else initcap(workflow_status)
    end as workflow_status_new

  from `{{project_id}}.{{prod_dataset_name}}.{{public}}contracts_v3_contractv3` as a
  left join on_hold as b on a.id = b.contract_id
  where 
  status not in ( 'HARD_DELETED')
  and 
  contract_kind not in ('UPLOAD_EXECUTED')
  -- and created_by_workspace_id = prod_india_id
  -- and (created_by_id not in (select user_id from spotdraft_users) or created_by_workspace_id = 2633)
  order by id desc
),  


contract_stages as (

select a.contract_id, ac.created as con_created, min(case when a.status = 'REDLINING' then a.created end) Redlining_starts, 
max(case when ac.workflow_status in ('SIGN', 'COMPLETED', 'COMPLETING') and a.status = 'SIGN' then a.created end) sign_starts,
ac.execution_date as executed_date,
max(case when a.status = 'VOIDED' then a.created end) as contract_voided_on,
ac.contract_kind,
contract_template_id, 
workflow_status, 
ac.created_by_workspace_id, 
contract_type_id 
from `{{project_id}}.{{prod_dataset_name}}.state_changes_table` as a
join all_con as ac on a.contract_id = ac.id
group by 1, 2, 5, 7, 8, 9, 10, 11

),
    
redlining_cons as (
  select 
    contract_id as id 
  from contract_stages 
  where redlining_starts is not null 
),



redlining_events as
(select * from
(
  select 
  case when pending_with = 'COUNTER_PARTY' then  concat('redlining_', contract_id,'_CP_', row_number() over(partition by contract_id, pending_with order by created))
  when pending_with = 'CREATOR_PARTY' then  concat('redlining_', contract_id,'_Client_', row_number() over(partition by contract_id, pending_with order by created))
  when pending_with = 'SIGN_STAGE' then concat('redlining_', contract_id,'_Signstage_', row_number() over(partition by contract_id, pending_with order by created))

  end as uu_id,
  contract_id, created_by_workspace_id,   
case 
  when pending_with = 'COUNTER_PARTY' then 'Counterparty Redlining'
  when pending_with = 'CREATOR_PARTY' then  'Creator Party Redlining'
  when pending_with = 'SIGN_STAGE' then 'Signstage Negotiation'
end as cat_1,
case 
  when pending_with = 'COUNTER_PARTY' then concat('CP Round ', row_number() over(partition by contract_id, pending_with order by created))  
  when pending_with = 'CREATOR_PARTY' then  concat('Client Round ', row_number() over(partition by contract_id, pending_with order by created))
  when pending_with = 'SIGN_STAGE' then concat('Signstage round ', row_number() over(partition by contract_id, pending_with order by created))
end as cat_2, status,
created as start_timestamp, next_stage as end_timestamp, end_time as end_timestamp_current,
timestamp_diff(end_time, created, second) as time_spent


from
  (select *, 
  case when row_number() over(partition by contract_id order by created desc) = 1 and pending_with not in ('END', 'SIGN_STAGE') then current_timestamp
  else lead(created) over(partition by contract_id order by created) 
  end as end_time,
  case when row_number() over(partition by contract_id order by created desc) = 1 and pending_with not in ('END', 'SIGN_STAGE') then 'Pending'
  else 'Completed'
  end as status,

  lead(created) over(partition by contract_id order by created) as next_stage,  row_number() over(partition by contract_id order by created desc) as rn from 
    
    (select new_pending_with, previous_pending_with, reason, contract_kind, pending_with, created , contract_id , stage_counts,
    lag(pending_with) over(partition by contract_id order by created) as previous_pending, created_by_workspace_id
    from
      (select a.*,created_by_workspace_id,
      case 
      when source_logs =  'turn_logs' then new_pending_with
      when reason = 'convert_to_editable' then 'CREATOR_PARTY'
      when new_pending_with = 'SIGN' then 'SIGN_STAGE'
      when new_pending_with in ('VOIDED', 'EXECUTED') then 'END'
      when new_pending_with = 'REDLINING' and previous_pending_with = 'SIGN' then 'CREATOR_PARTY'
      when reason = 'CONTRACT_CREATED' and a.contract_kind in ('UPLOAD_EDITABLE') then 'CREATOR_PARTY'
      when a.contract_kind in ('TEMPLATE', 'TEMPLATE_EDITABLE') and new_pending_with = 'REDLINING' and previous_pending_with = 'DRAFT' then 'COUNTER_PARTY'
      when a.contract_kind = 'EXPRESS_TEMPLATE' and reason = 'CONTRACT_CREATED' then 'COUNTER_PARTY'
      end as pending_with,

      row_number() over(partition by a.contract_id order by a.created, new_pending_with desc) as rn,
      count(*) over(partition by a.contract_id) as stage_counts
      from
        (
          select contract_id, toggled_at as created, new_pending_with, previous_pending_with, reason , contract_kind, null as stage_order , 
          null as status_order_rev, 'turn_logs' as source_logs  
          from `{{project_id}}.{{prod_dataset_name}}.turn_logs_table`

        union all
          select contract_id, created, status, previous_status, reason, contract_kind , status_order, status_order_rev, 'state_change' as source_logs
          from `{{project_id}}.{{prod_dataset_name}}.state_changes_table`

        ) as a
      join contract_stages as b on a.contract_id = b.contract_id and 
      a.created >= b.Redlining_starts 
      and (TIMESTAMP_SUB(a.created, INTERVAL 2 SECOND) <= sign_starts
      or a.created <= coalesce( contract_voided_on, executed_date,  current_timestamp)
      
      )

      order by created )

    )
  where (pending_with != previous_pending or previous_pending is null)
  order by stage_counts desc, contract_id desc, created)
where 
end_time is not null
order by stage_counts desc, contract_id, created

)where cat_1 is not null
),


draft_events as 
(select concat('draft_', contract_id) as uu_id, contract_id, created_by_workspace_id as workspace_id,
 'Draft' as cat_1, 
 
 case when coalesce(redlining_starts, sign_starts, executed_date, contract_voided_on) is null then 'Draft Pending' else 'Draft Completed' end as cat_2,  
 
 case when coalesce(redlining_starts, sign_starts, executed_date, contract_voided_on)  is null then 'Pending' else 'Completed' end as status, 
con_created as start_timestamp, coalesce(redlining_starts, sign_starts, executed_date, contract_voided_on)  as end_timestamp, coalesce(redlining_starts, sign_starts, executed_date, contract_voided_on, current_timestamp) as end_timestamp_current,
timestamp_diff( coalesce(redlining_starts, sign_starts, executed_date, contract_voided_on, current_timestamp), con_created, second) as time_spent, 
  from contract_stages
where (con_created != redlining_starts or redlining_starts is null)
and contract_kind like 'TEMPLATE%' 
),


on_hold_tab as 
(
select contract_id, audit_type, created as on_hold_start, next_ts as on_hold_ends, coalesce(next_ts, current_timestamp) as on_hold_ends_current from 
  (

  select count(*) over(partition by contract_id), *,
  lead(created) over(partition by contract_id, audit_type order by created) as next_ts,
  lead(on_hold) over(partition by contract_id, audit_type order by created) as next_on_hold
  from
    (select contract_id, created, audit_type, on_hold , 
    lag(on_hold) over(partition by contract_id, audit_type order by created) as pre_on_hold , created_by_workspace,
    on_hold = lag(on_hold) over(partition by contract_id, audit_type order by created) as repeats
    from `{{project_id}}.{{prod_dataset_name}}.cron_audit_table`
    where 
    audit_type in ( 'on-hold-status-update')
    )
  where repeats = false or repeats is null -- removing repeated entries
) 
where on_hold = 'true' -- logic for starting when on hold is true and the next event is either null or is taken off hold
and (next_on_hold = 'false' or next_on_hold is null)
),


deleted_tabs as
(select count(*) over(partition by contract_id), contract_id, created, deleted_end, status, end_status, 
timestamp_diff(deleted_end, created, second) as time_spent

 from
  (select *, 
  lead(status) over(partition by contract_id order by created) as end_status,
  lead(created) over(partition by contract_id order by created) as deleted_end
  from
    (select  *, 
    split(on_hold, '-')[1] as status,
    on_hold = lag(on_hold) over(partition by contract_id order by created) as repeats
    from `{{project_id}}.{{prod_dataset_name}}.cron_audit_table`
    where audit_type in ('update-status') 
    )
  where repeats = false or repeats is null -- removing repeated entries
  
  )
where status = 'DELETED'
and coalesce(timestamp_diff(deleted_end, created, second), 61) >= 60 -- removing deleted stages less than a minute
order by 1 desc, contract_id desc, created
),

sent_for_sign as 
(select * from 
  (select *, row_number() over(partition by required_id order by created desc) as rn from `{{project_id}}.{{prod_dataset_name}}.cron_audit_table`  
where audit_type in ('sent-for-signature-in-order', 'sent-for-signature'))
where rn = 1 ),

signs_completed_on as
(select * from 
(select *, row_number() over(partition by sign_recipient_id order by created desc) as rn from `{{project_id}}.{{prod_dataset_name}}.{{public}}contracts_signatorysignaturedata`
where is_success
and is_revoked = false
and user_agent != 'Auto Added by SpotDraft'
order by 2 desc)
where rn = 1),



field_created as 
(select contract_id, max(modified) as last_updated from `{{project_id}}.{{prod_dataset_name}}.{{public}}contracts_v3_contractsignaturesetup`
where is_deleted = false and is_completed = true and sent_for_signature = true
group by 1),

all_signs as 
(select a.id, a.contract_id,a.org_user_id, 
a.created as signatory_created_on, 
case when a.contract_role = 'CONTRACTOR' then com.name
when contract_role = 'SUBSCRIBER' then com.name
end as contract_role,

case when a.contract_role = 'CONTRACTOR' then 'Creator Party'
when contract_role = 'SUBSCRIBER' then 'Counterparty'
end as new_contract_role,

a.created_by_workspace,
d.recipient_order, d.created as sign_recipient_created,
f.last_updated as field_updated_last,
b.created as sign_sent_on, c.created as signed_on 
from `{{project_id}}.{{prod_dataset_name}}.{{public}}contracts_v3_contractv3signatory` as a 
left join sent_for_sign as b on a.id = b.required_id
left join signs_completed_on as c on a.sign_recipient_id = c.sign_recipient_id
join `{{project_id}}.{{prod_dataset_name}}.{{public}}contracts_v3_signrecipient` as d on a.sign_recipient_id = d.id
left join field_created as f on a.contract_id = f.contract_id
left join `{{project_id}}.{{prod_dataset_name}}.{{public}}sd_organizations_organizationuser` as org on org.id = a.org_user_id
left join `{{project_id}}.{{prod_dataset_name}}.{{public}}sd_organizations_companyprofile` as com on org.organization_id = com.owner_id

where a.is_deleted = false
order by signatory_created_on desc
),

final_all_sign as
(select a.*, 
case -- logic for using the last signed on time when sign_sent_on is null
when timestamp_diff(sign_starts, sign_sent_on, second) > 1 and signed_on is null then null
when signed_on is not null and sign_sent_on is null then coalesce(lag(signed_on) over(partition by a.contract_id order by recipient_order), field_updated_last, sign_starts) 
else sign_sent_on
end as sign_sent_on_final,
from all_signs as a
left join contract_stages as cs on cs.contract_id = a.contract_id
),

final_tab as
(select distinct a.id as signatory_id, 
a.contract_id, a.org_user_id, a.signatory_created_on,
contract_role as signatory_party, b.created_by_workspace_id as workspace_id,
recipient_order as sign_order,
sign_starts,
sign_sent_on_final as sign_sent_on,
signed_on, new_contract_role,
case when (sign_sent_on_final) is null then 'Sign email not sent'
when (sign_sent_on_final) is not null and a.signed_on is null and b.workflow_status != 'Executed'  then 'Pending'
when signed_on is not null then 'Completed'
end as sign_status,
round(timestamp_diff(signed_on, sign_sent_on_final, second)/3600, 2) as time_to_sign_hours,
round(timestamp_diff(signed_on, sign_sent_on_final, second)/60, 2) as time_to_sign_mins,
case 
      when b.contract_kind in ('TEMPLATE', 'TEMPLATE_EDITABLE', 'EXPRESS_TEMPLATE') then 'Template Contracts'
      when b.contract_kind in ('UPLOAD_EXECUTED') then 'Externally Executed Contracts'
      when b.Contract_kind in ('UPLOAD_SIGN') then 'Sent for Signature'
      when b.Contract_kind in ('CLICKWRAP') then 'Clickwrap Contracts'
      else 'Uploaded for review'
  end as contract_kind,

concat(d.first_name, ' ',d.last_name) as signatory,
date(b.created) as con_created,
date(b.execution_date) as executed_on,

b.workflow_status_new as workflow_status
from final_all_sign as a 
join all_con as b on a.contract_id = b.id 
join `{{project_id}}.{{prod_dataset_name}}.{{public}}sd_organizations_organizationuser` as d 
on a.org_user_id = d.id

left join contract_stages as cs on cs.contract_id = a.contract_id
),

sign_events as
(select a.* from 
(select concat('signatory_',signatory_id) as uu_id ,contract_id, workspace_id,   'Signing' as cat_1, concat(signatory_party, ': ',signatory), sign_status, 
sign_sent_on , signed_on , coalesce(signed_on, current_timestamp) as end_timestamp_current  , timestamp_diff(coalesce(signed_on, current_timestamp), sign_sent_on, second) as time_spent, new_contract_role
from final_tab
where sign_status != 'Sign email not sent'
order by 1 desc, contract_id) as a
join (select * from contract_stages
where sign_starts is not null
) as b on a.contract_id = b.contract_id and a.sign_sent_on >= b.sign_starts),


sign_setup_events as
(select concat('sign_setup_',b.contract_id) as uuid, b.contract_id, b.created_by_workspace_id,'Sign Setup' as cat_1, 'Sign Setup' as cat_2, case when a.sign_first_sent is null then 'Pending' else 'Completed' end as status, 
 b.sign_starts as start_timestamp, a.sign_first_sent as end_timestamp , coalesce(sign_first_sent, current_timestamp) end_timestamp_current, 


greatest(timestamp_diff(coalesce(sign_first_sent, current_timestamp), sign_starts, second), 0) as time_spent
from 
(select contract_id, min(sign_sent_on) as sign_first_sent from sign_events
group by 1) as a 
right join contract_stages as b on a.contract_id = b.contract_id
where sign_starts is not null
order by sign_starts desc),
 

raw_approval_timeline as (
 select *
 from (
     select 
         cast(id as string) as id, 
         required_approval_id,
         contract_id, 
         created, 
         status, 
         notes, 
         created_by_org_user_id 
    from `{{project_id}}.{{prod_dataset_name}}.{{public}}contracts_v3_contractapprovalv2`
    where required_approval_id is not null

 ) as a
 union all (
    select 
        cast(a.id as string) as id,
        a.required_id as required_approval_id,  
        a.contract_id, 
        a.created,
        'Approval Request Sent' as action, 
        '', 
        b.id as user_id
    from `{{project_id}}.{{prod_dataset_name}}.cron_audit_table` as a
    left join `{{project_id}}.{{prod_dataset_name}}.{{public}}sd_organizations_organizationuser` as b on a.created_by_id = b.user_id
    where audit_type in ('contract-approval-sent', 'contract-approval-resent')
    -- and a.created_by_id not in (select user_id from spotdraft_users)
    -- and created_by_workspace = @workspace_id
) 
order by 2, 4
),

cleaned_app_timeline as (
  select * 
  from (
    select *, 
    lag(status) over(partition by contract_id, required_approval_id order by created) as test, 
    row_number() over(partition by contract_id, required_approval_id order by created desc) as rn
    from raw_approval_timeline
  ) as a 
  where (status != test or test is null)
  or rn = 1
  order by required_approval_id, created
), 


app_data_with_time as (
  select 
    *, 
    row_number() over(partition by contract_id, required_approval_id order by app_sent_on) as app_no,
    row_number() over(partition by contract_id, required_approval_id order by app_sent_on desc) as app_no_rev
  from (
    select id, required_approval_id ,contract_id, created as app_sent_on, status, created_by_org_user_id as requestor_id,
    lead(status) over(partition by contract_id, required_approval_id order by created) as next_event, 
    lead(created) over(partition by contract_id, required_approval_id order by created) as next_timestamp, 
    lead(created_by_org_user_id) over(partition by contract_id, required_approval_id order by created) as approver_id,
    round(timestamp_diff(lead(created) over(partition by contract_id, required_approval_id order by created), created, second) / 3600, 3) as Approval_time_hours
    from cleaned_app_timeline
  ) as a 
  where status = 'Approval Request Sent'
),


v4_pending_with as 
(select a.id, 
coalesce(concat(b.first_name, ' ',b.last_name) , concat('Team: ',c.name,' (POC: ', d.first_name, ' ',d.last_name, ')')) as pending_name 
from `{{project_id}}.{{prod_dataset_name}}.{{public}}contracts_v3_contractrequiredapprovalv2` as a 
left join `{{project_id}}.{{prod_dataset_name}}.{{public}}sd_organizations_organizationuser` as b on a.org_user_id = b.id
left join `{{project_id}}.{{prod_dataset_name}}.{{public}}sd_auth_role` as c on a.role_id = c.id
left join `{{project_id}}.{{prod_dataset_name}}.{{public}}sd_organizations_organizationuser` as d on c.point_of_contact_id = d.id
order by 2 desc),


sign_app_data as (
(select distinct a.id as required_id, 
    concat(b.id,'_',a.id) as uniqueid,
    b.created_by_id as sent_by_user_id, 
    concat(d.first_name, ' ', d.last_name) as sent_by, 
    a.contract_id, 
    created_by_workspace,
    b.req_order,
    b.created as app_sent, 
    b.next_request,
    c.created as app_finished, a.org_user_id as approver, concat(e.first_name, ' ', e.last_name) as approved_by,
    case 
      when f.id != created_by_workspace then 'Signatory Approval - Counterparty' else 'Signatory Approval - Internal' 
    end as cp_approv,
    timestamp_diff(c.created, b.created, second ) as time_spent,
    case 
      when c.created is null then 1 else 0
    end as pending
      from `{{project_id}}.{{prod_dataset_name}}.{{public}}contracts_v3_signrecipient` as a
      join
      (select *, lead(created) over(partition by required_id order by created) as next_request, row_number() over(partition by required_id order by created desc) as req_order 
        from `{{project_id}}.{{prod_dataset_name}}.cron_audit_table` 
        where audit_type = 'recipient-approver-email-sent'
      )as b
    on a.id = b.required_id 
      left join (select distinct created, recipient_id, is_success, is_rejected,  created_by_workspace_id
      from `{{project_id}}.{{prod_dataset_name}}.{{public}}contracts_v3_recipientaction`
      ) 
      as c on a.id = c.recipient_id and b.created <= c.created and (b.next_request is null or (b.next_request > c.created)) 
      join `{{project_id}}.{{prod_dataset_name}}.{{public}}sd_organizations_organizationuser` as d on b.created_by_id = d.user_id
      join `{{project_id}}.{{prod_dataset_name}}.{{public}}sd_organizations_organizationuser` as e on a.org_user_id = e.id
      join `{{project_id}}.{{prod_dataset_name}}.{{public}}sd_organizations_companyprofile` as f on f.owner_id = e.organization_id
    where a.is_deleted = false
    -- and b.created_by_id not in (select user_id from spotdraft_users)
    )
),

v5_cleaned as 
(select *, 
row_number() over(partition by contract_id, required_approval_id order by action_performed_at) as app_no,
row_number() over(partition by contract_id, required_approval_id order by action_performed_at desc) as app_no_rev
 from 
(select *, lead(action) over(partition by required_approval_id order by action_performed_at) as next_event,
lead(action_performed_at) over(partition by required_approval_id order by action_performed_at) as next_timestamp, 
timestamp_diff( lead(action_performed_at) over(partition by required_approval_id order by action_performed_at), action_performed_at, second )/3600.0 as Approval_time_hours, 
lead(action_performed_by_id) over(partition by required_approval_id order by action_performed_at) as approver_id,
action_performed_by_id as requestor_id, action_performed_at as app_sent_on
from 
(select a.id as required_approval_id, a.tenant_workspace_id, a.name, a.current_state, linked_to_entity_id as contract_id, a.created_by_org_user_id , 
b.id, b.action, 
case 
when action in ('instate', 'trigger', 'resend') then 'sent' 
when action in ('skip', 'approve', 'reject') then 'action'
else null 
end as ab,
b.action_performed_at, b.action_performed_by_id, action_reason, 
lag(case 
when action in ('instate', 'trigger', 'resend') then 'sent' 
when action in ('skip', 'approve', 'reject') then 'action'
else null 
end) over(partition by a.id order by action_performed_at) as next_ab
from `{{project_id}}.{{prod_dataset_name}}.{{public}}approvals_v5_approvalv5` a 
join `{{project_id}}.{{prod_dataset_name}}.{{public}}approvals_v5_approvalv5actions` b on a.id = b.approval_id
where linked_to_entity_type  = 'CONTRACT'
and a.is_deleted = false
and b.is_deleted = false
and a.is_required = true
and a.breakpoint_type = 'NONE'
and current_state not in ('CREATED')
and action != 'reset'
and (a.approval_type != 'REVIEW' or approval_type is null)
order by a.id, b.created)
where ab != next_ab or next_ab is null) as a 
where ab = 'sent'),

v5_pending_with as 
(select a.approval_id, 
coalesce(concat(b.first_name, ' ',b.last_name) , concat('Team: ',c.name,' (POC: ', d.first_name, ' ',d.last_name, ')')) as pending_name
from `{{project_id}}.{{prod_dataset_name}}.{{public}}approvals_v5_approvalv5actormapping` as a 
left join `{{project_id}}.{{prod_dataset_name}}.{{public}}sd_organizations_organizationuser` as b on cast(a.actor_id as int64) = b.id and 
a.actor_type = 'ORGANIZATION_USER'
left join `{{project_id}}.{{prod_dataset_name}}.{{public}}sd_auth_role` as c on cast(a.actor_id as int64) = c.id and 
a.actor_type = 'ROLE'
left join `{{project_id}}.{{prod_dataset_name}}.{{public}}sd_organizations_organizationuser` as d on c.point_of_contact_id = d.id 
where a.is_deleted = false
and actor_relation_type = 'APPROVER'
),


app_v4_events as
(select concat('app_v4_', a.contract_id, a.required_approval_id, '_', row_number() over(partition by a.contract_id, a.required_approval_id order by app_sent_on) ) as uu_id, a.contract_id, d.created_by_workspace_id, coalesce(e.approval_name, 'Ad-hoc') as approval_name, coalesce(concat(h.first_name,' ' ,h.last_name), j.pending_name) as approver_name , 
case when next_event = 'Approval Request Sent' then 'Pending' else
initcap(coalesce(next_event, 'PENDING')) end as Approval_status,


a.app_sent_on, next_timestamp,    coalesce(next_timestamp, current_timestamp) as end_timestamp_current , timestamp_diff(next_timestamp, a.app_sent_on, second) as time_spent
from app_data_with_time as a
  left join `{{project_id}}.{{prod_dataset_name}}.{{public}}contracts_v3_contractrequiredapprovalv2` as d --joins for approval name
  on a.required_approval_id = d.id
  left join `{{project_id}}.{{prod_dataset_name}}.{{public}}contracts_v3_contractrequiredfullapproval` as e  --joins for approval name
  on d.required_approval_id = e.id
  left join v4_pending_with as j on a.required_approval_id = j.id
  left join `{{project_id}}.{{prod_dataset_name}}.{{public}}sd_organizations_organizationuser` as h --table for user names
  on a.approver_id = h.id
),

app_v5_events as 
(
select concat('app_v5_', a.contract_id, a.required_approval_id,'_', row_number() over(partition by a.contract_id, a.required_approval_id order by app_sent_on) ) as uuid, 
contract_id, tenant_workspace_id, name,  
coalesce(concat(h.first_name,' ' ,h.last_name), j.pending_name) as approver,  
initcap(coalesce(case when(next_event) = 'approve' then 'Approved' 
                      when next_event = 'skip' then 'Skipped' 
                      when next_event = 'reject' then 'Rejected' 
                      end , 'Pending')) as approval_status ,
app_sent_on, next_timestamp, coalesce(next_timestamp, current_timestamp), timestamp_diff(next_timestamp, app_sent_on, second) as time_spent

from v5_cleaned as a
  left join `{{project_id}}.{{prod_dataset_name}}.{{public}}sd_organizations_organizationuser` as h --table for user names
  on a.approver_id = h.id
  left join v5_pending_with as j on a.required_approval_id = j.approval_id
  ),


sign_app_events as
(select concat('sign_app_',uniqueid) as uuid, contract_id, created_by_workspace as workspace_id,  concat(cp_approv, ' ',approved_by) as cat_1, approved_by as cat_2, case when app_finished is not null then 'Approved' else 'Pending' end as approval_status,
 app_sent, app_finished, coalesce(app_finished, current_timestamp), timestamp_diff(app_finished, app_sent, second) as timespent
  from sign_app_data
  ),




v5_pending as
(select a.approval_id,
coalesce(b.id, d.id) as pending_org_id, 
coalesce(concat(b.first_name, ' ',b.last_name) , concat('Team: ',c.name,' (POC: ', d.first_name, ' ',d.last_name, ')')) as pending_name,
coalesce(concat(b.first_name,' ', b.last_name), concat(d.first_name, ' ',d.last_name)) as reviewer, coalesce(b.user_email, d.user_email) as reviewer_email

from `{{project_id}}.{{prod_dataset_name}}.{{public}}approvals_v5_approvalv5actormapping` as a 
left join `{{project_id}}.{{prod_dataset_name}}.{{public}}sd_organizations_organizationuser` as b on cast(a.actor_id as int64) = b.id and 
a.actor_type = 'ORGANIZATION_USER'
left join `{{project_id}}.{{prod_dataset_name}}.{{public}}sd_auth_role` as c on cast(a.actor_id as int64) = c.id and 
a.actor_type = 'ROLE'
left join `{{project_id}}.{{prod_dataset_name}}.{{public}}sd_organizations_organizationuser` as d on c.point_of_contact_id = d.id 
where a.is_deleted = false
and actor_relation_type = 'APPROVER'
),


review_data_tab as (
  select 
    mt.*, 
    concat(first_name, ' ',last_name) as user_name 
  from `{{project_id}}.{{prod_dataset_name}}.{{public}}contracts_v3_manualtaskdata` as mt
  left join `{{project_id}}.{{prod_dataset_name}}.{{public}}sd_organizations_organizationuser` as org 
  on mt.created_by_org_user_id = org.id
  where contract_id in (select id from all_con)
  and type = 'LEGAL_REVIEW'
),

old_review_data_formatted as (
  select 
    aa.contract_id, 
      cast(aa.parent_manual_task_id as string) parent_manual_task_id, 
      aa.Review_request_Notes,
      aa.Review_requested_on,
      aa.Review_requested_by, 
      aa.role_id ,
    'Ad-hoc Review' as review_name,
    row_number() over(partition by aa.contract_id order by aa.Review_requested_on) as contract_review_instance,
    aa.created_by_workspace, 
    bb.Review_assigned_on, 
    concat(org.first_name,' ' ,org.last_name) as Reviewer_name, org.user_email as Legal_reviewer, 
    concat(org2.first_name,' ' ,org2.last_name) as Assigned_by_name, org2.user_email as Assigned_by, 
    cc.Review_started_on, dd.Review_completed_on, dd.Update_notes,
    case 
      when role_id is null then 'Indivual' 
      else 'Role' 
    end as review_role,
    org.id as legal_reviewer_id
  from (
    select 
      contract_id, parent_manual_task_id, description as Review_request_Notes, created as Review_requested_on, Review_requested_by, role_id , created_by_workspace
    from (
      select 
        contract_id, 
        created, 
        user_name as Review_requested_by,
        min(created) over(partition by parent_manual_task_id) as min, 
        description, status, assignee_org_user_id as Legal_reviewer, created_by_org_user_id as Assigned_by, parent_manual_task_id, role_id,
        created_by_workspace
      from review_data_tab 
      where status = 'PENDING') as a
      where created = min
  ) as aa
  left join (
    select 
      contract_id, parent_manual_task_id, created as Review_assigned_on, Legal_reviewer, Assigned_by  
    from (
      select 
        contract_id, created, min(created) over(partition by parent_manual_task_id) as min, 
        description, status, assignee_org_user_id as Legal_reviewer, created_by_org_user_id as Assigned_by, parent_manual_task_id
      from review_data_tab 
      where status = 'PENDING' 
      and assignee_org_user_id is not null
      and role_id is not null
    ) as b
    where created = min
  ) as bb
  on aa.contract_id = bb.contract_id and aa.parent_manual_task_id = bb.parent_manual_task_id
  left join (
    select 
      contract_id, parent_manual_task_id, created as Review_started_on 
    from (
      select 
        contract_id, created, max(created) over(partition by parent_manual_task_id) as max, description, status, 
        assignee_org_user_id as Legal_reviewer, created_by_org_user_id as Assigned_by,parent_manual_task_id
      from review_data_tab 
      where status = 'IN_PROGRESS' 
      and assignee_org_user_id is not null
    ) as b
    where created = max
  ) as cc
  on aa.contract_id = cc.contract_id and aa.parent_manual_task_id = cc.parent_manual_task_id
  left join (
    select 
    contract_id, parent_manual_task_id, Update_notes,created as Review_completed_on, Legal_reviewer, Assigned_by 
    from (
      select 
        contract_id, created, max(created) over(partition by parent_manual_task_id) as max, Update_notes, status, 
        assignee_org_user_id as Legal_reviewer,created_by_org_user_id as Assigned_by, parent_manual_task_id
      from review_data_tab 
      where status in ('COMPLETED', 'FORCE_COMPLETED') 
      -- and assignee_org_user_id is not null
    ) as b
    where created = max
  ) as dd
  on aa.contract_id = dd.contract_id and aa.parent_manual_task_id = dd.parent_manual_task_id
  left join (
    select 
    contract_id, parent_manual_task_id, Update_notes,created as Review_completed_on,  Legal_reviewer, Assigned_by 
    from (
      select 
        contract_id, created, max(created) over(partition by parent_manual_task_id) as max,Update_notes, 
        status, assignee_org_user_id as Legal_reviewer, created_by_org_user_id as Assigned_by, parent_manual_task_id
      from review_data_tab 
      where assignee_org_user_id is not null
    ) as b
    where created = max
  ) as ee
  on aa.contract_id = ee.contract_id and aa.parent_manual_task_id = ee.parent_manual_task_id
  left join `{{project_id}}.{{prod_dataset_name}}.{{public}}sd_organizations_organizationuser` as org 
  on org.id = ee.Legal_reviewer
  left join `{{project_id}}.{{prod_dataset_name}}.{{public}}sd_organizations_organizationuser` as org2 
  on org2.id = bb.Assigned_by
  where aa.parent_manual_task_id not in (select distinct parent_manual_task_id from review_data_tab where status in ('DELETED'))
  order by 1, Review_requested_on
),



v5_reviews as 

(select contract_id, 
concat('v5_',required_approval_id,'_',row_number() over(partition by contract_id, name order by action_performed_at)) as parent_manual_task_id, 
instructions as Review_request_Notes ,
action_performed_at as Review_requested_on,
cast(null as string) as Review_requested_by,
null as role_id,
name as review_name,  
row_number() over(partition by contract_id, name order by action_performed_at) as contract_review_instance,
tenant_workspace_id as created_by_workspace,
cast(null as timestamp) as Review_assigned_on,
reviewer as Reviewer_name,
reviewer_email as Legal_reviewer,
cast(null as string) as Assigned_by_name,
cast(null as string) as Assigned_by,
cast(null as timestamp) as Review_started_on,
next_timestamp as Review_completed_on,
cast(null as string) as Update_notes,
'role' as review_role,
pending_org_id as legal_reviewer_id
from
  (select *,  lead(action) over(partition by required_approval_id order by action_performed_at) as next_event,
  lead(action_performed_at) over(partition by required_approval_id order by action_performed_at) as next_timestamp, 
  timestamp_diff( lead(action_performed_at) over(partition by required_approval_id order by action_performed_at), action_performed_at, second )/3600.0 as old_Approval_time_hours, 
  lead(action_performed_by_id) over(partition by required_approval_id order by action_performed_at) as approver_id,
  action_performed_by_id as requestor_id, action_performed_at as app_sent_on
  from 
    (select a.id as required_approval_id, a.tenant_workspace_id, a.name, a.current_state, linked_to_entity_id as contract_id, a.created_by_org_user_id , 
    b.id, b.action, a.instructions,
    case 
    when action in ('instate', 'trigger', 'resend') then 'sent' 
    when action in ('skip', 'approve', 'reject') then 'action'
    else null 
    end as ab,
    b.action_performed_at, b.action_performed_by_id, action_reason, 
    lag(case 
    when action in ('instate', 'trigger', 'resend') then 'sent' 
    when action in ('skip', 'approve', 'reject') then 'action'
    else null 
    end) over(partition by a.id order by action_performed_at) as next_ab
    from `{{project_id}}.{{prod_dataset_name}}.{{public}}approvals_v5_approvalv5` a 
    join `{{project_id}}.{{prod_dataset_name}}.{{public}}approvals_v5_approvalv5actions` b on a.id = b.approval_id
    where linked_to_entity_type  = 'CONTRACT'
    and a.is_deleted = false
    and b.is_deleted = false
    and a.is_required = true
    and a.breakpoint_type = 'NONE'
    and current_state not in ('CREATED')
    and action != 'reset'
    and (a.approval_type = 'REVIEW')
    order by a.id, b.created)
  where ab != next_ab or next_ab is null) as a 
left join v5_pending as b on a.required_approval_id = b.approval_id
where ab = 'sent'
),

review_data_formatted as 
(select * from old_review_data_formatted
union all 
select * from v5_reviews
),


review_events as
(select concat('review_',contract_id, '_',parent_manual_task_id) as uuid,contract_id,  created_by_workspace, review_name, reviewer_name, case when review_data_formatted.Review_completed_on is null then 'Pending' else 'Completed' end as status,  review_requested_on , review_completed_on , coalesce(review_completed_on, current_timestamp) as end_timestamp_current, timestamp_diff(review_completed_on, review_requested_on, second) as time_spent
from review_data_formatted),

all_events as
(select *, timestamp_diff(end_timestamp_current, start_timestamp, second) as time_spent from
(select '01' as ordering, 'redlining' as event_category ,uu_id, contract_id, created_by_workspace_id, 'Redlining' as cat_1, cat_2, status, 
  start_timestamp, end_timestamp, end_timestamp_current, time_spent as time_spent_old ,
  case 
  when cat_1 = 'Creator Party Redlining' then 'Creator Party'
  when cat_1 = 'Counterparty Redlining' then 'Counterparty'
  else 'All Parties'
  end as internal_external
from redlining_events
union all
select '00' as ordering,'draft' as category , *, 'Creator Party' as internal_external from draft_events
union all
select '02' as ordering ,'sign setup' as category , *,  'Creator Party' as internal_external from sign_setup_events
union all
select '07' as ordering ,'signing' as category ,* from sign_events
-- union all
-- select * from sign_app_events -- to do fix duplications or multiple time SA was requested
union all
select '04' as ordering ,'approvals' as category , *, 'Creator Party' as internal_external from app_v4_events
union all
select '05' as ordering ,'approvals' as category , * , 'Creator Party' as internal_external from app_v5_events
union all 
select '06' as ordering ,'reviews' as category , *, 'Creator Party' as internal_external from review_events
) 
order by contract_id, ordering, start_timestamp),

all_events_with_on_hold as
(
  select a.*, b.on_hold_start, b.on_hold_ends, on_hold_ends_current from all_events as a 
left join on_hold_tab as b on a.contract_id = b.contract_id and a.start_timestamp <= b.on_hold_start and a.end_timestamp_current >= b.on_hold_start
),

oh_inter as 
(select count(*) over(partition by uu_id) as on_hold_coutns, a.* , 
row_number() over(partition by uu_id order by on_hold_start ) rn, 
row_number() over(partition by uu_id order by on_hold_start desc) rev_rn,
lag(on_hold_ends_current) over(partition by uu_id order by on_hold_start) as prev_end
 from all_events_with_on_hold as a 
where on_hold_start is not null
order by 1 desc, uu_id, on_hold_start
),


all_events_hold as
(select 
ordering,  event_category , concat(uu_id,'_oh_',ranking) as uu_id, contract_id, created_by_workspace_id,  cat_1, cat_2, status, 
  new_start_timestamp as start_timestamp, new_end_timestamp as end_timestamp, new_end_timestamp as end_timestamp_current, null as time_spent_old ,
internal_external,timestamp_diff(new_end_timestamp, new_start_timestamp, second) as time_spent
from 
(select *, rn as ranking,coalesce( prev_end, start_timestamp) as new_start_timestamp, on_hold_start as new_end_timestamp  from oh_inter
union all 
select *,rn+rev_rn as ranking, on_hold_ends_current, end_timestamp_current from oh_inter
where rev_rn = 1 
and on_hold_ends_current != end_timestamp_current
)
order by 1 desc, uu_id, start_timestamp
)


select *, 
case when count(case when event_category = 'reviews' then 1 else null end) over(partition by contract_id) >0 and event_category in ('reviews', 'On Hold') then 'true' else 'false' end as review_filter  ,
case 


when count(case when event_category = 'approvals' then 1 else null end) over(partition by contract_id) >0 and event_category in ('approvals', 'On Hold') then 'true' else 'false' end as approval_filter  ,
case when count(case when event_category = 'signing' then 1 else null end) over(partition by contract_id) > 0 and event_category in ('signing', 'On Hold') then 'true' else 'false' end as sign_filter  

from
(  
  (select a.* from all_events as a 
  left join on_hold_tab as b on a.contract_id = b.contract_id and a.start_timestamp <= b.on_hold_start and a.end_timestamp_current >= b.on_hold_start 
  where on_hold_start is null)
union all 
  select * from all_events_hold 

union all 

  (select  
  '0' as ordering, 'On Hold' event_category , concat(contract_id,'_oh_',row_number() over(partition by contract_id order by on_hold_start)) as uu_id, contract_id, created_by_workspace_id, 'On Hold' as cat_1, 'On Hold' cat_2, case when on_hold_ends is null then 'On Hold' else 'On Hold' end as status, 
    on_hold_start as start_timestamp, on_hold_ends as end_timestamp, on_hold_ends_current as end_timestamp_current, null as time_spent_old ,
  'All Parties' as internal_external, timestamp_diff(on_hold_ends_current, on_hold_start, second) as time_spent
  from on_hold_tab as a 
  join `{{project_id}}.{{prod_dataset_name}}.{{public}}contracts_v3_contractv3` as b on a.contract_id = b.id)
)
--redlining_26414_Client_1



