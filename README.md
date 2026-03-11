# pg_repack – Installation and Unused Space Cleanup

## 1. Overview

**pg_repack** is a PostgreSQL extension used to reclaim unused disk space (*bloat*) from tables and indexes **without taking heavy locks**. It reorganizes tables online and helps maintain database performance.

> [!NOTE]
> Unlike `VACUUM FULL` or `CLUSTER`, pg_repack performs reorganization **online** — the target table is still readable and writable during the operation.

### What This Document Covers

| Section | Description |
|---------|-------------|
| [Installing pg_repack](#2-installing-pg_repack) | Package installation and extension setup |
| [Cleaning Unused Space](#3-cleaning-unused-space) | Repacking individual tables and indexes |
| [Running Across the Entire Database](#4-running-across-the-entire-database) | Full-database bloat cleanup |
| [Automating with Cron](#5-automating-with-cron) | Scheduling automatic cleanup |
| [Monitoring & Verification](#6-monitoring--verification) | Checking bloat and confirming results |
| [Troubleshooting](#7-troubleshooting) | Common issues and solutions |

---

## 2. Installing pg_repack

### 2.1 Prerequisites

- PostgreSQL **9.4+** (recommended: **14, 15, 16, 17, 18**)
- Superuser or `pg_repack` role privileges
- Sufficient disk space (pg_repack creates a copy of the table during reorganization)

### 2.2 Install the Package

#### On RHEL / CentOS / Rocky Linux / AlmaLinux

```bash
# Install the PGDG repository (if not already installed)
sudo dnf install -y https://download.postgresql.org/pub/repos/yum/reporpms/EL-$(rpm -E %{rhel})-x86_64/pgdg-redhat-repo-latest.noarch.rpm

# Install pg_repack (replace 18 with your PostgreSQL major version)
sudo dnf install -y pg_repack_18

# Also install the development package (required for building other extensions from source)
sudo dnf install -y postgresql18-devel
```

> [!TIP]
> To see all available pg_repack versions: `dnf list available | grep pg_repack`

#### On Ubuntu / Debian

```bash
# Install pg_repack (replace 16 with your PostgreSQL major version)
sudo apt-get update
sudo apt-get install -y postgresql-16-repack
```

#### From Source (Any Platform)

```bash
# Install build dependencies (RHEL/CentOS)
sudo dnf install -y gcc make postgresql18-devel redhat-rpm-config readline-devel zlib-devel openssl-devel

# Ensure pg_config is in your PATH
export PATH=/usr/pgsql-18/bin:$PATH

# Clone and build
git clone https://github.com/reorg/pg_repack.git
cd pg_repack
make
sudo make install
```

> [!WARNING]
> The `postgresql18-devel` package is **required** — it provides the build infrastructure (`pgxs.mk`, headers) needed to compile extensions from source. Without it, `make` will fail.

### 2.3 Create the Extension in PostgreSQL

Connect to the target database and create the extension:

```sql
-- Connect to your database
\c your_database_name

-- Create the extension
CREATE EXTENSION pg_repack;
```

Verify the installation:

```sql
SELECT * FROM pg_extension WHERE extname = 'pg_repack';
```

> [!IMPORTANT]
> The `pg_repack` extension must be created **in every database** where you want to run the repack operation.

---

## 3. Cleaning Unused Space

### 3.1 Repack a Single Table

```bash
pg_repack -d your_database -t your_schema.your_table
```

**Example:**

```bash
pg_repack -d production_db -t public.orders
```

### 3.2 Repack a Single Index

```bash
pg_repack -d your_database --index your_index_name
```

**Example:**

```bash
pg_repack -d production_db --index idx_orders_created_at
```

### 3.3 Repack Multiple Specific Tables

```bash
pg_repack -d your_database -t public.orders -t public.line_items -t public.customers
```

### 3.4 Repack Only Indexes of a Table

```bash
pg_repack -d your_database -x -t public.orders
```

> [!TIP]
> Use the `-x` (or `--only-indexes`) flag when the table data is fine but indexes are bloated.

### 3.5 Common Options

| Flag | Description |
|------|-------------|
| `-d` / `--dbname` | Target database name |
| `-t` / `--table` | Target table (schema-qualified) |
| `-s` / `--schema` | Target schema (all tables in that schema) |
| `-x` / `--only-indexes` | Repack only the indexes, not the table |
| `--index` | Repack a specific index |
| `-j` / `--jobs` | Number of parallel jobs |
| `-k` / `--no-superuser-check` | Skip the superuser privilege check |
| `-h` / `--host` | Database server host |
| `-p` / `--port` | Database server port |
| `-U` / `--username` | Database user name |
| `-w` / `--no-password` | Never prompt for password |
| `--wait-timeout` | Timeout (seconds) to wait for lock acquisition |
| `--no-kill-backend` | Do not kill other backends when acquiring lock |
| `--dry-run` | Show what would be done without executing |

---

## 4. Running Across the Entire Database

### 4.1 Repack All Tables in a Database

```bash
pg_repack -d your_database
```

This will repack **all bloated tables** in the specified database.

### 4.2 Repack All Tables in a Specific Schema

```bash
pg_repack -d your_database -s public
```

### 4.3 Repack with Parallel Jobs

For large databases, use multiple parallel workers to speed up the process:

```bash
pg_repack -d your_database -j 4
```

### 4.4 Full-Database Repack Script (All Databases)

To repack **every database** on a PostgreSQL instance:

```bash
#!/bin/bash
# ============================================================
#  repack_all_databases.sh
#  Repacks all user databases on the PostgreSQL instance
# ============================================================

PGUSER="postgres"
PGHOST="localhost"
PGPORT="5432"
LOG_FILE="/var/log/pg_repack/repack_$(date +%Y%m%d_%H%M%S).log"

mkdir -p /var/log/pg_repack

# Get list of all user databases (exclude templates)
DATABASES=$(psql -U "$PGUSER" -h "$PGHOST" -p "$PGPORT" -Atc \
  "SELECT datname FROM pg_database WHERE datistemplate = false AND datname NOT IN ('postgres');")

for DB in $DATABASES; do
    echo "======================================" | tee -a "$LOG_FILE"
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] Repacking database: $DB" | tee -a "$LOG_FILE"
    echo "======================================" | tee -a "$LOG_FILE"

    # Ensure the extension exists
    psql -U "$PGUSER" -h "$PGHOST" -p "$PGPORT" -d "$DB" -c \
      "CREATE EXTENSION IF NOT EXISTS pg_repack;" 2>&1 | tee -a "$LOG_FILE"

    # Run pg_repack
    pg_repack -U "$PGUSER" -h "$PGHOST" -p "$PGPORT" -d "$DB" -j 2 2>&1 | tee -a "$LOG_FILE"

    echo "[$(date '+%Y-%m-%d %H:%M:%S')] Completed: $DB" | tee -a "$LOG_FILE"
    echo "" | tee -a "$LOG_FILE"
done

echo "[$(date '+%Y-%m-%d %H:%M:%S')] All databases repacked." | tee -a "$LOG_FILE"
```

Make the script executable:

```bash
chmod +x repack_all_databases.sh
```

---

## 5. Automating with Cron

### 5.1 Single Database – Weekly Cron Job

Open the crontab editor for the `postgres` user:

```bash
sudo crontab -u postgres -e
```

Add the following entry to run pg_repack every **Sunday at 2:00 AM**:

```cron
# pg_repack – weekly full repack of production_db
0 2 * * 0 /usr/bin/pg_repack -U postgres -d production_db -j 2 >> /var/log/pg_repack/repack.log 2>&1
```

### 5.2 All Databases – Weekly Cron Job

```cron
# pg_repack – weekly repack of all databases
0 2 * * 0 /path/to/repack_all_databases.sh >> /var/log/pg_repack/repack_cron.log 2>&1
```

### 5.3 Cron Schedule Reference

| Schedule | Cron Expression | Description |
|----------|-----------------|-------------|
| Every Sunday at 2 AM | `0 2 * * 0` | Weekly maintenance window |
| Every day at midnight | `0 0 * * *` | Daily (for high-write databases) |
| 1st of every month at 3 AM | `0 3 1 * *` | Monthly maintenance |
| Every Saturday at 1 AM | `0 1 * * 6` | Weekend maintenance |

### 5.4 Verify the Cron Job

```bash
sudo crontab -u postgres -l
```

---

## 6. Monitoring & Verification

### 6.1 Check Table Bloat Before Repacking

Use the `pgstattuple` extension to measure bloat:

```sql
CREATE EXTENSION IF NOT EXISTS pgstattuple;

-- Check bloat for a specific table
SELECT * FROM pgstattuple('public.orders');
```

Key columns to watch:

| Column | Meaning |
|--------|---------|
| `dead_tuple_count` | Number of dead (deleted) rows |
| `dead_tuple_percent` | Percentage of dead tuples |
| `free_space` | Unused space in bytes |
| `free_percent` | Percentage of free space |

### 6.2 Check Table Sizes Before and After

```sql
-- Table size (data + indexes + toast)
SELECT
    schemaname,
    tablename,
    pg_size_pretty(pg_total_relation_size(schemaname || '.' || tablename)) AS total_size,
    pg_size_pretty(pg_relation_size(schemaname || '.' || tablename)) AS table_size,
    pg_size_pretty(pg_indexes_size(schemaname || '.' || quote_ident(tablename))) AS index_size
FROM pg_tables
WHERE schemaname NOT IN ('pg_catalog', 'information_schema')
ORDER BY pg_total_relation_size(schemaname || '.' || tablename) DESC;
```

### 6.3 Estimate Bloat Across All Tables

```sql
SELECT
    schemaname || '.' || relname AS table_name,
    pg_size_pretty(pg_total_relation_size(relid)) AS total_size,
    n_dead_tup AS dead_tuples,
    n_live_tup AS live_tuples,
    CASE
        WHEN n_live_tup > 0
        THEN round(100.0 * n_dead_tup / (n_live_tup + n_dead_tup), 2)
        ELSE 0
    END AS dead_tuple_pct
FROM pg_stat_user_tables
ORDER BY n_dead_tup DESC;
```

> [!TIP]
> Tables with a `dead_tuple_pct` above **20%** are good candidates for repacking.

---

## 7. Troubleshooting

### Common Issues

| Issue | Cause | Solution |
|-------|-------|----------|
| `ERROR: pg_repack is not installed` | Extension not created in the target database | Run `CREATE EXTENSION pg_repack;` in that database |
| `ERROR: query failed: SSL connection has been closed` | Network timeout during long repack | Use `--wait-timeout` or increase `tcp_keepalives_idle` in `postgresql.conf` |
| `ERROR: could not obtain lock` | Another transaction holds a lock on the table | Retry later or use `--wait-timeout 60` |
| Disk space exhaustion | pg_repack needs ~1× the table size as temporary space | Free disk space before running |
| `permission denied` | User doesn't have superuser privileges | Run as superuser or grant the `pg_repack` role |
| Slow performance | Single-threaded by default | Use `-j N` for parallel jobs |

### Safety Notes

> [!CAUTION]
> - **Disk Space**: pg_repack creates a **full copy** of the table. Ensure you have at least **1× the size of the largest table** as free disk space.
> - **Replication**: On replicated setups, pg_repack operations will be replicated to standby servers. Monitor replication lag.
> - **Long Transactions**: Avoid running pg_repack during long-running transactions — it may block or be blocked.

---

## 8. Quick Reference

```bash
# Install extension in a database
psql -d mydb -c "CREATE EXTENSION pg_repack;"

# Repack a single table
pg_repack -d mydb -t public.orders

# Repack only indexes of a table
pg_repack -d mydb -x -t public.orders

# Repack all tables in a database
pg_repack -d mydb

# Repack a specific schema
pg_repack -d mydb -s public

# Repack with 4 parallel jobs
pg_repack -d mydb -j 4

# Dry run (show what would be done)
pg_repack -d mydb --dry-run
```

---

## 9. References

- **Official Repository**: [https://github.com/reorg/pg_repack](https://github.com/reorg/pg_repack)
- **Documentation**: [https://reorg.github.io/pg_repack/](https://reorg.github.io/pg_repack/)
- **PostgreSQL PGDG Packages**: [https://www.postgresql.org/download/](https://www.postgresql.org/download/)
