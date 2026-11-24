# Written by Gemini CLI
# This file is licensed under the MIT License.
# See the LICENSE file for details.

# Stage 1: Build the Go application
# Keep this tag in sync with go-version in .github/workflows/build-test.yml,
# so CI tests on the same toolchain that builds the shipped binary.
FROM golang:1.27-alpine AS builder

ARG TARGETOS
ARG TARGETARCH

WORKDIR /app

COPY go.mod ./
COPY go.sum ./
RUN go mod download

COPY . .

# Use TARGETOS and TARGETARCH for cross-compilation
RUN CGO_ENABLED=0 GOOS=${TARGETOS:-linux} GOARCH=${TARGETARCH:-amd64} go build -o /main .

# Stage 2: Create the final image
# Distroless static: no shell, no package manager, includes CA certs and tzdata.
# The binary is built with CGO_ENABLED=0, so it needs nothing else.
# The :nonroot tag runs as UID/GID 65532.
FROM gcr.io/distroless/static-debian12:nonroot

WORKDIR /app

COPY --from=builder /main .
COPY templates ./templates
COPY static ./static

USER nonroot:nonroot

EXPOSE 8080

ENTRYPOINT ["/app/main"]
