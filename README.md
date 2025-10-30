# TM Forum Migration

A comprehensive guide and toolset for migrating TM Forum API entities from v0.31.2 to v1.3.13 format using the FIWARE data-migrator.


## Architecture

```
┌─────────────────────────────────┐    ┌─────────────────────────────────┐
│        SOURCE Environment       │    │        TARGET Environment       │
│       (tmforum-source)          │    │       (tmforum-target)          │
│                                 │    │                                 │
│ ┌─────────────────────────────┐ │    │ ┌─────────────────────────────┐ │
│ │ TM Forum API v0.31.2        │ │    │ │ TM Forum API v1.3.13        │ │
│ │ (Active - Legacy Format)    │ │    │ │ (Disabled during migration) │ │
│ └─────────────────────────────┘ │    │ └─────────────────────────────┘ │
│ ┌─────────────────────────────┐ │    │ ┌─────────────────────────────┐ │
│ │ Scorpio v4.1.10             │ │    │ │ Scorpio v4.1.10             │ │
│ │ (Contains v0.31.2 entities) │ │    │ │ (Receives v1.3.13 entities) │ │
│ └─────────────────────────────┘ │    │ └─────────────────────────────┘ │
│ ┌─────────────────────────────┐ │    │ ┌─────────────────────────────┐ │
│ │ PostgreSQL 13.18.0          │ │    │ │ PostgreSQL 13.18.0          │ │
│ │ (Legacy entity storage)     │ │    │ │ (New entity storage)        │ │
│ └─────────────────────────────┘ │    │ └─────────────────────────────┘ │
└─────────────────────────────────┘    └─────────────────────────────────┘
                  │                                        │
                  └────────────────────────────────────────┘
                              │
                    ┌─────────────────────┐
                    │ FIWARE Data Migrator│
                    │                     │
                    │                     │
                    │ • Reads v0.31.2     │
                    │ • Transforms format │
                    │ • Writes v1.3.13    │
                    └─────────────────────┘
```

## Quick Start


### 1. Access Environments

**Source Environment (v0.31.2):**
```bash
kubectl port-forward -n tmforum-source svc/scorpio-source 9090:9090
```
- Scorpio: http://localhost:9090

**Target Environment (v1.3.13):**
```bash
kubectl port-forward -n tmforum-target svc/scorpio-target 9092:9090
```
- Scorpio: http://localhost:9092


### 2. Run Migration

```bash
# Run FIWARE data migration
./scripts/migration/run-data-migration.sh
```

### 3. Perform validation

```bash
# Validate Migration
./script/validation/entity_compare.sh
```

