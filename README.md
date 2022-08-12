# DEF CON 30 - The Call Is Coming From Inside the Cluster

My sincere hope is that this walkthrough makes it incredibly easy for anyone interested in recreating the attack from our demo to do just that. I'm sure there is some step I either left out or did not fully document, so if you get stuck, please feel free to open an issue on the GitHub project. I'll do my best to respond promptly.

## Setup

### Prerequisites

- [istioctl v1.4.6](https://github.com/istio/istio/releases/tag/1.4.6)
- [docker](https://docs.docker.com/get-docker/)
- [kind](https://kind.sigs.k8s.io/docs/user/quick-start/#installation)
- [kubectl](https://kubernetes.io/docs/tasks/tools/#kubectl)
- [helm](https://helm.sh/docs/intro/install/)

Also, you'll need to clone the Longhorn exploit package and build the Docker image. As long as the Docker image is locally available, the Makefile will take care of loading it into the demo cluster.
1. Clone git@github.com:dagan/rustler.git
2. Run ```make raider```

### Make

The included Makefile creates a fully functional demo cluster for you to attack. It was written for *nix and MacOS systems. For Windows, you'll need to perform the steps manually (sorry!).

The Makefile will:
 - Stand up a kind cluster with Longhorn dependencies preloaded in the node
 - Install Longhorn, Istio, Kiali, and Fleet
 - Create a CronJob to simulate active GitOps-based cluster management
 - Preload the exploit image into the cluster (this is only necessary because the exploit image is not published to a public registry)

## Walkthrough

### Kiali

1. Use https://jwt.io to create a new JWT signed with the secret "kiali".
    - the signing key must be "kiali"
    - "exp" claim with a future timestamp is required (e.g., 1975944776)
    - "iss" claim must be set to "kiali-login"
    - "sub" claim must be a non-empty string
   ```
   eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJleHAiOjE5NzU5NDQ3NzYsImlzcyI6ImtpYWxpLWxvZ2luIiwic3ViIjoiMTMzNyBoYXhvciJ9.Ub63IF6JujWvPc9AEzj4QbE1hjRujEB3Q4kOxabDzUo
   ```
2. Visit http://localhost:8080/kiali/console.
3. Using your browser's developer tools/console, add a cookie named "kiali-token" and set the value to be the JWT created in step 2.
4. Reload the page.
5. You're in.

### Fleet

1. With Kiali, take look at the logs of the fleet-agent workload in the fleet-system namespace.
2. Look for an error message like this:
 > 2022-08-12T14:39:01.809864780Z time="2022-08-12T14:39:01Z" level=error msg="bundle bootstrap: gitrepo.fleet.cattle.io fleet-local/control error] time=\"2022-08-12T14:38:20Z\" level=info msg=\"updated: fleet-local/control\\n\"\ntime=\"2022-08-12T14:38:21Z\" level=fatal msg=\"error downloading 'ssh://git@gitea-ssh.gitops/gitops/vitruvian.git?ref=develop&sshkey=LS0tLS1CRU...
3. I removed most of the SSH key from the log snippet above, but the actual error message includes the entire base64-encoded private SSH key. Decode it and save it to local file.
4. There is also a complete GIT URL for the erring repository. To simplify the demo environment, Gitea is running in the same cluster as Fleet, so this URL only works inside the cluster. However, the same SSH service can be reached at localhost:2222, so replace ```gitea-ssh.gitpos``` with ```loalhost:2222``` and then clone the repository. (In a real-world scenario, Fleet would most likely be pulling from a remote Git repository and the URL would not need to be modified.)
5. Note that while Fleet is looking a ```develop``` branch, the only branch in the repository is ```main```. To run the exploit, you'll need to:
   1. Create and checkout a ```develop``` branch.
   2. Start netcat listening on a chosen port (the demo uses 12345)
   3. Modify the Helm chart to deploy dagan/rustler:raider and provide your system's LAN IP (localhost will _not_ work) and chosen netcat port as the arguments.]
   4. Commit your changes and push the ```develop``` branch.
6. As soon as Fleet picks up your changes and deploys them, your exploit payload should connect to netcat and provide you a remote shell.

### Longhorn

1. From your remote shell, run ifconfig to determine the pod's CIDR block. Then run nmap to find Longhorn manager pods (they listen on port 8500).
2. Start a second netcat listener on a different port (the demo uses 12346).
3. From your remote shell, execute rustle to get the second reverse shell. (The longhorn base image is Ubuntu, so bash is available.)
4. Your second reverse shell provides root access on the Longhorn pod, which is _very_ privileged.
5. The host's (node's) ```/proc``` and ```/dev``` filesystems are mounted in the Longhorn pod at ```/host/proc``` and ```/host/dev```, respectively. Using chroot, change your session's root to ```/host/proc/1/root```.
6. You are now running as root on the node. ```crictl``` works, and if you dig around in the containers to find either longhorn-manager or fleet-agent, you can get a Service Account token that has "*, *, *" permissions.