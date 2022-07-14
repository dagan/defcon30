# This Makefile is meant for compatibility with MacOS and Linux. For Windows,
# manually follow the steps documented in README.md.

.PHONY: build
build: depends image cluster istio

.PHONY: clean
clean:
	kind delete cluster --name pwnership || true
	docker image rm defcon30/kind:pwnership || true
	rm -rf istio-1.4.6 || true

.PHONY: image
image:
	@[ -n "`docker images --format "{{ .Repository }}" defcon30/kind:pwnership`" ] || docker build -t defcon30/kind:pwnership .

.PHONY: cluster
cluster:
	kind create cluster --image=defcon30/kind:pwnership --name pwnership --config kind.yaml

ISTIOCTL := "$(shell pwd)/istio-1.4.6/bin/istioctl"
.PHONY: istio
istio:
	$(ISTIOCTL) manifest apply --set values.kiali.enabled=true --set values.gateways.istio-ingressgateway.type=NodePort || true
	kubectl -n istio-system patch svc/istio-ingressgateway --type=merge --patch='{"spec": {"ports": [{"name": "http2", "port": 80, "targetPort": 80, "nodePort": 31080, "hostPort": 8080, "listenAddress": "127.0.0.1", "protocol": "TCP"}]}}'
	kubectl -n istio-system create secret generic kiali --from-literal=username=kiali --from-literal=passphrase=$$(openssl rand -base64 12)
	kubectl -n istio-system apply -f istio.yaml

.PHONY: depends
depends: istio-1.4.6
	@which docker > /dev/null || (echo "Please install docker: https://docs.docker.com/get-docker/" && OK=1)
	@which kind > /dev/null || (echo "Please install kind: https://kind.sigs.k8s.io/docs/user/quick-start/#installation" && OK=1)
	@which kubectl > /dev/null || (echo "Please install kubectl: https://kubernetes.io/docs/tasks/tools/#kubectl" && OK=1)
	@which helm > /dev/null || (echo "Please install helm: https://helm.sh/docs/intro/install/" && OK=1)
	@[ $OK ] || exit 1

OS = $(shell uname -s)
ifeq ($(OS),Linux)
  ISTIO = "https://github.com/istio/istio/releases/download/1.4.6/istio-1.4.6-linux.tar.gz"
endif
ifeq ($(OS),Darwin)
  ISTIO = "https://github.com/istio/istio/releases/download/1.4.6/istio-1.4.6-osx.tar.gz"
endif
istio-1.4.6:
	@[ -n "$(ISTIO)" ] || (echo "For Windows, manually follow the instructions in README.md" && exit 1)
	curl -Lo istio-1.4.6.tar.gz "$(ISTIO)"
	tar -zxf istio-1.4.6.tar.gz && rm istio-1.4.6.tar.gz
