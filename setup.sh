#!/bin/bash

# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#
set -o errexit
set -o pipefail

wait_for_nodes(){
  while :
  do
    readyNodes=1
    statusList=$(kubectl get nodes --no-headers | awk '{ print $2}')
    while read status
    do
      if [ "$status" == "NotReady" ] || [ "$status" == "" ]
      then
        readyNodes=0
        break
      fi
    done <<< "$(echo -e  "$statusList")"
    if [[ $readyNodes == 1 ]]
    then
      break
    fi
    sleep 1
  done
}

curl -sLS https://get.arkade.dev | sh

curl -sfL https://get.k3s.io | INSTALL_K3S_EXEC='--no-deploy traefik --write-kubeconfig-mode 664' sh -
eval "export KUBECONFIG=/etc/rancher/k3s/k3s.yaml"

wait_for_nodes

kubectl apply -f https://github.com/splunk/splunk-operator/releases/download/1.0.1/splunk-operator-install.yaml 

cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: local-path-pvc
  namespace: default
spec:
  accessModes:
    - ReadWriteOnce
  storageClassName: local-path
  resources:
    requests:
      storage: 2Gi
EOF


cat <<EOF | kubectl apply -f -
apiVersion: apps/v1
kind: Deployment
metadata:
  name: nginx-deployment
  labels:
    app: nginx
spec:
  replicas: 1
  selector:
    matchLabels:
      app: nginx
  template:
    metadata:
      labels:
        app: nginx
    spec:
        containers:
        - name: nginx-deployment
          image: nginx:stable-alpine
          imagePullPolicy: IfNotPresent
          volumeMounts:
            - name: volv
              mountPath: /usr/share/nginx/html
          ports:
            - containerPort: 80
        volumes:
          - name: volv
            persistentVolumeClaim:
              claimName: local-path-pvc
---
apiVersion: v1
kind: Service
metadata:
  name: nginx
spec:
  ports:
  - name: client
    port: 80
    targetPort: 80
  selector:
    app: nginx
EOF


curl -s https://api.github.com/repos/splunk/splunk-add-on-for-modinput-test/releases/latest | grep "Splunk_TA.*tar.gz" | grep -v search_head | grep -v indexer | grep -v forwarder | cut -d : -f 2,3 | tr -d \" | wget -qi - || true
MODINPUT_PACKAGE=$(ls Splunk_TA*)

arkade install istio

cat <<EOF | kubectl apply -f -
apiVersion: networking.istio.io/v1beta1
kind: Gateway
metadata:
  name: splunk-web
spec:
  selector:
    istio: ingressgateway # use istio default ingress gateway
  servers:
  - port:
      number: 8000
      name: http
      protocol: TCP
    hosts:
    - "*"
  - port:
      number: 8088
      name: splunk-hec
      protocol: TCP  
    hosts:
        - "*"
  - port:
      number: 8089
      name: https-splunk-mgmt
      protocol: TCP  
    hosts:
      - "*"
  - port:
      number: 9997
      name: tcp-splunk-s2s
      protocol: TCP
    hosts:
      - "*"
---
apiVersion: networking.istio.io/v1beta1
kind: VirtualService
metadata:
  name: splunk-web
spec:
  hosts:
  - "*"
  gateways:
  - "splunk-web"
  tcp:
  - match:
    - port: 8088
    route:
    - destination:
        port:
          number: 8088
        host: splunk-s1-standalone-headless
  - match:
    - port: 8089
    route:
    - destination:
        port:
          number: 8089
        host: splunk-s1-standalone-headless
  - match:
    - port: 8000
    route:
    - destination:
        host: splunk-s1-standalone-service
        port: 
          number: 8000
  - match:
    - port: 9997
    route:
    - destination:
        host: splunk-s1-standalone-service
        port: 
          number: 9997
---
apiVersion: networking.istio.io/v1beta1
kind: DestinationRule
metadata:
  name: splunk-s1-standalone-service
spec:
  host:  splunk-s1-standalone-service
  trafficPolicy:
    loadBalancer:
      consistentHash:
        httpCookie:
          name: SPLUNK_ISTIO_SESSION
          ttl: 3600s
EOF

PACKAGE_NAME='splunk-add-on-for-salesforce_410.tgz'
POD_NAME=$(kubectl get po -l app=nginx --no-headers -o custom-columns=":metadata.name")

kubectl cp $PACKAGE_NAME $POD_NAME:/usr/share/nginx/html
kubectl cp $MODINPUT_PACKAGE $POD_NAME:/usr/share/nginx/html 


echo "PACKA" $PACKAGE_NAME
echo "MOOD" $MODINPUT_PACKAGE 

cat <<EOF | kubectl apply -f -
apiVersion: enterprise.splunk.com/v1
kind: Standalone
metadata:
  name: s1
  finalizers:
  - enterprise.splunk.com/delete-pvc
spec:
  defaults: |-
    splunk:
      apps_location:
        - "http://nginx/$PACKAGE_NAME"
        - "http://nginx/$MODINPUT_PACKAGE"
EOF

kubectl patch -n istio-system service istio-ingressgateway --patch '{"spec":{"ports":[{"name":"splunk-web","port":8000,"protocol":"TCP"}]}}'
kubectl patch -n istio-system service istio-ingressgateway --patch '{"spec":{"ports":[{"name":"splunk-hec","port":8088,"protocol":"TCP"}]}}'
kubectl patch -n istio-system service istio-ingressgateway --patch '{"spec":{"ports":[{"name":"splunk-s2s","port":9997,"protocol":"TCP"}]}}'
kubectl patch -n istio-system service istio-ingressgateway --patch '{"spec":{"ports":[{"name":"splunkd","port":8089,"protocol":"TCP"}]}}'

kubectl wait --for=condition=Ready pods splunk-s1-standalone-0 --timeout=-30s

SPLUNK_IP=$(kubectl -n istio-system get service istio-ingressgateway -o jsonpath='{.status.loadBalancer.ingress[0].ip}')

echo "::set-output name=ip::$SPLUNK_IP"
echo "::set-output name=password::$password"
echo "::set-output name=hec_token::$hec_token"
echo "::set-output name=pass4SymmKey::$pass4SymmKey"
echo "::set-output name=idxc_secret::$idxc_secret"
echo "::set-output name=shc_secret::$shc_secret"