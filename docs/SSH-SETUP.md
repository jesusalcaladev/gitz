# SSH Configuration for GitZ

GitZ supports SSH transport natively. This guide explains how to configure SSH for push/pull/fetch operations.

## Quick Setup

### 1. Generate SSH Key (if you don't have one)

```bash
ssh-keygen -t ed25519 -C "your_email@example.com"
```

Press Enter to accept defaults, or specify a different path.

### 2. Add Key to SSH Agent

```bash
eval "$(ssh-agent -s)"
ssh-add ~/.ssh/id_ed25519
```

### 3. Add Public Key to GitHub

```bash
cat ~/.ssh/id_ed25519.pub
```

Copy the output and add it to GitHub:
1. Go to https://github.com/settings/keys
2. Click "New SSH key"
3. Paste your key
4. Click "Add SSH key"

### 4. Test Connection

```bash
ssh -T git@github.com
```

You should see: `Hi username! You've successfully authenticated...`

## Using SSH with GitZ

Once SSH is configured, GitZ automatically uses it for remote operations:

```bash
# Clone via SSH
gitz clone git@github.com:user/repo.git

# Set remote to SSH
gitz remote add origin git@github.com:user/repo.git

# Push/pull/fetch work automatically
gitz push origin main
gitz pull origin
gitz fetch origin
```

## Using HTTPS with Personal Access Token

If you prefer HTTPS, you can use a Personal Access Token (PAT):

### 1. Create a Token

1. Go to https://github.com/settings/tokens
2. Click "Generate new token (classic)"
3. Select scopes: `repo`, `read:org`
4. Copy the token

### 2. Use Token with GitZ

```bash
# Set remote with token in URL
gitz remote add origin https://<TOKEN>@github.com/user/repo.git

# Or use the install script which configures this automatically
curl -fsSL https://raw.githubusercontent.com/jesusalcaladev/gitz/main/install.sh | bash
```

## Troubleshooting

### "Permission denied (publickey)"

1. Check if SSH key is added to agent:
   ```bash
   ssh-add -l
   ```

2. Test SSH connection:
   ```bash
   ssh -vT git@github.com
   ```

3. Verify key is added to GitHub

### "Host key verification failed"

1. Add GitHub to known_hosts:
   ```bash
   ssh-keyscan github.com >> ~/.ssh/known_hosts
   ```

### GitZ Falls Back to Git

If you see "Note: SSH transport failed, falling back to git", it means:

1. SSH key might not be configured
2. SSH agent might not be running
3. Network issues

To debug:
```bash
# Test SSH directly
ssh -T git@github.com

# Check if gitz can detect SSH
gitz remote -v
```

## Multiple SSH Keys

If you have multiple SSH keys for different accounts:

### ~/.ssh/config

```
Host github.com
    HostName github.com
    User git
    IdentityFile ~/.ssh/id_ed25519_work
    IdentitiesOnly yes

Host github-personal
    HostName github.com
    User git
    IdentityFile ~/.ssh/id_ed25519_personal
    IdentitiesOnly yes
```

Then use different hostnames:

```bash
# Work account
gitz remote add work git@github.com:work/repo.git

# Personal account
gitz remote add personal git@github-personal:personal/repo.git
```

## GitZ vs Git SSH

GitZ uses the system `ssh` command for SSH transport, so it:

- Uses your existing SSH configuration
- Works with SSH agent
- Supports all SSH key types
- Is compatible with GitHub, GitLab, Bitbucket

The main advantage of GitZ's SSH transport is that it's integrated directly - no need to have git installed separately for SSH operations.
