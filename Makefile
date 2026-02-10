GO ?= $(shell which go)
OCB_VERSION ?= 0.145.0
OTELCOL_VERSION = $(OCB_VERSION)
OTELCOL_BUILDER_DIR ?= ${PWD}/bin
OTELCOL_BUILDER ?= ${OTELCOL_BUILDER_DIR}/ocb

# VENDOR_LD_EXTRAFLAGS ?=
VENDOR_LD_EXTRAFLAGS = -s -w -X runtime.buildVersion=unknown -X runtime.modinfo=
LD_EXTRAFLAGS ?= "$(VENDOR_LD_EXTRAFLAGS)"
PLATFORMS ?= linux/arm64,linux/amd64
# BUILDX_OUTPUT defines the buildx output
# --load builds locally the container image
# --push builds and pushes the container image to a registry
BUILDX_OUTPUT ?= --push
HUB = build-harbor.alauda.cn/asm
IMAGE_BASE = opentelemetry-collector
EPOCH ?=
TAG ?= ${OTELCOL_VERSION}-${EPOCH}
IMAGE ?= ${HUB}/${IMAGE_BASE}:${TAG}
# BUILDX_ADDITIONAL_TAGS are the additional --tag flags passed to the docker buildx build command.
BUILDX_ADDITIONAL_TAGS ?=

.PHONY: build
build: ocb
	@mkdir -p _build
	${OTELCOL_BUILDER} --skip-compilation=false --config manifest.yaml 2>&1 | tee _build/build.log

.PHONY: generate-sources
generate-sources: ocb
	@mkdir -p _build
	${OTELCOL_BUILDER} --skip-compilation=true --config manifest.yaml 2>&1 | tee _build/build.log

.PHONY: alauda-docker-build
alauda-docker-build:
	docker build --build-arg OCB_VERSION=$(OCB_VERSION) --build-arg LD_EXTRAFLAGS=$(LD_EXTRAFLAGS) -t ${IMAGE} .

.PHONY: alauda-docker-buildx
alauda-docker-buildx:
	docker buildx build $(BUILDX_OUTPUT) --platform=$(PLATFORMS) -f Dockerfile --tag ${IMAGE} \
	--build-arg OCB_VERSION=$(OCB_VERSION) --build-arg LD_EXTRAFLAGS=$(LD_EXTRAFLAGS) \
	$(BUILDX_ADDITIONAL_TAGS) .

.PHONY: ocb
ocb:
ifeq (, $(shell command -v ocb 2>/dev/null))
	@{ \
	[ ! -x '$(OTELCOL_BUILDER)' ] || exit 0; \
	set -e ;\
	os=$$(uname | tr A-Z a-z) ;\
	machine=$$(uname -m) ;\
	[ "$${machine}" != x86 ] || machine=386 ;\
	[ "$${machine}" != x86_64 ] || machine=amd64 ;\
    echo "Installing ocb ($${os}/$${machine}) at $(OTELCOL_BUILDER_DIR)";\
	mkdir -p $(OTELCOL_BUILDER_DIR) ;\
	CGO_ENABLED=0 go install -trimpath -ldflags="-s -w" go.opentelemetry.io/collector/cmd/builder@v$(OCB_VERSION) ;\
	mv $$(go env GOPATH)/bin/builder $(OTELCOL_BUILDER) ;\
	}
else
OTELCOL_BUILDER=$(shell command -v ocb)
endif

.PHONY: version
version:
	@echo $(OTELCOL_VERSION)
