with spotdraft_users as (
    select * 
    from `{{project_id}}.{{prod_dataset_name}}.{{public}}sd_organizations_organizationuser`
    where (user_email like '%@spotdraft.com'
    or user_email like '%@yopmail.com'
    or user_email like '%@vtestcorp.com')
    and organization_id not in (select owner_id from `{{project_id}}.{{prod_dataset_name}}.core_workspaces`)
),

all_con as (
  select 
    id, 
    cast(created as date) as created,
    cast(Execution_date as date) as Execution_date,
    Execution_date as exec_date,
    workflow_status, 
    contract_kind, 
    created_by_workspace_id 
    from `{{project_id}}.{{prod_dataset_name}}.{{public}}contracts_v3_contractv3` as a 
  where status not in ('DELETED', 'HARD_DELETED')
  and ((created_by_id not in (select user_id from spotdraft_users) and contract_kind != 'UPLOAD_EXECUTED') or contract_kind = 'UPLOAD_EXECUTED')
),

contract_stages as (
select a.contract_id, ac.created as con_created, 
case 
  when min(case when a.status = 'REDLINING' then a.created end) is not null and min(case when a.status = 'SIGN' then a.created end) is not null
    then least(min(case when a.status = 'REDLINING' then a.created end), min(case when a.status = 'SIGN' then a.created end))
  else min(case when a.status = 'REDLINING' then a.created end)
end as Redlining_starts, 
max(case when ac.workflow_status in ('SIGN', 'COMPLETED', 'COMPLETING') and a.status = 'SIGN' then a.created end) sign_starts,
ac.exec_date as executed_date,
max(case when a.status = 'VOIDED' then a.created end) as contract_voided_on,
ac.contract_kind,
workflow_status, 
ac.created_by_workspace_id
from `{{project_id}}.{{prod_dataset_name}}.state_changes_table` as a
join all_con as ac on a.contract_id = ac.id
group by 1, 2, 5, 7, 8, 9
),

on_hold_tab as
(select contract_id, uu_id, audit_type, on_hold_start, on_hold_end as on_hold_ends, on_hold_ends_current, workspace_id 
from `{{project_id}}.{{prod_dataset_name}}.on_hold_non_work_days`
),

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
    and created_by_org_user_id not in (select id from spotdraft_users)
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
    and a.created_by_id not in (select user_id from spotdraft_users)
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

old_app_data_with_time as 
( 
  select row_number() over() as uuid,  
    *, 
    row_number() over(partition by a.contract_id, required_approval_id order by app_sent_on) as app_no,
    row_number() over(partition by a.contract_id, required_approval_id order by app_sent_on desc) as app_no_rev
  from (
    select id, required_approval_id ,a.contract_id, created as app_sent_on, status, created_by_org_user_id as requestor_id,
    lead(status) over(partition by a.contract_id, required_approval_id order by created) as next_event, 
    lead(created) over(partition by a.contract_id, required_approval_id order by created) as next_timestamp,
    coalesce(lead(created) over(partition by a.contract_id, required_approval_id order by created), b.executed_date, b.contract_voided_on, current_timestamp) as next_timestamp_current, 
    lead(created_by_org_user_id) over(partition by a.contract_id, required_approval_id order by created) as approver_id,
    b.contract_voided_on, b.executed_date,
    timestamp_diff(coalesce(lead(created) over(partition by a.contract_id, required_approval_id order by created), b.executed_date, b.contract_voided_on, current_timestamp), created, second) as old_Approval_time_secs
    from cleaned_app_timeline as a
    left join contract_stages as b on a.contract_id = b.contract_id
  ) as a 
  where status = 'Approval Request Sent'
),

app_data_with_time as
(select *, old_Approval_time_secs - coalesce(total_on_hold_time_calc, 0) as Approval_time_secs 
 from 
(select 
distinct 
sum(timestamp_diff(least(on_hold_ends_current, next_timestamp_current), greatest(on_hold_start, app_sent_on), second))
over(partition by uuid) as total_on_hold_time_calc ,
sum(case when b.audit_type = 'on-hold-status-update' then timestamp_diff(least(on_hold_ends_current, next_timestamp_current), greatest(on_hold_start, app_sent_on), second) end)
over(partition by uuid) as on_hold_time ,
sum(case when b.audit_type = 'non-workday' then timestamp_diff(least(on_hold_ends_current, next_timestamp_current), greatest(on_hold_start, app_sent_on), second) end)
over(partition by uuid) as non_work_day ,
a.* 
from old_app_data_with_time as a
left join on_hold_tab as b on a.contract_id = b.contract_id and 
((b.on_hold_start >= a.app_sent_on 
and b.on_hold_start <= next_timestamp_current)
or (b.on_hold_ends_current >= a.app_sent_on 
and b.on_hold_ends_current <= next_timestamp_current))
)
),

v4_pending_with as 
(select a.id, 
coalesce(concat(b.first_name, ' ',b.last_name) , concat('Team: ',c.name,' (POC: ', d.first_name, ' ',d.last_name, ')')) as pending_name , c.name as approval_team, concat(b.first_name, ' ',b.last_name) as approval_user
from `{{project_id}}.{{prod_dataset_name}}.{{public}}contracts_v3_contractrequiredapprovalv2` as a 
left join `{{project_id}}.{{prod_dataset_name}}.{{public}}sd_organizations_organizationuser` as b on a.org_user_id = b.id
left join `{{project_id}}.{{prod_dataset_name}}.{{public}}sd_auth_role` as c on a.role_id = c.id
left join `{{project_id}}.{{prod_dataset_name}}.{{public}}sd_organizations_organizationuser` as d on c.point_of_contact_id = d.id
order by 2 desc),

report_tab as (
  select 
    coalesce(e.approval_name, 'Ad-Hoc Approval') as approval_name, 
    concat('v4_',a.required_approval_id) as required_approval_id, 
      a.contract_id, 
      a.Total_app_time_hours, 
      a.number_of_app,
    f.Approval_Status, 
    concat(g.first_name, ' ',g.last_name) as Latest_Requested_by, 
    h.id as latest_approver_id,
    coalesce(concat(h.first_name, ' ',h.last_name), 'No Approver') as latest_approved_by, 
    cast(f.app_sent_on as date) as Last_app_requesed_on,
    cast(b.app_sent_on as date) as App_First_sent_on, 
    b.Approval_time_secs as time_initial_app_hours, 
    coalesce(Total_app_time_hours_wo_skip, 0) as Total_app_time_hours_wo_skip, 
    coalesce(number_of_app_wo_skip, 0) number_of_app_wo_skip, 
    date(f.next_timestamp) as app_completed_on,
    pending_name as pending_with,
    approval_team, 
    approval_user,
    concat('v4_', coalesce(e.approval_name, 'Ad-Hoc Approval')) as  approval_name_sub_cat,
    a.total_on_hold_time,
    a.total_non_work_days
  from (
    select 
      required_approval_id, 
      contract_id, 
      sum(Approval_time_secs) as Total_app_time_hours, 
      max(app_no) as number_of_app, 
      sum(on_hold_time) as total_on_hold_time,
      sum(non_work_day) as total_non_work_days
      from app_data_with_time
      group by 1, 2
  ) as a 
  left join (
    select * 
    from app_data_with_time
    where app_no = 1
  ) as b 
  on a.required_approval_id = b.required_approval_id
  left join (
    select 
      required_approval_id, 
      contract_id, 
      sum(Approval_time_secs) as Total_app_time_hours_wo_skip, 
      count(app_no) as number_of_app_wo_skip 
    from app_data_with_time
    where (next_event != 'SKIPPED' or next_event is null)
    group by 1, 2
  ) as c 
  on a.required_approval_id = c.required_approval_id 
  left join `{{project_id}}.{{prod_dataset_name}}.{{public}}contracts_v3_contractrequiredapprovalv2` as d 
  on a.required_approval_id = d.id
  left join `{{project_id}}.{{prod_dataset_name}}.{{public}}contracts_v3_contractrequiredfullapproval` as e  
  on d.required_approval_id = e.id
  left join (
    select 
      required_approval_id,
      case 
        when next_timestamp is null then 'Pending' 
        when next_timestamp is not null then 'Completed' 
      end as Approval_Status, requestor_id, approver_id, app_sent_on , next_timestamp
    from app_data_with_time
    where app_no_rev = 1
  ) as f 
  on a.required_approval_id = f.required_approval_id
  left join `{{project_id}}.{{prod_dataset_name}}.{{public}}sd_organizations_organizationuser` as g 
  on f.requestor_id = g.id
  left join `{{project_id}}.{{prod_dataset_name}}.{{public}}sd_organizations_organizationuser` as h 
  on f.approver_id = h.id
  left join v4_pending_with as j on a.required_approval_id = j.id
),

-- old_sign_app_data as (
-- (
--   select row_number() over() uuid, * from 
--   (select distinct  a.id as required_id, 
--     concat(b.id,'_',a.id) ,
--     b.created_by_id as sent_by_user_id, 
--     concat(d.first_name, ' ', d.last_name) as sent_by, 
--     a.contract_id, 
--     created_by_workspace,
--     b.req_order,
--     b.created as app_sent, 
--     b.next_request,
--     c.created as app_finished,
--     coalesce(c.created, contract_voided_on, executed_date, current_timestamp) as app_finishied_current, 
--     a.org_user_id as approver, concat(e.first_name, ' ', e.last_name) as approved_by,
--     case 
--       when f.id != created_by_workspace then 'Signatory Approval - Counterparty' else 'Signatory Approval - Internal' 
--     end as cp_approv,
--     timestamp_diff(coalesce(c.created, contract_voided_on, executed_date, current_timestamp), b.created, second ) as old_time_spent,
--     case 
--       when c.created is null then 1 else 0
--     end as pending
--        from `{{project_id}}.{{prod_dataset_name}}.{{public}}contracts_v3_signrecipient` as a
--        join contract_stages as cs on a.contract_id = cs.contract_id
--       join
--       (select *, lead(created) over(partition by required_id order by created) as next_request, row_number() over(partition by required_id order by created desc) as req_order 
--         from `{{project_id}}.{{prod_dataset_name}}.cron_audit_table` 
--         where audit_type = 'recipient-approver-email-sent'
--       )as b
--     on a.id = b.required_id 
--       left join (select distinct created, recipient_id, is_success, is_rejected,  created_by_workspace_id
--       from `{{project_id}}.{{prod_dataset_name}}.{{public}}contracts_v3_recipientaction`
--       ) 
--       as c on a.id = c.recipient_id and b.created <= c.created and (b.next_request is null or (b.next_request > c.created)) 
--       join `{{project_id}}.{{prod_dataset_name}}.{{public}}sd_organizations_organizationuser` as d on b.created_by_id = d.user_id
--       join `{{project_id}}.{{prod_dataset_name}}.{{public}}sd_organizations_organizationuser` as e on a.org_user_id = e.id
--       join `{{project_id}}.{{prod_dataset_name}}.{{public}}sd_organizations_companyprofile` as f on f.owner_id = e.organization_id
--     where a.is_deleted = false
--     and b.created_by_id not in (select user_id from spotdraft_users)
--     )
--     )
-- --),



sign_reset as 
(
(select created,  null as recipient_id, 'Reset move to redlining' as action,contract_id, created_by_workspace_id  from `{{project_id}}.{{prod_dataset_name}}.state_changes_table`
where status in ('REDLINING') and previous_status in ('SIGN')
order by created)
union all 
(select distinct created, null as recepient_id, 'Reset reject sign or approval' as action, contract_id, created_by_workspace_id
from `{{project_id}}.{{prod_dataset_name}}.{{public}}contracts_v3_recipientaction`
where (is_success = false or is_rejected = true))
union all 
(select distinct created, null as recepient_id, 'Reset upload sign version' as action, contract_id, created_by_workspace_id
from `{{project_id}}.{{prod_dataset_name}}.{{public}}contracts_v3_contractversion`
where action = 'UPLOADED_EXECUTION_PDF' 
and (json_extract_scalar(meta_data, '$.restored_version')='false' or json_extract_scalar(meta_data, '$.restored_version') is null)
)

),

sign_app_sent as
(select * from
  (select distinct a.*, min(b.created) over(partition by a.contract_id, a.required_id, a.created) as reset from 
    (select created, required_id, 'sent' as action ,contract_id, created_by_workspace , created_by_id as sent_by_id,
    lag(created) Over(partition by contract_id, required_id order by created) as prev_sent,
    row_number() over(partition by contract_id, required_id order by created) as req_num  
    from `{{project_id}}.{{prod_dataset_name}}.cron_audit_table` 
    where audit_type in ('recipient-approver-email-sent','recipient-approver-email-resent' )
    ) as a
  left join sign_reset as b on a.contract_id = b.contract_id and b.created <= a.created and b.created >= a.prev_sent
  -- where a.contract_id = 1877583
  )
where req_num = 1 or reset is not null 
order by contract_id, required_id, req_num),


old_sign_app_data as
(select
row_number() over() uuid, 
required_id, 
sent_by_id as sent_by_user_id, b.user_name as sent_by, a.contract_id,
workspace_id as created_by_workspace, 
app_order as req_order,
a.created as app_sent, next_timestamp as app_finished, 
coalesce(next_timestamp, contract_voided_on, executed_date, current_timestamp) as app_finishied_current,
c.org_user_id as approver,
concat(d.first_name, ' ',d.last_name) as approved_by,

case when next_action = 'sent' then 'Skipped' 
when next_action is null and reset is not null then 'Skipped'
when next_action is null and reset is null and coalesce(contract_voided_on, executed_date) is null then 'Pending'
when next_action is null and reset is null and coalesce(contract_voided_on, executed_date) is not null then 'Force Completed'
else next_action
end as status,

case 
  when e.id != workspace_id then 'Signatory Approval - Counterparty' else 'Signatory Approval - Internal' 
end as cp_approv,
timestamp_diff(coalesce(next_timestamp, contract_voided_on, executed_date, current_timestamp), a.created, second) as old_time_spent,
case when next_action is null and reset is null and coalesce(contract_voided_on, executed_date) is null then 1 else 0 end as pending
 from
(select a.*, contract_voided_on, executed_date,
row_number() over(partition by a.contract_id, required_id order by created) as app_order, 
row_number() over(partition by a.contract_id, required_id order by created desc) as app_rev_order 
from
  (select contract_id,created_by_workspace as workspace_id, required_id, action,  sent_by_id,
  lead(action) over(partition by contract_id, required_id order by created) as next_action, 
  created,
  case 
  when lead(action) over(partition by contract_id, required_id order by created) = 'sent' then reset
  when lead(action) over(partition by contract_id, required_id order by created) is null then reset
  else lead(created) over(partition by contract_id, required_id order by created) end as next_timestamp,
  reset
  from
    (select *, 
    case when action = 'sent' then 'keep'
    when action != 'sent' and lead(action) over(partition by contract_id, required_id order by created) in ('Rejected', 'Approved') then 'drop'
    when action != 'sent' and lag(action) over(partition by contract_id, required_id order by created) is null then 'drop'
    else 'keep' end as approval_logic
    from 
    (
      select created, required_id, action, contract_id, created_by_workspace, lead(reset) over(partition by contract_id, required_id order by created) as reset, sent_by_id from sign_app_sent 
      union all 
      (select distinct created, recipient_id, case when is_success = true then 'Approved' else 'Rejected' end as action, contract_id, created_by_workspace_id, cast(null as timestamp) as reset, null as sent_by_id
      from `{{project_id}}.{{prod_dataset_name}}.{{public}}contracts_v3_recipientaction`)
    )
    -- where contract_id = 1877583

    order by contract_id, required_id, created)
  where approval_logic = 'keep'
  order by contract_id desc, required_id, created)  as a
  join contract_stages as b on a.contract_id = b.contract_id
where action = 'sent') as a
left join 
(select * from (select concat(first_name,' ' ,last_name) as user_name, user_id, id, row_number() over(partition by user_id order by created desc) as rn
 from `{{project_id}}.{{prod_dataset_name}}.{{public}}sd_organizations_organizationuser`)where rn = 1) as b on a.sent_by_id = b.user_id
left join `{{project_id}}.{{prod_dataset_name}}.{{public}}contracts_v3_signrecipient` as c on a.required_id = c.id
left join `{{project_id}}.{{prod_dataset_name}}.{{public}}sd_organizations_organizationuser` as d on c.org_user_id = d.id
left join `{{project_id}}.{{prod_dataset_name}}.{{public}}sd_organizations_companyprofile` as e on d.organization_id = e.owner_id),


sign_app_data as
(select *, old_time_spent - coalesce(total_on_hold_time, 0) as time_spent
 from 
(select 
distinct sum(timestamp_diff(least(on_hold_ends, app_finished), on_hold_start, second )) over(partition by uuid) as total_on_hold_time ,
sum(case when b.audit_type = 'on-hold-status-update' then timestamp_diff(least(on_hold_ends, app_finished), greatest(on_hold_start, app_sent), second ) end) over(partition by uuid) as on_hold_time,
sum(case when b.audit_type = 'non-workday' then timestamp_diff(least(on_hold_ends, app_finished), greatest(on_hold_start, app_sent), second ) end) over(partition by uuid) as non_work_day, 
a.* from old_sign_app_data as a
left join on_hold_tab as b on a.contract_id = b.contract_id 
and ((b.on_hold_start >= a.app_sent 
and b.on_hold_start <= app_finishied_current)
or (b.on_hold_ends_current >= a.app_sent 
and b.on_hold_ends_current <= app_finishied_current))
)),

sign_app as
(select  * from
  (select 
  min(app_sent) over(partition by contract_id, cp_approv, approver) app_first_sent,
  sum(time_spent) over(partition by contract_id, cp_approv, approver) time_spent_secs,
  sum(case when status != 'Skipped' then(time_spent) end ) over(partition by contract_id, cp_approv, approver) Total_app_time_hours_wo_skip,
  sum(case when req_order = 1 then(time_spent) end ) over(partition by contract_id, cp_approv, approver) time_initial_app_hours,
  sum(pending)over(partition by contract_id, cp_approv, approver) pending_approvals,
  count(*) over(partition by contract_id, cp_approv, approver) no_of_app,
  count(case when status != 'Skipped' then 1 end ) over(partition by contract_id, cp_approv, approver) number_of_app_wo_skip, 
  row_number() over(partition by contract_id, cp_approv, approver order by coalesce(app_finished, app_sent) desc) as rn,
  concat(cp_approv, ' ', approved_by) as cp_approv_cat,
  sum(on_hold_time) over(partition by contract_id, cp_approv, approver) as total_cum_on_hold_time,
  sum(non_work_day) over(partition by contract_id, cp_approv, approver) as total_cum_non_workdays,
  *
  from
    sign_app_data
  where req_order = 1 or app_finished is not null
  order by required_id, req_order) 
  where rn = 1
),
 
final_app_data as
(select a.cp_approv, concat('SA_',required_id) as required_id,a.contract_id, time_spent_secs, no_of_app,
case when pending_approvals != 0 then 'Pending' else 'Completed' end as Approval_Status,
sent_by, 
approver as approver_id,
coalesce(approved_by, 'No Approver') as approver, date(app_sent), date(app_first_sent), 
time_initial_app_hours, Total_app_time_hours_wo_skip, 
number_of_app_wo_skip, 

date(app_finished),
  coalesce(approved_by, 'No Approver') as pending_with,
  cast(null as string) as approval_team,
  coalesce(approved_by, 'No Approver') as approval_user,
  cp_approv_cat,
  total_cum_on_hold_time,
  total_cum_non_workdays
from sign_app as a 
),

old_v5_cleaned as 
(select 
row_number() over() as uuid, 
*, 
row_number() over(partition by contract_id, required_approval_id order by action_performed_at) as app_no,
row_number() over(partition by contract_id, required_approval_id order by action_performed_at desc) as app_no_rev
 from 
  (select a.*, lead(action) over(partition by required_approval_id order by action_performed_at) as next_event,
  lead(action_performed_at) over(partition by required_approval_id order by action_performed_at) as next_timestamp,
  coalesce(lead(action_performed_at) over(partition by required_approval_id order by action_performed_at), contract_voided_on, executed_date, current_timestamp) as next_timestamp_current,
  timestamp_diff(coalesce(lead(action_performed_at) over(partition by required_approval_id order by action_performed_at), contract_voided_on, executed_date, current_timestamp), action_performed_at, second ) as old_Approval_time_secs, 
  lead(action_performed_by_id) over(partition by required_approval_id order by action_performed_at) as approver_id,
  action_performed_by_id as requestor_id, 
  action_performed_at as app_sent_on,
  contract_voided_on, executed_date
  from 
    (select a.id as required_approval_id, a.tenant_workspace_id, a.name, a.current_state, linked_to_entity_id as contract_id, a.created_by_org_user_id , 
    b.id, b.action, 
    case 
    when action in ('instate', 'trigger', 'resend') then 'sent' 
    when action in ('skip', 'approve', 'reject','revoke') then 'action'
    else null 
    end as ab,
    b.action_performed_at, b.action_performed_by_id, action_reason, 
    lag(case 
    when action in ('instate', 'trigger', 'resend') then 'sent' 
    when action in ('skip', 'approve', 'reject','revoke') then 'action'
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
    order by a.id, b.created) as a
    join contract_stages as b on a.contract_id = b.contract_id
  where ab != next_ab or next_ab is null) as a 
where ab = 'sent' and ( next_event != 'revoke' or next_event is null)
),

v5_cleaned as 
(select *,old_Approval_time_secs - coalesce(total_on_hold_time, 0) as Approval_time_secs 
 from 
(select distinct 
sum(timestamp_diff(least(on_hold_ends, next_timestamp_current), greatest(on_hold_start, app_sent_on), second )) over(partition by uuid) as total_on_hold_time,
sum(case when b.audit_type = 'on-hold-status-update' then timestamp_diff(least(on_hold_ends, next_timestamp_current), greatest(on_hold_start, app_sent_on), second ) end) over(partition by uuid) as on_hold_time,
sum(case when b.audit_type = 'non-workday' then timestamp_diff(least(on_hold_ends, next_timestamp_current), greatest(on_hold_start, app_sent_on), second ) end) over(partition by uuid) as non_work_day,  
a.* from old_v5_cleaned as a
left join on_hold_tab as b on a.contract_id = b.contract_id and
((b.on_hold_start >= a.app_sent_on 
and b.on_hold_start <= next_timestamp_current)
or (b.on_hold_ends_current >= a.app_sent_on 
and b.on_hold_ends_current <= next_timestamp_current))
)),

v5_pending_with as 
(select a.approval_id, 
coalesce(concat(b.first_name, ' ',b.last_name) , concat('Team: ',c.name,' (POC: ', d.first_name, ' ',d.last_name, ')')) as pending_name, c.name as approval_team, 
concat(b.first_name, ' ',b.last_name) as approval_user
from `{{project_id}}.{{prod_dataset_name}}.{{public}}approvals_v5_approvalv5actormapping` as a 
left join `{{project_id}}.{{prod_dataset_name}}.{{public}}sd_organizations_organizationuser` as b on cast(a.actor_id as int64) = b.id and 
a.actor_type = 'ORGANIZATION_USER'
left join `{{project_id}}.{{prod_dataset_name}}.{{public}}sd_auth_role` as c on cast(a.actor_id as int64) = c.id and 
a.actor_type = 'ROLE'
left join `{{project_id}}.{{prod_dataset_name}}.{{public}}sd_organizations_organizationuser` as d on c.point_of_contact_id = d.id 
where a.is_deleted = false
and actor_relation_type = 'APPROVER'
),

v5_final_tab as
(select 
  f.name as approval_name,
    concat('v5_',a.required_approval_id) as required_approval_id, 
      a.contract_id, 
      a.Total_app_time_hours,
      a.number_of_app, 
    f.Approval_Status, 
    concat(g.first_name, ' ',g.last_name) as Latest_Requested_by, 
    h.id as latest_approver_id,
    coalesce(concat(h.first_name, ' ',h.last_name), 'No Approver') as latest_approved_by, 
    cast(f.app_sent_on as date) as Last_app_requesed_on,
    cast(b.app_sent_on as date) as App_First_sent_on, 
    b.approval_time_secs as time_initial_app_hours, 
    coalesce(Total_app_time_hours_wo_skip, 0) as Total_app_time_hours_wo_skip, 
    coalesce(number_of_app_wo_skip, 0) as number_of_app_wo_skip,  
    date(f.next_timestamp) as app_completed_on,
  j.pending_name,
  j.approval_team,
  j.approval_user,
  concat('v5_',f.name) as approval_sub_cat,
  a.total_on_hold_time,
  a.total_non_workdays
from
( select 
      required_approval_id, 
      contract_id, 
      sum(Approval_time_secs) as Total_app_time_hours, 
      max(app_no) as number_of_app,
      sum(on_hold_time) as total_on_hold_time,
      sum(non_work_day) as total_non_workdays
      from v5_cleaned
      group by 1, 2) as a
left join (
    select * 
    from v5_cleaned
    where app_no = 1
  ) as b 
  on a.required_approval_id = b.required_approval_id
left join (
    select 
      required_approval_id, 
      contract_id, 
      sum(Approval_time_secs) as Total_app_time_hours_wo_skip, 
      count(app_no) as number_of_app_wo_skip 
    from v5_cleaned
    where next_event != 'skip'
    group by 1, 2
  ) as c
  on a.required_approval_id = c.required_approval_id 
left join (
    select 
      required_approval_id,
      case 
        when coalesce(next_timestamp, contract_voided_on, executed_date) is null then 'Pending' 
        else 'Completed' 
      end as Approval_Status, requestor_id, approver_id, app_sent_on, next_timestamp, name
    from v5_cleaned
    where app_no_rev = 1
  ) as f 
  on a.required_approval_id = f.required_approval_id
  left join `{{project_id}}.{{prod_dataset_name}}.{{public}}sd_organizations_organizationuser` as g 
  on f.requestor_id = g.id
  left join `{{project_id}}.{{prod_dataset_name}}.{{public}}sd_organizations_organizationuser` as h 
  on f.approver_id = h.id
  left join v5_pending_with as j on a.required_approval_id = j.approval_id
),

all_approvals as 
(select * from report_tab
union all
select * from final_app_data
union all
select * from v5_final_tab)

select 
a.approval_name,
a.required_approval_id,
a.contract_id,
round(a.Total_app_time_hours/timescale, 2) as Total_app_time_hours,
a.number_of_app,
case 
when a.Approval_Status not in ( 'Completed') and b.contract_display_status = 'Voided' then 'Approval Voided'
when a.Approval_Status not in ( 'Completed') and b.contract_display_status = 'On Hold' then 'Approval On Hold'
else a.Approval_Status end as Approval_Status,
a.Latest_Requested_by,
a.latest_approver_id,
a.latest_approved_by,
a.Last_app_requesed_on,
a.App_First_sent_on,
round(a.time_initial_app_hours/timescale, 2) as time_initial_app_hours,
round(a.Total_app_time_hours_wo_skip, 2) as Total_app_time_hours_wo_skip,
round(a.total_on_hold_time/timescale, 2) as total_on_hold_time,
round(a.total_non_work_days/timescale, 2) as total_non_work_days,
a.number_of_app_wo_skip,
b.contract_type,
date(b.contract_created) as contract_created_on,
date(date_trunc(b.contract_created, month)) as month_created_on,
b.con_name,
b.workspace_id,
b.contract_kind,
b.contract_created,
a.app_completed_on,
b.contract_display_status as contract_status,
a.pending_with,
a.approval_team,
a.approval_user,
a.approval_name_sub_cat,
b.contract_link,
case when Approval_Status = 'Pending' then 1 else 0 end as active_approvals,
b.cp_name,
b.legal_org_id,
b.legal_user,
b.bussiness_org_id,
b.business_user,
b.entity,
b.cp_and_entity,
b.business_user_teams,
case
when approval_status = 'Pending' then date_diff(current_date, Last_app_requesed_on, day)
else null
end as pending_since_days,
b.contract_created_by,
b.integration_name,
b.external_integration_id,
b.frozen_workflow_title,
b.frozen_workflow_id,
b.current_workflow_title,
b.workflow_id,
timescale
from all_approvals as a
join `{{project_id}}.{{prod_dataset_name}}.Analytics_contract_details` as b on a.contract_id = b.contract_id
where b.status not in ('DELETED', 'HARD_DELETED')
and b.created_by_id not in (select user_id from spotdraft_users)