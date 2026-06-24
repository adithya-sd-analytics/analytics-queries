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


all_con as (
  select  
    contr.id, 
    contr.created, 
    contr.execution_date, 
    contr.created_by_id, 
    contr.status, 
    contr.contract_kind, 
    contr.contract_template_id, 
    contr.workflow_status,
    contract_type_id, 
    contr.created_by_workspace_id,
    campaign_v3_id
  from `{{project_id}}.{{prod_dataset_name}}.{{public}}contracts_v3_contractv3` as contr
  where (created_by_id not in (select user_id from spotdraft_users) or created_by_workspace_id in (2633, 546494, 3513, 239272))
  -- and created_by_workspace_id = @workspace_id
  and contract_kind not in ('UPLOAD_EXECUTED')
  and status not in ('DELETED', 'HARD_DELETED')
  order by contr.id desc
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

    
latest_name as (
  select * 
  from (
    select 
      contract_id as con_id, 
      row_number() over(partition by contract_id order by version_number desc) as row_number, 
    case 
      when length(cast(docx_version as string)) > length(cast(pdf_version as string)) then reverse(split(reverse(docx_version), '/')[safe_offset(0)])
      when length(cast(docx_version as string)) <= length(cast(pdf_version as string)) then reverse(split(reverse(pdf_version), '/')[safe_offset(0)])
      else null
    end as con_name
    from `{{project_id}}.{{prod_dataset_name}}.{{public}}contracts_v3_contractversion` 
    where docx_version like 'contracts%' or pdf_version like 'contracts%'
  ) as ab
  where row_number = 1
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
    bb.Review_assigned_on,  
    concat(org.first_name,' ' ,org.last_name) as Reviewer_name,
    org.user_email as Legal_reviewer, 
    concat(org2.first_name,' ' ,org2.last_name) as Assigned_by_name, 
    org2.user_email as Assigned_by, 
    cc.Review_started_on, 
    dd.Review_completed_on, 
    dd.Update_notes,
    case 
      when role_id is null then 'Indivual' 
      else 'Role' 
    end as review_role,
    org.id as legal_reviewer_id
  from (
    select 
      contract_id, 
      parent_manual_task_id, 
      description as Review_request_Notes,
      created as Review_requested_on,
      Review_requested_by, 
      role_id 
    from (
      select 
        contract_id, 
        created, 
        user_name as Review_requested_by,
        min(created) over(partition by parent_manual_task_id) as min, 
        description, 
        status, 
        assignee_org_user_id as Legal_reviewer, 
        created_by_org_user_id as Assigned_by,
        parent_manual_task_id, role_id
      from review_data_tab 
      where status = 'PENDING') as a
      where created = min
  ) as aa
  left join (
    select 
      contract_id, 
      parent_manual_task_id, 
      created as Review_assigned_on, 
      Legal_reviewer, 
      Assigned_by  
    from (
      select 
        contract_id,
        created, 
        min(created) over(partition by parent_manual_task_id) as min, 
        description, status, 
        assignee_org_user_id as Legal_reviewer, 
        created_by_org_user_id as Assigned_by, 
        parent_manual_task_id
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
      contract_id, 
      parent_manual_task_id, 
      created as Review_started_on 
    from (
      select 
        contract_id, 
        created, 
        max(created) over(partition by parent_manual_task_id) as max, 
        description, 
        status, 
        assignee_org_user_id as Legal_reviewer, 
        created_by_org_user_id as Assigned_by, 
        parent_manual_task_id
      from review_data_tab 
      where status = 'IN_PROGRESS' 
      and assignee_org_user_id is not null
    ) as b
    where created = max
  ) as cc
  on aa.contract_id = cc.contract_id and aa.parent_manual_task_id = cc.parent_manual_task_id
  left join (
    select 
    contract_id, 
    parent_manual_task_id, 
    Update_notes,created as Review_completed_on,  
    Legal_reviewer, 
    Assigned_by 
    from (
      select 
        contract_id, 
        created, 
        max(created) over(partition by parent_manual_task_id) as max,
        Update_notes, 
        status, 
        assignee_org_user_id as Legal_reviewer, 
        created_by_org_user_id as Assigned_by, 
        parent_manual_task_id
      from review_data_tab 
      where status in ('COMPLETED', 'FORCE_COMPLETED') 
      -- and assignee_org_user_id is not null
    ) as b
    where created = max
  ) as dd
  on aa.contract_id = dd.contract_id and aa.parent_manual_task_id = dd.parent_manual_task_id
  left join (
    select 
    contract_id, 
    parent_manual_task_id, 
    Update_notes,created as Review_completed_on,  
    Legal_reviewer, 
    Assigned_by 
    from (
      select 
        contract_id, 
        created, 
        max(created) over(partition by parent_manual_task_id) as max,
        Update_notes, 
        status, 
        assignee_org_user_id as Legal_reviewer, 
        created_by_org_user_id as Assigned_by, 
        parent_manual_task_id
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

review_data_formatted  as
(select * from old_review_data_formatted 
union all
(select contract_id, 
concat('v5_',required_approval_id,'_',row_number() over(partition by contract_id, name order by action_performed_at)) as parent_manual_task_id, 
instructions as Review_request_Notes ,
action_performed_at as Review_requested_on,
cast(null as string) as Review_requested_by,
null as role_id,
name as review_name,  
row_number() over(partition by contract_id, name order by action_performed_at) as contract_review_instance,
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
)
),

redline_entry as 
(select distinct contract_id from `{{project_id}}.{{prod_dataset_name}}.cron_audit_table`
where audit_type in ('send-to-counterparty-v2', 'send-to-counterparty', 'contract-moved-to-redlining')),


old_final_tab as (
  select 
    a.parent_manual_task_id as review_id,
    a.review_name,
    a.contract_review_instance,
    a.contract_id, --con_name, 
    date(ac.created) as Con_created,
    b.display_name as contract_type, 
    concat('https://app.spotdraft.com/contracts/v2/',a.contract_id) as contract_link, review_role as review_request_type,
    case 
        when Review_completed_on is not null then 'Review Completed'
        when review_role = 'Role' and Review_assigned_on is null then 'Review not yet assigned'
        when review_role = 'Role' and Review_assigned_on is not null and Review_started_on is null and Review_completed_on is null then 'Review Assigned but not completed'
        
        else 'Review Pending'
    end as review_status,
    coalesce(Review_requested_by, 'No Requestor') as Review_requested_by, 
    Review_requested_on,
    Review_assigned_on, 
    Review_started_on, 
    Review_completed_on,
    round(timestamp_diff(Review_completed_on, Review_requested_on, second) / 3600.0, 3) as old_Total_time_take_for_review_hours, 
    case 
        when review_role = 'Indivual' then round(timestamp_diff(Review_started_on, Review_requested_on, second) / 3600.0, 3)
        else round(timestamp_diff(Review_assigned_on, Review_requested_on, second) / 3600.0, 3)
    end as Time_taken_for_firstresponse_hours,
    case 
        when review_role = 'Indivual' then round(timestamp_diff(Review_completed_on, Review_started_on, second) / 3600.0, 3)
        else round(timestamp_diff(Review_completed_on, Review_assigned_on, second) / 3600.0, 3)
    end as time_taken_since_firstresponse_hours,
    coalesce(Assigned_by_name, 'No Assigner') as review_assigned_by, 
    Assigned_by as review_assigned_by_email,
    coalesce(Reviewer_name, 'No Reviewer') as Legal_reviewer, 
    Legal_reviewer as Reviewer_email,
    Review_request_Notes, Update_notes,
    ac.created_by_workspace_id as workspace_id,
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
  legal_reviewer_id,
  role_id,
  ac.created_by_id,
  case 
      when ac.status in ('VOIDED') then 'Voided'
      when oh.on_hold = true then 'On Hold'
      when contract_kind in ('UPLOAD_EDITABLE', 'TEMPLATE_EDITABLE') and workflow_status not in ('COMPLETED', 'SIGN' ) then 'Redlining'
      when contract_kind in ('UPLOAD_SIGN') and workflow_status not in ('COMPLETED') then 'Sign'
      when workflow_status = 'COMPLETED' then 'Executed'
      when contract_kind in ('TEMPLATE', 'EXPRESS_TEMPLATE') and workflow_status in ('SIGN') then 'Sign'
      when contract_kind in ('TEMPLATE', 'EXPRESS_TEMPLATE') and re.contract_id is null then 'Draft'
      when contract_kind in ('TEMPLATE', 'EXPRESS_TEMPLATE') and re.contract_id is not null then 'Redlining'
      else initcap(workflow_status)
    end as workflow_status,
  from review_data_formatted as a 
  left join all_con as ac 
  on a.contract_id = ac.id
  left join `{{project_id}}.{{prod_dataset_name}}.{{public}}contracts_v3_workspacecontracttype` as b 
  on b.contract_type_id = ac.contract_type_id and b.workspace_id = ac.created_by_workspace_id
  left join on_hold as oh on a.contract_id = oh.contract_id
  left join redline_entry as re on re.contract_id = a.contract_id
  -- left join latest_name as c 
  -- on c.con_id = ac.id
  order by review_id desc
),

final_tab as 

(select  distinct a.*, old_Total_time_take_for_review_hours - coalesce(sum(timestamp_diff(b.on_hold_ends, b.on_hold_start, second)/3600) over(partition by review_id), 0) as Total_time_take_for_review_hours, sum(timestamp_diff(b.on_hold_ends, b.on_hold_start, second)/3600) over(partition by review_id) as on_hold_time_hours 
from old_final_tab as a
left join on_hold_tab as b on a.review_requested_on <= b.on_hold_start and a.contract_id = b.contract_id and a.Review_completed_on >= b.on_hold_ends
),

final_display_tab as    
(select 
  c.con_name, 
  a.* ,
  d.name as team_name,
  date(date_trunc(review_requested_on,month)) as review_requested_month,
  date(date_trunc(review_completed_on,month)) as review_completed_month,
  e.legal_org_id, COALESCE(e.legal_user, 'No Legal User') legal_user, e.bussiness_org_id, e.business_user,
  de.entity, concat(cp_name, ', ', de.entity) as cp_and_entity , fe.teams as business_user_teams,
  cp.cp_name
from final_tab as a 
left join latest_name as c 
on c.con_id = a.contract_id
left join `{{project_id}}.{{prod_dataset_name}}.{{public}}sd_auth_role` as d 
on a.role_id = d.id
left join bus_legal as e 
on a.contract_id = e.contract_id
left join entity as de on a.contract_id = de.contract_id
left join `{{prod_dataset_name}}.Teams` as fe on e.bussiness_org_id = fe.id
left join cp_name as cp on cp.contract_id = a.contract_id
)

,
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
where entity_type = 'CONTRACT')

select a.*,
case
  when review_status != 'Review Completed' then timestamp_diff(current_timestamp, (Review_requested_on), day)
  else null
end as pending_since_days,
int.integration_name, int.external_integration_id,
wi.frozen_workflow_title, wi.frozen_workflow_id,
wi.current_workflow_title, wi.workflow_id 

 from final_display_tab a
left join integration as int on a.contract_id = int.contract_id
left join workflow_info as wi on a.contract_id = wi.contract_id


