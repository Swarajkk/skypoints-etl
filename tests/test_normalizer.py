import pytest

from skypoints.excel_normalizer import to_dob, to_yyyymmdd


@pytest.mark.parametrize(
    "raw,fmt,expected",
    [
        (44562, None, "20220101"),             # Excel serial
        (44562.0, None, "20220101"),           # serial read as float
        ("6152022", "%m%d%Y", "20220615"),     # leading zero lost
        ("1052022", "%m%d%Y", "20220105"),
        ("12282021", "%m%d%Y", "20211228"),
        ("2021-13-13", None, "2021-13-13"),    # invalid date passes through for DQ
        ("NULL", None, None),
        (None, None, None),
    ],
)
def test_to_yyyymmdd(raw, fmt, expected):
    assert to_yyyymmdd(raw, fmt) == expected


def test_dob_uses_country_format():
    assert to_dob(36130, None, "%d%m%Y") == "01121998"