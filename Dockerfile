FROM golang:1.21-alpine as builder
RUN apk add --no-cache git
COPY . /go/src/github.com/mikebarkmin/docker-volume-glusterfs
WORKDIR /go/src/github.com/mikebarkmin/docker-volume-glusterfs
RUN go mod tidy && go mod vendor
RUN go install --ldflags '-extldflags "-static"'

FROM debian:bookworm-slim
RUN apt-get update \
  && apt-get install -y --no-install-recommends glusterfs-client \
  && apt-get clean \
  && rm -rf /var/lib/apt/lists/*
COPY --from=builder /go/bin/docker-volume-glusterfs .
CMD ["docker-volume-glusterfs"]
