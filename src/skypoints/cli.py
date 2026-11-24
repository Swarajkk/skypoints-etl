import pathlib
import sys

import yaml

from skypoints.excel_normalizer import convert


def main(src_dir: str, out_dir: str, feed_date: str) -> None:
    with open("config/country_sources.yaml", encoding="utf-8") as f:
        cfg = yaml.safe_load(f)

    pathlib.Path(out_dir).mkdir(parents=True, exist_ok=True)
    for country, c in cfg.items():
        lines = convert(f"{src_dir}/{country}.xlsx", country, c)
        out_file = pathlib.Path(out_dir, f"member_{country}_{feed_date}.txt")
        out_file.write_text("\n".join(lines) + "\n", encoding="utf-8")
        print(f"wrote {out_file} ({len(lines) - 1} rows)")


if __name__ == "__main__":
    if len(sys.argv) != 4:
        sys.exit("usage: python -m skypoints.cli <src_dir> <out_dir> <feed_date YYYYMMDD>")
    main(*sys.argv[1:4])