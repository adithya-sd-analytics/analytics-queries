with

relevant_workspaces as 
(
SELECT 
    a.id AS workspace_id, 
    a.owner_id, 
    a.name 
FROM `{{project_id}}.{{prod_dataset_name}}.{{public}}sd_organizations_companyprofile` AS a
WHERE EXISTS (
    SELECT 1
    FROM `{{project_id}}.{{prod_dataset_name}}.{{public}}sd_organizations_enhancedflag_company_profiles` AS b
    INNER JOIN `{{project_id}}.{{prod_dataset_name}}.{{public}}sd_organizations_enhancedflag` AS c 
      ON b.enhancedflag_id = c.id
    WHERE b.companyprofile_id = a.id
      AND c.name = 'REMOVE_NON_WORKING_DAYS'
) 
or a.id in (239272) 
),

settings as  
(
select 
tenant_workspace_id, level, owner_id,
max(  REGEXP_REPLACE(
    REGEXP_REPLACE(json_extract_scalar(value, '$.date_format'), r'[\[\]]', ''),
    r' +', ' '                                                 
  )) as date_format,
max(  regexp_replace
  ( REGEXP_REPLACE(
    REGEXP_REPLACE(json_extract_scalar(value, '$.date_time_format'), r'[\[\]]', ''),
    r' +', ' '                                                 
  ),  r'Z|zz', 'Timezone')) as date_time_format,
max( json_extract_scalar(value,'$')) as time_zone,

  from {{project_id}}.{{prod_dataset_name}}.{{public}}settings_manager_settingvalue
where level in ('entity', 'workspace')
and config_key in ('date_format_config', 'date_time_format_config', 'timezone' )
and is_deleted = false
group by 1, 2, 3
),

entities_setup as
(select b.workspace_id, b.name as workspace_name, a.id as entity_id,  a.name as entity_name, a.modified as last_updated_on, 
concat(e.line_one, ' ',line_two) as address, city_name , state_name, f.name as country_name, zipcode, g.name as jurisdiction_of_incorporation, 
coalesce(se.date_format, sr.date_format) as date_format, coalesce(se.date_time_format, sr.date_time_format) as date_time_format, 
coalesce(se.time_zone, sr.time_zone) as timezone

from `{{project_id}}.{{prod_dataset_name}}.{{public}}sd_organizations_v2_organizationentity`  as a
join relevant_workspaces as b on a.organization_id = b.owner_id
left join `{{project_id}}.{{prod_dataset_name}}.{{public}}geo_address` as e on a.primary_address_id = e.id
left join `{{project_id}}.{{prod_dataset_name}}.{{public}}geo_country` as f on e.country_id = f.id
left join `{{project_id}}.{{prod_dataset_name}}.{{public}}geo_country` as g on a.jurisdiction_id = g.id
left join (select * from settings where level = 'workspace') as sr on sr.tenant_workspace_id = b.workspace_id 
left join (select * from settings where level = 'entity') as se on se.owner_id = cast(a.id as string) 
where a.is_deleted = false
order by 1, 2, 3),

entity as 
(select contract_id, b.name as entity, c.timezone as time_zone_setting,
json_extract_scalar(da.value,'$') as default_timezone,
coalesce(c.timezone, json_extract_scalar(da.value,'$')) as timezone,
db.value as target_dates
from `{{project_id}}.{{prod_dataset_name}}.{{public}}contracts_v3_contractrole` as a 
join `{{project_id}}.{{prod_dataset_name}}.{{public}}sd_organizations_v2_organizationentity` as b on a.organization_entity_id = b.id
join relevant_workspaces as rw on b.organization_id = rw.owner_id
left join entities_setup as c on b.id = c.entity_id
left join `{{project_id}}.{{prod_dataset_name}}.default_analytics_setting` as da on da.config_key = 'timezone'
left join `{{project_id}}.{{prod_dataset_name}}.default_analytics_setting` as db on db.config_key = 'non_working_days'
where role = 'CONTRACTOR'),

non_workdays as 
(select id as contract_id, 
start_date, end_date, timezone, offset_seconds_utc_now, 
timestamp_sub(timestamp(generated_date), interval coalesce(offset_seconds_utc_now, 0) second) as weekend_day_start,
least(timestamp_add(timestamp(generated_date), interval (3600*24 - coalesce(offset_seconds_utc_now, 0)) second), 
        current_timestamp) as weekend_day_end, workspace_id
from
    (select id, created as start_date, coalesce(execution_date, current_timestamp) as end_date , b.entity, b.timezone, c.offset_seconds_utc_now,
    timestamp_add(created, interval coalesce(offset_seconds_utc_now, 0) second) as local_start_date,
    timestamp_add(coalesce(execution_date, current_timestamp), interval coalesce(offset_seconds_utc_now, 0) second) as local_end_date,
    target_dates, a.created_by_workspace_id as workspace_id

    from `{{project_id}}.{{prod_dataset_name}}.{{public}}contracts_v3_contractv3` as a
    
    left join entity as b on a.id = b.contract_id
    left join `{{project_id}}.{{prod_dataset_name}}.timezone_table` as c on b.timezone = c.iana_timezone
    where contract_kind not in ('UPLOAD_EXECUTED')
    and status not in ('DELETED', 'VOIDED', 'HARD_DELETED')
    ) as a,
UNNEST(GENERATE_DATE_ARRAY(date(local_start_date), date(local_end_date))) AS generated_date
WHERE EXTRACT(DAYOFWEEK FROM generated_date) IN (
    SELECT CAST(day AS INT64) 
    FROM UNNEST(JSON_VALUE_ARRAY(target_dates)) AS day
)),

PreviousEnds AS (
    SELECT 
        contract_id,
        weekend_day_start,
        weekend_day_end,
        workspace_id,
        MAX(weekend_day_end) OVER (
            PARTITION BY contract_id 
            ORDER BY weekend_day_start, weekend_day_end
            ROWS BETWEEN UNBOUNDED PRECEDING AND 1 PRECEDING
        ) AS prev_max_end
    FROM non_workdays
),

IslandFlags AS (
    SELECT 
        contract_id,
        weekend_day_start,
        weekend_day_end,
        workspace_id,
        CASE 
            WHEN prev_max_end IS NULL THEN 1
            WHEN weekend_day_start > prev_max_end THEN 1
            ELSE 0 
        END AS is_new_island
    FROM PreviousEnds
),

Islands AS (
    SELECT 
        contract_id,
        weekend_day_start,
        weekend_day_end,
        workspace_id,
        SUM(is_new_island) OVER (
            PARTITION BY contract_id 
            ORDER BY weekend_day_start, weekend_day_end
        ) AS island_id
    FROM IslandFlags
),

non_workdays_cleaned as
(select concat('non_work_day_',contract_id,'_', row_number() over(partition by contract_id order by start_time)) as uu_id, *
from
        (SELECT
                contract_id,
                MIN(weekend_day_start) AS start_time,
                MAX(weekend_day_end) AS end_time,
                workspace_id
        FROM Islands
        GROUP BY 
        contract_id, 
        island_id,
        workspace_id
        )
),

on_hold_tab as 
(
select concat('on_hold_',contract_id,'_',row_number() over(partition by contract_id order by created)) as uu_id, contract_id, audit_type, created as on_hold_start, next_ts as on_hold_ends, 
coalesce(next_ts, current_timestamp) as on_hold_ends_current, created_by_workspace as workspace_id from 
  (

  select count(*) over(partition by contract_id), *,
  lead(created) over(partition by contract_id, audit_type order by created) as next_ts,
  lead(on_hold) over(partition by contract_id, audit_type order by created) as next_on_hold
  from
    (select contract_id, created, audit_type, on_hold , 
    lag(on_hold) over(partition by contract_id, audit_type order by created) as pre_on_hold , created_by_workspace,
    on_hold = lag(on_hold) over(partition by contract_id, audit_type order by created) as repeats
    from `{{project_id}}.{{prod_dataset_name}}.cron_audit_table`
    where 
    audit_type in ( 'on-hold-status-update')
    )
  where repeats = false or repeats is null 
) 
where on_hold = 'true' 
and (next_on_hold = 'false' or next_on_hold is null)
),

oh_with_cuts AS (
  SELECT 
    oh.uu_id, -- ADDED uu_id
    oh.contract_id,
    oh.audit_type,
    oh.on_hold_start AS base_start,
    oh.on_hold_ends_current AS base_end,
    oh.on_hold_ends AS original_ends,
    oh.workspace_id,
    GREATEST(oh.on_hold_start, nw.start_time) AS cut_start,
    LEAST(oh.on_hold_ends_current, nw.end_time) AS cut_end
  FROM on_hold_tab oh
  LEFT JOIN non_workdays_cleaned nw 
    ON oh.contract_id = nw.contract_id 
    AND nw.start_time < oh.on_hold_ends_current 
    AND nw.end_time > oh.on_hold_start
),

ordered_cuts AS (
  SELECT 
    uu_id, -- ADDED uu_id
    contract_id,
    audit_type,
    base_start,
    base_end,
    original_ends,
    cut_start,
    cut_end,
    workspace_id,
    ROW_NUMBER() OVER (PARTITION BY contract_id, base_start ORDER BY cut_start) as rn,
    LEAD(cut_start) OVER (PARTITION BY contract_id, base_start ORDER BY cut_start) as next_cut_start,
    COUNT(cut_start) OVER (PARTITION BY contract_id, base_start) as cut_count
  FROM oh_with_cuts
),

split_on_holds AS (
  -- Piece 1: Time BEFORE the FIRST non-workday cut
  SELECT 
    uu_id, -- ADDED uu_id
    contract_id, audit_type, 
    base_start AS on_hold_start, original_ends AS on_hold_end, cut_start AS on_hold_ends_current,
    workspace_id 
  FROM ordered_cuts
  WHERE rn = 1 AND base_start < cut_start

  UNION ALL

  -- Piece 2: Time BETWEEN two consecutive non-workday cuts
  SELECT 
    uu_id, -- ADDED uu_id
    contract_id, audit_type, 
    cut_end AS on_hold_start, original_ends AS on_hold_end, next_cut_start AS on_hold_ends_current,
    workspace_id 
  FROM ordered_cuts
  WHERE next_cut_start IS NOT NULL AND cut_end < next_cut_start

  UNION ALL

  -- Piece 3: Time AFTER the LAST non-workday cut
  SELECT 
    uu_id, -- ADDED uu_id
    contract_id, audit_type, 
    cut_end AS on_hold_start, original_ends AS on_hold_end, base_end AS on_hold_ends_current,
    workspace_id 
  FROM ordered_cuts
  WHERE next_cut_start IS NULL AND cut_end < base_end

  UNION ALL

  -- Piece 4: On Hold records that had NO non-workday overlaps at all
  SELECT 
    uu_id, -- ADDED uu_id
    contract_id, audit_type, 
    base_start AS on_hold_start, original_ends AS on_hold_end, base_end AS on_hold_ends_current,
    workspace_id 
  FROM ordered_cuts
  WHERE cut_count = 0
)

-- Finally, UNION the split on-hold records with the non-workday records
select * from
(SELECT 
  uu_id, -- ADDED uu_id
  contract_id, 
  audit_type, 
  on_hold_start, 
  on_hold_end, 
  on_hold_ends_current,
  workspace_id 
FROM split_on_holds

UNION ALL

SELECT 
  uu_id, -- ADDED uu_id
  contract_id, 
  'non-workday' AS audit_type, 
  start_time AS on_hold_start, 
  NULL AS on_hold_end, 
  end_time AS on_hold_ends_current,
  workspace_id 
FROM non_workdays_cleaned)