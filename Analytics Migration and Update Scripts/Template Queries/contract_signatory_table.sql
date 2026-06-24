
with
spotdraft_users as (
  select * 
  from `{{project_id}}.{{prod_dataset_name}}.{{public}}sd_organizations_organizationuser`
    where (user_email like '%@spotdraft.com'
    or user_email like '%@yopmail.com'
    or user_email like '%@vtestcorp.com')
    and organization_id != 580
    and organization_id != 115627
),
on_hold as 
(SELECT contract_id, on_hold FROM `{{project_id}}.{{prod_dataset_name}}.{{public}}contracts_v3_contractprofile` as a 
where on_hold = true),
    
redline_entry as 
(select distinct contract_id from `{{project_id}}.{{prod_dataset_name}}.cron_audit_table`
where audit_type in ('send-to-counterparty-v2', 'send-to-counterparty', 'contract-moved-to-redlining')),


all_con as (
  select *,

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
    end as workflow_status_new, 
  from `{{project_id}}.{{prod_dataset_name}}.{{public}}contracts_v3_contractv3` as a 
  left join on_hold as b on a.id = b.contract_id 
  left join redline_entry as re on re.contract_id = a.id
  where status not in ('DELETED', 'HARD_DELETED')
  and contract_kind not in ('UPLOAD_EXECUTED')
  and workflow_status in ('SIGN', 'COMPLETED')
  -- and created_by_workspace_id = prod_india_id
  and (created_by_id not in (select user_id from spotdraft_users) or created_by_workspace_id in (2633, 546494, 3513, 239272))
  order by id desc
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
   *
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

con_name as 
(
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
  ),


field_created as 
(select contract_id, max(modified) as last_updated from `{{project_id}}.{{prod_dataset_name}}.{{public}}contracts_v3_contractsignaturesetup`
where is_deleted = false and is_completed = true and sent_for_signature = true
group by 1),

all_signs as 
(select a.id, a.contract_id,a.org_user_id, 
a.created as signatory_created_on, 
case when a.contract_role = 'CONTRACTOR' then 'Client'
when contract_role = 'SUBSCRIBER' then 'Counterparty'
end as contract_role,

a.created_by_workspace,
d.recipient_order, d.created as sign_recipient_created,
f.last_updated as field_updated_last,
b.created as sign_sent_on, c.created as signed_on 
from `{{project_id}}.{{prod_dataset_name}}.{{public}}contracts_v3_contractv3signatory` as a 
left join sent_for_sign as b on a.id = b.required_id
left join signs_completed_on as c on a.sign_recipient_id = c.sign_recipient_id
join `{{project_id}}.{{prod_dataset_name}}.{{public}}contracts_v3_signrecipient` as d on a.sign_recipient_id = d.id
left join field_created as f on a.contract_id = f.contract_id

where a.is_deleted = false
order by signatory_created_on desc
),

final_all_sign as
(select a.*, 
case 
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
-- case when (sign_sent_on_final )
-- end as sign_sent_on, 
sign_sent_on_final as sign_sent_on,
signed_on, 
case when (sign_sent_on_final) is null then 'Sign email not sent'
when (sign_sent_on_final) is not null and a.signed_on is null and b.workflow_status != 'Executed'  then 'Sign Pending'
when signed_on is not null then 'Sign Completed'
end as sign_status,
round(timestamp_diff(signed_on, sign_sent_on_final, second)/3600, 2) as time_to_sign_hours,
round(timestamp_diff(signed_on, sign_sent_on_final, second)/60, 2) as time_to_sign_mins,
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
c.display_name as contract_type,
coalesce(cty.name, '--') as template_name,
concat(d.first_name, ' ',d.last_name) as signatory,
date(b.created) as con_created,
date(b.execution_date) as executed_on,
e.cp_name,
ce.legal_org_id, coalesce(ce.legal_user, 'No Legal user') legal_user, ce.bussiness_org_id ,ce.business_user,
cn.con_name,
b.workflow_status_new as workflow_status,
CASE WHEN ssd.external_signature_service in ('DOCU_SIGN_V2','DOCU_SIGN') then 'DOCU_SIGN' else 
Coalesce(ssd.external_signature_service,'NATIVE_E_SIGN') end as signature_service
from final_all_sign as a 
join all_con as b on a.contract_id = b.id 
join `{{project_id}}.{{prod_dataset_name}}.{{public}}contracts_v3_workspacecontracttype` as c 
on b.contract_type_id = c.contract_type_id and b.created_by_workspace_id = c.workspace_id
join `{{project_id}}.{{prod_dataset_name}}.{{public}}sd_organizations_organizationuser` as d 
on a.org_user_id = d.id
left join cp_name as e on a.contract_id = e.contract_id
left join bus_legal as ce on a.contract_id = ce.contract_id
left join con_name as cn on a.contract_id = cn.con_id
left join `{{project_id}}.{{prod_dataset_name}}.{{public}}contracts_contracttemplate` as cty  
  on cty.id = b.contract_template_id 
left join contract_stages as cs on cs.contract_id = a.contract_id
left join `{{project_id}}.{{prod_dataset_name}}.{{public}}contracts_signatorysignaturedata` as ssd on a.id = ssd.contract_signatory_id)

,

integration as
(select * from
(select contract_id, external_metadata_id as external_integration_id, external_metadata ,
json_extract_scalar(external_metadata, '$.integration_name') as integration_name, row_number() over(partition by contract_id order by id desc) as rn
from `{{project_id}}.{{prod_dataset_name}}.{{public}}{{public}}externalintegrationcontractdetail`
where json_extract_scalar(external_metadata, '$.integration_name') is not null)
where rn = 1),

workflow_info as 
(select a.entity_id contract_id, b.title as frozen_workflow_title, b.id as frozen_workflow_id,
 c.title as current_workflow_title, c.id as workflow_id 
 from `{{project_id}}.{{prod_dataset_name}}.{{public}}workflow_v1_frozenworkflowtoconsumerentitymapping` as a
join `{{project_id}}.{{prod_dataset_name}}.{{public}}workflow_v1_frozenworkflow` as b on a.frozen_workflow_id = b.id
join `{{project_id}}.{{prod_dataset_name}}.{{public}}workflow_v1_workflow` as c on b.workflow_id = c.id
where entity_type = 'CONTRACT')


select a.* ,
int.integration_name, int.external_integration_id,
wi.frozen_workflow_title, wi.frozen_workflow_id,
wi.current_workflow_title, wi.workflow_id 

from final_tab as a
left join integration as int on a.contract_id = int.contract_id
left join workflow_info as wi on a.contract_id = wi.contract_id
