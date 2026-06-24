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

exec_date as (
  select *  
  from (
    select 
      contract_id,
      --cast(json_extract_scalar(value, '$') as date) as Execution_date,
      date((substr((cast(json_extract_scalar(value,'$') as string)),1,10 ))) as Execution_date, 
      cast(created as date) as created, 
      row_number() over(partition by contract_id order by created desc) as rn 
    from `{{project_id}}.{{prod_dataset_name}}.{{public}}contracts_v3_contractkeypointer`
    where key_pointer_id in (
      select 
        id 
      from `{{project_id}}.{{prod_dataset_name}}.{{public}}historic_contracts_keypointer`
       where (well_known_type = 'EXECUTION_DATE' or label = 'Execution Date' or id in (48013)) --- note the kp should be of type date
      -- and created_by_workspace_id = @workspace_id
    ) 
    and regexp_contains(cast(json_extract_scalar(value,'$') as string), r'\d{4}\-(0?[1-9]|1[012])\-(0?[1-9]|[12][0-9]|3[01])')
  ) as a where rn = 1
),

expiry_date as (
  select * 
  from (
    select 
      contract_id,
      value,
      --cast(json_extract_scalar(value, '$') as date) as Expiry_date,
      date((substr((cast(json_extract_scalar(value,'$') as string)),1,10 ))) as Expiry_date, 
      cast(created as date) as created, 
      row_number() over(partition by contract_id order by created desc) as rn 
    from `{{project_id}}.{{prod_dataset_name}}.{{public}}contracts_v3_contractkeypointer`
    where key_pointer_id in (
      select id from `{{project_id}}.{{prod_dataset_name}}.{{public}}historic_contracts_keypointer`
      where (well_known_type = 'EXPIRATION_DATE'
              or 
              id in ( 48016) 
      )--- note the kp should be of type date
      and data_type = 'date'
      -- and created_by_workspace_id = @workspace_id
    ) 
    and regexp_contains(cast(json_extract_scalar(value,'$') as string), r'\d{4}\-(0?[1-9]|1[012])\-(0?[1-9]|[12][0-9]|3[01])')
    and id not in  (7966737,7966736)
  ) as a 
  where rn = 1
),

post_exec as (
  select * 
  from (
    select 
      contract_id, 
      replace(cast(json_extract_scalar(value, '$') as string), '"','') as Post_exec_status, 
      cast(created as date) as created, 
      row_number() over(partition by contract_id) as rn 
    from `{{project_id}}.{{prod_dataset_name}}.{{public}}contracts_v3_contractkeypointer`
    where key_pointer_id in (
      select 
        id 
      from `{{project_id}}.{{prod_dataset_name}}.{{public}}historic_contracts_keypointer`
      where ( label = 'Post-Execution Status'
      --[[or id in ({{expiry_date_kp}})]] --- post exec kp
      )
      -- and created_by_workspace_id =  @workspace_id
    ) 
  ) as a 
  where rn = 1
  -- and Post_exec_status != 'Active'
),


term_length as (
  select 
    contract_id,  
    term_length,  --term_length_days,
    case 
      when regexp_contains(term_length, r'^[0-9]+ (day|month|year|week)s?') then replace(term_length, 's', '')
    end as string_term_length
  from (
    select 
      contract_id, 
      --(value->'days')::int as term_length_days, 
      case
        when replace(replace(cast(json_extract_scalar(value, '$') as string), '"', ''), '  ', '') not like '{%}' then replace(replace(cast(json_extract_scalar(value, '$') as string), '"', ''), '  ', '') -- for string Kps
        else lower(replace(concat(cast(json_extract_scalar(value, '$.value') as string), ' ', cast(json_extract_scalar(value, '$.type') as string)), '"', '')) -- for duration Kps
      end as term_length,
      cast(created as date) as created, 
      row_number() over(partition by contract_id order by created desc) as rn 
    from `{{project_id}}.{{prod_dataset_name}}.{{public}}contracts_v3_contractkeypointer`
    where key_pointer_id in (
                              select 
                                id 
                              from `{{project_id}}.{{prod_dataset_name}}.{{public}}historic_contracts_keypointer`
                              where (lower(label) like 'term length'
                              or id = 48015) -- KPs must be either string or duration
                              -- and created_by_workspace_id =  @workspace_id
                            
                            )
  and id not in (select id from `{{project_id}}.{{prod_dataset_name}}.{{public}}contracts_v3_contractkeypointer` where cast(json_extract_scalar(value, '$.days')as float64) > 36500)
  ) as a 
  where rn = 1
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


raw_data_status as (
  select 
    a.*, 
    contr.con_name as contract_name, 
    case when a.status != 'COMPLETED' then  (workflow_status) ELSE 'EXECUTED' END AS contract_status,
    ct.display_name as contract_type, 
    ty.internal_name as Template_name, 
    cast(ex.Execution_date as date) as Execution_date_kp,
    cast(coalesce(ex.Execution_date, a.Execution_date) as date) as Execution_date_combined,
    term_length, 
    cast(ep.expiry_date as date) as expiry_date_kp,
    case
      when split(string_term_length, ' ')[safe_offset(1)] = 'day' then coalesce(ep.expiry_date, date_add(coalesce(ex.Execution_date, a.Execution_date), interval cast(split(string_term_length, ' ')[safe_offset(0)] as int64) DAY) - 1)
      when split(string_term_length, ' ')[safe_offset(1)] = 'week' then coalesce(ep.expiry_date, date_add(coalesce(ex.Execution_date, a.Execution_date), interval cast(split(string_term_length, ' ')[safe_offset(0)] as int64) WEEK) - 1)
      when split(string_term_length, ' ')[safe_offset(1)] = 'month' then coalesce(ep.expiry_date, date_add(coalesce(ex.Execution_date, a.Execution_date), interval cast(split(string_term_length, ' ')[safe_offset(0)] as int64) MONTH) - 1)
      when split(string_term_length, ' ')[safe_offset(1)] = 'year' then coalesce(ep.expiry_date, date_add(coalesce(ex.Execution_date, a.Execution_date), interval cast(split(string_term_length, ' ')[safe_offset(0)] as int64) YEAR) - 1)
      else ep.expiry_date
    end as expiry_date_combined, 
-- (coalesce(ex.Execution_date, a.Execution_date) ::date + term_length_days -1 ) as expiry_days_kp,
-- tl.term_length_days, 
    pe.Post_exec_status
  from all_con as a 
  left join exec_date as ex on a.id = ex.contract_id
  left join expiry_date as ep on a.id = ep.contract_id
  left join term_length as tl on a.id = tl.contract_id
  left join post_exec as pe on a.id = pe.contract_id
  left join `{{project_id}}.{{prod_dataset_name}}.{{public}}contracts_v3_workspacecontracttype` as ct on a.contract_type_id = ct.contract_type_id and a.created_by_workspace_id = ct.workspace_id
  left join `{{project_id}}.{{prod_dataset_name}}.{{public}}contracts_templateworkspaceaccess` as ty on a.contract_template_id = ty.contract_template_id and a.created_by_workspace_id = ty.workspace_id
  left join (
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
    ) as ab
    where row_number = 1
  ) as contr 
  on a.id = contr.con_id 
  left join (
    select * 
    from (
      select 
        contract_id, 
        contract_display_status, 
        row_number() over(partition by contract_id order by timestamp desc) as rn 
      from `{{project_id}}.{{prod_dataset_name}}.{{public}}spot_insights_contractevent`
    ) as a 
    where rn = 1
  ) as ds 
  on a.id = ds.contract_id 
),

final_tab as
(select 
  id, 
  cast(created as date) as created, 
  created_by_id,
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
  contract_type_id, contract_template_id, 
  initcap(contract_status) as con_status, 
  contract_name, 
  contract_type, 
  template_name,
  Execution_date_combined as Execution_date, 
  term_length, 
  expiry_date_combined as expiry_date, 
  date_trunc(expiry_date_combined,month) as Expiry_Month,
  date_trunc(created,month) as Creation_Month,
  date_trunc(execution_date_combined,month) as Execution_Month,
  Post_exec_status,
  case
      when status = 'COMPLETED' and Post_exec_status is not null then Post_exec_status 
      when status = 'COMPLETED' and expiry_date_combined >= current_date then 'Active Contracts' 
      when status = 'COMPLETED' and expiry_date_combined < current_date then 'Expired Contracts'
      when status = 'COMPLETED' and expiry_date_combined is null and Post_exec_status is null then 'Executed Contracts, no Expiry date'
      when status = 'COMPLETED' and expiry_date_combined is null then 'Expired Contracts'
      when status != 'COMPLETED' then initcap(contract_status)
      else 'N/A'
  end as Exec_status, 
  created_by_workspace_id as workspace_id,
  concat('https://app.spotdraft.com/contracts/v2/',id) as contract_link
from raw_data_status )

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


(select  a.*, b.cp_name, c.legal_org_id, c.legal_user, c.bussiness_org_id ,c.business_user, d.entity, concat(cp_name, ', ', d.entity) as cp_and_entity , e.teams as business_user_teams,
int.integration_name, int.external_integration_id,
wi.frozen_workflow_title, wi.frozen_workflow_id,
wi.current_workflow_title, wi.workflow_id 
 from final_tab as a 
left join cp_name as b on a.id = b.contract_id 
left join bus_legal as c on a.id = c.contract_id
left join entity as d on a.id = d.contract_id
left join `{{prod_dataset_name}}.Teams` as e on c.bussiness_org_id = e.id
left join `{{project_id}}.{{prod_dataset_name}}.{{public}}contracts_v3_bulkuploaddetail` as ae on ae.contract_id = a.id

left join integration as int on a.id = int.contract_id
left join workflow_info as wi on a.id = wi.contract_id
where (ae.upload_status = 'PROCESSED' or ae.upload_status is null)
)


