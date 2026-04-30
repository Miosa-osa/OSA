# Example: Legacy PHP HR/Payroll System — Security Hardening + Modernization Foundation

> Fictional 10-year-old PHP monolith. Raw PHP + MySQL + Apache + jQuery. No framework, no Composer, no tests.

Demonstrates:

- **Execution traces through spaghetti code** — tracing SQL injection from a `$_GET` form input through a chain of `include`d files to a raw `mysql_query()` concatenation. No clean call stack. Agents must read includes like an archaeologist reading strata.
- **Codebase archaeology** — zero documentation, zero framework conventions, zero tests. Agents must infer intent from variable names, comment fragments, and database column shapes. `$conn` is passed around as a global. Functions named `do_thing()` do three unrelated things.
- **Characterization testing** — QA's first job is not to find bugs. It is to write tests that capture what the application *currently does*, including wrong behavior. No behavior changes until tests exist and pass against the current code. This is the safety net before anyone touches anything.
- **Legacy safety patterns** — the standing rule is: no refactoring without characterization tests first. Agents that encounter untested code stop, flag it, and wait for QA rather than touching it. Fixing a SQL injection in an untested function is safe. Reorganizing that function while fixing it is not.
- **Incremental modernization** — INFRA introduces Composer and PSR-4 autoloading without breaking the existing include-based code. Both systems run in parallel during the transition. New classes live under `src/`. Old includes stay where they are until a future sprint migrates them one file at a time.

## The Codebase You Are Inheriting

```
/var/www/html/
├── index.php                  # Login redirect or dashboard
├── login.php                  # Session start, MD5 password check
├── logout.php
├── dashboard.php
├── search.php                 # Employee search — SQL injection here
├── view_employee.php          # Shows employee record + notes — XSS here
├── notes_form.php             # Add note to employee
├── save_note.php              # Saves note to DB — stores raw HTML
├── salary_form.php            # Change employee salary
├── update_salary.php          # Applies salary update — no CSRF token
├── reports.php
├── includes/
│   ├── db.php                 # mysql_connect(), $conn global, raw queries
│   ├── auth.php               # Session check, include at top of every page
│   ├── header.php             # HTML header + jQuery 2.1.4 CDN
│   └── footer.php
└── admin/
    ├── users.php              # Add/edit system users
    └── reset_password.php     # Resets to plaintext, emails it
```

Everything is procedural. There are no classes. Routing is filename-based — you navigate to `search.php` directly. Database calls are scattered across page files and `includes/db.php`. `includes/db.php` exports helper functions like `get_employee($id)` that build queries by string concatenation.

## The Four Vulnerabilities You Are Fixing

**SQL Injection in employee search.**
`search.php` reads `$_GET['q']` and passes it to `get_employees_by_name()` in `includes/db.php`. That function does:
```php
$result = mysql_query("SELECT * FROM employees WHERE name LIKE '%" . $search . "%'");
```
No escaping. No prepared statements. Direct concatenation of unvalidated user input.

**Stored XSS in employee notes.**
`notes_form.php` submits to `save_note.php`, which saves `$_POST['note']` directly to `employees.notes`. `view_employee.php` renders it:
```php
echo "<div class='notes'>" . $row['notes'] . "</div>";
```
No `htmlspecialchars()`. Any HTML or `<script>` stored in the notes field executes in every browser that views that employee.

**CSRF on salary updates.**
`salary_form.php` is a plain HTML form that POSTs to `update_salary.php`. `update_salary.php` checks only that the user is logged in, then runs the update. There is no token. Any page on the internet can submit that form on behalf of a logged-in HR manager.

**Plaintext password storage (MD5 without salt).**
`login.php` compares `md5($_POST['password'])` to `users.password` in the database. MD5 is not a password hash. It has no salt. Every password in this database is recoverable from rainbow tables. Migration path: bcrypt with `password_hash()`, verified via `password_verify()`.

## Conventions Agents Must Know

- `mysql_*` functions were removed in PHP 7.0. The codebase uses them with a compatibility shim (`includes/db.php` polyfills them against `mysqli`). This shim is load-bearing — do not remove it until every caller is migrated to PDO prepared statements.
- `register_globals` is off, but the code predates that assumption. Several files start with `extract($_POST)` or `extract($_GET)` to simulate it. Those extractions are injection surfaces.
- There are no namespaces. New code introduced by INFRA under `src/` uses the `HRApp\` namespace and is loaded via Composer's PSR-4 autoloader. The two systems do not interact yet.
- Session state is PHP's default file-based sessions. `$_SESSION['user_id']` and `$_SESSION['role']` are the auth primitives. There is no token refresh, no secure/httpOnly flag set on the session cookie, and the session lifetime is the PHP default.
