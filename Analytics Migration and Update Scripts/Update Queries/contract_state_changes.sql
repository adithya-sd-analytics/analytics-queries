with 
redlining_entry as 
(select contract_id, min(created) as redline_started from 
     (
     select contract_id, a.created from `spotdraft-prod.prod_india_db.cron_audit_table` as a 
     join `spotdraft-prod.prod_india_db.public_contracts_v3_contractv3` as b on a.contract_id = b.id
     where audit_type in ('send-to-counterparty-v2', 'send-to-counterparty')
     and contract_id is not null
     and contract_kind in ('TEMPLATE', 'TEMPLATE_EDITABLE', 'EXPRESS_TEMPLATE')

     union all 
     select contract_id, created from `spotdraft-prod.prod_india_db.public_contracts_v3_contractversion`
     where action = 'BASE_EDITABLE'
     union all
     select contract_id, a.created from `spotdraft-prod.prod_india_db.cron_audit_table` as a 
     join `spotdraft-prod.prod_india_db.public_contracts_v3_contractv3` as b on a.contract_id = b.id
     where audit_type in ( 'contract-moved-to-redlining')
     and contract_id is not null
     -- and contract_kind not in ('UPLOAD_SIGN')

     )

group by 1),



audit_stage_changes as 
(select  
case
  when split(on_hold, '~')[safe_offset(1)] in ('SIGN', 'COMPLETING') then 'SIGN'
  when split(on_hold, '~')[safe_offset(1)] = 'COMPLETED' then 'EXECUTED'
  -- TEMPLATE-only branch: DRAFT vs REDLINING depends on redline_started
  when contract_kind in ('TEMPLATE', 'TEMPLATE_EDITABLE')
       and redline_started is not null
       and a.created >= redline_started then 'REDLINING'
  when contract_kind in ('TEMPLATE', 'TEMPLATE_EDITABLE')
       and (redline_started is null or a.created < redline_started) then 'DRAFT'
  -- all non-TEMPLATE kinds default to REDLINING outside SIGN/COMPLETED
  when contract_kind in ('TEMPLATE_EDITABLE', 'UPLOAD_SIGN', 'UPLOAD_EDITABLE', 'EXPRESS_TEMPLATE')
       and split(on_hold, '~')[safe_offset(1)] not in ('SIGN', 'COMPLETING', 'COMPLETED') then 'REDLINING'
  else 'test'
end as new_status_alt,

case
  when split(on_hold, '~')[safe_offset(0)] in ('SIGN', 'COMPLETING') then 'SIGN'
  when split(on_hold, '~')[safe_offset(0)] = 'COMPLETED' then 'EXECUTED'
  -- TEMPLATE-only branch: DRAFT vs REDLINING depends on redline_started
  when contract_kind in ('TEMPLATE', 'TEMPLATE_EDITABLE')
       and redline_started is not null
       and a.created >= redline_started then 'REDLINING'
  when contract_kind in ('TEMPLATE', 'TEMPLATE_EDITABLE')
       and (redline_started is null or a.created < redline_started) then 'DRAFT'
  -- all non-TEMPLATE kinds default to REDLINING outside SIGN/COMPLETED
  when contract_kind in ( 'UPLOAD_SIGN', 'UPLOAD_EDITABLE', 'EXPRESS_TEMPLATE')
       and split(on_hold, '~')[safe_offset(0)] not in ('SIGN', 'COMPLETING', 'COMPLETED') then 'REDLINING'
  else 'test'
end as old_status_alt,
-- split(on_hold, '~')[safe_offset(1)], split(on_hold, '~')[safe_offset(0)],
a.contract_id, c.created as contract_created,
a.created, created_by_workspace as workspace_id, b.redline_started, c.contract_kind, c.status, c.created_by_workspace_id
from `spotdraft-prod.prod_india_db.cron_audit_table` as a
join `spotdraft-prod.prod_india_db.public_contracts_v3_contractv3` as c on a.contract_id =c.id
left join redlining_entry as b on a.contract_id = b.contract_id
where audit_type = 'workflow-status-update'
and a.contract_id is not null
order by contract_id desc, created

),

template_editable_transition as
(select distinct 'REDLINING' as new_status, cast(null as string), a.contract_id, c.created as contract_created, min(a.created) over(partition by a.contract_id) as created,
a.created_by_workspace_id, b.redline_started, c.contract_kind, c.status, c.created_by_workspace_id
from `spotdraft-prod.prod_india_db.public_contracts_v3_contractversion` as a
join `spotdraft-prod.prod_india_db.public_contracts_v3_contractv3` as c on a.contract_id = c.id
left join redlining_entry as b on a.contract_id = b.contract_id
where action = 'BASE_EDITABLE'
),


contract_voided as
(select 'VOIDED' as new_status, cast(null as string) as old_status, a.contract_id, b.created as contract_created, a.created, a.created_by_workspace, c.redline_started,
b.contract_kind, cast(null as string) as status, created_by_workspace_id
from `spotdraft-prod.prod_india_db.cron_audit_table` as a
join `spotdraft-prod.prod_india_db.public_contracts_v3_contractv3` as b on a.contract_id = b.id
left join redlining_entry as c on a.contract_id = c.contract_id
where audit_type = 'contract-voided'
)

,
redlining_status as
(
select 'REDLINING' as status, cast(null as string) as old_status, a.contract_id, b.created as contract_created, a.redline_started, 
b.created_by_workspace_id, a.redline_started, b.contract_kind,  cast(null as string) as status, created_by_workspace_id
from redlining_entry as a
join `spotdraft-prod.prod_india_db.public_contracts_v3_contractv3` as b on a.contract_id = b.id
)
,

transitions as
(select *, row_number() over(partition by contract_id order by created) as transition_order from
     (
     select new_status_alt, coalesce(old_status_alt, lag(new_status_alt) over(partition by contract_id order by created), 'DRAFT') as old_status_alt,
     contract_id, contract_created, created, workspace_id, redline_started, contract_kind, status, reason, created_by_workspace_id
     from
          (
          select *, 'state_change' as reason from audit_stage_changes
          union all 
          select *, 'convert_to_editable' as reason from template_editable_transition
          union all
          select *,  'state_change' as reason  from contract_voided
          union all
          select *, 'state_change'  from redlining_status 

          )
     )
where new_status_alt != old_status_alt)

,
final as 
(select *, row_number() over(partition by contract_id, status order by created) as status_order, row_number() over(partition by contract_id, status order by created desc) as status_order_rev , row_number() over(partition by contract_id order by created) as lifecycle_order
from 
     (
          (select contract_id, new_status_alt as status, old_status_alt as previous_status, 
          created, contract_kind, reason, created_by_workspace_id from transitions)

     union all

          (select id as contract_id, 
          case 
               when contract_kind in ('TEMPLATE', 'TEMPLATE_EDITABLE') then 'DRAFT' 
               when contract_kind = 'UPLOAD_SIGN' then 'SIGN'
               when contract_kind in ('UPLOAD_EDITABLE', 'EXPRESS_TEMPLATE') then 'REDLINING'
          end as new_status 
          , null as previous_status, created as contract_created, contract_kind, 'CONTRACT_CREATED' reason, created_by_workspace_id 
               from `spotdraft-prod.prod_india_db.public_contracts_v3_contractv3`
               where contract_kind in ('TEMPLATE', 'TEMPLATE_EDITABLE', 'UPLOAD_EDITABLE', 'EXPRESS_TEMPLATE','UPLOAD_SIGN')
          )
     order by contract_id desc, created
     )
)

select * from final