# Swarm Stackhouse

Bash utilities for deploying Docker Swarm stacks, cleaning old images and
rolling back by digest.

## Quick start

1. **Generate a deployment script**

   Run the setup script directly from the internet and answer the prompts:

   ```bash
   curl -fsSL https://raw.githubusercontent.com/tanngoc93/swarm-stackhouse/main/setup.sh | bash
   ```

   A file named `deploy_<STACK_NAME>_<timestamp>.sh` will be created in the
   current directory with your values baked in.

2. **Deploy**

   Execute the generated script to deploy or update your stack. Optionally
   override the image tag at runtime (defaults to `latest`):

   ```bash
   IMAGE_TAG=v1 ./deploy_<STACK_NAME>_<timestamp>.sh
   ```

## Logs and debugging

* Logs are written to `/var/log/deploy_<STACK_NAME>_uniq.log` by default.
  View them with:

  ```bash
  tail -f /var/log/deploy_<STACK_NAME>_uniq.log
  ```

* For verbose debugging output, run the deployment script with `bash -x`:

  ```bash
  IMAGE_TAG=v1 bash -x ./deploy_<STACK_NAME>_<timestamp>.sh
  ```

## Manual rollback

The repository provides `scripts/manual_rollback.sh` to roll back services to a
previously deployed image digest. Run it like this:

```bash
STACK_NAME=my_stack IMAGE_REPO=myorg/myimage \
  bash /tmp/swarm-stackhouse/scripts/manual_rollback.sh
```

You will be prompted to select a stored digest. Set `TARGET_DIGEST` to skip the
prompt.

You may create a convenience wrapper (e.g. `rollback_swarm.sh`) containing the
above command and make it executable with `chmod +x rollback_swarm.sh`.

## Running rollback

To roll back using a specific digest:

```bash
STACK_NAME=my_stack IMAGE_REPO=myorg/myimage \
  TARGET_DIGEST=sha256:deadbeef \
  bash /tmp/swarm-stackhouse/scripts/manual_rollback.sh
```

## Requirements

- Bash
- Docker CLI available in `PATH`
- Access to a Docker daemon in Swarm mode

## Development

Run basic syntax checks before submitting changes:

```bash
bash -n scripts/*.sh stackhouse_deploy_and_clean.sh setup.sh
```

## License

This project is provided under the MIT License.

