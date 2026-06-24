#!/usr/bin/env python3
"""Create or dry-run BigQuery scheduled queries from SQL templates."""

from __future__ import annotations

import argparse
from dataclasses import dataclass
from pathlib import Path
import time
from typing import Dict, List

from google.cloud import bigquery
from google.cloud import bigquery_datatransfer
from google.protobuf import timestamp_pb2


TEMPLATE_VALUES: Dict[str, str] = {
    "dataset_name": "Metadata_views_IN",
    "prod_dataset_name": "prod_india_db",
    "Analytics_base_dataset_name": "Test_Dataset_for_BI",
    "metadata_dataset_name": "Metadata_views_IN",
    "internal_dataset_name": "Internal_Dataset_IN",
    "pricing_dataset_name": "pricing_metrics",
    "public": "public_",
    "project_id": "spotdraft-prod",
}

DEFAULT_GCP_SERVER_LOCATION = "asia-south1"
AUDIT_TO_DEPENDENTS_WAIT_SECONDS = 120
TABLE_POPULATION_TIMEOUT_SECONDS = 900
TABLE_POPULATION_POLL_SECONDS = 20

PRIMARY_DEPENDENCY_QUERY = "Auto Audit cron table"
SECOND_WAVE_QUERIES = {
    "Auto Contract stages",
    "Auto Contract turns",
    "Auto Contract review",
    "Auto Contract signatory table",
}
IMMEDIATE_RUN_QUERIES = {PRIMARY_DEPENDENCY_QUERY, *SECOND_WAVE_QUERIES}


@dataclass(frozen=True)
class ScheduledQuerySpec:
    display_name: str
    template_file: str
    dataset_id: str
    destination_table: str
    schedule: str = "every 24 hours"
    write_disposition: str = "WRITE_TRUNCATE"


SCHEDULED_QUERIES: List[ScheduledQuerySpec] = [
    # Dependency order (upstream first):
    # cron audit table -> contract stages -> contract turns
    # -> contract review -> contract signatory -> all other derived tables
    ScheduledQuerySpec(
        display_name="Auto Audit cron table",
        template_file="audit_cron_table.sql",
        dataset_id="{{dataset_name}}",
        destination_table="cron_audit_table",
    ),
    ScheduledQuerySpec(
        display_name="Auto Contract stages",
        template_file="contract_state_changes.sql",
        dataset_id="{{prod_dataset_name}}",
        destination_table="state_changes_table",
    ),
    ScheduledQuerySpec(
        display_name="Auto Contract turns",
        template_file="contract_turns_logs.sql",
        dataset_id="{{prod_dataset_name}}",
        destination_table="turn_logs_table",
    ),
    ScheduledQuerySpec(
        display_name="Auto Contract review",
        template_file="contract_reviews.sql",
        dataset_id="{{dataset_name}}",
        destination_table="contract_reviews",
    ),
    ScheduledQuerySpec(
        display_name="Auto Contract signatory table",
        template_file="contract_signatory_table.sql",
        dataset_id="{{dataset_name}}",
        destination_table="contract_signatory_table",
    ),
    # Remaining scheduled queries.
    ScheduledQuerySpec(
        display_name="Auto Contract Approvals",
        template_file="contract_approvals.sql",
        dataset_id="{{dataset_name}}",
        destination_table="contract_approvals",
    ),
    ScheduledQuerySpec(
        display_name="Auto Contract Lifecycle",
        template_file="contract_lifecycle.sql",
        dataset_id="{{dataset_name}}",
        destination_table="contract_lifecycle",
    ),
    ScheduledQuerySpec(
        display_name="Auto Contract TAT details",
        template_file="contract_tat_details.sql",
        dataset_id="{{dataset_name}}",
        destination_table="contract_tat_details",
    ),
    ScheduledQuerySpec(
        display_name="Auto Contract level metrics",
        template_file="contract_level_metrics.sql",
        dataset_id="{{dataset_name}}",
        destination_table="contract_level_metrics",
    ),
    ScheduledQuerySpec(
        display_name="Auto On hold non workdays",
        template_file="on_hold_non_workdays.sql",
        dataset_id="{{prod_dataset_name}}",
        destination_table="on_hold_non_work_days",
    ),
    ScheduledQuerySpec(
        display_name="Auto Contract details",
        template_file="contract_details.sql",
        dataset_id="{{prod_dataset_name}}",
        destination_table="Analytics_contract_details",
    ),
    ScheduledQuerySpec(
        display_name="Auto Metadata parsing",
        template_file="metadata_parsing.sql",
        dataset_id="{{prod_dataset_name}}",
        destination_table="parsed_contractkeypointer",
    ),
]


def render_template(content: str, values: Dict[str, str]) -> str:
    rendered = content
    for key, value in values.items():
        rendered = rendered.replace(f"{{{{{key}}}}}", value)
    return rendered


def parse_template_values(overrides: List[str]) -> Dict[str, str]:
    values = dict(TEMPLATE_VALUES)
    for item in overrides:
        if "=" not in item:
            raise ValueError(f"Invalid --set '{item}'. Expected key=value.")
        key, value = item.split("=", 1)
        values[key.strip()] = value.strip()
    return values


def create_scheduled_query(
    client: bigquery_datatransfer.DataTransferServiceClient,
    project_id: str,
    location: str,
    display_name: str,
    dataset_id: str,
    destination_table: str,
    query: str,
    schedule: str,
    write_disposition: str,
) -> str:
    parent = f"projects/{project_id}/locations/{location}"
    transfer_config = bigquery_datatransfer.TransferConfig(
        destination_dataset_id=dataset_id,
        display_name=display_name,
        data_source_id="scheduled_query",
        schedule=schedule,
        params={
            "query": query,
            "destination_table_name_template": destination_table,
            "write_disposition": write_disposition,
        },
    )
    response = client.create_transfer_config(
        request=bigquery_datatransfer.CreateTransferConfigRequest(
            parent=parent,
            transfer_config=transfer_config,
        )
    )
    return response.name


def trigger_manual_run(
    client: bigquery_datatransfer.DataTransferServiceClient,
    transfer_config_name: str,
) -> None:
    requested_run_time = timestamp_pb2.Timestamp()
    requested_run_time.GetCurrentTime()
    client.start_manual_transfer_runs(
        request=bigquery_datatransfer.StartManualTransferRunsRequest(
            parent=transfer_config_name,
            requested_run_time=requested_run_time,
        )
    )


def wait_for_table_population(
    bq_client: bigquery.Client,
    project_id: str,
    dataset_id: str,
    table_name: str,
    timeout_seconds: int = TABLE_POPULATION_TIMEOUT_SECONDS,
    poll_seconds: int = TABLE_POPULATION_POLL_SECONDS,
) -> None:
    table_ref = f"`{project_id}.{dataset_id}.{table_name}`"
    query = f"SELECT COUNT(1) AS row_count FROM {table_ref}"
    start = time.time()
    while True:
        try:
            rows = list(bq_client.query(query).result())
            row_count = int(rows[0]["row_count"]) if rows else 0
            if row_count > 0:
                return
        except Exception:
            # Table may not exist yet right after run trigger.
            pass

        if time.time() - start >= timeout_seconds:
            raise TimeoutError(
                f"Timed out waiting for populated table {project_id}.{dataset_id}.{table_name}. "
                f"Expected at least 1 row within {timeout_seconds} seconds."
            )
        time.sleep(poll_seconds)


def main() -> None:
    parser = argparse.ArgumentParser(
        description="Create BigQuery scheduled queries from SQL templates."
    )
    parser.add_argument(
        "--templates-dir",
        default="Template Queries",
        help="Directory containing .sql template files.",
    )
    parser.add_argument(
        "--cluster-id",
        required=True,
        help="Cluster identifier to suffix each scheduled query name.",
    )
    parser.add_argument(
        "--gcp-server-location",
        "--location",
        dest="gcp_server_location",
        default=DEFAULT_GCP_SERVER_LOCATION,
        help="GCP location/region for BigQuery Data Transfer configs.",
    )
    parser.add_argument(
        "--set",
        action="append",
        default=[],
        help="Override template key as key=value. Can be passed multiple times.",
    )
    parser.add_argument(
        "--apply",
        action="store_true",
        help="Actually create scheduled queries (default is dry-run).",
    )
    args = parser.parse_args()

    values = parse_template_values(args.set)
    templates_dir = Path(args.templates_dir)
    project_id = values["project_id"]
    cluster_id = args.cluster_id.strip()
    if not cluster_id:
        raise ValueError("--cluster-id cannot be empty.")

    client = bigquery_datatransfer.DataTransferServiceClient()
    bq_client = bigquery.Client(project=project_id)
    dry_run = not args.apply

    for spec in SCHEDULED_QUERIES:
        template_path = templates_dir / spec.template_file
        if not template_path.exists():
            raise FileNotFoundError(f"Template missing: {template_path}")

        raw_sql = template_path.read_text()
        if not raw_sql.strip():
            raise ValueError(
                f"Template is empty: {template_path}. "
                "Save/paste SQL before running this script."
            )

        rendered_sql = render_template(raw_sql, values)
        rendered_dataset_id = render_template(spec.dataset_id, values)
        rendered_destination_table = render_template(spec.destination_table, values)
        display_name_with_cluster = f"{spec.display_name} - {cluster_id}"

        if dry_run:
            print(
                f"[DRY-RUN] {display_name_with_cluster} -> "
                f"{rendered_dataset_id}.{rendered_destination_table}"
            )
            if spec.display_name in IMMEDIATE_RUN_QUERIES:
                if spec.display_name == PRIMARY_DEPENDENCY_QUERY:
                    print(
                        f"[DRY-RUN] Will trigger immediate run and wait "
                        f"{AUDIT_TO_DEPENDENTS_WAIT_SECONDS}s before dependents."
                    )
                else:
                    print("[DRY-RUN] Will trigger immediate run and validate table rows > 0.")
            continue

        transfer_config_name = create_scheduled_query(
            client=client,
            project_id=project_id,
            location=args.gcp_server_location,
            display_name=display_name_with_cluster,
            dataset_id=rendered_dataset_id,
            destination_table=rendered_destination_table,
            query=rendered_sql,
            schedule=spec.schedule,
            write_disposition=spec.write_disposition,
        )
        print(
            f"[CREATED] {display_name_with_cluster} -> "
            f"{rendered_dataset_id}.{rendered_destination_table}"
        )

        if spec.display_name in IMMEDIATE_RUN_QUERIES:
            trigger_manual_run(client, transfer_config_name)
            print(f"[RUN-TRIGGERED] {display_name_with_cluster}")
            wait_for_table_population(
                bq_client=bq_client,
                project_id=project_id,
                dataset_id=rendered_dataset_id,
                table_name=rendered_destination_table,
            )
            print(
                f"[POPULATED] {project_id}.{rendered_dataset_id}.{rendered_destination_table}"
            )

            if spec.display_name == PRIMARY_DEPENDENCY_QUERY:
                print(
                    f"[WAIT] Sleeping {AUDIT_TO_DEPENDENTS_WAIT_SECONDS}s before dependent runs."
                )
                time.sleep(AUDIT_TO_DEPENDENTS_WAIT_SECONDS)


if __name__ == "__main__":
    main()

