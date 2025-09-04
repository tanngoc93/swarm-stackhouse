# Swarm Stackhouse

Collection of Bash utilities to deploy Docker Swarm stacks, clean up old images, and roll back services by image digest.

## Requirements

- Bash
- Docker CLI available in `PATH`
- Access to a Docker daemon in Swarm mode

## Quick start

1. **Generate a deployment script**

   Run the setup script from the internet and answer the prompts:

   ```bash
   bash <(curl -fsSL https://raw.githubusercontent.com/tanngoc93/swarm-stackhouse/main/setup.sh)
   ```

   The command creates `deploy_<STACK_NAME>_<timestamp>.sh` in the current directory with your answers baked in.

2. **Deploy the stack**

   Execute the generated script to deploy or update your stack. Optionally override the image tag at runtime (defaults to `latest`):

   ```bash
   IMAGE_TAG=v1 ./deploy_<STACK_NAME>_<timestamp>.sh
   ```

## Sample stack file

An example Docker Swarm stack configuration is provided in `swarm-stack-sample/sample-stack.yml`.
The `image` field supports overriding via an `IMAGE_NAME` environment variable and falls back to
`exampleorg/myapp:latest` if none is provided. Replace this placeholder along with `example.com`
and other sample values with settings for your environment.

## Logs and debugging

* Logs are written to `/tmp/swarm-stackhouse/log/deploy_<STACK_NAME>_uniq.log` in the repository root. Tail them with:

  ```bash
  tail -f /tmp/swarm-stackhouse/log/deploy_<STACK_NAME>_uniq.log
  ```

* For verbose debugging output, run the deployment script with `bash -x`:

  ```bash
  IMAGE_TAG=v1 bash -x ./deploy_<STACK_NAME>_<timestamp>.sh
  ```

## Manual rollback

Use `scripts/manual_rollback.sh` to roll back services to a previously deployed image digest:

```bash
STACK_NAME=my_stack IMAGE_REPO=myorg/myimage \
  bash /tmp/swarm-stackhouse/scripts/manual_rollback.sh
```

You will be prompted to select a stored digest. Set `TARGET_DIGEST` to skip the prompt.

You can create a wrapper (e.g. `rollback_swarm.sh`) containing the above command and make it executable with `chmod +x rollback_swarm.sh`.

## Roll back to a specific digest

To roll back using a known digest:

```bash
STACK_NAME=my_stack IMAGE_REPO=myorg/myimage \
  TARGET_DIGEST=sha256:deadbeef \
  bash /tmp/swarm-stackhouse/scripts/manual_rollback.sh
```

## Development

Run basic syntax checks before submitting changes:

```bash
bash -n scripts/*.sh stackhouse_deploy_and_clean.sh setup.sh
```

## License

This project is provided under the MIT License.
