# Swarm Stackhouse

Small Bash utilities for deploying a single application image to Docker Swarm,
recording successful image digests, rolling back to an earlier digest, and
cleaning unused copies of that image from every Swarm node.

## What it does

A normal deployment follows this order:

1. Pull `IMAGE_REPO:IMAGE_TAG` on the manager.
2. Resolve `latest` to an immutable digest.
3. Create the stack if it does not exist, or update matching services one at a
   time.
4. Wait for one-shot services such as database migrations to exit successfully.
5. Record the digest only after the deployment succeeds.
6. Run the optional image cleanup job on every Swarm node.

The deploy command runs in the foreground by default, so CI receives the real
exit status. Concurrent deployments of the same stack are rejected by a lock
instead of terminating the deployment already in progress.

## Requirements

- Bash 4 or newer
- `git`, `curl`, and the Docker CLI
- A Docker Swarm manager with access to `/var/run/docker.sock`
- Registry credentials already configured with `docker login` when the image is
  private
- A stack YAML file available on the manager

## Important scope

The updater changes only services whose current image starts with
`IMAGE_REPO:` or `IMAGE_REPO@`. This makes a stack containing the app plus
PostgreSQL, Redis, or Traefik safe: infrastructure services using other image
repositories are skipped.

All application services selected this way receive the same image. Use a
separate deployment invocation when a stack contains multiple independently
versioned application images.

For an existing stack, this tool updates service images; it does not apply other
changes made to the stack YAML. Apply configuration, secret, network, label, or
replica changes separately with `docker stack deploy` before using this tool.

## Quick start

### 1. Generate an app-specific wrapper

Run the interactive setup script from a trusted checkout:

```bash
git clone https://github.com/tanngoc93/swarm-stackhouse.git
cd swarm-stackhouse
bash setup.sh
```

Enter:

- `IMAGE_REPO`, for example `myorg/myapp`
- `STACK_NAME`, for example `my-app`
- `STACK_FILE`, for example `/root/docker/my-app-stack.yml`

The generator creates an executable file named similar to
`deploy_my-app_1787020000.sh`.

### 2. Deploy an immutable tag

```bash
IMAGE_TAG=v1.4.2 ./deploy_my-app_1787020000.sh
```

Immutable build tags are recommended. `latest` is supported and is resolved to
its registry digest before services are updated:

```bash
IMAGE_TAG=latest ./deploy_my-app_1787020000.sh
```

The generated wrapper keeps a shallow checkout at `/tmp/swarm-stackhouse` and
refreshes it from the selected branch when upstream changes.

## Direct usage

To run the deploy implementation from an existing checkout:

```bash
IMAGE_REPO=myorg/myapp \
STACK_NAME=my-app \
STACK_FILE=/root/docker/my-app-stack.yml \
IMAGE_TAG=v1.4.2 \
bash scripts/deploy_and_cleanup.sh
```

Required variables:

| Variable | Meaning |
| --- | --- |
| `IMAGE_REPO` | Registry repository without a tag or digest |
| `STACK_NAME` | Docker Swarm stack name |
| `STACK_FILE` | Absolute or working-directory-relative stack YAML path |

Common optional variables:

| Variable | Default | Meaning |
| --- | --- | --- |
| `IMAGE_TAG` | `latest` | Tag to deploy |
| `LOG_FILE` | `log/deploy_<stack>_uniq.log` | Deployment log |
| `DIGEST_DIR` | `digests/` | Successful digest history |
| `DEPLOY_BACKGROUND` | `false` | Return immediately while deployment continues |
| `CLEANUP_SCRIPT` | `scripts/run_swarm_cleanup.sh` | Cleanup entry point |

Avoid `DEPLOY_BACKGROUND=true` in CI because the caller cannot receive a later
deployment failure.

## One-shot migration services

A migration service should exit after its command succeeds:

```yaml
services:
  migrate:
    image: "${IMAGE_NAME:-myorg/myapp:latest}"
    command: ["bundle", "exec", "rails", "db:prepare"]
    deploy:
      replicas: 1
      restart_policy:
        condition: none
      placement:
        constraints:
          - node.role == manager
```

Stackhouse recognizes `restart_policy.condition: none`, updates the service in
detached mode, and waits for the new task. Exit code `0` is success; failed,
rejected, orphaned, non-zero, or timed-out tasks stop the deployment before
long-running services are updated.

## Rollback

Successful deployments retain the five most recent digests in
`digests/<STACK_NAME>_image_digests.log`.

Choose one interactively:

```bash
STACK_NAME=my-app IMAGE_REPO=myorg/myapp \
bash scripts/manual_rollback.sh
```

Or supply a known digest without a prompt:

```bash
STACK_NAME=my-app \
IMAGE_REPO=myorg/myapp \
TARGET_DIGEST=sha256:deadbeef \
bash scripts/manual_rollback.sh
```

Rollback uses the same repository filter and one-shot service handling as a
normal deployment.

## Image cleanup

After a successful deployment, `run_swarm_cleanup.sh` creates a temporary global
service. Each node clones this repository and removes unused images belonging to
`IMAGE_REPO`. Images referenced by running containers or Swarm services are
kept. Containers and images belonging to other repositories are not removed.

Preview cleanup without deleting images:

```bash
IMAGE_REPO=myorg/myapp DRY_RUN=1 bash scripts/run_swarm_cleanup.sh
```

Cleanup nodes need outbound access to GitHub and Alpine package repositories.
The cleanup service mounts the Docker socket, which grants root-equivalent
control of that node; use only a trusted repository and stack file.

## Logs and troubleshooting

Follow a deployment:

```bash
tail -f /tmp/swarm-stackhouse/log/deploy_my-app_uniq.log
```

Inspect a failed migration:

```bash
docker service ps my-app_migrate --no-trunc
docker service logs my-app_migrate --raw --timestamps --tail 200
docker service inspect my-app_migrate --format '{{json .UpdateStatus}}'
```

Inspect all stack services:

```bash
docker stack services my-app
docker stack ps my-app --no-trunc
```

If a deploy reports that another deployment is running, check the PID recorded
in `/tmp/deploy_<STACK_NAME>_uniq.pid`. A stale lock is removed automatically;
do not delete a lock belonging to a live deployment.

## Sample stack

[`swarm-stack-sample/sample-stack.yml`](swarm-stack-sample/sample-stack.yml)
shows the expected `${IMAGE_NAME:-...}` image override. Replace all placeholder
domains, credentials, commands, and health endpoints before using it.

Do not store production secrets directly in a committed stack file. Use Docker
secrets or environment values managed on the Swarm manager.

## Development checks

```bash
bash -n setup.sh stackhouse_deploy_and_clean.sh scripts/*.sh
git diff --check
```

For deeper static analysis when ShellCheck is installed:

```bash
shellcheck setup.sh stackhouse_deploy_and_clean.sh scripts/*.sh
```

## License

MIT.
