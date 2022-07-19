# This Makefile is meant for compatibility with MacOS and Linux. For Windows,
# manually follow the steps documented in README.md.

.PHONY: build
build: depends image cluster longhorn istio gitea fleet

.PHONY: reset
reset: clean-kind clean-fleet-repos clean-fleet-keys build

.PHONY: clean
clean: clean-kind clean-fleet-keys clean-fleet-repos
	@echo "Remember to clean your ~/.ssh/config and ~/.ssh/known_hosts files"

.PHONY: scrub
scrub: clean clean-docker clean-depends

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
	helm -n longhorn-system install --create-namespace longhorn https://github.com/longhorn/charts/releases/download/longhorn-1.2.2/longhorn-1.2.2.tgz \
	  --set persistence.defaultClass=false

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
	kubectl -n gitops get secret/git-user -o name || kubectl -n gitops create secret generic git-user --from-literal=username=gitops --from-literal=password=$$(openssl rand -hex 6)

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
	@echo "Waiting for Gitea to be ready. This could take a few of minutes..."
	@kubectl -n gitops wait --for=condition=Ready pod/gitea-0 --timeout=3m
	@echo "Pod is up, waiting for API calls to succeed..."
	until curl --fail http://localhost:8080/gitea/api/v1/version > /dev/null 2>&1; do echo '.'; sleep 1; done
	@echo " Done!"

.PHONY: clean-gitea
clean-gitea:
	helm -n gitops uninstall gitea || true
	kubectl -n gitops delete vs/gitea-http || true
	kubectl delete ns gitops || true

.PHONY: reset-gitea
reset-gitea: clean-gitea gitea

.PHONY: gitea-admin-password
gitea-admin-password:
	@kubectl -n gitops get secret/git-admin -o go-template='{{ .data.password }}' |base64 -d

.PHONY: gitea-user-password
gitea-user-password:
	@kubectl -n gitops get secret/git-user -o go-template='{{ .data.password }}' |base64 -d

.PHONY: fleet
fleet : GITEA_ADMIN_USERNAME=$(shell kubectl -n gitops get secret/git-admin -o go-template='{{ .data.username }}' |base64 -d)
fleet : GITEA_ADMIN_PASSWORD=$(shell kubectl -n gitops get secret/git-admin -o go-template='{{ .data.password }}' |base64 -d)
fleet : GITEA_USERNAME=$(shell kubectl -n gitops get secret/git-user -o go-template='{{ .data.username }}' |base64 -d)
fleet : GITEA_PASSWORD=$(shell kubectl -n gitops get secret/git-user -o go-template='{{ .data.password }}' |base64 -d)
fleet:
	curl --fail --user "$(GITEA_ADMIN_USERNAME):$(GITEA_ADMIN_PASSWORD)" -H "Content-Type: application/json" -H "Accept: application/json" --data '{"email":"ops@ellingsonmineral.fun","username":"$(GITEA_USERNAME)","password":"$(GITEA_PASSWORD)", "send_notify":false, "must_change_password":false}' http://localhost:8080/gitea/api/v1/admin/users
	curl --fail --user "$(GITEA_USERNAME):$(GITEA_PASSWORD)" -H "Content-Type: application/json" -H "Accept: application/json" --data '{"name":"fleet-bootstrap"}' http://localhost:8080/gitea/api/v1/user/repos
	curl --fail --user "$(GITEA_USERNAME):$(GITEA_PASSWORD)" -H "Content-Type: application/json" -H "Accept: application/json" --data '{"name":"fleet-control"}' http://localhost:8080/gitea/api/v1/user/repos
	curl --fail --user "$(GITEA_USERNAME):$(GITEA_PASSWORD)" -H "Content-Type: application/json" -H "Accept: application/json" --data '{"name":"vitruvian"}' http://localhost:8080/gitea/api/v1/user/repos
	echo protocol=http > .gitcredentials
	echo host=localhost:8080 >> .gitcredentials
	echo username=$(GITEA_USERNAME) >> .gitcredentials
	echo password=$(GITEA_PASSWORD) >> .gitcredentials
	git credential approve < .gitcredentials
	@sleep 3
	cd fleet/bootstrap && git init && git config --local --add user.name "Ellingson Gitops" && git config --local --add user.email "ops@ellingsonmineral.fun" && git checkout -B main && git add -A && git commit -m "Fleet Bootstrap" && git remote add origin http://localhost:8080/gitea/gitops/fleet-bootstrap && git push -u origin main
	cd fleet/control && git init && git config --local --add user.name "Eugene Belford" && git config --local --add user.email "plague@ellingsonmineral.fun" && git checkout -B main && git add -A && git commit -m "Fleet Control" && git remote add origin http://localhost:8080/gitea/gitops/fleet-control && git push -u origin main
	cd fleet/vitruvian && git init && git config --local --add user.name "Eugene Belford" && git config --local --add user.email "plague@ellingsonmineral.fun" && git checkout -B main && git add -A && git commit -m "The Vitruvian Man" && git remote add origin http://localhost:8080/gitea/gitops/vitruvian && git push -u origin main
	git credential reject < .gitcredentials
	rm .gitcredentials
	ssh-keygen -t ecdsa -C "Fleet" -f fleet-key -N ""
	curl --fail --user "$(GITEA_USERNAME):$(GITEA_PASSWORD)" -H "Content-Type: application/json" -H "Accept: application/json" --data "{\"key\":\"$$(cat fleet-key.pub |tr -d '\n')\",\"title\":\"fleet\"}" http://localhost:8080/gitea/api/v1/user/keys
	kubectl create ns fleet-local
	kubectl -n fleet-local create secret generic gitops-ssh-key --type=kubernetes.io/ssh-auth --from-file=ssh-privatekey=fleet-key --from-file=ssh-publickey=fleet-key.pub
	kubectl create ns fleet-default
	kubectl -n fleet-default create secret generic gitops-ssh-key --type=kubernetes.io/ssh-auth --from-file=ssh-privatekey=fleet-key --from-file=ssh-publickey=fleet-key.pub
	rm fleet-key fleet-key.pub
	helm -n fleet-system install --create-namespace --wait fleet-crd https://github.com/rancher/fleet/releases/download/v0.3.8/fleet-crd-0.3.8.tgz
	helm -n fleet-system install fleet https://github.com/rancher/fleet/releases/download/v0.3.8/fleet-0.3.8.tgz \
	  --set bootstrap.repo=git@gitea-ssh.gitops:gitops/fleet-bootstrap.git \
	  --set bootstrap.secret=gitops-ssh-key \
	  --set bootstrap.branch=main

.PHONY: clean-fleet
clean-fleet : GITEA_ADMIN_USERNAME=$(shell kubectl -n gitops get secret/git-admin -o go-template='{{ .data.username }}' |base64 -d)
clean-fleet : GITEA_ADMIN_PASSWORD=$(shell kubectl -n gitops get secret/git-admin -o go-template='{{ .data.password }}' |base64 -d)
clean-fleet : GITEA_USERNAME=$(shell kubectl -n gitops get secret/git-user -o go-template='{{ .data.username }}' |base64 -d)
clean-fleet: clean-fleet-repos clean-fleet-keys
	helm -n fleet-system uninstall fleet || true
	helm -n fleet-system uninstall fleet-crd || true
	kubectl delete ns fleet-default || true
	kubectl delete ns fleet-local || true
	kubectl delete ns fleet-system || true
	curl --user "$(GITEA_ADMIN_USERNAME):$(GITEA_ADMIN_PASSWORD)" -H "Accept: application/json" -X DELETE http://localhost:8080/gitea/api/v1/repos/$(GITEA_USERNAME)/vitruvian || true
	curl --user "$(GITEA_ADMIN_USERNAME):$(GITEA_ADMIN_PASSWORD)" -H "Accept: application/json" -X DELETE http://localhost:8080/gitea/api/v1/repos/$(GITEA_USERNAME)/fleet-control || true
	curl --user "$(GITEA_ADMIN_USERNAME):$(GITEA_ADMIN_PASSWORD)" -H "Accept: application/json" -X DELETE http://localhost:8080/gitea/api/v1/repos/$(GITEA_USERNAME)/fleet-bootstrap || true
	curl --user "$(GITEA_ADMIN_USERNAME):$(GITEA_ADMIN_PASSWORD)" -H "Accept: application/json" -X DELETE http://localhost:8080/gitea/api/v1/admin/users/$(GITEA_USERNAME) || true

.PHONY: clean-fleet-repos
clean-fleet-repos:
	cd fleet/bootstrap && rm -rf .git || true
	cd fleet/control && rm -rf .git || true
	cd fleet/vitruvian && rm -rf .git || true

.PHONY: clean-fleet-keys
clean-fleet-keys:
	[ ! -f fleet-key ] || rm fleet-key
	[ ! -f fleet-key.pub ] || rm fleet-key.pub

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
