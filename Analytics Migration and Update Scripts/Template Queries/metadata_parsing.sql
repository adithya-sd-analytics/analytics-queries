select * from 
(select * , 
CASE 
  WHEN data_type = 'date' THEN
    CASE
      -- Day Month, Year → 31 March, 2020
      WHEN REGEXP_CONTAINS(string_value, r'^\d{1,2}\s+[A-Za-z]+\s*,\s*\d{4}$') THEN 
        SAFE.PARSE_DATE('%d %B, %Y', string_value)

      -- Day Month Year (no comma) → 5 March 2020
      WHEN REGEXP_CONTAINS(string_value, r'^\d{1,2}\s+[A-Za-z]+\s+\d{4}$') THEN 
        SAFE.PARSE_DATE('%d %B %Y', string_value)

      -- Day Short-Month Year → 5 Mar 2020
      WHEN REGEXP_CONTAINS(string_value, r'^\d{1,2}\s+[A-Za-z]{3}\s+\d{4}$') THEN 
        SAFE.PARSE_DATE('%d %b %Y', string_value)

      -- Day Month with ordinal suffix → 30th June 2025
      WHEN REGEXP_CONTAINS(string_value, r'^\d{1,2}(st|nd|rd|th)\s+[A-Za-z]+\s+\d{4}$') THEN 
        SAFE.PARSE_DATE('%d %B %Y', REGEXP_REPLACE(string_value, r'(st|nd|rd|th)', ''))

      -- Short month with ordinal suffix → Dec 17th 2025
      WHEN REGEXP_CONTAINS(string_value, r'^[A-Za-z]{3}\s+\d{1,2}(st|nd|rd|th)\s+\d{4}$') THEN 
        SAFE.PARSE_DATE('%b %d %Y', REGEXP_REPLACE(string_value, r'(st|nd|rd|th)', ''))

      -- Long month with comma → December 12, 2022
      WHEN REGEXP_CONTAINS(string_value, r'^[A-Za-z]+\s+\d{1,2},\s*\d{4}$') THEN 
        SAFE.PARSE_DATE('%B %d, %Y', string_value)

      -- D-M-YYYY or DD-MM-YYYY → 30-06-2025
      WHEN REGEXP_CONTAINS(string_value, r'^\d{1,2}-\d{1,2}-\d{4}$') THEN 
        SAFE.PARSE_DATE('%d-%m-%Y', string_value)

      -- D/M/YYYY or DD/MM/YYYY → 30/05/2024
      WHEN REGEXP_CONTAINS(string_value, r'^\d{1,2}/\d{1,2}/\d{4}$') THEN 
        SAFE.PARSE_DATE('%d/%m/%Y', string_value)

      -- M/D/YYYY or MM/DD/YYYY (U.S. style) → 3/7/2020, 12/31/2020
      WHEN REGEXP_CONTAINS(string_value, r'^\d{1,2}/\d{1,2}/\d{4}$') THEN 
        SAFE.PARSE_DATE('%m/%d/%Y', string_value)

      -- ISO style YYYY-MM-DD or YYYY-M-D → 2020-03-31, 2022-9-8
      WHEN REGEXP_CONTAINS(string_value, r'^\d{4}-\d{1,2}-\d{1,2}$') THEN 
        SAFE.PARSE_DATE('%Y-%m-%d', string_value)

      -- Month Day, Year (numeric month) → 12 31, 2023
      WHEN REGEXP_CONTAINS(string_value, r'^\d{1,2}\s+\d{1,2},\s*\d{4}$') THEN 
        SAFE.PARSE_DATE('%m %d, %Y', string_value)

      -- ISO 8601 with time → 2022-08-05T00:00:00.000Z
      WHEN REGEXP_CONTAINS(string_value, r'^\d{4}-\d{1,2}-\d{1,2}T') THEN 
        SAFE.PARSE_DATE('%Y-%m-%d', REGEXP_EXTRACT(string_value, r'^(\d{4}-\d{1,2}-\d{1,2})'))

      ELSE NULL
    END
  ELSE NULL
END AS parsed_date_value,

case 
  when data_type in ('string', 'dropdown', 'rich-text', 'check-box' , 'text-box') then string_value
  when data_type in ('phone-number') then concat(coalesce(json_extract_scalar(value, '$.country_code'),''),' ' ,coalesce(json_extract_scalar(value, '$.code'), ''), ' - ',coalesce(json_extract_scalar(value, '$.number'), '') )

  WHEN data_type = 'multi-text-input' THEN
      (SELECT STRING_AGG(JSON_VALUE(x, '$.displayValue'), ', ') FROM UNNEST(JSON_EXTRACT_ARRAY(value)) AS x)
  WHEN data_type = 'multi-dropdown' then 
      (SELECT STRING_AGG(JSON_VALUE(x, '$'), ', ') FROM UNNEST(JSON_EXTRACT_ARRAY(value)) AS x)

  when data_type = 'currency' then concat(json_extract_scalar(value, '$.type'), ' ', json_extract_scalar(value, '$.value'))
  when data_type = 'duration' and SAFE_CAST(json_extract_scalar(value, '$.value') as float64) = 1 
    then concat(json_extract_scalar(value, '$.value'), ' ', initcap(substring(json_extract_scalar(value, '$.type'), 0,length(json_extract_scalar(value, '$.type')) -1 ))  )
    when data_type = 'duration' and SAFE_CAST(json_extract_scalar(value, '$.value') as float64) != 1 
    then concat(json_extract_scalar(value, '$.value'), ' ', initcap((json_extract_scalar(value, '$.type'))))
end as parsed_string_value,

CASE
  WHEN data_type = 'number' and REGEXP_CONTAINS(string_value, r'^-?\d+(\.\d+)?$') THEN SAFE_CAST(string_value AS FLOAT64)
  when data_type = 'currency' then SAFE_CAST(json_extract_scalar(value, '$.value') as float64)
  when data_type = 'duration' and json_extract_scalar(value, '$.type') = 'MONTHS' then SAFE_CAST(json_extract_scalar(value, '$.value') as float64) * 30
  when data_type = 'duration' and json_extract_scalar(value, '$.type') = 'YEARS' then SAFE_CAST(json_extract_scalar(value, '$.value') as float64) * 365
  when data_type = 'duration' and json_extract_scalar(value, '$.type') = 'WEEKS' then SAFE_CAST(json_extract_scalar(value, '$.value') as float64) * 7
  when data_type = 'duration' and json_extract_scalar(value, '$.type') = 'DAYS' then SAFE_CAST(json_extract_scalar(value, '$.value') as float64) * 1
  ELSE NULL
END as parsed_number_value
from
(select b.label, b.data_type, b.field_name, a.contract_id, a.value, json_extract_scalar(value) as string_value ,b.created_by_workspace_id as created_by_workspace, a.created , row_number() over(partition by contract_id, field_name order by a.created desc) as rn
from `{{project_id}}.{{prod_dataset_name}}.{{public}}contracts_v3_contractkeypointer` as a
join `{{project_id}}.{{prod_dataset_name}}.{{public}}historic_contracts_keypointer` as b on a.key_pointer_id = b.id
where b.is_deleted = false
and b.is_visible = true)
where rn = 1
) 
