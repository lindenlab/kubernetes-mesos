#!/bin/bash

cd $GOPATH

go get -d github.com/GoogleCloudPlatform/kubernetes

# Switch to mesosphere checkout. Event channels not yet supported in kubernetes
# proper.
pushd src/github.com/GoogleCloudPlatform/kubernetes
mesosphere_remote=`git remote -v | grep "mesosphere"`
if [ $? -ne 0 ]
then
  git remote add mesosphere git@github.com:mesosphere/kubernetes.git
fi

git fetch
git checkout mesos_provider
git pull mesosphere mesos_provider
popd

if [ -d src/github.com/fsouza/go-dockerclient-copiedstructsa ]
then
  git clone https://github.com/nqn/go-dockerclient-copiedstructs src/github.com/fsouza/go-dockerclient-copiedstructs
fi

pushd src/github.com/mesosphere/kubernetes-mesos
godep restore

popd


pushd src/github.com/GoogleCloudPlatform/kubernetes
git checkout mesos_provider
popd

go install github.com/mesosphere/kubernetes-mesos/kubernetes-mesos
go install github.com/mesosphere/kubernetes-mesos/kubernetes-executor
go install github.com/GoogleCloudPlatform/kubernetes/cmd/proxy
