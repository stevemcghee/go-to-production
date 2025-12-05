# Written by Gemini CLI
# This file is licensed under the MIT License.
# See the LICENSE file for details.

# Stage 1: Build the Go application
FROM golang:1.24-alpine AS builder

ARG TARGETOS
ARG TARGETARCH

WORKDIR /app

COPY go.mod ./
COPY go.sum ./
RUN go mod download

COPY . .

# Use TARGETOS and TARGETARCH for cross-compilation
RUN CGO_ENABLED=0 GOOS=${TARGETOS:-linux} GOARCH=${TARGETARCH} go build -o /main .

# Stage 2: Create the final image
FROM alpine:latest

WORKDIR /app

RUN apk add --no-cache curl && \
    addgroup -S appgroup && \
    adduser -S appuser -G appgroup

USER appuser

COPY --from=builder /main .
COPY templates ./templates
COPY static ./static

EXPOSE 8080

CMD ["/app/main"]
