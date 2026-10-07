#!/usr/bin/env bash
# بيشغّل الـ migrations + الاختبارات على Postgres محلي (من غير Supabase).
# الاستخدام:  PGUSER=postgres ./run_tests.sh
set -euo pipefail
cd "$(dirname "$0")"
DB=kms_test
psql -v ON_ERROR_STOP=1 -q -d postgres -c "drop database if exists $DB" -c "create database $DB"
for r in anon authenticated service_role; do psql -q -d postgres -c "drop role if exists $r" 2>/dev/null || true; done
psql -v ON_ERROR_STOP=1 -q -d $DB -f 00_supabase_stub.sql
for f in ../migrations/*.sql; do echo "== $f"; psql -v ON_ERROR_STOP=1 -q -d $DB -f "$f"; done
psql -v ON_ERROR_STOP=1 -d $DB -f 10_tests.sql 2>&1 | grep -E "ok  -|ERROR|FAIL|PASSED|WRONG|EXPECTED" 
