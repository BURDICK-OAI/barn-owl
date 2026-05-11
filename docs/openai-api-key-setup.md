# OpenAI API Key Setup

Barn Owl uses your own OpenAI API key for transcription, summaries, note edits, and meeting chat. The app stores the key in a private local user config file for your macOS account. The app bundle does not contain an API key.

## Create a key

1. Open the OpenAI API keys page: https://platform.openai.com/api-keys
2. Create a new secret key for Barn Owl.
3. Copy the key once. OpenAI will not show it again.

If you want tighter control, create a dedicated OpenAI project for Barn Owl and set a project budget or rate limit in the OpenAI dashboard.

## Add it to Barn Owl

1. Open Barn Owl Settings.
2. Paste the key into OpenAI Connection.
3. Choose Save & Test Key.

Barn Owl saves the key locally with restricted file permissions, then makes a small OpenAI authentication check. If the test fails, Settings will show whether the key was rejected, missing permissions, out of quota, or blocked by a network issue.

## Migrate older Keychain keys

Older Barn Owl builds stored the key in macOS Keychain. Lightweight ad-hoc app
packages can trigger repeated Keychain approval prompts after updates, so current
builds prefer the private local user config file instead.

If this Mac has an older Keychain-saved key, open Barn Owl Settings and choose
Migrate Keychain Key in the OpenAI Connection section. If migration cannot read
the old saved key, paste the key again and choose Save & Test Key.

## Replace or revoke

Use Clear Saved Key in Barn Owl Settings to remove the local copy.

To revoke the key completely, delete it from the OpenAI API keys page. Revoking in OpenAI is the source of truth; clearing it in Barn Owl only removes it from this Mac.
