#!/usr/bin/env bash
# بيشغّل الـ migrations + الاختبارات على Postgres محلي (من غير Supabase).
# الاستخدام:  PGUSER=postgres ./run_tests.sh
set -euo pipefail
cd "$(dirname "$0")"
DB=kms_test
psql -v ON_ERROR_STOP=1 -q -d postgres -c "drop database if exists $DB" -c "create database $DB"
psql -v ON_ERROR_STOP=1 -q -d $DB -f 00_supabase_stub.sql
for f in ../migrations/*.sql; do echo "== $f"; psql -v ON_ERROR_STOP=1 -q -d $DB -f "$f"; done
for t in 10_tests.sql 20_tests_batch2.sql 30_tests_batch3.sql; do
  [ -f "$t" ] || continue
  psql -v ON_ERROR_STOP=1 -d $DB -f "$t" 2>&1 | grep -E "ok  -|ERROR|FAIL|PASSED|WRONG|EXPECTED"
done
