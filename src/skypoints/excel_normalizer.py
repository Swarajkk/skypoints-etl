from __future__ import annotations

import re
from datetime import date, datetime, timedelta

import pandas as pd

EXCEL_EPOCH = date(1899, 12, 30)
NULLS = {"", "NULL", "NONE", "NAN", "N/A"}
HEADER = (
    "|H|Member_Name|Member_Id|Enrollment_Date|Last_Flight_Date|Tier_Code|"
    "Agent_Name|State|Country|DOB|Is_Active"
)


def to_yyyymmdd(value, compact_fmt: str | None = None) -> str | None:
    """Normalise a date cell to YYYYMMDD.

    Null-like values return None. Values that cannot be parsed are returned
    unchanged so the SQL validation layer rejects them visibly.
    """
    if value is None or (isinstance(value, float) and pd.isna(value)):
        return None
    if isinstance(value, (datetime, date)):  # datetime is a subclass of date
        return value.strftime("%Y%m%d")

    s = str(value).strip()
    if s.upper() in NULLS:
        return None
    if s.endswith(".0"):
        s = s[:-2]

    # Excel serial number (at most 5 digits)
    if re.fullmatch(r"\d{1,5}", s):
        return (EXCEL_EPOCH + timedelta(days=int(s))).strftime("%Y%m%d")

    # ISO date; impossible calendar dates such as 2021-13-13 pass through
    if re.fullmatch(r"\d{4}-\d{2}-\d{2}", s):
        try:
            return date.fromisoformat(s).strftime("%Y%m%d")
        except ValueError:
            return s

    # Compact digits whose leading zero was lost (e.g. 6152022 -> 06152022)
    if compact_fmt and re.fullmatch(r"\d{7,8}", s):
        try:
            return datetime.strptime(s.zfill(8), compact_fmt).strftime("%Y%m%d")
        except ValueError:
            return s

    return s


def to_dob(value, compact_fmt: str | None, out_fmt: str) -> str | None:
    """Return DOB in the country's spec format (DDMMYYYY or MMDDYYYY)."""
    iso = to_yyyymmdd(value, compact_fmt)
    if iso and re.fullmatch(r"\d{8}", iso):
        try:
            return datetime.strptime(iso, "%Y%m%d").strftime(out_fmt)
        except ValueError:
            return iso
    return iso


def convert(path: str, country: str, cfg: dict) -> list[str]:
    """Convert one country workbook into pipe-delimited flat-file lines."""
    df = pd.read_excel(path, sheet_name=cfg["sheet"], dtype=object)
    df = df.rename(columns=cfg["columns"])
    fmt = cfg.get("compact_fmt")

    lines = [HEADER]
    for r in df.to_dict("records"):
        fields = [
            str(r.get("member_name") or "").strip(),
            f'{cfg["id_prefix"]}{str(r.get("member_id", "")).strip()}',
            to_yyyymmdd(r.get("enrollment_date"), fmt) or "",
            to_yyyymmdd(r.get("last_flight_date"), fmt) or "",
            str(r.get("tier_code") or "").strip().upper(),
            "",  # agent_name: not in source
            "",  # state: not in source
            country,
            to_dob(r.get("dob"), fmt, cfg["dob_out"]) or "",
            "",  # is_active: not in source
        ]
        lines.append("|D|" + "|".join(fields))
    return lines