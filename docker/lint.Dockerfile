# Lint toolchain for omarchy-scripts: shellcheck + shfmt.
#
# Built on alpine — a Docker Official Image, maintained by Docker and the
# Alpine team — and pinned by digest, because a tag can be repointed at new
# content while a digest cannot. The tools come from Alpine's signed package
# repositories, so the whole chain is Docker's base image plus Alpine's
# packaging, with no third-party image in between.
#
# Built by podman or docker alike — the Dockerfile format is not engine-specific
# and bin/lint prefers rootless podman. To refresh the base (podman shown; swap
# in docker and the commands are identical):
#   podman pull alpine:3.22
#   podman image inspect alpine:3.22 --format '{{index .RepoDigests 0}}'
# Paste the digest below; bin/lint rebuilds automatically on the next run.
FROM alpine@sha256:14358309a308569c32bdc37e2e0e9694be33a9d99e68afb0f5ff33cc1f695dce

RUN apk add --no-cache shellcheck shfmt

# Containers run as the caller's uid via --user (plus --userns=keep-id under
# rootless podman, where that is what makes --user mean the caller), and nothing
# is written inside the image, so there is no USER here. Empty entrypoint:
# bin/lint picks the tool, so one image serves both.
WORKDIR /mnt
ENTRYPOINT []
