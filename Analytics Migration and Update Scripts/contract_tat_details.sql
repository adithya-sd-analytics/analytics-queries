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

all_con as ( 
  select * 
  from `{{project_id}}.{{prod_dataset_name}}.{{public}}contracts_v3_contractv3`
  where status not in ('DELETED', 'HARD_DELETED')
  and contract_kind not in ('UPLOAD_EXECUTED')
  -- and created_by_workspace_id = prod_india_id
  and (created_by_id not in (select user_id from spotdraft_users) or created_by_workspace_id in (2633, 546494, 3513, 239272))
  order by id desc
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
     
raw_tab as (
  select 
    distinct contract_id, 
    event_type, 
    max(timestamp) over(partition by contract_id, event_type) as times 
  from (
    select 
      id, 
      contract_display_status, 
      event_type, 
      timestamp, 
      contract_id 
    from `{{project_id}}.{{prod_dataset_name}}.{{public}}spot_insights_contractevent`
    where contract_id in (select id from all_con)
    and event_type in ( 'AWAITING_SIGNATURE', 'EXECUTED')) as a
    union all 
    select 
      distinct a.contract_id, 
      a.event_type, 
      min(a.timestamp) over(partition by a.contract_id, a.event_type) as times 
    from (
      select 
        id, 
        contract_display_status, 
        case 
          when event_type in ('REDLINING', 'SENT_TO_COUNTERPARTY') then 'REDLINING'
          else event_type 
        end as event_type, 
        timestamp, 
        contract_id 
      from `{{project_id}}.{{prod_dataset_name}}.{{public}}spot_insights_contractevent`
      where contract_id in (select id from all_con)
      and event_type in ('REDLINING', 'SENT_TO_COUNTERPARTY', 'CREATED')
    ) as a 
),
    
contract_stages as (
  select 
    a.*, 
    contract_kind,
    contract_template_id, 
    workflow_status, 
    created_by_workspace_id, 
    contract_type_id 
  from (
    select 
      rt.*, 
      st.times as Redlining_starts, 
      tt.times as sign_starts, 
      ut.times as executed_date 
    from (select contract_id, times as con_created from raw_tab where event_type in ('CREATED')) as rt
    left join (select contract_id, times from raw_tab where event_type in ('REDLINING')) as st 
    on rt.contract_id = st.contract_id
    left join (select contract_id, times from raw_tab where event_type in ('AWAITING_SIGNATURE')) as tt 
    on rt.contract_id = tt.contract_id
    left join (select contract_id, times from raw_tab where event_type in ('EXECUTED')) as ut 
    on rt.contract_id = ut.contract_id
  ) as a
  left join all_con as ac 
  on a.contract_id = ac.id
),
    
redlining_cons as (
  select 
    contract_id as id 
  from contract_stages 
  where contract_kind in ('UPLOAD_EDITABLE', 'TEMPLATE','TEMPLATE_EDITABLE', 'EXPRESS_TEMPLATE') 
  and redlining_starts is not null 
),


reviews as (
  select 
    distinct parent_manual_task_id,
    contract_id, 
    min(created) over(partition by parent_manual_task_id) as review_requested, 
    max(case when status in ('COMPLETED', 'FORCE_COMPLETED') then created end) over (partition by parent_manual_task_id) as review_finished 
  from `{{project_id}}.{{prod_dataset_name}}.{{public}}contracts_v3_manualtaskdata`
  where type in ('LEGAL_REVIEW')
  and parent_manual_task_id not in (
    select parent_manual_task_id 
    from `{{project_id}}.{{prod_dataset_name}}.{{public}}contracts_v3_manualtaskdata`
    where status = 'DELETED'
  )
  and contract_id in (select id from all_con)
),


timeLine_raw as (
  select 
    distinct a.*,  
    b.workflow_status, 
    contract_kind 
  from (
    select * 
    from raw_tab as a 
    where event_type in ('REDLINING', 'AWAITING_SIGNATURE','EXECUTED')
    and contract_id in (select id from redlining_cons)

    union all 

    select contract_id, event_type, timestamp from `{{project_id}}.{{prod_dataset_name}}.{{public}}spot_insights_contractevent`
    where contract_id in (select id from redlining_cons)
    and event_type in ('SENT_TO_COUNTERPARTY', 'RECEIVED_FROM_COUNTERPARTY', 'AWAITING_SIGNATURE')

    union all

    select contract_id, action, created from `{{project_id}}.{{prod_dataset_name}}.{{public}}contracts_v3_contractversion`
    where contract_id in (select id from redlining_cons)
    and action in ('EDIT_EDITABLE', 'UPLOAD_EDITABLE', 'UPLOADED_PDF', 'UPLOADED_TPP_PDF','UPLOADED_EXECUTION_PDF')

    union all

    select contract_id, 'Review Requested', REVIEW_REQUESTED from reviews

    union all 

    select contract_id, 'Review finished', review_finished from reviews
    where review_finished is not null

    union all 

    (select 
      contract_id, 
      case
          when audit_type = 'on-hold-status-update' and on_hold = 'true' then 'contract on hold'
          when audit_type = 'on-hold-status-update' and on_hold = 'false' then 'contract resumed'
          when audit_type = 'contract-voided' then 'contract voided'
          when audit_type = 'pending-with-manual-override' and pending_with_counterparty = 'true' then 'pending with CP'
          when audit_type = 'pending-with-manual-override' and pending_with_counterparty = 'false' then 'pending with client'
          else 'test'
      end as test,
      created  
      from `{{project_id}}.{{prod_dataset_name}}.cron_audit_table`
      where audit_type in ('contract-voided','pending-with-manual-override', 'on-hold-status-update')
      and contract_id in (select id from redlining_cons)
    )
  ) as a 
  join contract_stages as b on a.contract_id = b.contract_id 
  and a.times >= (b.redlining_starts)  
  and a.times <= coalesce(b.sign_starts, b.executed_date)
  order by 1 desc, 3
),

refined_raw_timeline as (
  select * from 
  (
  select *, 
  lead(pend) over(partition by contract_id order by times) as next_event_type,   
  lead(times) over(partition by contract_id order by times) as next_time_stamp, 

case 
  when lead(times) over (partition by contract_id order by times) is null and pend != 'End' then timestamp_diff(current_timestamp, times, second)
  else timestamp_diff(lead(times) over (partition by contract_id order by times), times, second)
  
end as time_spent
  from (
    select 
      a.*, 
      coalesce(ab, pending_with) as pend, 
      lag(coalesce(ab, pending_with)) over(partition by contract_id order by ord) as lag
    from (
      select distinct a.*,
      case 
          when event_type in ('EDIT_EDITABLE', 'UPLOAD_EDITABLE', 'UPLOADED_PDF', 'UPLOADED_TPP_PDF','UPLOADED_EXECUTION_PDF') then 'New version'
          when event_type in ('SENT_TO_COUNTERPARTY', 'pending with CP', 'SIGNATURE_REQUESTED') then 'Sent to CP'
          when event_type in ('RECEIVED_FROM_COUNTERPARTY', 'pending with client') then 'Recieved from CP'
          when event_type in ('EXECUTED') then 'Redlining end'
          when event_type in ('REDLINING', 'AWAITING_SIGNATURE') then 'ignore'
          else event_type
      end as Action_type, 
      case 
          when event_type in ('EDIT_EDITABLE', 'UPLOAD_EDITABLE', 'UPLOADED_PDF', 'UPLOADED_TPP_PDF', 'Review finished', 'Review Requested', 'RECEIVED_FROM_COUNTERPARTY', 'pending with client') then 'Client Pending'
          when event_type in ('SENT_TO_COUNTERPARTY', 'pending with CP') then 'CP Pending'
          when event_type in ('contract on hold', 'contract resumed') then 'On Hold'
          when event_type in ('AWAITING_SIGNATURE') then 'Signstage Pending'
      end as pending_with,
      (row_number() over(partition by a.contract_id order by times)) as ord,
      case 
          when(row_number() over(partition by a.contract_id order by times)) = 1 and event_type = 'SENT_TO_COUNTERPARTY' then 'CP Pending'
          when(row_number() over(partition by a.contract_id order by times)) = 1 and event_type != 'SENT_TO_COUNTERPARTY' then 'Client Pending'
          when((max(times) over(partition by a.contract_id)) = times and event_type in ('AWAITING_SIGNATURE', 'EXECUTED'))then 'End'
      end as ab
      from timeLine_raw as a
    ) as a
  ) as a
  where pend != lag or lag is null 

) as a
where not (ord = 1 and timestamp_diff (next_time_stamp, times, MILLISECOND) < 900 )
),


test_cases as (
select b.*, 
  case
    when contract_kind not in ('UPLOAD_EDITABLE', 'UPLOAD_SIGN') then round(timestamp_diff(coalesce(Redlining_starts, sign_starts), con_created, second) / 3600.0, 2)
  end as draft_time, 
  case
      when contract_kind = 'UPLOAD_SIGN' then null 
      when (workflow_status='COMPLETED' and sign_starts is null) then round(timestamp_diff(executed_date, redlining_starts,second) / 3600.0, 2)
      when redlining_starts is null and sign_starts is null then null
      else round(timestamp_diff(sign_starts, redlining_starts, second) / 3600.0, 2)
  end as redlining_time,

  round(a.Client_time/3600.0, 2) Client_time, 
  round(CP_time/3600.0, 2) CP_time, 
  round(On_hold_time/3600.0,2) On_hold_time,
  round(timestamp_diff(executed_date, sign_starts, second) / 3600.0, 2) as sign_time,
  round(timestamp_diff(executed_date, con_created, second) / 3600.0, 2) as execution_time,
  Client_rounds, 
  CP_rounds, 
  on_hold_rounds,
  Sign_nego_rounds, 
  round(Sign_nego_time/3600.0,2) Sign_nego_time
  from (
    select contract_id as con_id, 
    count(case when pend = 'Client Pending' then 1 end) as Client_rounds, 
    sum(case when pend = 'Client Pending' then time_spent end) as Client_time,  
    count(case when pend = 'CP Pending' then 1 end) as CP_rounds, sum(case when pend = 'CP Pending' then time_spent end) as CP_time,
    count(case when pend = 'On Hold' then 1 end) as on_hold_rounds, sum(case when pend = 'On Hold' then time_spent end) as On_hold_time,
    count(case when pend = 'Signstage Pending' then 1 end) as Sign_nego_rounds, 
    sum(case when pend = 'Signstage Pending' then time_spent end) as Sign_nego_time 

    from refined_raw_timeline 
    where time_spent is not null 
    group by contract_id
  ) as a 
  right join contract_stages as b
  on a.con_id = b.contract_id
order by 10 
),

sign_email as (
  select 
    contract_id, 
    created as sign_email_sent 
  from (
    select 
      a.contract_id,
      a.created, 
      a.audit_type,
      row_number() over(partition by a.contract_id order by created) as rn 
    from `{{project_id}}.{{prod_dataset_name}}.{{public}}contracts_v3_contractv3audit` as a 
    join contract_stages as b 
    on a.contract_id = b.contract_id and a.created >= b.sign_starts
    where audit_type in ('sent-for-signature-in-order', 'sent-for-signature')
  ) as a 
  where rn = 1
),

entity as
(select contract_id, name as entity from `{{project_id}}.{{prod_dataset_name}}.{{public}}contracts_v3_contractrole` as a 
join `{{project_id}}.{{prod_dataset_name}}.{{public}}sd_organizations_v2_organizationentity` as b on a.organization_entity_id = b.id
where role = 'CONTRACTOR'),


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

redline_entry as 
(select distinct contract_id from `{{project_id}}.{{prod_dataset_name}}.cron_audit_table`
where audit_type in ('send-to-counterparty-v2', 'send-to-counterparty', 'contract-moved-to-redlining')),


final_tab as (
  select 
    contr.contract_id, 
    concat('https://app.spotdraft.com/contracts/v2/',contr.contract_id) as contract_link, 
  case
      when (campaign_v3_id) is not null then 'Campaign Contracts' 
      when d.contract_kind in ( 'TEMPLATE_EDITABLE') then 'Template Contracts (Redlined)'
      when d.contract_kind in ('TEMPLATE') then 'Template Contracts'
      when d.contract_kind in ('EXPRESS_TEMPLATE') then 'Express Template Contracts'
      when d.contract_kind in ('UPLOAD_EXECUTED') then 'Externally Executed Contracts'
      when d.Contract_kind in ('UPLOAD_SIGN') then 'Upload Sign Contracts'
      when d.Contract_kind in ('CLICKWRAP') then 'Clickwrap Contracts'
      else 'Uploaded for review'
  end as contract_kind,
    contr.contract_type_id, 
    contr.contract_template_id,  
    coalesce(a.con_name, 'No Title') as con_name, 
    b.display_name as contract_type, 
    coalesce(c.internal_name, '--') as template_name, 
    case 
      when d.status in ('VOIDED') then 'Voided'
      when on_hold = true then 'On Hold'
      when d.contract_kind in ('UPLOAD_EDITABLE', 'TEMPLATE_EDITABLE') and d.workflow_status not in ('COMPLETED', 'SIGN' ) then 'Redlining'
      when d.contract_kind in ('UPLOAD_SIGN') and d.workflow_status not in ('COMPLETED') then 'Sign'
      when d.workflow_status = 'COMPLETED' then 'Executed'
      when d.contract_kind in ('TEMPLATE', 'EXPRESS_TEMPLATE') and d.workflow_status in ('SIGN') then 'Sign'
      when d.contract_kind in ('TEMPLATE', 'EXPRESS_TEMPLATE') and re.contract_id is null then 'Draft'
      when d.contract_kind in ('TEMPLATE', 'EXPRESS_TEMPLATE') and re.contract_id is not null then 'Redlining'
      else initcap(d.workflow_status)
    end as contract_display_status,
    con_created, 
    redlining_starts, 
    sign_starts,
    se.sign_email_sent,
    executed_date,
    draft_time, 
    REDLINING_time, 
    Client_time, 
    cp_time, 
    On_hold_time, 
    sign_nego_time,
    sign_time,
    round(timestamp_diff(sign_email_sent, sign_starts, second) / 3600.0, 2) as sign_approvals,
    round(sign_time - round(timestamp_diff(sign_email_sent, sign_starts, second) / 3600.0, 2), 2) as signature_collection,
    Execution_time, 
    time_for_reviews, 
    reviews_requested, 
    reviews_requested - Reviewes_completed as pending_reviews,
    client_rounds,  
case 
    when d.contract_kind = 'UPLOAD_EDITABLE' then cp_rounds + 1 
    else cp_rounds
end as cp_rounds, 
case 
    when d.contract_kind = 'UPLOAD_EDITABLE' then cp_rounds + 1 + Client_rounds
    else cp_rounds + Client_rounds
end as turns,
    on_hold_rounds,
    Sign_nego_rounds,
    contr.created_by_workspace_id as workspace_id
  from test_cases as contr 
  left join (
    select * 
    from (
      select 
        contract_id as con_id, 
        row_number() over(partition by contract_id order by version_number desc) as row_number,    
        case 
          when docx_version like '%contract_versions%' then regexp_extract(docx_version, r'\/contract_versions\/(.+)')
          else regexp_extract(pdf_version, r'\/contract_versions\/(.+)') 
        end as con_name
        from `{{project_id}}.{{prod_dataset_name}}.{{public}}contracts_v3_contractversion` 
        where docx_version like 'contracts%' or pdf_version like 'contracts%'
    ) as ab
    where row_number = 1
  ) as a 
  on a.con_id = contr.contract_id
  left join `{{project_id}}.{{prod_dataset_name}}.{{public}}contracts_v3_workspacecontracttype` as b 
  on b.contract_type_id = contr.contract_type_id and b.workspace_id = contr.created_by_workspace_id
  left join `{{project_id}}.{{prod_dataset_name}}.{{public}}contracts_templateworkspaceaccess` as c  
  on c.contract_template_id = contr.contract_template_id and c.workspace_id = contr.created_by_workspace_id
  left join on_hold as oh on contr.contract_id = oh.contract_id
  left join redline_entry as re on re.contract_id = contr.contract_id
  left join all_con as d on d.id = contr.contract_id
  left join (
    select 
      contract_id,  
      count(*) as reviews_requested, 
      count(review_finished) as Reviewes_completed, 
      round(sum(timestamp_diff(review_finished, review_requested, second) / 3600.0), 2) as time_for_reviews 
  from reviews group by contract_id
  ) as e  
  on contr.contract_id = e.contract_id
  left join sign_email as se 
  on se.contract_id = contr.contract_id
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

(select a.*, coalesce(b.cp_name, 'No Data' ) as cp_name, c.legal_org_id, c.legal_user, c.bussiness_org_id ,c.business_user, d.entity, concat(cp_name, ', ', d.entity) as cp_and_entity , e.teams as business_user_teams, 
case when contract_display_status not in  ('Executed', 'Voided', 'On Hold') then
timestamp_diff( current_timestamp,con_created, day) else null end as TAT_pending,
int.integration_name, int.external_integration_id,
wi.frozen_workflow_title, wi.frozen_workflow_id,
wi.current_workflow_title, wi.workflow_id 

 from final_tab as a 
left join cp_name as b on a.contract_id = b.contract_id 
left join bus_legal as c on a.contract_id = c.contract_id
left join entity as d on a.contract_id = d.contract_id
left join `{{prod_dataset_name}}.Teams` as e on c.bussiness_org_id = e.id
left join integration as int on a.contract_id = int.contract_id
left join workflow_info as wi on a.contract_id = wi.contract_id
)

