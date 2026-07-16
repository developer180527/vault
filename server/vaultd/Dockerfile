# Build vaultd. Pure-Go SQLite (modernc) means no cgo — static binary,
# tiny final image.
FROM golang:1.26-alpine AS build
WORKDIR /src
COPY go.mod go.sum ./
RUN go mod download
COPY . .
RUN CGO_ENABLED=0 go build -o /out/vaultd ./cmd/vaultd \
 && CGO_ENABLED=0 go build -o /out/vaultdctl ./cmd/vaultdctl

FROM alpine:3.20
# Runs as the shared `vault` user (988:988 on this deployment) so files it
# writes into /srv/vault match the worker containers' output. The compose
# file passes user: "988:988"; this just ensures the dirs/tools are sane.
RUN apk add --no-cache ca-certificates tzdata
COPY --from=build /out/vaultd /usr/local/bin/vaultd
COPY --from=build /out/vaultdctl /usr/local/bin/vaultdctl
EXPOSE 8080
ENTRYPOINT ["/usr/local/bin/vaultd"]
