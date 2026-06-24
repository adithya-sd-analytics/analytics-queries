with spotdraft_users as (
    select * 
    from `{{project_id}}.{{prod_dataset_name}}.{{public}}sd_organizations_organizationuser`
    where (user_email like '%@spotdraft.com'
    or user_email like '%@yopmail.com'
    or user_email like '%@vtestcorp.com')
    and organization_id not in (select owner_id from `{{project_id}}.{{prod_dataset_name}}.core_workspaces`)
),

on_hold as 
(SELECT contract_id, on_hold FROM `{{project_id}}.{{prod_dataset_name}}.{{public}}contracts_v3_contractprofile` as a 
where on_hold = true),

entity as
(select contract_id, name as entity from `{{project_id}}.{{prod_dataset_name}}.{{public}}contracts_v3_contractrole` as a 
join `{{project_id}}.{{prod_dataset_name}}.{{public}}sd_organizations_v2_organizationentity` as b on a.organization_entity_id = b.id
where role = 'CONTRACTOR'),

redline_entry as 
(select distinct contract_id from `{{project_id}}.{{prod_dataset_name}}.cron_audit_table`
where audit_type in ('send-to-counterparty-v2', 'send-to-counterparty', 'contract-moved-to-redlining')),

all_con as (
  select 
    id, 
    cast(created as date) as created,
    cast(Execution_date as date) as Execution_date, 
    contract_kind, 
    contract_type_id, 
    created_by_id, 
    contract_template_id, 
    status, 
    campaign_v3_id,
    case 
      when status in ('VOIDED') then 'Voided'
      when b.on_hold = true then 'On Hold'
      when contract_kind in ('UPLOAD_EDITABLE', 'TEMPLATE_EDITABLE') and workflow_status not in ('COMPLETED', 'SIGN' ) then 'Redlining'
      when contract_kind in ('UPLOAD_SIGN') and workflow_status not in ('COMPLETED') then 'Sign'
      when workflow_status = 'COMPLETED' then 'Executed'
      when contract_kind in ('TEMPLATE', 'EXPRESS_TEMPLATE') and workflow_status in ('SIGN') then 'Sign'
      when contract_kind in ('TEMPLATE', 'EXPRESS_TEMPLATE') and re.contract_id is null then 'Draft'
      when contract_kind in ('TEMPLATE', 'EXPRESS_TEMPLATE') and re.contract_id is not null then 'Redlining'
      else initcap(workflow_status)
    end as workflow_status,
    created_by_workspace_id 
    from `{{project_id}}.{{prod_dataset_name}}.{{public}}contracts_v3_contractv3` as a 
    left join on_hold as b on a.id = b.contract_id
    left join redline_entry as re on a.id = re.contract_id
  where status not in ('DELETED', 'HARD_DELETED')
  and ((created_by_id not in (select user_id from spotdraft_users) and contract_kind != 'UPLOAD_EXECUTED') or contract_kind = 'UPLOAD_EXECUTED')
  -- and created_by_workspace_id = @workspace_id
),

on_hold_tab as 
(
select contract_id, audit_type, created as on_hold_start, next_ts as on_hold_ends from 
  (

  select count(*) over(partition by contract_id), *,
  lead(created) over(partition by contract_id, audit_type order by created) as next_ts,
  lead(on_hold) over(partition by contract_id, audit_type order by created) as next_on_hold
  from
    (select contract_id, created, audit_type, on_hold , 
    lag(on_hold) over(partition by contract_id, audit_type order by created) as pre_on_hold , 
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

bus_legal as 
(select ab.id as contract_id, a.org_user_id as bussiness_org_id, b.org_user_id as legal_org_id ,
concat(c.first_name, ' ',c.last_name) as business_user, concat(d.first_name, ' ',d.last_name) as legal_user, 
 from  all_con as ab
left join 
(select * from
  (select row_number() over(partition by contract_id order by created desc) as rn, contract_id, org_user_id from 
`{{project_id}}.{{prod_dataset_name}}.{{public}}contracts_v3_contractuser` as a 
where type = 'BUSINESS') where rn = 1) as a
on a.contract_id = ab.id 
left join 
(select * from (select row_number() over(partition by contract_id order by created desc) as rn, contract_id, org_user_id from 
`{{project_id}}.{{prod_dataset_name}}.{{public}}contracts_v3_contractuser` as a 
where type = 'LEGAL')
where rn = 1) as b on ab.id = b.contract_id
left join `{{project_id}}.{{prod_dataset_name}}.{{public}}sd_organizations_organizationuser` as c 
on a.org_user_id = c.id
left join `{{project_id}}.{{prod_dataset_name}}.{{public}}sd_organizations_organizationuser` as d 
on b.org_user_id = d.id
),

cp_name as 
(
 select distinct contract_id, string_agg(cp_name,', ') over(partition by contract_id) as cp_name, 
from
(select distinct contract_id, b.name as cp_name
from `{{project_id}}.{{prod_dataset_name}}.{{public}}contracts_v3_contractrole` as a 
join `{{project_id}}.{{prod_dataset_name}}.{{public}}sd_organizations_companyprofile` as b on a.workspace_id = b.id
where role = 'SUBSCRIBER'
and contract_id in (select id from all_con))
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
    -- and created_by_workspace_id = @workspace_id
 ) as a
 union all (
    select 
        cast(a.id as string) as id,
        a.required_id as required_approval_id,  
        --json_extract_scalar(approvals, '$.id') as approval_id,
        --approvals,
        a.contract_id, 
        a.created,
        'Approval Request Sent' as action, 
        '', 
        b.id as user_id
    from `{{project_id}}.{{prod_dataset_name}}.cron_audit_table` as a
    left join `{{project_id}}.{{prod_dataset_name}}.{{public}}sd_organizations_organizationuser` as b on a.created_by_id = b.user_id
    where audit_type in ('contract-approval-sent', 'contract-approval-resent')
    and a.created_by_id not in (select user_id from spotdraft_users)
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


old_app_data_with_time as  -- made changes after removing on hold time
( 
  select row_number() over() as uuid,  
    *, 
    row_number() over(partition by contract_id, required_approval_id order by app_sent_on) as app_no,
    row_number() over(partition by contract_id, required_approval_id order by app_sent_on desc) as app_no_rev
  from (
    select id, required_approval_id ,contract_id, created as app_sent_on, status, created_by_org_user_id as requestor_id,
    lead(status) over(partition by contract_id, required_approval_id order by created) as next_event, 
    lead(created) over(partition by contract_id, required_approval_id order by created) as next_timestamp, 
    lead(created_by_org_user_id) over(partition by contract_id, required_approval_id order by created) as approver_id,
    round(timestamp_diff(lead(created) over(partition by contract_id, required_approval_id order by created), created, second) / 3600, 3) as old_Approval_time_hours
    from cleaned_app_timeline
  ) as a 
  where status = 'Approval Request Sent'
),

latest_name as (
  select *  
  from (
    select 
      contract_id as con_id, 
      row_number() over(partition by contract_id order by version_number desc) as row_number, 
      case  
        when docx_version like '%contract_versions%' then split(docx_version, '/contract_versions/')[safe_offset(1)]
        else split(pdf_version, '/contract_versions/')[safe_offset(1)]
      end as con_name
      from `{{project_id}}.{{prod_dataset_name}}.{{public}}contracts_v3_contractversion` 
      where docx_version like 'contracts%' or pdf_version like 'contracts%'
      -- and created_by_workspace_id = @workspace_id
  ) as ab
  where row_number = 1
),

app_data_with_time as  -- added in after removing on hold time
(select *, old_Approval_time_hours - coalesce(on_hold_time, 0) as Approval_time_hours 
 from 
(select distinct sum(timestamp_diff(least(on_hold_ends, next_timestamp), on_hold_start, second )/3600.0) over(partition by uuid) as on_hold_time , a.* from old_app_data_with_time as a
left join on_hold_tab as b on b.on_hold_start >= a.app_sent_on and b.on_hold_ends <= a.next_timestamp and a.contract_id = b.contract_id
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
    round(cast(b.Approval_time_hours as numeric), 3) as time_initial_app_hours, 
    coalesce(Total_app_time_hours_wo_skip, 0) as Total_app_time_hours_wo_skip, 
    coalesce(number_of_app_wo_skip, 0) number_of_app_wo_skip, 
    typ.display_name as contract_type,
    cast(con.created as date) as contract_created_on,
    date_trunc(cast(con.created as date), month) as month_created_on,
    nam.con_name,
    -- concat(i.first_name, ' ',i.last_name) as contract_created_by, 
    d.created_by_workspace_id as workspace_id,
  case
      when (campaign_v3_id) is not null then 'Campaign Contracts' 
      when contract_kind in ( 'TEMPLATE_EDITABLE') then 'Template Contracts (Redlined)'
      when contract_kind in ('TEMPLATE') then 'Template Contracts'
      when contract_kind in ('EXPRESS_TEMPLATE') then 'Express Template Contracts'
      when contract_kind in ('UPLOAD_EXECUTED') then 'Externally Executed Contracts'
      when Contract_kind in ('UPLOAD_SIGN') then 'Upload Sign Contracts'
      when Contract_kind in ('CLICKWRAP') then 'Clickwrap Contracts'
      else 'Uploaded for review'
  end as contract_kind,
  date(f.next_timestamp) as app_completed_on,
  case
      when con.status in ('VOIDED') then 'Voided'
      when oh.on_hold = true then 'On Hold'
      when contract_kind in ('UPLOAD_EDITABLE', 'TEMPLATE_EDITABLE') and workflow_status not in ('COMPLETED', 'SIGN' ) then 'Redlining'
      when contract_kind in ('UPLOAD_SIGN') and workflow_status not in ('COMPLETED') then 'Sign'
      when contract_kind in ('TEMPLATE', 'EXPRESS_TEMPLATE') and workflow_status not in ('COMPLETED', 'SIGN', 'DRAFT' ) then 'Redlining'
      when workflow_status = 'COMPLETED' then 'Executed'
      else initcap(workflow_status)
  end as contract_status,
  pending_name as pending_with,
  approval_team, approval_user
  from (
    select 
      required_approval_id, 
      contract_id, 
      sum(Approval_time_hours) as Total_app_time_hours, 
      max(app_no) as number_of_app from app_data_with_time
      group by 1, 2
  ) as a --aggregate of all approvals
  left join (
    select * 
    from app_data_with_time
    where app_no = 1
  ) as b -- initial approvals
  on a.required_approval_id = b.required_approval_id
  left join (
    select 
      required_approval_id, 
      contract_id, 
      sum(Approval_time_hours) as Total_app_time_hours_wo_skip, 
      count(app_no) as number_of_app_wo_skip 
    from app_data_with_time
    where next_event != 'SKIPPED'
    group by 1, 2
  ) as c -- removing skipped approvals
  on a.required_approval_id = c.required_approval_id 
  left join `{{project_id}}.{{prod_dataset_name}}.{{public}}contracts_v3_contractrequiredapprovalv2` as d --joins for approval name
  on a.required_approval_id = d.id
  left join `{{project_id}}.{{prod_dataset_name}}.{{public}}contracts_v3_contractrequiredfullapproval` as e  --joins for approval name
  on d.required_approval_id = e.id
  left join (
    select 
      required_approval_id,
      case 
        when Approval_time_hours is null then 'Pending' 
        else 'Completed' 
      end as Approval_Status, requestor_id, approver_id, app_sent_on , next_timestamp
    from app_data_with_time
    where app_no_rev = 1
  ) as f -- table for latest status requestor and approver
  on a.required_approval_id = f.required_approval_id
  left join `{{project_id}}.{{prod_dataset_name}}.{{public}}sd_organizations_organizationuser` as g --table for user names
  on f.requestor_id = g.id
  left join `{{project_id}}.{{prod_dataset_name}}.{{public}}sd_organizations_organizationuser` as h --table for user names
  on f.approver_id = h.id
  left join `{{project_id}}.{{prod_dataset_name}}.{{public}}contracts_v3_contractv3` as con -- table for contract details
  on a.contract_id = con.id 
  left join `{{project_id}}.{{prod_dataset_name}}.{{public}}contracts_v3_workspacecontracttype` as typ on --table for contract type details
  con.contract_type_id = typ.contract_type_id and con.created_by_workspace_id =typ.workspace_id
  left join latest_name as nam -- table for name of the latest version of the contract
  on con.id = nam.con_id
  -- left join `{{project_id}}.{{prod_dataset_name}}.{{public}}sd_organizations_organizationuser` as i -- table for user names of contract creator
  -- on con.created_by_id = i.user_id
  left join v4_pending_with as j on a.required_approval_id = j.id
  left join on_hold as oh on oh.contract_id = con.id
  where con.status not in ('DELETED', 'HARD_DELETED')
  and con.created_by_id not in (select user_id from spotdraft_users)
),

old_sign_app_data as (
(
  select row_number() over() uuid, * from 
  (select distinct  a.id as required_id, 
    concat(b.id,'_',a.id) ,
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
    timestamp_diff(c.created, b.created, second ) as old_time_spent,
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
    and b.created_by_id not in (select user_id from spotdraft_users)
    )
    )
),

sign_app_data as
(select *,old_time_spent - coalesce(on_hold_time, 0) as time_spent
 from 
(select distinct sum(timestamp_diff(least(on_hold_ends, app_finished), on_hold_start, second )/3600.0) over(partition by uuid) as on_hold_time , a.* from old_sign_app_data as a
left join on_hold_tab as b on b.on_hold_start >= a.app_sent and b.on_hold_ends <= a.app_finished and a.contract_id = b.contract_id
)),

sign_app as
(select  * from
  (select 
  min(app_sent) over(partition by contract_id, cp_approv, approver) app_first_sent,
  round(sum(time_spent) over(partition by contract_id, cp_approv, approver)/3600.0, 2) time_spent_hours,
  sum(pending)over(partition by contract_id, cp_approv, approver) pending_approvals,
  count(*) over(partition by contract_id, cp_approv, approver) no_of_app, 
  row_number() over(partition by contract_id, cp_approv, approver order by coalesce(app_finished, app_sent) desc) as rn,
  concat(cp_approv, ' ', approved_by) as cp_approv_cat,
  *
  from
    sign_app_data
  where req_order = 1 or app_finished is not null
  order by required_id, req_order) 
  where rn = 1
  -- and contract_id = 19361
  ),
 
-- approval_name	required_approval_id	contract_id	Total_app_time_hours	number_of_app	Approval_Status	Latest_Requested_by	latest_approved_by	Last_app_requesed_on	App_First_sent_on	time_initial_app_hours	Total_app_time_hours_wo_skip	number_of_app_wo_skip	contract_type	contract_created_on	month_created_on	con_name	contract_created_by	workspace_id	contract_kind

final_app_data as  --- add in pending with same as coalesce(approved_by, 'No Approver')
(select a.cp_approv, concat('SA_',required_id) as required_id,a.contract_id, time_spent_hours, no_of_app,
case when pending_approvals != 0 then 'Pending' else 'Completed' end as Approval_Status,
sent_by, 
approver as approver_id,
coalesce(approved_by, 'No Approver') as approver, date(app_sent), date(app_first_sent), time_spent_hours, time_spent_hours, no_of_app, c.display_name, date(b.created),
date_trunc(date(b.created) , month) as month_created, e.con_name, 
-- concat(first_name, ' ', last_name) as created_by, 
created_by_workspace_id, 
  case
      when (campaign_v3_id) is not null then 'Campaign Contracts' 
      when contract_kind in ( 'TEMPLATE_EDITABLE') then 'Template Contracts (Redlined)'
      when contract_kind in ('TEMPLATE') then 'Template Contracts'
      when contract_kind in ('EXPRESS_TEMPLATE') then 'Express Template Contracts'
      when contract_kind in ('UPLOAD_EXECUTED') then 'Externally Executed Contracts'
      when Contract_kind in ('UPLOAD_SIGN') then 'Upload Sign Contracts'
      when Contract_kind in ('CLICKWRAP') then 'Clickwrap Contracts'
      else 'Uploaded for review'
  end as contract_kind,
  date(app_finished),
    case 
      when b.status in ('VOIDED') then 'Voided'
      when oh.on_hold = true then 'On Hold'
      when contract_kind in ('UPLOAD_EDITABLE', 'TEMPLATE_EDITABLE') and workflow_status not in ('COMPLETED', 'SIGN' ) then 'Redlining'
      when contract_kind in ('UPLOAD_SIGN') and workflow_status not in ('COMPLETED') then 'Sign'
      when workflow_status = 'COMPLETED' then 'Executed'
      when contract_kind in ('TEMPLATE', 'EXPRESS_TEMPLATE') and workflow_status in ('SIGN') then 'Sign'
      when contract_kind in ('TEMPLATE', 'EXPRESS_TEMPLATE') and re.contract_id is null then 'Draft'
      when contract_kind in ('TEMPLATE', 'EXPRESS_TEMPLATE') and re.contract_id is not null then 'Redlining'
      else initcap(workflow_status)
    end as workflow_status,
  coalesce(approved_by, 'No Approver') as pending_with,
  cast(null as string) as approval_team,
  coalesce(approved_by, 'No Approver') as approval_user,
  cp_approv_cat
from sign_app as a 
join `{{project_id}}.{{prod_dataset_name}}.{{public}}contracts_v3_contractv3` as b on a.contract_id = b.id 
join `{{project_id}}.{{prod_dataset_name}}.{{public}}contracts_v3_workspacecontracttype` as c on b.contract_type_id = c.contract_type_id and b.created_by_workspace_id = c.workspace_id
-- join `{{project_id}}.{{prod_dataset_name}}.{{public}}sd_organizations_organizationuser` as d on b.created_by_id = d.user_id
join latest_name as e on a.contract_id = e.con_id
left join on_hold as oh on oh.contract_id = b.id
left join redline_entry as re on re.contract_id = b.id
where b.status in ('ACTIVE', 'COMPLETED')
and b.created_by_id not in (select user_id from spotdraft_users)
),

old_v5_cleaned as  -- changed it to old for on hold logic
(select 
row_number() over() as uuid, 
*, 
row_number() over(partition by contract_id, required_approval_id order by action_performed_at) as app_no,
row_number() over(partition by contract_id, required_approval_id order by action_performed_at desc) as app_no_rev
 from 
(select *, lead(action) over(partition by required_approval_id order by action_performed_at) as next_event,
lead(action_performed_at) over(partition by required_approval_id order by action_performed_at) as next_timestamp, 
timestamp_diff( lead(action_performed_at) over(partition by required_approval_id order by action_performed_at), action_performed_at, second )/3600.0 as old_Approval_time_hours, 
lead(action_performed_by_id) over(partition by required_approval_id order by action_performed_at) as approver_id,
action_performed_by_id as requestor_id, action_performed_at as app_sent_on
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
order by a.id, b.created)
where ab != next_ab or next_ab is null) as a 
where ab = 'sent' and ( next_event != 'revoke' or next_event is null)),


v5_cleaned as 

(select *,old_Approval_time_hours - coalesce(on_hold_time, 0) as Approval_time_hours 
 from 
(select distinct sum(timestamp_diff(least(on_hold_ends, next_timestamp), on_hold_start, second )/3600.0) over(partition by uuid) as on_hold_time , a.* from old_v5_cleaned as a
left join on_hold_tab as b on b.on_hold_start >= a.app_sent_on and b.on_hold_ends <= a.next_timestamp and a.contract_id = b.contract_id
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
    concat('v5_',a.required_approval_id), 
      a.contract_id, 
      a.Total_app_time_hours,
      a.number_of_app, 
    f.Approval_Status, 
    concat(g.first_name, ' ',g.last_name) as Latest_Requested_by, 
    h.id as latest_approver_id,
    coalesce(concat(h.first_name, ' ',h.last_name), 'No Approver') as latest_approved_by, 
    cast(f.app_sent_on as date) as Last_app_requesed_on,
    cast(b.app_sent_on as date) as App_First_sent_on, 
    round(cast(b.Approval_time_hours as numeric), 3) as time_initial_app_hours, 
    coalesce(Total_app_time_hours_wo_skip, 0) as Total_app_time_hours_wo_skip, 
    coalesce(number_of_app_wo_skip, 0) number_of_app_wo_skip,  
    typ.display_name as contract_type,
    cast(con.created as date) as contract_created_on,
    date_trunc(cast(con.created as date), month) as month_created_on,
    nam.con_name,
    -- concat(i.first_name, ' ',i.last_name) as contract_created_by, 
    con.created_by_workspace_id as workspace_id,
  case
      when (campaign_v3_id) is not null then 'Campaign Contracts' 
      when contract_kind in ( 'TEMPLATE_EDITABLE') then 'Template Contracts (Redlined)'
      when contract_kind in ('TEMPLATE') then 'Template Contracts'
      when contract_kind in ('EXPRESS_TEMPLATE') then 'Express Template Contracts'
      when contract_kind in ('UPLOAD_EXECUTED') then 'Externally Executed Contracts'
      when Contract_kind in ('UPLOAD_SIGN') then 'Upload Sign Contracts'
      when Contract_kind in ('CLICKWRAP') then 'Clickwrap Contracts'
      else 'Uploaded for review'
  end as contract_kind,
  date(f.next_timestamp) as app_completed_on,
  case
      when con.status in ('VOIDED') then 'Voided'
      when oh.on_hold = true then 'On Hold'
      when contract_kind in ('UPLOAD_EDITABLE', 'TEMPLATE_EDITABLE') and workflow_status not in ('COMPLETED', 'SIGN' ) then 'Redlining'
      when contract_kind in ('UPLOAD_SIGN') and workflow_status not in ('COMPLETED') then 'Sign'
      when contract_kind in ('TEMPLATE', 'EXPRESS_TEMPLATE') and workflow_status not in ('COMPLETED', 'SIGN', 'DRAFT' ) then 'Redlining'
      when workflow_status = 'COMPLETED' then 'Executed'
      else initcap(workflow_status)
  end as contract_status,
  j.pending_name,
  j.approval_team,
  j.approval_user,
  concat('v5_',f.name) as approval_sub_cat,
  


from
( select 
      required_approval_id, 
      contract_id, 
      sum(Approval_time_hours) as Total_app_time_hours, 
      max(app_no) as number_of_app from v5_cleaned
      group by 1, 2) as a
left join (
    select * 
    from v5_cleaned
    where app_no = 1
  ) as b -- initial approvals
  on a.required_approval_id = b.required_approval_id
left join (
    select 
      required_approval_id, 
      contract_id, 
      sum(Approval_time_hours) as Total_app_time_hours_wo_skip, 
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
        when current_state = 'PENDING' then 'Pending' 
        else 'Completed' 
      end as Approval_Status, requestor_id, approver_id, app_sent_on, next_timestamp, name
    from v5_cleaned
    where app_no_rev = 1
  ) as f -- table for latest status requestor and approver
  on a.required_approval_id = f.required_approval_id
  left join `{{project_id}}.{{prod_dataset_name}}.{{public}}sd_organizations_organizationuser` as g --table for user names
  on f.requestor_id = g.id
  left join `{{project_id}}.{{prod_dataset_name}}.{{public}}sd_organizations_organizationuser` as h --table for user names
  on f.approver_id = h.id
  left join `{{project_id}}.{{prod_dataset_name}}.{{public}}contracts_v3_contractv3` as con -- table for contract details
  on a.contract_id = con.id 
  left join `{{project_id}}.{{prod_dataset_name}}.{{public}}contracts_v3_workspacecontracttype` as typ on --table for contract type details
  con.contract_type_id = typ.contract_type_id and con.created_by_workspace_id =typ.workspace_id
  left join latest_name as nam -- table for name of the latest version of the contract
  on con.id = nam.con_id
  -- left join `{{project_id}}.{{prod_dataset_name}}.{{public}}sd_organizations_organizationuser` as i -- table for user names of contract creator
  -- on con.created_by_id = i.user_id
  left join v5_pending_with as j on a.required_approval_id = j.approval_id
  left join on_hold as oh on oh.contract_id = con.id
  where con.status not in ('DELETED', 'HARD_DELETED')
  and con.created_by_id not in (select user_id from spotdraft_users)
  ),

integration as
(select * from
(select contract_id, external_metadata_id as external_integration_id, external_metadata ,
json_extract_scalar(external_metadata, '$.integration_name') as integration_name, row_number() over(partition by contract_id order by id desc) as rn
from `{{project_id}}.{{prod_dataset_name}}.{{public}}public_externalintegrationcontractdetail`
where json_extract_scalar(external_metadata, '$.integration_name') is not null)
where rn = 1),

workflow_info as 
(select a.entity_id contract_id, b.title as frozen_workflow_title, b.id as frozen_workflow_id,
 c.title as current_workflow_title, c.id as workflow_id 
 from `{{project_id}}.{{prod_dataset_name}}.{{public}}workflow_v1_frozenworkflowtoconsumerentitymapping` as a
join `{{project_id}}.{{prod_dataset_name}}.{{public}}workflow_v1_frozenworkflow` as b on a.frozen_workflow_id = b.id
join `{{project_id}}.{{prod_dataset_name}}.{{public}}workflow_v1_workflow` as c on b.workflow_id = c.id
where entity_type = 'CONTRACT'),



final_final_tab as

(select  
  *, 
  concat('https://app.spotdraft.com/contracts/v2/', contract_id) as contract_link,
  case 
    when Approval_Status = 'Pending' then 1 
    else 0 
  end as active_approvals
from (
 select *,
  approval_name as approval_name_sub_cat from report_tab
union all 
select * from final_app_data
union all
select * from v5_final_tab
)
order by approval_name, Last_app_requesed_on desc),

final_display_tab as
(select distinct a.*, b.cp_name, c.legal_org_id, coalesce(c.legal_user, 'No Legal user') legal_user, c.bussiness_org_id ,c.business_user, d.entity, concat(cp_name, ', ', d.entity) as cp_and_entity , e.teams as business_user_teams,
case
  when approval_status = 'Pending' then date_diff(
    current_date,
    Last_app_requesed_on,
    day
  )
  else null
end as pending_since_days,
business_user as contract_created_by,
int.integration_name, int.external_integration_id,
wi.frozen_workflow_title, wi.frozen_workflow_id,
wi.current_workflow_title, wi.workflow_id 


from final_final_tab as a
left join cp_name as b on a.contract_id = b.contract_id 
left join bus_legal as c on a.contract_id = c.contract_id
left join entity as d on a.contract_id = d.contract_id
left join `{{prod_dataset_name}}.Teams` as e on c.bussiness_org_id = e.id
left join integration as int on a.contract_id = int.contract_id
left join workflow_info as wi on a.contract_id = wi.contract_id
)




select * from 
final_display_tab 



