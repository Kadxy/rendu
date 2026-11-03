# Builds a static rendu-server (pure-Go SQLite, no cgo).
FROM golang:1.27 AS build
WORKDIR /src
COPY go.mod go.sum ./
RUN go mod download
COPY cmd ./cmd
COPY internal ./internal
ARG VERSION=dev
RUN CGO_ENABLED=0 go build -trimpath -ldflags="-s -w -X github.com/Kadxy/rendu/internal/server.Version=${VERSION}" -o /out/rendu-server ./cmd/rendu-server \
 && mkdir -p /out/data

FROM gcr.io/distroless/static-debian12:nonroot
COPY --from=build /out/rendu-server /usr/local/bin/rendu-server
# A fresh named volume inherits this directory's ownership, so the nonroot
# user can create the database in it.
COPY --from=build --chown=65532:65532 /out/data /data
ENV RENDU_DB=/data/rendu.db RENDU_ADDR=0.0.0.0:8787
EXPOSE 8787
ENTRYPOINT ["/usr/local/bin/rendu-server"]
CMD ["serve"]
