# Private Model Download Guide

When downloading a gated model (e.g., `Qwen/Qwen2.5-32B-Instruct`) from the Hugging Face Hub you must:

1. **Obtain a token** with `download` scope from https://huggingface.co/settings/tokens.

2. **Set the token** in the environment:
   ```bash
   export HF_TOKEN=***   ```
   Or pass `--token $HF_TOKEN` to the `hf` command.

3. **Use the correct CLI flags**:
   - `--local-dir <path>` to specify the target directory.
   - `--force-download` to re-download even if cached.
   - (Optionally) `--repo-type model` if you want to be explicit.

4. **Start the download** (example for a large model):
   ```bash
   mkdir -p $HOME/models && \
   hf download Qwen/Qwen2.5-32B-Instruct \
       --local-dir $HOME/models/qwen-32b \
       --force-download \
       --token $HF_TOKEN \
       --repo-type model
   ```

5. **Monitor the download** (recommended pattern):
   ```bash
   # In a separate terminal or backgrounded command
   terminal(command="watch -n 5 'ls -lh $HOME/models/qwen-32b'" background=true notify_on_complete=true
   ```
   Or use Hermes' own background process tool:
   ```bash
   terminal(command="mkdir -p $HOME/models && hf download Qwen/Qwen2.5-32B-Instruct --local-dir $HOME/models/qwen-32b --force-download --token $HF_TOKEN" background=true notify_on_complete=true timeout=3600
   ```

6. **Verify the files** were downloaded:
   ```bash
   ls -lh $HOME/models/qwen-32b
   ```

7. **Optional: Create a local alias** for use with Hermes:
   - Add an entry to `~/.hermes/aliases.yaml` (or wherever aliases are stored):
     ```yaml
     qwen-32b: http://172.17.0.1:8000/v1
     ```
   - Update `~/.hermes/config.yaml`:
     ```yaml
     model.provider: custom:local
     model.default: qwen-32b
     ```

8. **Restart Hermes** (or start a new session) to use the newly aliased model.

### Tips & Pitfalls
- **Token leakage**: Never commit your token to version control. Add `*.token` to `.gitignore`.
- **Rate limits**: Unauthenticated requests are heavily rate‑limited. Always use a token for any gated model.
- **Background completion**: Hermes’ `terminal` tool can run the download in the background and notify you when it finishes (`notify_on_complete=true`). This avoids blocking your chat session.
- **Resume capability**: The `hf` CLI does not support a `--resume-download` flag; use `--force-download` to re‑fetch or simply let the CLI continue where it left off if the process crashes (it will resume automatically if the connection drops briefly).