# Security Policy

## Supported Versions

| Version | Supported          |
|---------|--------------------|
| 0.3.x   | ✅ Yes             |
| < 0.3   | ❌ No              |

## Reporting a Vulnerability

If you discover a security vulnerability within GitZ, please send an email to Jesús Alcalá at jesusalcalarojas@gmail.com. All security vulnerabilities will be promptly addressed.

**Please do not report security vulnerabilities through public GitHub issues.**

## What to Include

When reporting a vulnerability, please include:

1. Type of vulnerability (buffer overflow, code injection, etc.)
2. Full paths of source file(s) related to the vulnerability
3. The specific location of the vulnerable code (line number if possible)
4. Any special configuration required to reproduce the issue
5. Step-by-step instructions to reproduce the issue
6. Proof-of-concept or exploit code (if possible)
7. Impact of the issue, including how an attacker might exploit it

## Response Timeline

- **Acknowledgment**: Within 48 hours
- **Assessment**: Within 1 week
- **Fix**: Depending on severity, within 1-4 weeks
- **Disclosure**: After fix is released

## Security Considerations

GitZ handles git objects and network operations. Key security areas:

- **Object parsing**: Git objects are parsed from untrusted sources (e.g., cloned repos)
- **SSH transport**: Uses system SSH for authentication
- **Path traversal**: File operations must be sandboxed to the repository
- **Buffer safety**: Zig provides memory safety guarantees, but unsafe patterns should be reviewed

## Best Practices

When using GitZ:

1. Only clone repositories from trusted sources
2. Keep GitZ updated to the latest version
3. Review diffs before committing sensitive changes
4. Use SSH keys with appropriate permissions
