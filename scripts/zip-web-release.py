#!/usr/bin/env python3
"""Create a portable ZIP with UTF-8 names and executable permissions."""
from pathlib import Path
from zipfile import ZipFile, ZIP_DEFLATED
import sys

folder = Path(sys.argv[1]).resolve(strict=True)
output = Path(sys.argv[2]).resolve()
if not folder.is_dir() or output.is_relative_to(folder):
    raise SystemExit('Output must be outside the package directory')
with ZipFile(output, 'x', compression=ZIP_DEFLATED, compresslevel=9) as archive:
    for path in sorted(folder.rglob('*')):
        if path.is_symlink():
            raise SystemExit(f'Unexpected package symlink: {path}')
        archive.write(path, path.relative_to(folder.parent))
print(output)
