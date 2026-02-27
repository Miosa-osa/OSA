---
globs: ["src/api/**/*.ts", "src/routes/**/*.ts", "internal/handler/**/*.go", "**/api/**/*.go"]
alwaysApply: false
---

# API Security Rules

## Authentication
- Always validate JWT tokens on protected routes
- Check token expiration
- Verify token signature
- Use secure token storage (httpOnly cookies)

## Authorization
- Implement role-based access control (RBAC)
- Check permissions on every request
- No IDOR vulnerabilities (validate resource ownership)

## Input Validation
```typescript
// Always validate and sanitize inputs
const schema = z.object({
  email: z.string().email(),
  password: z.string().min(8),
});
const validated = schema.parse(input);
```

## SQL Injection Prevention
```typescript
// ALWAYS use parameterized queries
const user = await db.query('SELECT * FROM users WHERE id = $1', [userId]);

// NEVER string concatenation
// const user = await db.query(`SELECT * FROM users WHERE id = ${userId}`);  // BAD!
```

## XSS Prevention
- Escape all user-generated content
- Use Content-Security-Policy headers
- Set `httpOnly` and `secure` on cookies

## Rate Limiting
```typescript
// Apply to all endpoints
app.use(rateLimit({
  windowMs: 15 * 60 * 1000, // 15 minutes
  max: 100 // limit each IP
}));

// Stricter for auth endpoints
app.use('/auth', rateLimit({ windowMs: 60000, max: 5 }));
```

## Security Headers
```typescript
app.use(helmet({
  contentSecurityPolicy: true,
  crossOriginEmbedderPolicy: true,
  crossOriginOpenerPolicy: true,
  crossOriginResourcePolicy: true,
  dnsPrefetchControl: true,
  frameguard: true,
  hidePoweredBy: true,
  hsts: true,
  ieNoOpen: true,
  noSniff: true,
  originAgentCluster: true,
  permittedCrossDomainPolicies: true,
  referrerPolicy: true,
  xssFilter: true,
}));
```

## Logging
- Log all authentication attempts
- Log authorization failures
- Never log sensitive data (passwords, tokens, PII)
- Use structured logging
