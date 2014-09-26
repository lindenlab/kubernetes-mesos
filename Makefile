
# the assumption is that current_dir is something along the lines of:
# 	/home/bob/yourproject/src/github.com/mesosphere/kubernetes-mesos

mkfile_path	:= $(abspath $(lastword $(MAKEFILE_LIST)))
current_dir	:= $(patsubst %/,%,$(dir $(mkfile_path)))
fail		:= ${MAKE} --no-print-directory --quiet -f $(current_dir)/Makefile error

#frmwk_gopath	:= $(shell readlink -f $(current_dir)/../../../..)
frmwk_gopath	:= $(current_dir)

# HACK: this version needs to match the k8s version in Godeps.json
k8s_version	:= release_v0.3
k8s_pkg		:= github.com/GoogleCloudPlatform/kubernetes
#k8s_repo	:= https://$(k8s_pkg).git
k8s_repo	:= https://github.com/lindenlab/kubernetes.git
k8s_dir		:= $(frmwk_gopath)/src/$(k8s_pkg)
k8s_git		:= $(k8s_dir)/.git
k8s_gopath	:= $(k8s_dir)/Godeps/_workspace

PROXY_SRC	:= $(k8s_pkg)/cmd/proxy
PROXY_OBJ	:= $(subst $(k8s_pkg)/cmd/,$(frmwk_gopath)/bin/,$(PROXY_SRC))

FRAMEWORK_DIR	:= github.com/mesosphere/kubernetes-mesos
FRAMEWORK_SRC	:= $(FRAMEWORK_DIR)/kubernetes-mesos $(FRAMEWORK_DIR)/kubernetes-executor
FRAMEWORK_OBJ	:= $(subst $(FRAMEWORK_DIR)/,$(frmwk_gopath)/bin/,$(FRAMEWORK_SRC))

OBJS		:= $(PROXY_OBJ) $(FRAMEWORK_OBJ)

DESTDIR		?= /target

.PHONY: all error require-godep framework require-k8s require-frmwk proxy install require-mesos require-protobuf

WITH_DEPS_DIR := $(current_dir)/deps/usr

CFLAGS		+= -I$(WITH_DEPS_DIR)/include
CPPFLAGS	+= -I$(WITH_DEPS_DIR)/include
CXXFLAGS	+= -I$(WITH_DEPS_DIR)/include
LDFLAGS		+= -L$(WITH_DEPS_DIR)/lib -L$(WITH_DEPS_DIR)/lib/$(shell dpkg-architecture -qDEB_HOST_MULTIARCH 2>/dev/null) -lprotobuf

CGO_CFLAGS	+= -I$(WITH_DEPS_DIR)/include
CGO_CPPFLAGS	+= -I$(WITH_DEPS_DIR)/include
CGO_CXXFLAGS	+= -I$(WITH_DEPS_DIR)/include
CGO_LDFLAGS		+= -L$(WITH_DEPS_DIR)/lib -L$(WITH_DEPS_DIR)/lib/$(shell dpkg-architecture -qDEB_HOST_MULTIARCH 2>/dev/null) -lprotobuf

WITH_DEPS_CGO_FLAGS :=  \
	  CGO_CFLAGS="$(CGO_CFLAGS)" \
	  CGO_CPPFLAGS="$(CGO_CPPFLAGS)" \
	  CGO_CXXFLAGS="$(CGO_CXXFLAGS)" \
	  CGO_LDFLAGS="$(CGO_LDFLAGS)"

all: $(OBJS)

error:
	echo -E "$@: ${MSG}" >&2
	false

require-godep:
	env GOPATH=$(frmwk_gopath) go get github.com/tools/godep

proxy: $(PROXY_OBJ)

$(PROXY_OBJ): require-k8s
	env GOPATH=$(k8s_gopath):$(frmwk_gopath)$${GOPATH:+:$$GOPATH} go install $(PROXY_SRC)

require-k8s: | $(k8s_git)

$(k8s_git): require-frmwk
	mkdir -p $(k8s_dir)
	test -d $(k8s_git) || git clone $(k8s_repo) $(k8s_dir)
	cd $(k8s_dir) && git checkout $(k8s_version)

require-frmwk:
	test -L src/$(FRAMEWORK_DIR) || ( mkdir -p src/$$(dirname $(FRAMEWORK_DIR)) && ln -sf $(current_dir) src/$$(dirname $(FRAMEWORK_DIR))/$$(basename $(FRAMEWORK_DIR)) )

framework: $(FRAMEWORK_OBJ)

require-mesos:
	test -d deps/usr/include/mesos || ( \
		wget $$(curl $$(curl http://s3-proxy.lindenlab.com/private-builds-secondlife-com/hg/repo/mesos/latest.html | grep 'URL=' | sed -e 's/.*URL=\(.*\)".*/\1/' -e 's/html/json/')  |  python -c "import json, sys; debs=json.loads(sys.stdin.read())['arch']['Linux']['result']['debian_repo']; print [v['url'] for (k, v) in debs.items() if k.startswith('mesos_')][0]" ) \
		&& dpkg-deb --extract mesos_*.deb deps )

require-protobuf:
	test -d deps/usr/include/google/protobuf || ( apt-get download libprotobuf-dev && dpkg-deb --extract libprotobuf-dev_*deb deps )
	test -d deps/usr/share/doc/libprotobuf9 || ( apt-get download libprotobuf9 && dpkg-deb --extract libprotobuf9_*deb deps )

$(FRAMEWORK_OBJ): require-godep require-mesos require-protobuf
	env PATH=$(frmwk_gopath)/bin:$${PATH:+:$$PATH} \
		GOPATH=$(frmwk_gopath):$(k8s_gopath)$${GOPATH:+:$$GOPATH} \
		$(WITH_DEPS_CGO_FLAGS) \
	 godep get github.com/mesosphere/kubernetes-mesos/$(notdir $@)

install: $(OBJS)
	mkdir -p $(DESTDIR)
	/bin/cp -vpf -t $(DESTDIR) $(FRAMEWORK_OBJ)
	/bin/cp -vpf $(PROXY_OBJ) $(DESTDIR)/proxy

clean:
	rm -f *.deb
	rm -rf pkg src bin deps
