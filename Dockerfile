#syntax=build-harbor.alauda.cn/asm/dockerfile:1.12

FROM docker-mirrors.alauda.cn/library/golang:1.25.7 AS build-stage

ARG OCB_VERSION
ARG LD_EXTRAFLAGS

ENV GOPROXY="https://goproxy.cn,direct"

WORKDIR /build

COPY ./manifest.yaml manifest.yaml

RUN GO111MODULE=on go install go.opentelemetry.io/collector/cmd/builder@v${OCB_VERSION}
RUN builder --config manifest.yaml --ldflags "${LD_EXTRAFLAGS}"

FROM build-harbor.alauda.cn/mlops/static@sha256:d2185a95c5e553a32e4f82d8138ccb78b57242f987985bd089ae2fb3c21e18d0

COPY ./configs/otelcol.yaml /etc/otelcol/config.yaml
COPY --chmod=755 --from=build-stage /build/_build/otelcol /otelcol

ENTRYPOINT ["/otelcol"]
CMD ["--config", "/etc/otelcol/config.yaml"]

EXPOSE 4317 4318 55679
