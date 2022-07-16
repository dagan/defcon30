# This Makefile is meant for compatibility with MacOS and Linux. For Windows,
# manually follow the steps documented in README.md.

GITOPS_PUBLIC_KEY=ecdsa-sha2-nistp256 AAAAE2VjZHNhLXNoYTItbmlzdHAyNTYAAAAIbmlzdHAyNTYAAABBBN6HY7lDW2kSd0V6J/I8PZEG9bYGkl0oXYqowJIjyPxDvnezbfc2fgQiZscb03ySihdMaxtSWJcer93suyYKShM=

.PHONY: build
build: depends image cluster longhorn istio gitea

.PHONY: reset
reset: clean-kind clean-git-repos build

.PHONY: clean
clean: clean-kind clean-docker clean-depends

.PHONY: clean-kind
clean-kind:
	kind delete cluster --name pwnership || true

.PHONY: clean-docker
clean-docker:
	docker image rm defcon30/kind:pwnership || true

.PHONY: clean-depends
clean-depends:
	rm -rf istio-1.4.6 || true

.PHONY: image
image:
	@[ -n "`docker images --format "{{ .Repository }}" defcon30/kind:pwnership`" ] || docker build -t defcon30/kind:pwnership .

.PHONY: cluster
cluster:
	kind create cluster --image=defcon30/kind:pwnership --name pwnership --config kind.yaml

.PHONY: longhorn
longhorn:
	helm -n longhorn-system install --create-namespace longhorn https://github.com/longhorn/charts/releases/download/longhorn-1.2.2/longhorn-1.2.2.tgz

ISTIOCTL := "$(shell pwd)/istio-1.4.6/bin/istioctl"
.PHONY: istio
istio:
	$(ISTIOCTL) manifest apply --set values.kiali.enabled=true --set values.gateways.istio-ingressgateway.type=NodePort || true
	kubectl -n istio-system patch svc/istio-ingressgateway --type=merge --patch='{"spec": {"ports": [{"name": "http2", "port": 80, "targetPort": 80, "nodePort": 31080, "hostPort": 8080, "listenAddress": "127.0.0.1", "protocol": "TCP"}]}}'
	kubectl -n istio-system create secret generic kiali --from-literal=username=kiali --from-literal=passphrase=$$(openssl rand -hex 12)
	kubectl -n istio-system apply -f istio.yaml

.PHONY: gitea-secrets
gitea-secrets:
	kubectl get ns gitops || (kubectl create ns gitops && kubectl wait ns gitops --for=jsonpath='{.status.phase}'=Active)
	kubectl -n gitops get secret/git-admin -o name || kubectl -n gitops create secret generic git-admin --from-literal=username=git-admin --from-literal=password=$$(openssl rand -hex 8)
	kubectl -n gitops get secret/git-user -o name || kubectl -n gitops create secret generic git-user --from-literal=username=git-user --from-literal=password=$$(openssl rand -hex 6)

.PHONY: gitea
gitea : ADMIN_PASSWORD=$(shell kubectl -n gitops get secret/git-admin -o go-template='{{ .data.password }}' |base64 -d)
gitea : USER_PASSWORD=$(shell kubectl -n gitops get secret/git-user -o go-template='{{ .data.password }}' |base64 -d)
gitea: gitea-secrets
	helm -n gitops install gitea https://dl.gitea.io/charts/gitea-5.0.9.tgz \
      --set gitea.admin.existingSecret=git-admin \
      --set gitea.config.server.ROOT_URL=http://localhost:8080/gitea/ \
      --set gitea.config.server.DOMAIN=localhost \
      --set gitea.config.server.SSH_DOMAIN=localhost \
      --set gitea.config.server.SSH_PORT=2222 \
      --set service.ssh.type=NodePort \
      --set service.ssh.nodePort=31022
	kubectl -n gitops apply -f gitea.yaml
	@echo "Waiting for Gitea to be ready. This could take a couple of minutes..."
	@kubectl -n gitops wait --for=condition=Ready pod/gitea-0 --timeout=2m && sleep 5
	curl --fail --user "git-admin:$(ADMIN_PASSWORD)" -H "Content-Type: application/json" -H "Accept: application/json" --data '{"email":"ops@ellingsonmineral.fun","username":"gitops","password":"$(USER_PASSWORD)", "send_notify":false, "must_change_password":false}' http://localhost:8080/gitea/api/v1/admin/users
	curl --fail --user "gitops:$(USER_PASSWORD)" -H "Content-Type: application/json" -H "Accept: application/json" --data '{"key":"$(GITOPS_PUBLIC_KEY)","title":"fleet"}' http://localhost:8080/gitea/api/v1/user/keys
	curl --fail --user "gitops:$(USER_PASSWORD)" -H "Content-Type: application/json" -H "Accept: application/json" --data '{"name":"fleet-bootstrap"}' http://localhost:8080/gitea/api/v1/user/repos
	curl --fail --user "gitops:$(USER_PASSWORD)" -H "Content-Type: application/json" -H "Accept: application/json" --data '{"name":"fleet-control"}' http://localhost:8080/gitea/api/v1/user/repos
	curl --fail --user "gitops:$(USER_PASSWORD)" -H "Content-Type: application/json" -H "Accept: application/json" --data '{"name":"vitruvian"}' http://localhost:8080/gitea/api/v1/user/repos
	echo protocol=http > .gitcredentials
	echo host=localhost:8080 >> .gitcredentials
	echo username=gitops >> .gitcredentials
	echo password=$(USER_PASSWORD) >> .gitcredentials
	git credential approve < .gitcredentials
	sleep 1
	cd fleet/bootstrap && git init && git config --local --add user.name "Ellingson Gitops" && git config --local --add user.email "ops@ellingsonmineral.fun" && git checkout -B main && git add -A && git commit -m "Fleet Bootstrap" && git remote add origin http://localhost:8080/gitea/gitops/fleet-bootstrap && git push -u origin main
	cd fleet/control && git init && git config --local --add user.name "Eugene Belford" && git config --local --add user.email "plague@ellingsonmineral.fun" && git checkout -B main && git add -A && git commit -m "Fleet Control" && git remote add origin http://localhost:8080/gitea/gitops/fleet-control && git push -u origin main
	cd fleet/vitruvian && git init && git config --local --add user.name "Eugene Belford" && git config --local --add user.email "plague@ellingsonmineral.fun" && git checkout -B main && git add -A && git commit -m "The Vitruvian Man" && git remote add origin http://localhost:8080/gitea/gitops/vitruvian && git push -u origin main
	git credential reject < .gitcredentials
	rm .gitcredentials

.PHONY: gitea-check
gitea-check:
	eval ""$$check""

.PHONY: clean-gitea
clean-gitea:
	helm -n gitops uninstall gitea || true
	kubectl -n gitops delete vs/gitea-http || true
	kubectl delete ns gitops || true

.PHONY: clean-git-repos
clean-git-repos:
	cd fleet/bootstrap && rm -rf .git || true
	cd fleet/control && rm -rf .git || true
	cd fleet/vitruvian && rm -rf .git || true

.PHONY: reset-gitea
reset-gitea: clean-git-repos clean-gitea gitea

.PHONY: gitea-admin-password
gitea-admin-password:
	@kubectl -n gitops get secret/git-admin -o go-template='{{ .data.password }}' |base64 -d

.PHONY: gitea-user-password
gitea-user-password:
	@kubectl -n gitops get secret/git-user -o go-template='{{ .data.password }}' |base64 -d

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
