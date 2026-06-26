---
date: 2026-06-25
project: sonique-mac
status: automated-scan
---

# Architecture Summary: sonique-mac

**Generated:** Thu Jun 25 21:58:49 CDT 2026
**Location:** /Users/charlieseay/Projects/sonique-mac

## Project Inventory

```json
{
  "totalFiles": 102,
  "estimatedComplexity": "moderate",
  "stats": {
    "filesScanned": 102,
    "byCategory": {
      "docs": 25,
      "code": 63,
      "config": 6,
      "script": 8
    },
    "byLanguage": {
      "markdown": 24,
      "unknown": 2,
      "json": 2,
      "xml": 4,
      "python": 2,
      "shell": 8,
      "txt": 1,
      "swift": 56,
      "entitlements": 1,
      "pbxproj": 1,
      "xcuserstate": 1
    }
  }
}
```

### Files by Category

- **docs**: 25 files
- **code**: 63 files
- **config**: 6 files
- **script**: 8 files

### Languages Detected

- **swift**: 56 files
- **markdown**: 24 files
- **shell**: 8 files
- **xml**: 4 files
- **unknown**: 2 files
- **json**: 2 files
- **python**: 2 files
- **txt**: 1 files
- **entitlements**: 1 files
- **pbxproj**: 1 files
- **xcuserstate**: 1 files


### Import Relationships

**Stats:**
- Files with imports: 0
- Total import edges: 0

**Import map available:** `.understand-anything/tmp/ua-import-map.json`


## Lore Map

*Lore Map requires interactive workflow — run manually:*
```bash
cd /Users/charlieseay/Projects/sonique-mac
lore plan  # or: lore scan
```


## Next Steps

### Interactive Exploration

**Understand Anything** (knowledge graph):
```bash
cd /Users/charlieseay/Projects/sonique-mac
# Generate full knowledge graph (uses Claude API)
claude /understand

# Launch interactive dashboard
claude /understand-dashboard

# Ask questions
claude /understand-chat "How does authentication work?"
```

**Lore Map** (architecture editor):
```bash
cd /Users/charlieseay/Projects/sonique-mac
# Plan new feature
lore plan

# Quick scan
lore scan

# Deep scan with internals
lore deep-scan
```

### Automated Re-scan

Run this script again to refresh the analysis:
```bash
~/Projects/analyze-project-automated.sh /Users/charlieseay/Projects/sonique-mac
```

---

**Scan logs:**
- Understand scan: `.architecture/understand-scan.log`
- Import extraction: `.architecture/understand-imports.log`
- Lore scan: `.architecture/lore-scan.log`

**Raw data:**
- File inventory: `.understand-anything/tmp/ua-scan-files.json`
- Import map: `.understand-anything/tmp/ua-import-map.json`

