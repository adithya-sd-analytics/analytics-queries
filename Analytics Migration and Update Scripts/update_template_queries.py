#!/usr/bin/env python3
"""Generate template SQL files from default-dataset SQL files."""

from __future__ import annotations

import argparse
from pathlib import Path
from typing import Dict, List, Tuple


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


def parse_template_values(overrides: List[str]) -> Dict[str, str]:
    values = dict(TEMPLATE_VALUES)
    for item in overrides:
        if "=" not in item:
            raise ValueError(f"Invalid --set '{item}'. Expected key=value.")
        key, value = item.split("=", 1)
        values[key.strip()] = value.strip()
    return values


def replacement_pairs(values: Dict[str, str]) -> List[Tuple[str, str]]:
    pairs: List[Tuple[str, str]] = []
    for key, value in values.items():
        if value:
            pairs.append((value, f"{{{{{key}}}}}"))
    # Replace longer values first to avoid partial collisions.
    return sorted(pairs, key=lambda pair: len(pair[0]), reverse=True)


def to_template_sql(sql_text: str, values: Dict[str, str]) -> str:
    templated_sql = sql_text
    for concrete_value, placeholder in replacement_pairs(values):
        templated_sql = templated_sql.replace(concrete_value, placeholder)
    return templated_sql


def main() -> None:
    parser = argparse.ArgumentParser(
        description=(
            "Read SQL files with default dataset/project names and generate "
            "templated SQL files."
        )
    )
    parser.add_argument(
        "--source-dir",
        default="Update Queries",
        help="Directory containing source SQL files with default dataset values.",
    )
    parser.add_argument(
        "--templates-dir",
        default="Template Queries",
        help="Directory where templated SQL files will be written.",
    )
    parser.add_argument(
        "--set",
        action="append",
        default=[],
        help="Override template key as key=value. Can be passed multiple times.",
    )
    args = parser.parse_args()

    values = parse_template_values(args.set)
    source_dir = Path(args.source_dir)
    templates_dir = Path(args.templates_dir)

    if not source_dir.exists() or not source_dir.is_dir():
        raise FileNotFoundError(f"Source directory not found: {source_dir}")

    source_files = sorted(source_dir.glob("*.sql"))
    if not source_files:
        raise FileNotFoundError(f"No .sql files found in source directory: {source_dir}")

    templates_dir.mkdir(parents=True, exist_ok=True)

    for source_file in source_files:
        raw_sql = source_file.read_text()
        templated_sql = to_template_sql(raw_sql, values)

        output_path = templates_dir / source_file.name
        output_path.write_text(templated_sql)
        print(f"[UPDATED] {output_path}")


if __name__ == "__main__":
    main()
