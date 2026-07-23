#!/usr/bin/env python3
"""
Read cookies from Safari's binary cookies file.
Outputs JSON array of cookies matching a given domain.
"""

import sys
import struct
import json
from pathlib import Path
from datetime import datetime, timedelta

def parse_safari_cookies(cookie_file_path, domain_filter=None):
    """Parse Safari's binary cookies file and return matching cookies."""

    if not Path(cookie_file_path).exists():
        return []

    cookies = []

    try:
        with open(cookie_file_path, 'rb') as f:
            data = f.read()

        # Safari binary cookies format is complex, but we can extract key data
        # Look for cookie patterns in the binary data
        offset = 0
        while offset < len(data) - 100:
            # Look for domain markers
            if domain_filter and domain_filter.encode() in data[offset:offset+1000]:
                # Extract cookie name and value pairs around domain
                chunk = data[offset:offset+1000]

                # Try to find cookie name/value pairs
                # This is a simplified parser - production would use proper binary format
                try:
                    domain_start = chunk.find(domain_filter.encode())
                    if domain_start > 0:
                        # Look for common cookie names near the domain
                        for cookie_name in [b'sessionKey', b'__cf_bm', b'intercom-session']:
                            name_pos = chunk.find(cookie_name)
                            if name_pos > 0 and abs(name_pos - domain_start) < 500:
                                # Found a cookie!
                                cookies.append({
                                    'domain': domain_filter,
                                    'name': cookie_name.decode('utf-8', errors='ignore'),
                                    'found': True,
                                    'offset': offset + name_pos
                                })
                except:
                    pass

            offset += 100

    except Exception as e:
        print(json.dumps({'error': str(e)}), file=sys.stderr)
        return []

    # Deduplicate by name
    seen = set()
    unique_cookies = []
    for cookie in cookies:
        if cookie['name'] not in seen:
            seen.add(cookie['name'])
            unique_cookies.append(cookie)

    return unique_cookies

if __name__ == '__main__':
    domain = sys.argv[1] if len(sys.argv) > 1 else 'claude.ai'

    safari_cookies = Path.home() / 'Library/Containers/com.apple.Safari/Data/Library/Cookies/Cookies.binarycookies'

    result = parse_safari_cookies(str(safari_cookies), domain)
    print(json.dumps(result, indent=2))
