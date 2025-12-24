#!/usr/bin/env python3
"""Extract a valid service date from GTFS feed (deterministic)."""

import csv
import sys
import zipfile
from datetime import datetime, timedelta

def extract_service_date(gtfs_path: str) -> str:
    """Extract service date with 6-day offset for stability."""
    with zipfile.ZipFile(gtfs_path, 'r') as z:
        # Preference 1: calendar.txt
        if 'calendar.txt' in z.namelist():
            with z.open('calendar.txt') as f:
                reader = csv.DictReader(f.read().decode('utf-8').splitlines())
                dates = [row['start_date'] for row in reader if row.get('start_date')]
                if dates:
                    earliest = min(dates)
                    dt = datetime.strptime(earliest, '%Y%m%d') + timedelta(days=6)
                    return dt.strftime('%Y-%m-%d')

        # Fallback: calendar_dates.txt
        if 'calendar_dates.txt' in z.namelist():
            with z.open('calendar_dates.txt') as f:
                reader = csv.DictReader(f.read().decode('utf-8').splitlines())
                dates = [row['date'] for row in reader
                         if row.get('exception_type') == '1']
                if dates:
                    earliest = min(dates)
                    dt = datetime.strptime(earliest, '%Y%m%d') + timedelta(days=6)
                    return dt.strftime('%Y-%m-%d')

    print("ERROR: No valid service dates found in GTFS", file=sys.stderr)
    sys.exit(1)

if __name__ == '__main__':
    if len(sys.argv) != 2:
        print("Usage: extract-service-date.py <gtfs.zip>", file=sys.stderr)
        sys.exit(1)
    print(extract_service_date(sys.argv[1]))
