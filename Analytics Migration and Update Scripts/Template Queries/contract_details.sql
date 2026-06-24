with 

redline_entry as 
(select distinct contract_id from `{{project_id}}.{{prod_dataset_name}}.cron_audit_table`
where audit_type in ('send-to-counterparty-v2', 'send-to-counterparty', 'contract-moved-to-redlining')),

on_hold as 
(SELECT contract_id, on_hold FROM `{{project_id}}.{{prod_dataset_name}}.{{public}}contracts_v3_contractprofile` as a 
where on_hold = true),


base_details as 
(select ab.id as contract_id, ab.created as contract_created, ab.execution_date, ab.status, ab.workflow_status, 
ab.contract_type_id, ab.contract_template_id, ab.created_by_workspace_id as workspace_id, ab.created_by_id,
a.org_user_id as bussiness_org_id, b.org_user_id as legal_org_id ,
concat(c.first_name, ' ',c.last_name) as business_user, concat(d.first_name, ' ',d.last_name) as legal_user, 
 case
      when (campaign_v3_id) is not null then 'Campaign Contracts' 
      when ab.contract_kind in ( 'TEMPLATE_EDITABLE') then 'Template Contracts (Redlined)'
      when ab.contract_kind in ('TEMPLATE') then 'Template Contracts'
      when ab.contract_kind in ('EXPRESS_TEMPLATE') then 'Express Template Contracts'
      when ab.contract_kind in ('UPLOAD_EXECUTED') then 'Externally Executed Contracts'
      when ab.contract_kind in ('UPLOAD_SIGN') then 'Upload Sign Contracts'
      when ab.contract_kind in ('CLICKWRAP') then 'Clickwrap Contracts'
      else 'Uploaded for review'
  end as contract_kind,
    case 
      when ab.status in ('VOIDED') then 'Voided'
      when on_hold = true then 'On Hold'
      when ab.contract_kind in ('UPLOAD_EDITABLE', 'TEMPLATE_EDITABLE') and ab.workflow_status not in ('COMPLETED', 'SIGN' ) then 'Redlining'
      when ab.contract_kind in ('UPLOAD_SIGN') and ab.workflow_status not in ('COMPLETED') then 'Sign'
      when ab.workflow_status = 'COMPLETED' then 'Executed'
      when ab.contract_kind in ('TEMPLATE', 'EXPRESS_TEMPLATE') and ab.workflow_status in ('SIGN') then 'Sign'
      when ab.contract_kind in ('TEMPLATE', 'EXPRESS_TEMPLATE') and re.contract_id is null then 'Draft'
      when ab.contract_kind in ('TEMPLATE', 'EXPRESS_TEMPLATE') and re.contract_id is not null then 'Redlining'
      else initcap(ab.workflow_status)
    end as contract_display_status,
ct.display_name as contract_type,
coalesce(tem.internal_name, '--') as template_name,
concat('https://app.spotdraft.com/contracts/v2/', ab.id) as contract_link
 from  `{{project_id}}.{{prod_dataset_name}}.{{public}}contracts_v3_contractv3` as ab
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
left join redline_entry as re
on ab.id = re.contract_id
left join on_hold as oh 
on ab.id = oh.contract_id
left join `{{project_id}}.{{prod_dataset_name}}.{{public}}contracts_v3_workspacecontracttype` as ct 
on ab.contract_type_id = ct.contract_type_id and ct.workspace_id = ab.created_by_workspace_id
left join `{{project_id}}.{{prod_dataset_name}}.{{public}}contracts_templateworkspaceaccess` as tem  
on tem.contract_template_id = ab.contract_template_id and tem.workspace_id = ab.created_by_workspace_id
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
)),

integration as
(select * from
(select contract_id, external_metadata_id as external_integration_id, external_metadata ,
initcap(json_extract_scalar(external_metadata, '$.integration_name')) as integration_name, row_number() over(partition by contract_id order by id desc) as rn
from `{{project_id}}.{{prod_dataset_name}}.{{public}}{{public}}externalintegrationcontractdetail`
where json_extract_scalar(external_metadata, '$.integration_name') is not null)
where rn = 1),

workflow_info as 
(select a.entity_id contract_id, b.title as frozen_workflow_title, b.id as frozen_workflow_id,
 c.title as current_workflow_title, c.id as workflow_id 
 from `{{project_id}}.{{prod_dataset_name}}.{{public}}workflow_v1_frozenworkflowtoconsumerentitymapping` as a
join `{{project_id}}.{{prod_dataset_name}}.{{public}}workflow_v1_frozenworkflow` as b on a.frozen_workflow_id = b.id
join `{{project_id}}.{{prod_dataset_name}}.{{public}}workflow_v1_workflow` as c on b.workflow_id = c.id
where entity_type = 'CONTRACT'),

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
) ,

contract_created_by as
(select * from
  (select user_id, first_name, last_name, row_number() over(partition by user_id order by created desc) as rn from `{{project_id}}.{{prod_dataset_name}}.{{public}}sd_organizations_organizationuser`)
where rn = 1
),

final_tab as
(select a.*, 
b.cp_name,
c.entity,
d.external_integration_id, d.integration_name,
e.frozen_workflow_title, e.frozen_workflow_id, e.current_workflow_title, e.workflow_id,
concat(b.cp_name, ', ', c.entity) as cp_and_entity,
coalesce(f.con_name, 'No Title') as con_name,
g.teams as  business_user_teams,
date(date_trunc(contract_created, month)) as month_created_on,
concat(h.first_name, ' ', h.last_name) as contract_created_by,
3600 as timescale
from base_details as a
left join cp_name as b on a.contract_id = b.contract_id
left join entity as c on a.contract_id = c.contract_id
left join integration as d on a.contract_id = d.contract_id
left join workflow_info as e on a.contract_id = e.contract_id
left join con_name as f on a.contract_id = f.con_id
left join `{{project_id}}.{{prod_dataset_name}}.Teams` as g on a.bussiness_org_id = g.id
left join contract_created_by as h on a.created_by_id = h.user_id )



select * from final_tab
