with spotdraft_users as (
  select * 
  from `spotdraft-prod.prod_india_db.public_sd_organizations_organizationuser`
    where (user_email like '%@spotdraft.com'
    or user_email like '%@yopmail.com'
    or user_email like '%@vtestcorp.com')
    and organization_id not in (select owner_id from `spotdraft-prod.prod_india_db.core_workspaces`)
),


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
  from `spotdraft-prod.prod_india_db.public_contracts_v3_contractv3` as contr
  where (created_by_id not in (select user_id from spotdraft_users) or created_by_workspace_id in (2633, 546494, 3513, 239272))
  and contract_kind not in ('UPLOAD_EXECUTED')
  and status not in ('DELETED', 'HARD_DELETED')
  order by contr.id desc
),

contract_stages as (
select a.contract_id, ac.created as con_created, 
case 
  when min(case when a.status = 'REDLINING' then a.created end) is not null and min(case when a.status = 'SIGN' then a.created end) is not null
    then least(min(case when a.status = 'REDLINING' then a.created end), min(case when a.status = 'SIGN' then a.created end))
  else min(case when a.status = 'REDLINING' then a.created end)
end as Redlining_starts, 
max(case when ac.workflow_status in ('SIGN', 'COMPLETED', 'COMPLETING') and a.status = 'SIGN' then a.created end) sign_starts,
ac.execution_date as executed_date,
max(case when a.status = 'VOIDED' then a.created end) as contract_voided_on,
ac.contract_kind,
workflow_status, 
ac.created_by_workspace_id
from `spotdraft-prod.prod_india_db.state_changes_table` as a
join all_con as ac on a.contract_id = ac.id
group by 1, 2, 5, 7, 8, 9
),


on_hold_tab as 
(
  select contract_id, uu_id, audit_type, on_hold_start, on_hold_end as on_hold_ends, on_hold_ends_current, workspace_id 
from `spotdraft-prod.prod_india_db.on_hold_non_work_days`
),


v5_pending as
(select a.approval_id,
coalesce(b.id, d.id) as pending_org_id, c.id as role_id,
coalesce(concat(b.first_name, ' ',b.last_name) , concat('Team: ',c.name,' (POC: ', d.first_name, ' ',d.last_name, ')')) as pending_name,
coalesce(concat(b.first_name,' ', b.last_name), concat(d.first_name, ' ',d.last_name)) as reviewer, coalesce(b.user_email, d.user_email) as reviewer_email

from `spotdraft-prod.prod_india_db.public_approvals_v5_approvalv5actormapping` as a 
left join `spotdraft-prod.prod_india_db.public_sd_organizations_organizationuser` as b on cast(a.actor_id as int64) = b.id and 
a.actor_type = 'ORGANIZATION_USER'
left join `spotdraft-prod.prod_india_db.public_sd_auth_role` as c on cast(a.actor_id as int64) = c.id and 
a.actor_type = 'ROLE'
left join `spotdraft-prod.prod_india_db.public_sd_organizations_organizationuser` as d on c.point_of_contact_id = d.id 
where a.is_deleted = false
and actor_relation_type = 'APPROVER'
),


review_data_tab as (
  select 
    mt.*, 
    concat(first_name, ' ',last_name) as user_name 
  from `spotdraft-prod.prod_india_db.public_contracts_v3_manualtaskdata` as mt
  left join `spotdraft-prod.prod_india_db.public_sd_organizations_organizationuser` as org 
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
  left join `spotdraft-prod.prod_india_db.public_sd_organizations_organizationuser` as org 
  on org.id = ee.Legal_reviewer
  left join `spotdraft-prod.prod_india_db.public_sd_organizations_organizationuser` as org2 
  on org2.id = bb.Assigned_by
  where aa.parent_manual_task_id not in (select distinct parent_manual_task_id from review_data_tab where status in ('DELETED'))
  order by 1, Review_requested_on
)
,

v5_starts as
(select approval_id, created, action from `spotdraft-prod.prod_india_db.public_approvals_v5_approvalv5actions`
where is_deleted = false
and action = 'start'
),

v5_reassign as 
(select required_id, created, on_hold, created_by_id from `spotdraft-prod.prod_india_db.cron_audit_table`
where audit_type = 'approval-v5-reassigned'
and on_hold like '%~ORGANIZATION_USER'
 ),


v5_rev as 

(select contract_id, 
concat('v5_',required_approval_id,'_',row_number() over(partition by contract_id, name order by action_performed_at)) as parent_manual_task_id, 
instructions as Review_request_Notes ,
action_performed_at as Review_requested_on,
review_requested_by as Review_requested_by,
b.role_id as role_id,
name as review_name,  
row_number() over(partition by contract_id, name order by action_performed_at) as contract_review_instance,
-- cast(null as timestamp) as Review_assigned_on,
reviewer as Reviewer_name,
reviewer_email as Legal_reviewer,
-- cast(null as string) as Assigned_by_name,
-- cast(null as string) as Assigned_by,
-- cast(null as timestamp) as Review_started_on,
next_timestamp as Review_completed_on,
Update_notes,
case when b.role_id is not null then 'Role' else 'Indivual' end as review_role,
pending_org_id as legal_reviewer_id,
required_approval_id
from
  (select *,  lead(action) over(partition by required_approval_id order by action_performed_at) as next_event,
  lead(action_performed_at) over(partition by required_approval_id order by action_performed_at) as next_timestamp, 
  timestamp_diff( lead(action_performed_at) over(partition by required_approval_id order by action_performed_at), action_performed_at, second )/3600.0 as old_Approval_time_hours, 
  lead(action_performed_by_id) over(partition by required_approval_id order by action_performed_at) as approver_id,
  lead(action_note) over(partition by required_approval_id order by action_performed_at) as Update_notes,
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
    end) over(partition by a.id order by action_performed_at) as next_ab,
    (b.action_note),
    concat(c.first_name, ' ', c.last_name) as review_requested_by
    from `spotdraft-prod.prod_india_db.public_approvals_v5_approvalv5` a 
    join `spotdraft-prod.prod_india_db.public_approvals_v5_approvalv5actions` b on a.id = b.approval_id
    left join `spotdraft-prod.prod_india_db.public_sd_organizations_organizationuser` as c on a.created_by_org_user_id = c.id
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

-- put the reassigned by email and name , role and role ids
v5_rev_updated as
(select distinct 
 contract_id,
parent_manual_task_id,
Review_request_Notes,
Review_requested_on,
Review_requested_by,
role_id,
review_name,
contract_review_instance,
Review_assigned_on,
Reviewer_name,
Legal_reviewer,
max(assigned_by) over(partition by parent_manual_task_id) as Assigned_by_name,
max(assigned_email) over(partition by parent_manual_task_id) as Assigned_by,
Review_started_on,
Review_completed_on,
Update_notes,
review_role,
legal_reviewer_id, 
from 
  (select 
  distinct a.*, 
  min(b.created) over(partition by a.parent_manual_task_id) as review_started_on, 
  (min(c.created) over(partition by a.parent_manual_task_id)) as review_assigned_on,
  case when c.created = min(c.created) over(partition by a.parent_manual_task_id) then d.user_name else null end as assigned_by,
  case when c.created = min(c.created) over(partition by a.parent_manual_task_id) then d.user_email else null end as assigned_email

  from v5_rev as a
  left join v5_starts as b on a.required_approval_id = b.approval_id and a.review_requested_on <= b.created and b.created <= coalesce(Review_completed_on, current_timestamp)
  left join v5_reassign as c on a.required_approval_id = c.required_id and a.review_requested_on <= c.created and c.created <= coalesce(Review_completed_on, current_timestamp) and c.created <= b.created
  left join (select * from
    (select concat(first_name, ' ' ,last_name) as user_name, user_email, user_id, id, 
    row_number() over(partition by user_id order by created desc) as rn 
    from `spotdraft-prod.prod_india_db.public_sd_organizations_organizationuser` )
    where rn = 1
    )as d on c.created_by_id = d.user_id
  )
)
,

review_data_formatted  as
(select * from old_review_data_formatted 
union all
select * from v5_rev_updated
)
,

-- select * from review_data_formatted


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
    LEAST(COALESCE(review_assigned_on, review_started_on), COALESCE(review_started_on, review_assigned_on)) as review_first_response_on,
    coalesce(LEAST(COALESCE(review_assigned_on, review_started_on), COALESCE(review_started_on, review_assigned_on)), review_completed_on, cs.contract_voided_on, cs.executed_date, current_timestamp) as review_first_response_on_current,
    Review_completed_on,
    coalesce(review_completed_on, cs.contract_voided_on, cs.executed_date, current_timestamp) as review_completed_current,
    timestamp_diff( coalesce(review_completed_on, cs.contract_voided_on, cs.executed_date, current_timestamp), Review_requested_on, second) as old_Total_time_take_for_review_hours, 

    timestamp_diff(coalesce(LEAST(COALESCE(review_assigned_on, review_started_on), COALESCE(review_started_on, review_assigned_on)), review_completed_on, cs.contract_voided_on, cs.executed_date, current_timestamp), Review_requested_on, second) as old_Time_taken_for_firstresponse_hours,
    timestamp_diff(coalesce(review_completed_on, cs.contract_voided_on, cs.executed_date, current_timestamp), LEAST(COALESCE(review_assigned_on, review_started_on), COALESCE(review_started_on, review_assigned_on)), second) as old_time_taken_since_firstresponse_hours,
    coalesce(Assigned_by_name, 'No Assigner') as review_assigned_by, 
    Assigned_by as review_assigned_by_email,
    coalesce(Reviewer_name, 'No Reviewer') as Legal_reviewer, 
    Legal_reviewer as Reviewer_email,
    Review_request_Notes, Update_notes,

  legal_reviewer_id,
  role_id,
  ac.created_by_id
  from review_data_formatted as a
  join contract_stages as cs on a.contract_id = cs.contract_id 
  left join all_con as ac 
  on a.contract_id = ac.id
  left join `spotdraft-prod.prod_india_db.public_contracts_v3_workspacecontracttype` as b 
  on b.contract_type_id = ac.contract_type_id and b.workspace_id = ac.created_by_workspace_id
  order by review_id desc
),




final_tab as 

(select distinct a.*, 
old_time_taken_since_firstresponse_hours - coalesce(sum(timestamp_diff(least(bd.on_hold_ends_current, review_completed_current), greatest(bd.on_hold_start, review_first_response_on), second)) over(partition by review_id), 0) as time_taken_since_firstresponse_hours, 
 from
  (  select distinct a.*,  
    old_Time_taken_for_firstresponse_hours - coalesce(sum(timestamp_diff(least(bc.on_hold_ends_current, review_first_response_on_current), greatest(bc.on_hold_start, review_requested_on), second)) over(partition by review_id), 0) as Time_taken_for_firstresponse_hours, 

    from

      (select  
    distinct a.*, 
    old_Total_time_take_for_review_hours - coalesce(sum(timestamp_diff(least(b.on_hold_ends_current, review_completed_current), greatest(b.on_hold_start, review_requested_on), second)) over(partition by review_id), 0) as Total_time_take_for_review_hours, 
    sum(timestamp_diff(least(b.on_hold_ends_current, review_completed_current), greatest(b.on_hold_start, review_requested_on), second)) over(partition by review_id) as total_on_hold_and_nonworkday_time,
    sum(case when b.audit_type = 'on-hold-status-update' then timestamp_diff(least(b.on_hold_ends_current, review_completed_current), greatest(b.on_hold_start, review_requested_on), second) end)  over(partition by review_id) as total_on_hold_time,
    sum(case when b.audit_type = 'non-workday' then timestamp_diff(least(b.on_hold_ends_current, review_completed_current), greatest(b. on_hold_start, review_requested_on), second) end)  over(partition by review_id) as total_non_workday_time,

    from old_final_tab as a
    left join on_hold_tab as b on a.contract_id = b.contract_id and

    ((b.on_hold_start >= review_requested_on
    and b.on_hold_start <= review_completed_current)
    or (b.on_hold_ends_current >= a.review_requested_on 
    and b.on_hold_ends_current <= review_completed_current))
    ) as a 

    left join on_hold_tab as bc on a.contract_id = bc.contract_id and

    ((bc.on_hold_start >= review_requested_on
    and bc.on_hold_start <= review_first_response_on_current) 
    or (bc.on_hold_ends_current >= a.review_requested_on 
    and bc.on_hold_ends_current <= review_first_response_on_current))  
  ) as a

left join on_hold_tab as bd on a.contract_id = bd.contract_id and

((bd.on_hold_start >= a.review_first_response_on
and bd.on_hold_start <= review_completed_current)
or (bd.on_hold_ends_current >= a.review_first_response_on
and bd.on_hold_ends_current <= review_completed_current)) 
)


select 
b.con_name,
a.review_id,
b.contract_id,
a.review_name,
a.contract_review_instance,
a.Con_created,
b.contract_type,
b.contract_link,
a.review_request_type,
case 
when a.review_status not in ( 'Review Completed') and b.contract_display_status = 'Voided' then 'Review Voided'
when a.review_status not in ( 'Review Completed') and b.contract_display_status = 'On Hold' then 'Review On Hold'
else a.review_status end as review_status,
a.Review_requested_by,
a.Review_requested_on,
a.Review_assigned_on,
a.Review_started_on,
a.Review_completed_on,
round(a.old_Total_time_take_for_review_hours/timescale, 2) as old_Total_time_take_for_review_hours,
round(a.Time_taken_for_firstresponse_hours/timescale, 2)  as Time_taken_for_firstresponse_hours,
round(a.time_taken_since_firstresponse_hours/timescale, 2)  as time_taken_since_firstresponse_hours,
a.review_assigned_by,
a.review_assigned_by_email,
a.Legal_reviewer,
a.Reviewer_email,
a.Review_request_Notes,
a.Update_notes,
b.workspace_id,
b.contract_kind,
a.legal_reviewer_id,
a.role_id,
a.created_by_id,
b.contract_display_status as workflow_status,
round(a.Total_time_take_for_review_hours/timescale, 2)  as Total_time_take_for_review_hours,
round(a.total_on_hold_time/timescale, 2) as on_hold_time_hours,
round(a.total_non_workday_time/timescale, 2) as non_workday_time,
d.name as team_name,
date(date_trunc(review_requested_on,month)) as review_requested_month,
date(date_trunc(review_completed_on,month)) as review_completed_month,
b.legal_org_id,
b.legal_user,
b.bussiness_org_id,
b.business_user,
b.entity,
b.cp_and_entity,
b.business_user_teams,
b.cp_name,
case
  when review_status != 'Review Completed' then timestamp_diff(current_timestamp, (Review_requested_on), day)
  else null
end as pending_since_days,
b.integration_name,
b.external_integration_id,
b.frozen_workflow_title,
b.frozen_workflow_id,
b.current_workflow_title,
b.workflow_id,
b.timescale
from final_tab as a
join `spotdraft-prod.prod_india_db.Analytics_contract_details` as b on a.contract_id = b.contract_id
left join `spotdraft-prod.prod_india_db.public_sd_auth_role` as d on a.role_id = d.id
