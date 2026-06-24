with 

spotdraft_users as (
  select * 
  from `spotdraft-prod.prod_india_db.public_sd_organizations_organizationuser`
    where (user_email like '%@spotdraft.com'
    or user_email like '%@yopmail.com'
    or user_email like '%@vtestcorp.com')
    and organization_id not in (select owner_id from `spotdraft-prod.prod_india_db.core_workspaces`)
),

on_hold as 
(SELECT contract_id, on_hold FROM `spotdraft-prod.prod_india_db.public_contracts_v3_contractprofile` as a 
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

  from `spotdraft-prod.prod_india_db.public_contracts_v3_contractv3` as a
  left join on_hold as b on a.id = b.contract_id
  where 
  status not in ( 'HARD_DELETED', 'DELETED')
  and 
  contract_kind not in ('UPLOAD_EXECUTED')
  -- and created_by_workspace_id = prod_india_id
  and (created_by_id not in (select user_id from spotdraft_users) or created_by_workspace_id in (2633, 546494, 3513, 239272))
  order by id desc
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
contract_template_id, 
workflow_status, 
ac.created_by_workspace_id, 
contract_type_id 
from `spotdraft-prod.prod_india_db.state_changes_table` as a
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
          from `spotdraft-prod.prod_india_db.turn_logs_table`

        union all
          select contract_id, created, status, previous_status, reason, contract_kind , status_order, status_order_rev, 'state_change' as source_logs
          from `spotdraft-prod.prod_india_db.state_changes_table`

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
(select * from `spotdraft-prod.prod_india_db.on_hold_non_work_days`
),

review_events as
(select concat('review_',contract_id, '_',review_id) as uuid, contract_id, workspace_id, review_name, Legal_reviewer, 
case when review_status = 'Review Completed' then 'Completed'
else 'Pending'
end as status, Review_requested_on, 

Review_completed_on, coalesce(Review_completed_on, current_timestamp) as end_timestamp_current, timestamp_diff(coalesce(review_completed_on, current_timestamp), Review_requested_on, SECOND) as time_spent  from `spotdraft-prod.Test_Dataset_for_BI.Contracts_review_table`),


sign_email as (
  select 
    contract_id, 
    created as sign_email_sent,
    sign_starts,
    executed_date,
    contract_voided_on,
    created_by_workspace_id 
  from (
    select 
      a.contract_id,
      a.created, 
      a.audit_type,
      b.sign_starts,
      b.executed_date,
      b.created_by_workspace_id,
      b.contract_voided_on,
      row_number() over(partition by a.contract_id order by created) as rn 
    from `spotdraft-prod.prod_india_db.cron_audit_table` as a 
    join contract_stages as b 
    on a.contract_id = b.contract_id and a.created >= b.sign_starts
    where audit_type in ('sent-for-signature-in-order', 'sent-for-signature')
    and b.sign_starts is not null
  ) as a 
  where rn = 1
),

sign_app_events as 
(select concat('sign_app_',a.contract_id) as uuid, a.contract_id, a.created_by_workspace_id, 'Sign Approval' as event_type, 'Business user' as business_user, 
case when coalesce(sign_email_sent, a.executed_date, a.contract_voided_on) is null then 'Pending' else 'Completed' end as status,
a.sign_starts, coalesce(sign_email_sent, a.executed_date, a.contract_voided_on) as sign_app_completed, coalesce(sign_email_sent, a.executed_date, a.contract_voided_on, current_timestamp) sign_app_current, timestamp_diff(coalesce(sign_email_sent, a.executed_date, a.contract_voided_on, current_timestamp), a.sign_starts, SECOND) as time_spent
from 
contract_stages as a left join sign_email as b on a.contract_id = b.contract_id 
where a.sign_starts is not null),


redline_all_events as
(select concat('redlining_all_', contract_id), contract_id, created_by_workspace_id, 'Redlining All' as event_cat, 'All' as users, 
case when coalesce(sign_starts, executed_date, contract_voided_on) is null then 'Pending'
else 'Completed' end as status, redlining_starts, coalesce(sign_starts, executed_date, contract_voided_on) as redlining_end, 
coalesce(sign_starts, executed_date, contract_voided_on, current_timestamp) as redlining_end_current,
timestamp_diff (coalesce(sign_starts, executed_date, contract_voided_on, current_timestamp), redlining_starts, SECOND) as timespent
from contract_stages
where redlining_starts is not null),


sign_collection_events as 
(select concat('sign_collection_',contract_id) as uuid, contract_id, created_by_workspace_id, 'Sign Collection' as event_type, 'Signatories' as users, 
case when coalesce(executed_date, contract_voided_on) is not null then 'Completed'
else 'Pending' end as status, sign_email_sent, coalesce(executed_date, contract_voided_on) as sign_collection_complete, coalesce(executed_date, contract_voided_on, current_timestamp) sign_collection_complete_current, 
timestamp_diff( coalesce(executed_date, contract_voided_on, current_timestamp), sign_email_sent, SECOND) as time_spent 
from sign_email), 

sign_all_events as
(select concat('Sign_',contract_id) as uuid, contract_id, created_by_workspace_id, 'Signing' as event_category, 'Business users & Signatories',
case when  coalesce(executed_date, contract_voided_on) is null then 'Pending' else 'Completed' end as status,
sign_starts, coalesce(executed_date, contract_voided_on), coalesce(executed_date, contract_voided_on, current_timestamp),
timestamp_diff(coalesce(executed_date, contract_voided_on, current_timestamp), sign_starts, SECOND) as time_spent
from contract_stages
where sign_starts is not null),

all_events as
(select * from
  (select '01' as ordering, case 
    when cat_1 = 'Creator Party Redlining' then 'Creator Party nego'
    when cat_1 = 'Counterparty Redlining' then 'Counterparty nego'
    else 'Sign Stage nego'
    end as event_category 
  
  ,uu_id, contract_id, created_by_workspace_id, 'Redlining' as cat_1, cat_2, status, 
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
  select '06' as ordering ,'reviews' as category , *, 'Creator Party' as internal_external from review_events
  union all 
  select '07' as ordering ,'Sign All' as category , *, 'All Parties' as internal_external from sign_all_events
  union all 
  select '07' as ordering ,'Sign app' as category , *, 'All Parties' as internal_external from sign_app_events
  union all 
  select '07' as ordering ,'Sign collection' as category , *, 'All Parties' as internal_external from sign_collection_events
  union all 
  select '07' as ordering ,'Redline All' as category , *, 'All Parties' as internal_external from redline_all_events

  ) 
order by contract_id, ordering, start_timestamp)

,
all_events_on_hold as
(
select distinct a.*,  
sum(timestamp_diff(least(on_hold_ends_current, end_timestamp_current), greatest(on_hold_start, start_timestamp), second)) over(partition by a.uu_id) as on_hold_time,
time_spent_old - coalesce(sum(timestamp_diff(least(on_hold_ends_current, end_timestamp_current), greatest(on_hold_start, start_timestamp), second)) over(partition by a.uu_id) , 0) as time_spent_actual
from all_events as a
left join on_hold_tab as b on a.contract_id = b.contract_id 
and ((b.on_hold_start >= start_timestamp 
and b.on_hold_start <= end_timestamp_current)
or (b.on_hold_ends_current >= start_timestamp 
and b.on_hold_ends_current <= end_timestamp_current))
where time_spent_old >= 0 -- removing some weird cases where there are events after contract is executed
),

contract_time_spent as
(select  
contract_id,
created_by_workspace_id as workspace_id,  
sum(case when event_category = 'draft' then (time_spent_actual) end ) as draft_time,
sum(case when event_category = 'Redline All' then (time_spent_actual) end) as redlining_time,
sum(case when event_category = 'Sign All' then (time_spent_actual) end ) as sign_time,
sum(case when event_category = 'Sign app' then (time_spent_actual) end) as sign_approval_time,
sum(case when event_category = 'Sign collection' then (time_spent_actual) end ) as sign_collection_time,
sum(case when event_category = 'reviews' then (time_spent_actual) end) as internal_review_time,
sum(case when event_category = 'Creator Party nego' then (time_spent_actual) end) as client_time,
sum(case when event_category = 'Counterparty nego' then (time_spent_actual) end ) as cp_time,
sum(case when event_category = 'Sign Stage nego' then (time_spent_actual) end) as sign_nego_time,
count(distinct case when event_category = 'Creator Party nego' then uu_id end) as client_rounds,
count(distinct case when event_category = 'Counterparty nego' then uu_id end ) as cp_rounds,
count(distinct case when event_category = 'Sign Stage nego' then uu_id end) as sign_nego_rounds,
count(distinct case when event_category = 'reviews' then uu_id end) as reviews_requested,
count(distinct case when event_category = 'reviews' and status = 'Completed' then uu_id end) as reviews_completed
from all_events_on_hold
group by 1, 2),

contact_on_hold as
(select contract_id, 
sum(case when audit_type = 'on-hold-status-update' then timestamp_diff(on_hold_ends_current, on_hold_start, second) end)  as on_hold_time,
sum(case when audit_type = 'non-workday' then timestamp_diff(on_hold_ends_current, on_hold_start, second) end)  as non_working_day,
count(distinct case when audit_type = 'on-hold-status-update' then uu_id end) as on_hold_count,
from on_hold_tab
group by 1)

select 
a.contract_id,
b.contract_link,
b.contract_kind,
b.contract_type_id,
b.contract_template_id,
b.con_name,
b.contract_type,
b.template_name,
b.contract_display_status,
d.con_created,
d.redlining_starts,
d.sign_starts,
e.sign_email_sent,
d.executed_date,
d.contract_voided_on,
round(a.draft_time / timescale, 2) as draft_time,
round(a.redlining_time / timescale, 2) as REDLINING_time,
round(a.client_time / timescale, 2) as Client_time,
round(a.cp_time / timescale, 2) as cp_time,
round(c.on_hold_time / timescale, 2) as On_hold_time,
round(a.sign_nego_time / timescale, 2) as sign_nego_time,
round(a.sign_time / timescale, 2) as sign_time,
round(a.sign_approval_time / timescale, 2) as sign_approvals,
round(a.sign_collection_time / timescale, 2) as signature_collection,
round((timestamp_diff(coalesce(d.executed_date, d.contract_voided_on, current_timestamp), d.con_created, SECOND) - coalesce(c.non_working_day, 0) - coalesce(c.on_hold_time, 0)) / timescale, 2) as Execution_time,
round(a.internal_review_time / timescale, 2) as time_for_reviews,
a.reviews_requested,
a.reviews_requested - reviews_completed as pending_reviews,
a.client_rounds,
case 
    when d.contract_kind = 'UPLOAD_EDITABLE' then cp_rounds + 1 
    else cp_rounds
end as cp_rounds, 
case 
    when d.contract_kind = 'UPLOAD_EDITABLE' then cp_rounds + 1 + Client_rounds
    else cp_rounds + Client_rounds
end as turns,
c.on_hold_count as on_hold_rounds,
a.sign_nego_rounds as Sign_nego_rounds,
round( c.non_working_day / timescale, 2) as non_working_days,
a.workspace_id,
b.cp_name,
b.legal_org_id,
b.legal_user,
b.bussiness_org_id,
b.business_user,
b.entity,
b.cp_and_entity,
b.business_user_teams,
case 
  when b.contract_display_status not in  ('Executed', 'Voided', 'On Hold') then
  cast(round((timestamp_diff( current_timestamp, con_created, SECOND) - coalesce(c.non_working_day, 0) - coalesce(c.on_hold_time, 0))/(3600*24), 0) as int64) else null 
end as TAT_pending,
b.integration_name,
b.external_integration_id,
b.frozen_workflow_title,
b.frozen_workflow_id,
b.current_workflow_title,
b.workflow_id,
timescale 
 from contract_time_spent as a
join `spotdraft-prod.prod_india_db.Analytics_contract_details` as b on a.contract_id = b.contract_id
left join contact_on_hold as c on a.contract_id = c.contract_id
left join contract_stages as d on a.contract_id = d.contract_id
left join sign_email as e on a.contract_id = e.contract_id
