FROM --platform=$BUILDPLATFORM docker.io/golang:1.26 AS build

# Install Node.js and pnpm for UI build
RUN apt-get update && apt-get install -y nodejs npm && \
    npm install -g pnpm@latest && \
    rm -rf /var/lib/apt/lists/*

WORKDIR /src
COPY submodules/woodpecker/ .

# Init a git repo so Makefile version detection works
RUN git init && git add -A && git commit -m "build" --allow-empty

ARG TARGETOS TARGETARCH CI_COMMIT_SHA CI_COMMIT_TAG CI_COMMIT_BRANCH
RUN --mount=type=cache,target=/root/.cache/go-build \
    --mount=type=cache,target=/go/pkg \
    make build-server

FROM docker.io/alpine:3.23

RUN apk add -U --no-cache ca-certificates && \
  adduser -u 1000 -g 1000 woodpecker -D && \
  mkdir -p /var/lib/woodpecker && \
  chown -R woodpecker:woodpecker /var/lib/woodpecker

ENV GODEBUG=netdns=go
ENV WOODPECKER_IN_CONTAINER=true
ENV XDG_CACHE_HOME=/var/lib/woodpecker
ENV XDG_DATA_HOME=/var/lib/woodpecker
EXPOSE 8000 9000

COPY --from=build /src/dist/woodpecker-server /bin/

USER woodpecker

HEALTHCHECK CMD ["/bin/woodpecker-server", "ping"]
ENTRYPOINT ["/bin/woodpecker-server"]
