# Docker Compose destination

The native-installation instructions are in [README.MD](../README.MD). For Docker,
run these commands on the target host from its Compose project directory.

Set the actual service name, local files and existing destination username:

```sh
printf 'Mastodon web service name in Compose: '
read -r WEB_SERVICE
printf 'Local absolute path to import.rb: '
read -r IMPORT_SCRIPT
printf 'Local absolute archive directory: '
read -r ARCHIVE
printf 'Existing local Mastodon username: '
read -r TARGET_USER
```

Use a new container work directory to avoid merging different archives. The
following fixed temporary path is only an example, not a configured account/domain:

```sh
CONTAINER_WORK='/tmp/gotosocial-to-mastodon'
CONTAINER_OWNER=$(docker compose exec -T "$WEB_SERVICE" \
  sh -c 'printf "%s:%s" "$(id -u)" "$(id -g)"')

docker compose exec "$WEB_SERVICE" mkdir -p "$CONTAINER_WORK"
docker compose cp "$IMPORT_SCRIPT" "${WEB_SERVICE}:${CONTAINER_WORK}/import.rb"
docker compose cp "$ARCHIVE" "${WEB_SERVICE}:${CONTAINER_WORK}/archive"
docker compose exec --user 0 "$WEB_SERVICE" \
  chown -R "$CONTAINER_OWNER" "$CONTAINER_WORK"

docker compose exec -e RAILS_ENV=production "$WEB_SERVICE" \
  bundle exec rails runner "${CONTAINER_WORK}/import.rb" \
  --archive "${CONTAINER_WORK}/archive" \
  --target-user "$TARGET_USER" \
  --exclude-replies --split-long-posts
```

The ownership adjustment is needed because copied files may be owned by root,
while exports deliberately use restrictive permissions. The importer itself should
run as the container's regular Mastodon service user.

Review the preview, back up database and media, then repeat the final command with
`--apply`. Use `--skip-unsupported` only after accepting all reported exclusions.
The container needs no source token or access to the source server. Temporary
copied files can be removed after verification; the durable import mapping remains
in the database.

These deployment instructions are provided for maintainers. The recorded real
migration used a native installation; Docker import has not been independently
verified in this project.
