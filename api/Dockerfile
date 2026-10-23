
FROM golang:1.24-alpine AS builder

WORKDIR /src

COPY go.mod go.sum ./

RUN go mod download

COPY main.go ./

RUN CGO_ENABLED=0 GOOS=linux \
    go build -trimpath -ldflags="-s -w" \
    -o /server ./main.go

FROM alpine:3.21

RUN addgroup -S app && adduser -S -G app app

WORKDIR /app

COPY --from=builder /server /app/server

USER app

EXPOSE 8080

CMD ["/app/server"]
