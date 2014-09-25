/*
Copyright 2014 Google Inc. All rights reserved.

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

    http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.
*/

// apiserver is the main api server and master for the cluster.
// it is responsible for serving the cluster management API.
package main

import (
	"flag"
	"fmt"
	"net"
	"net/http"
	"strconv"
	"strings"
	"time"

	"code.google.com/p/goprotobuf/proto"
	"github.com/GoogleCloudPlatform/kubernetes/pkg/apiserver"
	"github.com/GoogleCloudPlatform/kubernetes/pkg/client"
	"github.com/GoogleCloudPlatform/kubernetes/pkg/cloudprovider"
	"github.com/GoogleCloudPlatform/kubernetes/pkg/master"
	"github.com/GoogleCloudPlatform/kubernetes/pkg/registry/binding"
	"github.com/GoogleCloudPlatform/kubernetes/pkg/registry/controller"
	"github.com/GoogleCloudPlatform/kubernetes/pkg/registry/etcd"
	"github.com/GoogleCloudPlatform/kubernetes/pkg/registry/minion"
	"github.com/GoogleCloudPlatform/kubernetes/pkg/registry/pod"
	"github.com/GoogleCloudPlatform/kubernetes/pkg/registry/service"
	"github.com/GoogleCloudPlatform/kubernetes/pkg/runtime"
	endpoint "github.com/GoogleCloudPlatform/kubernetes/pkg/service"

	kscheduler "github.com/GoogleCloudPlatform/kubernetes/pkg/scheduler"
	"github.com/GoogleCloudPlatform/kubernetes/pkg/tools"
	"github.com/GoogleCloudPlatform/kubernetes/pkg/util"
	plugin "github.com/GoogleCloudPlatform/kubernetes/plugin/pkg/scheduler"
	goetcd "github.com/coreos/go-etcd/etcd"
	log "github.com/golang/glog"
	"github.com/mesos/mesos-go/mesos"
	kmscheduler "github.com/mesosphere/kubernetes-mesos/scheduler"
)

var (
	port                        = flag.Uint("port", 8080, "The port to listen on.  Default 8080.")
	address                     = flag.String("address", "127.0.0.1", "The address on the local server to listen to. Default 127.0.0.1")
	apiPrefix                   = flag.String("api_prefix", "/api/v1beta1", "The prefix for API requests on the server. Default '/api/v1beta1'")
	mesosMaster                 = flag.String("mesos_master", "localhost:5050", "Location of leading Mesos master")
	executorPath                = flag.String("executor_path", "", "Location of the kubernetes executor executable")
	proxyPath                   = flag.String("proxy_path", "", "Location of the kubernetes proxy executable")
	minionPort                  = flag.Uint("minion_port", 10250, "The port at which kubelet will be listening on the minions.")
	etcdServerList, machineList util.StringList
)

const (
	artifactPort     = 9000
	cachePeriod      = 10 * time.Second
	syncPeriod       = 30 * time.Second
	httpReadTimeout  = 10 * time.Second
	httpWriteTimeout = 10 * time.Second
)

func init() {
	flag.Var(&etcdServerList, "etcd_servers", "Servers for the etcd (http://ip:port), comma separated")
	flag.Var(&machineList, "machines", "List of machines to schedule onto, comma separated.")
}

type kubernetesMaster struct {
	podRegistry        pod.Registry
	controllerRegistry controller.Registry
	serviceRegistry    service.Registry
	minionRegistry     minion.Registry
	bindingRegistry    binding.Registry
	storage            map[string]apiserver.RESTStorage
	client             *client.Client
	scheduler          *kmscheduler.KubernetesScheduler
}

// Copied from cmd/apiserver.go
func main() {
	flag.Parse()
	util.InitLogs()
	defer util.FlushLogs()

	if len(machineList) == 0 {
		log.Fatal("No machines specified!")
	}

	if len(etcdServerList) <= 0 {
		log.Fatal("No etcd severs specified!")
	}

	serveExecutorArtifact := func(path string) string {
		serveFile := func(pattern string, filename string) {
			http.HandleFunc(pattern, func(w http.ResponseWriter, r *http.Request) {
				http.ServeFile(w, r, filename)
			})
		}

		// Create base path (http://foobar:5000/<base>)
		pathSplit := strings.Split(path, "/")
		var base string
		if len(pathSplit) > 0 {
			base = pathSplit[len(pathSplit)-1]
		} else {
			base = path
		}
		serveFile("/"+base, path)

		hostURI := fmt.Sprintf("http://%s:%d/%s", *address, artifactPort, base)
		log.V(2).Infof("Hosting artifact '%s' at '%s'", path, hostURI)

		return hostURI
	}

	executorURI := serveExecutorArtifact(*executorPath)
	proxyURI := serveExecutorArtifact(*proxyPath)

	go http.ListenAndServe(":9000", nil)

	podInfoGetter := &client.HTTPPodInfoGetter{
		Client: http.DefaultClient,
		Port:   *minionPort,
	}

	client, err := client.New("http://"+net.JoinHostPort(*address, strconv.Itoa(int(*port))), nil)
	if err != nil {
		log.Fatal(err)
	}

	executorCommand := "./kubernetes-executor -v=2"
	if len(etcdServerList) > 0 {
		etcdServerArguments := strings.Join(etcdServerList, ",")
		executorCommand = "./kubernetes-executor -v=2 -hostname_override=0.0.0.0 -etcd_servers=" + etcdServerArguments
	}

	// Create mesos scheduler driver.
	executor := &mesos.ExecutorInfo{
		ExecutorId: &mesos.ExecutorID{Value: proto.String("KubeletExecutorID")},
		Command: &mesos.CommandInfo{
			Value: proto.String(executorCommand),
			Uris: []*mesos.CommandInfo_URI{
				{Value: &executorURI, Executable: proto.Bool(true)},
				{Value: &proxyURI, Executable: proto.Bool(true)},
			},
		},
		Name:   proto.String("Kubelet Executor"),
		Source: proto.String("kubernetes"),
	}

	etcdClient := goetcd.NewClient(etcdServerList)
	helper := tools.EtcdHelper{
		etcdClient,
		runtime.DefaultCodec,
		runtime.DefaultResourceVersioner,
	}
	mesosPodScheduler := kmscheduler.New(executor, kmscheduler.FCFSScheduleFunc, client, helper)
	driver := &mesos.MesosSchedulerDriver{
		Master: *mesosMaster,
		Framework: mesos.FrameworkInfo{
			Name: proto.String("KubernetesScheduler"),
			User: proto.String("root"),
		},
		Scheduler: mesosPodScheduler,
	}
	mesosPodScheduler.Driver = driver

	driver.Init()
	defer driver.Destroy()
	go driver.Start()

	log.V(2).Info("Serving executor artifacts...")
	// TODO(nnielsen): Using default pod info getter until
	// MesosPodInfoGetter supports network containers.

	// podInfoGetter := MesosPodInfoGetter.New(mesosPodScheduler)

	var cloud cloudprovider.Interface
	m := newKubernetesMaster(mesosPodScheduler, &master.Config{
		Client:        client,
		Cloud:         cloud,
		Minions:       machineList,
		PodInfoGetter: podInfoGetter,
		EtcdServers:   etcdServerList,
	}, etcdClient)
	log.Fatal(m.run(net.JoinHostPort(*address, strconv.Itoa(int(*port))), *apiPrefix, helper.Codec))
}

func newKubernetesMaster(scheduler *kmscheduler.KubernetesScheduler, c *master.Config, etcdClient tools.EtcdClient) *kubernetesMaster {
	var m *kubernetesMaster

	minionRegistry := minion.NewRegistry(c.Minions) // TODO(adam): Mimic minionRegistryMaker(c)?

	m = &kubernetesMaster{
		podRegistry:        scheduler,
		controllerRegistry: etcd.NewRegistry(etcdClient),
		serviceRegistry:    etcd.NewRegistry(etcdClient),
		minionRegistry:     minionRegistry,
		bindingRegistry:    etcd.NewRegistry(etcdClient),
		client:             c.Client,
		scheduler:          scheduler,
	}
	m.init(scheduler, c.Cloud, c.PodInfoGetter)

	return m
}

func (m *kubernetesMaster) init(scheduler kscheduler.Scheduler, cloud cloudprovider.Interface, podInfoGetter client.PodInfoGetter) {
	podCache := master.NewPodCache(podInfoGetter, m.podRegistry)
	go util.Forever(func() { podCache.UpdateAllContainers() }, cachePeriod)
	m.storage = map[string]apiserver.RESTStorage{
		"pods": pod.NewREST(&pod.RESTConfig{
			CloudProvider: cloud,
			PodCache:      podCache,
			PodInfoGetter: podInfoGetter,
			Registry:      m.podRegistry,
		}),
		"replicationControllers": controller.NewREST(m.controllerRegistry, m.podRegistry),
		"services":               service.NewREST(m.serviceRegistry, cloud, m.minionRegistry),
		"minions":                minion.NewREST(m.minionRegistry),
		// TODO: should appear only in scheduler API group.
		"bindings": binding.NewREST(m.bindingRegistry),
	}
}

// Run begins serving the Kubernetes API. It never returns.
func (m *kubernetesMaster) run(myAddress, apiPrefix string, codec runtime.Codec) error {
	endpoints := endpoint.NewEndpointController(m.serviceRegistry, m.client)
	go util.Forever(func() { endpoints.SyncServiceEndpoints() }, syncPeriod)
	plugin.New(m.scheduler.NewPluginConfig()).Run()

	s := &http.Server{
		Addr:           myAddress,
		Handler:        apiserver.Handle(m.storage, codec, apiPrefix),
		ReadTimeout:    httpReadTimeout,
		WriteTimeout:   httpWriteTimeout,
		MaxHeaderBytes: 1 << 20,
	}
	return s.ListenAndServe()
}
